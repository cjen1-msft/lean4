/-
Copyright (c) 2026 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Chris Jensen
-/
module

prelude
public import Lake.Config.Workspace
public import Lake.Build.Context
import Lake.Config.PackageCache
import Lake.Load.Manifest
import Lake.Load.Materialize
import Lake.Build.Run
import Lake.Build.Trace
import Lake.CLI.Build
import Lake.Util.Git
import Lake.Util.IO

/-! # `lake cache share`

Publishes built dependency packages to the global package cache (see `Lake.Config.PackageCache`)
and links the workspace's `.lake/packages/<name>` to them.
-/

open System Lean

namespace Lake

/-- Moves the directory `dir` to `dst`, copying it if they are on different file systems. -/
def moveDir (dir dst : FilePath) : IO Unit := do
  try
    IO.FS.rename dir dst
  catch _ =>
    runCmd "cp" #["-pR", dir.toString, dst.toString]
    removeDirAllIfExists dir

/-- Deletes a (possibly read-only) directory left over from an interrupted operation. -/
def removeStaleDir (dir : FilePath) : IO Unit := do
  if (← dir.isDir) then
    setDirWritable dir true
    removeDirAllIfExists dir

/--
Publishes the private package directory `dir` as the read-only cache entry `entryDir`.
The entry is staged, made read-only, and then atomically renamed into place.
If another process published the entry first, this one is discarded.
-/
def publishEntry (dir entryDir : FilePath) : IO Unit := do
  let cacheDir := entryDir.parent.getD "."
  IO.FS.createDirAll cacheDir
  -- Loading a package expects its `.lake` directory to exist
  IO.FS.createDirAll (dir / ".lake")
  let staging := cacheDir / s!".staging-{entryDir.fileName.getD ""}-{← IO.Process.getPID}"
  removeStaleDir staging
  moveDir dir staging
  setDirWritable staging false
  try
    IO.FS.rename staging entryDir
  catch e =>
    setDirWritable staging true
    if (← entryDir.isDir) then
      removeDirAllIfExists staging
    else
      moveDir staging dir
      throw e

/-- Replaces the private package directory `dir` with a link to the cache entry `entryDir`. -/
def linkEntry (dir entryDir : FilePath) : IO Unit := do
  if (← dir.pathExists) then
    let old := dir.parent.getD "." / s!".{dir.fileName.getD "package"}.unshared"
    removeStaleDir old
    IO.FS.rename dir old
    try
      createDirSymlink entryDir dir
    catch e =>
      IO.FS.rename old dir
      throw e
    removeDirAllIfExists old
  else
    createDirSymlink entryDir dir

/-- The state of `lake cache share`. -/
structure ShareState where
  /-- The cache entry name of each visited package (or `none` if it is kept private). -/
  entries : NameMap (Option String) := {}
  /-- Packages to share and their cache entries, in dependency order. -/
  shared : Array (Package × FilePath) := #[]

/--
Computes the name of the cache entry for the dependency `pkg`
given those of its dependencies (`depEntries`), or `none` if `pkg` must be kept private.
-/
def computeEntryName?
  (ws : Workspace) (cacheDir : FilePath) (manifestEntries : NameMap PackageEntry)
  (pkg : Package) (depEntries : Array (Option String))
: LoggerIO (Option String) := do
  let keepPrivate (why : String) : LoggerIO (Option String) := do
    logInfo s!"{pkg.prettyName}: kept private ({why})"
    return none
  if pkg.wsIdx == 0 then
    return none
  if (← isCachedDir cacheDir pkg.dir) then
    return (← IO.FS.realPath pkg.dir).fileName
  let some entry := manifestEntries.find? pkg.baseName
    | keepPrivate "not in the workspace manifest"
  let .git url rev _ none := entry.src
    | keepPrivate "only Git dependencies without a subdirectory can be shared"
  unless pkg.dir == ws.pkgsDir / entry.dirName do
    return ← keepPrivate "not in the workspace's packages directory"
  if depEntries.any (·.isNone) then
    return ← keepPrivate "a dependency is kept private"
  let repo := GitRepo.mk pkg.dir
  unless (← repo.getHeadRevision?) == some rev do
    return ← keepPrivate "not checked out at the revision in the manifest"
  if (← repo.hasDiff) then
    return ← keepPrivate "the repository has local changes"
  let url ← resolveGitUrl (ws.lakeEnv.pkgUrlMap.getD entry.name url)
  let url := url.dropSuffix "/" |>.copy.dropSuffix ".git" |>.copy
  let opts := ws.packages.foldl (init := #[]) fun opts p =>
    p.depConfigs.foldl (init := opts) fun opts dep =>
      if dep.name == pkg.baseName then
        dep.opts.foldl (init := opts) fun opts k v => opts.push s!"{k}={v}"
      else opts
  let opts := opts.qsort (· < ·) |>.toList.eraseDups
  let depEntries := depEntries.filterMap id |>.qsort (· < ·) |>.toList.eraseDups
  let key := "\n".intercalate <|
    ["lake-package-cache-v1", pkg.baseName.toString, url, rev,
      ws.lakeEnv.leanGithash, Platform.target] ++ opts ++ depEntries
  return some s!"{entry.dirName}-{(Hash.ofString key).hex}"

/-- Determines which packages to share (dependencies first). -/
partial def visitPackage
  (ws : Workspace) (cacheDir : FilePath) (manifestEntries : NameMap PackageEntry) (pkg : Package)
: StateT ShareState LoggerIO (Option String) := do
  if let some entry? := (← get).entries.find? pkg.keyName then
    return entry?
  let depEntries ← pkg.depPkgs.mapM (visitPackage ws cacheDir manifestEntries)
  let entry? ← computeEntryName? ws cacheDir manifestEntries pkg depEntries
  modify fun s => {s with entries := s.entries.insert pkg.keyName entry?}
  if let some entry := entry? then
    unless (← ws.lakeEnv.isCachedDir pkg.dir) do
      modify fun s => {s with shared := s.shared.push (pkg, cacheDir / entry)}
  return entry?

/--
Shares the dependency packages `pkgs` (and their dependencies) through the global package cache.

For each shareable package, if its cache entry does not yet exist, Lake builds the package's
default targets in the workspace and publishes the package directory (sources and build outputs)
as a new read-only cache entry. The package's directory in the workspace is then replaced by a
symbolic link to the entry.

Only clean checkouts of Git dependencies at their manifest revision whose dependencies are also
shareable are shared. Other packages are kept private to the workspace.
-/
public def Workspace.sharePackages
  (ws : Workspace) (pkgs : Array Package) (cfg : BuildConfig)
: LoggerIO PUnit := do
  if Platform.isWindows then
    error "the global package cache is not supported on Windows"
  let some cacheDir := ws.lakeEnv.packageCacheDir?
    | error "the global package cache requires a Lake cache directory (e.g., set `LAKE_CACHE_DIR`)"
  let manifest ← Manifest.load ws.manifestFile
  let overrides ← Manifest.tryLoadEntries ws.packageOverridesFile
  let manifestEntries := (manifest.packages ++ overrides).foldl (init := {})
    fun m entry => m.insert entry.name entry
  let (_, s) ← (pkgs.forM (discard <| visitPackage ws cacheDir manifestEntries ·)).run {}
  let mut existing := #[]
  let mut missing := #[]
  for shared@(_, entryDir) in s.shared do
    if (← entryDir.isDir) then
      existing := existing.push shared
    else
      missing := missing.push shared
  for (pkg, entryDir) in existing do
    linkEntry pkg.dir entryDir
    logInfo s!"{pkg.prettyName}: linked to {entryDir}"
  if missing.isEmpty then
    return
  let specs ← missing.flatMapM fun (pkg, _) => do
    match resolveDefaultPackageTarget ws pkg with
    | .ok specs => pure specs
    | .error e => error (toString e)
  -- Build outputs must be in the package directory (not only in the Lake artifact cache)
  let ws := {ws with lakeEnv.restoreAllArtifacts? := some true}
  ws.runBuild (buildSpecs specs) cfg
  for (pkg, entryDir) in missing do
    publishEntry pkg.dir entryDir
    linkEntry pkg.dir entryDir
    logInfo s!"{pkg.prettyName}: published to {entryDir}"
