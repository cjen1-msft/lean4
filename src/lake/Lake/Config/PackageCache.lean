/-
Copyright (c) 2026 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Chris Jensen
-/
module

prelude
public import Lake.Config.Env
public import Lake.Util.Log
import Lake.Util.IO
import Lake.Util.Proc
import Std.Sync.Mutex

/-! # Global Package Cache

Opt-in sharing of built dependency packages between workspaces (see `lake cache share`).

A shared package is stored once, read-only, in the `packages` directory of the Lake cache.
A workspace uses it by replacing `.lake/packages/<name>` with a symbolic link to the entry.
Such a link is the only marker of a cached package: Lake never writes through it, and it
unlinks (rather than deleting through) it when the package is cleaned, updated, or rebuilt.
-/

open System

namespace Lake

/-- The directory of the global package cache within the Lake cache. -/
@[inline] public def Cache.packagesDir (cache : Cache) : FilePath :=
  cache.dir / "packages"

/-- The global package cache directory, if Lake has a cache directory. -/
@[inline] public def Env.packageCacheDir? (env : Env) : Option FilePath :=
  env.lakeCache?.map (·.packagesDir)

/-- Whether `path` is strictly inside `dir`, comparing path components. -/
def isStrictlyWithin (dir path : FilePath) : Bool :=
  let dir := dir.normalize.components.filter (!·.isEmpty)
  let path := path.normalize.components.filter (!·.isEmpty)
  dir.length < path.length && path.take dir.length == dir

/--
Returns whether `path` is a symbolic link into the global package cache `cacheDir`
(i.e., a dependency package linked from the cache). Other paths, including symbolic
links elsewhere, are not cached directories.
-/
public def isCachedDir (cacheDir path : FilePath) : BaseIO Bool := do
  let .ok mdata ← path.symlinkMetadata.toBaseIO | return false
  unless mdata.type == .symlink do return false
  let target ← id do
    if let .ok target ← (IO.FS.realPath path).toBaseIO then
      return target
    -- The cache entry may have been deleted; inspect the link itself.
    let some target ← captureProc? {cmd := "readlink", args := #[path.toString]}
      | return ""
    let target : FilePath := target
    return if target.isAbsolute then target else (path.parent.getD ".") / target
  if target.toString.isEmpty then return false
  let realCacheDir ← resolvePath cacheDir
  return isStrictlyWithin cacheDir target ||
    (!realCacheDir.toString.isEmpty && isStrictlyWithin realCacheDir target)

/-- Returns whether `path` is a symbolic link into the global package cache of `env`. -/
public def Env.isCachedDir (env : Env) (path : FilePath) : BaseIO Bool := do
  if let some cacheDir := env.packageCacheDir? then
    Lake.isCachedDir cacheDir path
  else
    return false

/-- Runs an external command, throwing an `IO` error if it fails. -/
public def runCmd (cmd : String) (args : Array String) : IO Unit := do
  let out ← IO.Process.output {cmd, args}
  unless out.exitCode == 0 do
    throw <| IO.userError s!"'{cmd} {" ".intercalate args.toList}' failed: {out.stderr.trimAscii}"

/-- Recursively makes `dir` read-only (or writable by its owner, if `writable := true`). -/
public def setDirWritable (dir : FilePath) (writable : Bool) : IO Unit :=
  runCmd "chmod" #["-R", if writable then "u+w" else "a-w", dir.toString]

/-- Creates a symbolic link at `link` pointing to `target`. -/
public def createDirSymlink (target link : FilePath) : IO Unit :=
  runCmd "ln" #["-s", target.toString, link.toString]

/-- Serializes package detachment within this process (so each package is detached once). -/
builtin_initialize detachMutex : Std.BaseMutex ← Std.BaseMutex.new

/--
Replaces the symbolic link `dir` with a private, writable copy of the cache entry it points to.
Returns `false` if `dir` is no longer a link (e.g., it was already detached by another job).
-/
def detachCore (dir : FilePath) : IO Bool := do
  unless (← dir.symlinkMetadata).type == .symlink do return false
  let entry ← IO.FS.realPath dir
  let tmp := (dir.parent.getD ".") / s!".{dir.fileName.getD "package"}.detach"
  if (← tmp.pathExists) then
    setDirWritable tmp true
    removeDirAllIfExists tmp
  runCmd "cp" #["-pR", entry.toString, tmp.toString]
  setDirWritable tmp true
  IO.FS.removeFile dir -- unlinks the symbolic link
  IO.FS.rename tmp dir
  return true

/--
Makes the dependency package at `dir`, which is linked from the global package cache,
private to the workspace so that `target` can be built. Lake never writes into a cache entry,
so this copies the entry to `dir` (keeping its prepared build outputs) and leaves the entry
untouched. Does nothing if `dir` has already been made private.
-/
public def detachCachedPackage (pkgName : String) (dir : FilePath) (target : String) : LogIO Unit := do
  detachMutex.lock
  let result ← (detachCore dir).toBaseIO
  detachMutex.unlock
  match result with
  | .ok true =>
    logWarning s!"{pkgName}: caching not supported for built outputs ({target}); \
      made the package private and rebuilding it locally"
  | .ok false => pure ()
  | .error e => error s!"{pkgName}: failed to make cached package private: {e}"
