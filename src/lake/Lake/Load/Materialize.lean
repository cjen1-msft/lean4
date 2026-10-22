/-
Copyright (c) 2017 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Gabriel Ebner, Sebastian Ullrich, Mac Malone
-/
module

prelude
public import Lake.Config.Env
public import Lake.Load.Manifest
public import Lake.Config.Package
import Lake.Util.Git
import Lake.Util.IO
import Lake.Reservoir
import Init.Data.Random

set_option doc.verso true

open System Lean

/-! # Dependency Materialization
Definitions to "materialize" a package dependency.
That is, clone a local copy of a Git dependency at a specific revision
or resolve a local path dependency.
-/

namespace Lake

/--
Materialize the Git repository from {lean}`url` into {lean}`repo` at {lean}`rev?`.

If no revision is specified (i.e., {lean}`rev? = none`), the latest {lit}`master` is used.

If the repository is already at {lean}`rev?`, return early with no fetch.
Otherwise, fetch the revision {lean}`rev?` from the remote {lean}`url` and check it out.
If no local repository exists, initialize a new one.
-/
def materializeGitRepo
  (name : String) (repo : GitRepo) (url : String) (rev? : Option GitRev)
  (filter := true)
: LoggerIO Unit := do
  let rev := rev?.getD Git.upstreamBranch
  let remote := Git.defaultRemote
  let url ← resolveUrl url
  -- # Setup repository
  if (← repo.gitExists) then
    -- The URL may be updated even without a `lake update`.
    -- This ensures a package's `remoteUrl?` reflects Git's by default.
    if let some oldUrl ← repo.getRemoteUrl? remote then
      unless oldUrl = url do
        logInfo s!"{name}: remote URL changed\
          \n  old: {oldUrl}\
          \n  new: {url}"
        repo.setRemoteUrl remote url
    else
      repo.addRemote remote url
    -- Skip fetch if already on revision. Avoids errors when offline.
    -- https://github.com/leanprover/lake/issues/104
    if (← repo.getHeadRevision?) = some rev then
      checkDiff
      return
    if rev.isFullSha1 then
      -- If missing, `findCommit?` will fetch to try and find it (on a partial clone).
      -- This could be avoided with `--no-lazy-fetch`, but that requires Git 2.45+.
      -- Fetch will happen anyway next, so the higher minimum is not worth it.
      if (← repo.findCommit? rev).isSome then
        -- Skip revision fetch if the exact commit is already available.
        -- May still fetch objects due to the partial clone.
        checkout rev
        return
  else
    logInfo s!"{name}: materializing new dependency"
    IO.FS.createDirAll repo.dir
    repo.quietInit
    repo.addRemote remote url
  -- # New revision
  logInfo s!"{name}: fetching revision '{rev}' from {url}"
  let some rev ← repo.fetchRevision? remote rev filter
    | error s!"{name}: failed to fetch the package revision\
      \n  {rev}\
      \nfrom the Git repository at\
      \n  {url}"
  if (← repo.getHeadRevision?) = some rev then -- e.g., new tag = old rev
    checkDiff
    return
  checkout rev
  -- Cleanup unreachable references and objects to prevent excessive repository growth
  repo.pruneRemote remote
  repo.gcAuto
where
  @[inline] resolveUrl url := do
    if (← FilePath.pathExists url) then
      let some path ← resolvePath? url
        | error s!"{name}: failed to resolve path:\n  {url}"
      return path.toString
    else
      return url
  @[inline] checkout rev := do
    if (← repo.getHeadRevision?).isSome && (← repo.hasDiff) then
      error s!"{name}: refusing to change revisions in a repository with local changes:\n  {repo.dir}"
    logInfo s!"{name}: checking out revision '{rev}'"
    repo.checkoutDetach rev
    -- Remove untracked files from tracked folders in the package.
    -- This helps ensure reproducible behavior by removing leftovers.
    -- For example, Lake will trust leftover `.hash` files unconditionally,
    -- so stale ones from the previous revision cause incorrect trace computations.
    repo.clean
    checkDiff
  @[inline] checkDiff := do
    if (← repo.hasDiff) then
      logWarning s!"{name}: repository has local changes:\n  {repo.dir}"

private structure SharedSource where
  version : Nat := 1
  url : String
  rev : GitRev
  deriving FromJson, ToJson

private def readSharedSource? (entry : FilePath) : IO (Option SharedSource) := do
  let file := entry / "lake-package.json"
  let contents ← try IO.FS.readFile file catch
    | .noFileOrDirectory .. => return none
    | e => throw e
  match Json.parse contents >>= fromJson? with
  | .ok source =>
    unless source.version == 1 do
      throw <| IO.userError s!"{file}: unsupported shared package version"
    return some source
  | .error e => throw <| IO.userError s!"{file}: invalid shared package metadata: {e}"

/-- Find the shared repository containing a package, including repository subdirectories. -/
private partial def sharedSourceRoot? (dir : FilePath) : IO (Option FilePath) := do
  let some parent := dir.parent | return none
  if dir.fileName == some "source" then
    if (← readSharedSource? parent).isSome then
      return some dir
  if parent == dir then return none
  sharedSourceRoot? parent

private def sharedLink? (path : FilePath) : IO (Option FilePath) := do
  let metadata ← try path.symlinkMetadata catch
    | .noFileOrDirectory .. => return none
    | e => throw e
  unless metadata.type == .symlink do return none
  sharedSourceRoot? (← IO.FS.realPath path)

private def setSourceWritable (path : FilePath) (writable : Bool) : LogIO Unit :=
  -- Recursive chmod preserves executable bits and does not follow interior symlinks.
  proc {cmd := "chmod", args := #["-R", if writable then "u+w" else "a-w", path.toString]}
    (quiet := true)

private def linkSharedSource (source link : FilePath) : LogIO Unit := do
  createParentDirs link
  proc {cmd := "ln", args := #["-s", source.toString, link.toString]} (quiet := true)

private def replaceSharedLink (source link : FilePath) : LogIO Unit := do
  let temp := link.addExtension s!"lake-link-{← IO.rand 0 0xffffffff}"
  linkSharedSource source temp
  try
    IO.FS.rename temp link
  finally
    removeFileIfExists temp

private def detachSharedSource (name : String) (repo : GitRepo) (source : FilePath) : LogIO Unit := do
  logInfo s!"{name}: detaching shared dependency for private use"
  let temp := repo.dir.addExtension s!"lake-private-{← IO.rand 0 0xffffffff}"
  IO.FS.createDir temp
  let privateRepo := GitRepo.mk temp
  try
    privateRepo.clone source.toString
    let url ← (GitRepo.mk source).getRemoteUrl?
    if let some url := url then
      privateRepo.setRemoteUrl Git.defaultRemote url
    IO.FS.removeFile repo.dir
    let renamed ← IO.FS.rename temp repo.dir |>.toBaseIO
    if let .error e := renamed then
      linkSharedSource source repo.dir
      error s!"{name}: failed to detach shared dependency: {e}"
  finally
    removeDirAllIfExists temp

/--
Materialize a Git dependency without modifying a published shared repository.
Existing private repositories stay private, including repositories with local edits.
-/
private def materializeDependencyGit
  (name : String) (repo : GitRepo) (env : Env) (url : String) (rev? : Option GitRev)
: LoggerIO Unit := do
  let shared? ← sharedLink? repo.dir
  let cache? := if env.sharedPackages && !env.privatePackages.contains name then env.lakeCache? else none
  -- There is no native directory-link primitive on Windows yet.
  if System.Platform.isWindows || cache?.isNone then
    if let some source := shared? then detachSharedSource name repo source
    materializeGitRepo name repo url rev?
    return
  if shared?.isNone && (← repo.dir.pathExists) then
    materializeGitRepo name repo url rev?
    return
  let some cache := cache? | unreachable!
  let url ← if (← FilePath.pathExists url) then
    (·.toString) <$> IO.FS.realPath url
  else
    pure url
  let repository := cache.packagesDir / (Hash.ofString url).toString
  IO.FS.createDirAll repository
  let repository ← IO.FS.realPath repository
  let lockFile := repository / "lock"
  discard <| IO.FS.Handle.mk lockFile .append
  let lock ← IO.FS.Handle.mk lockFile .readWrite
  lock.lock
  try
    let source ← prepare repository url
    if let some current := shared? then
      if current == source then return
    logVerbose s!"{name}: using read-only shared sources at {source}; \
      set LAKE_PRIVATE_PACKAGES={name} for a private checkout"
    replaceSharedLink source repo.dir
  finally
    lock.unlock
where
  validate entry url rev := do
    let some source ← readSharedSource? entry
      | error s!"{entry}: incomplete shared package; refusing to use it"
    unless source.url == url && source.rev == rev do
      error s!"{entry}: shared package identity mismatch"
    let path := entry / "source"
    unless (← (GitRepo.mk path).getHeadRevision?) == some rev do
      error s!"{entry}: shared package revision mismatch"
    return path
  prepare repository url : LoggerIO FilePath := do
    if let some rev := rev? then
      if rev.isFullSha1 then
        let entry := repository / rev
        if (← entry.pathExists) then return ← validate entry url rev
    let staging := repository / "prepare"
    if (← staging.pathExists) then
      setSourceWritable staging true
      removeDirAllIfExists staging
    try
      let repo := GitRepo.mk (staging / "source")
      materializeGitRepo name repo url rev? (filter := false)
      let rev ← repo.getHeadRevision
      unless rev.isFullSha1 do
        error s!"{name}: expected a resolved Git commit, got '{rev}'"
      let entry := repository / rev
      if (← entry.pathExists) then return ← validate entry url rev
      IO.FS.writeFile (staging / "lake-package.json") <|
        toJson ({url, rev} : SharedSource) |>.compress
      setSourceWritable staging false
      IO.FS.rename staging entry
      return entry / "source"
    finally
      if (← staging.pathExists) then
        setSourceWritable staging true
        removeDirAllIfExists staging

public structure MaterializedDep where
  /-- Absolute path to the materialized package. -/
  pkgDir : FilePath
  /-- Path to the materialized package relative to the workspace's root directory. -/
  relPkgDir : FilePath
  /--
  URL for the materialized package.
  Used as the endpoint from which to fetch cloud releases for the package.
  -/
  remoteUrl : String
  /-- The manifest for the dependency or the error produced when trying to load it. -/
  manifest? : Except IO.Error Manifest
  /-- The manifest entry for the dependency. -/
  manifestEntry : PackageEntry
  /-- Whether the package's sources belong to an immutable shared repository. -/
  shared : Bool := false
  deriving Inhabited

namespace MaterializedDep

/-- **For internal use only.** Whether relative path dependencies escape the shared repository. -/
public def hasExternalPathDeps (self : MaterializedDep) (deps : Array Dependency) : IO Bool := do
  unless self.shared do return false
  let root? ← sharedSourceRoot? self.pkgDir
  for dep in deps do
    if let some (.path dir _) := dep.src? then
      unless dir.isAbsolute do
        let some path ← resolvePath? (self.pkgDir / dir) | return true
        unless (← sharedSourceRoot? path) == root? do return true
  return false

@[inline] public def name (self : MaterializedDep) : Name :=
  self.manifestEntry.name

@[inline] public def prettyName (self : MaterializedDep) : String :=
  self.manifestEntry.name.toString (escape := false)

@[inline] public def scope (self : MaterializedDep) : String :=
  self.manifestEntry.scope

/-- Path to the dependency's manfiest file (relative to {lean}`relPkgDir`). -/
@[inline] public def relManifestFile? (self : MaterializedDep) : Option FilePath :=
  self.manifestEntry.manifestFile?

/-- Path to the dependency's manfiest file (relative to {lean}`relPkgDir`). -/
@[inline] public def relManifestFile (self : MaterializedDep) : FilePath :=
  self.relManifestFile?.getD defaultManifestFile

/-- Absolute path to the dependency's manfiest file. -/
@[inline] public def manifestFile (self : MaterializedDep) : FilePath :=
  self.pkgDir / self.relManifestFile

/-- Path to the dependency's configuration file (relative to {lean}`relPkgDir`). -/
@[inline] public def relConfigFile (self : MaterializedDep) : FilePath :=
  self.manifestEntry.configFile

/-- Absolute path to the dependency's configuration file. -/
@[inline] public def configFile (self : MaterializedDep) : FilePath :=
  self.pkgDir / self.relConfigFile

public def fixedToolchain (self : MaterializedDep) : Bool :=
  match self.manifest? with
  | .ok manifest => manifest.fixedToolchain
  | _ => false

/-- **For internal use only.** Detach a materialized Git dependency without changing its pin. -/
public def detach (self : MaterializedDep) (wsDir relPkgsDir : FilePath) : LogIO MaterializedDep := do
  let repo := GitRepo.mk (wsDir / relPkgsDir / self.manifestEntry.dirName)
  let some source ← sharedLink? repo.dir
    | error s!"{self.prettyName}: shared source link not found: {repo.dir}"
  detachSharedSource self.prettyName repo source
  let path := wsDir / self.relPkgDir
  let some pkgDir ← resolvePath? path
    | error s!"{self.prettyName}: detached package directory not found: {path}"
  return {self with pkgDir, shared := false}

end MaterializedDep

def pkgNotIndexed (dep : Dependency) : String :=
  let (leanVer, tomlVer) :=
    match dep.version with
    | .none => ("", "")
    | .git rev => (s!" @ {repr rev}", s!"\n    rev = {repr rev}")
    | .ver ver => (s!" @ {repr ver.toString}", s!"\n    version = {repr ver.toString}")
s!"{dep.fullName}: package not found on Reservoir.

  If the package is on GitHub, you can add a Git source. For example:

    require ...
      from git \"https://github.com/{dep.scope}/{dep.reservoirName}\"{leanVer}

  or, if using TOML:

    [[require]]
    git = \"https://github.com/{dep.scope}/{dep.reservoirName}\"{tomlVer}
    ...
"

@[inline] def mkPath
  (wsDir relPkgsDir relSrc : FilePath) (dirName : String) (copy update : Bool)
: IO FilePath := do
  if copy then
    let relDst := relPkgsDir / dirName
    let dst := wsDir / relDst
    if update then
      removeDirAllIfExists dst
    else if (← dst.pathExists) then
      return relDst
    let src := wsDir / relSrc
    copyDirAll src dst
    return relDst
  else
    return relSrc

/--
Materializes a configuration dependency.
For Git dependencies, updates it to the latest input revision.
-/
public def Dependency.materialize
  (dep : Dependency) (inherited : Bool)
  (lakeEnv : Env) (wsDir relPkgsDir relParentDir : FilePath)
: LoggerIO MaterializedDep := do
  if let some src := dep.src? then
    match src with
    | .path dir copy =>
      let relSrc := relParentDir / dir
      let relPath ← mkPath wsDir relPkgsDir relSrc dep.dirName copy (update := true)
      mkDep dep.prettyName (relPath) "" (.path relSrc copy)
    | .git url inputRev? subDir? => do
      let repoUrl := Git.filterUrl? url |>.getD ""
      materializeGit dep.prettyName (relPkgsDir / dep.dirName) url repoUrl inputRev? subDir?
  else
    if dep.scope.isEmpty then
      error s!"{dep.prettyName}: ill-formed dependency: \
        dependency is missing a source and is missing a scope for Reservoir"
    let pkg ← id do
      match (← Reservoir.fetchPkg? lakeEnv dep.scope dep.reservoirName |>.toLogT) with
      | .ok (some pkg) => return pkg
      | .ok none => error <| pkgNotIndexed dep
      | .error .. => error s!"{dep.fullName}: could not materialize package: \
        this may be a transient error or a bug in Lake or Reservoir"
    let relPkgDir := relPkgsDir / pkg.name
    match pkg.gitSrc? with
    | some (.git _ url githubUrl? defaultBranch? subDir?) =>
      let rev? ← id do
        match dep.version with
        | .none => defaultBranch?
        | .git rev => some rev
        | .ver ver =>
          match (← Reservoir.fetchPkgVersions lakeEnv dep.scope dep.reservoirName |>.toLogT) with
          | .ok vers =>
            if let some ver := vers.find? (ver.test ·.version) then
              logInfo s!"{dep.fullName}: using version `{ver.version}` at revision `{ver.revision}`"
              return ver.revision
            else
              error s!"{dep.fullName}: version `{ver}` not found on Reservoir"
          | .error .. => error s!"{dep.fullName}: could not fetch package versions: \
            this may be a transient error or a bug in Lake or Reservoir"
      materializeGit pkg.fullName relPkgDir url (githubUrl?.getD "") rev? subDir?
    | _ => error s!"{pkg.fullName}: Git source not found on Reservoir"
where
  materializeGit name relPkgDir gitUrl remoteUrl inputRev? subDir? : LoggerIO MaterializedDep := do
    let gitDir := wsDir / relPkgDir
    let repo := GitRepo.mk gitDir
    let gitUrl := lakeEnv.pkgUrlMap.find? dep.name |>.getD gitUrl
    materializeDependencyGit dep.prettyName repo lakeEnv gitUrl inputRev?
    let rev ← repo.getHeadRevision
    let relPkgDir := if let some subDir := subDir? then relPkgDir / subDir else relPkgDir
    mkDep name relPkgDir remoteUrl <| .git gitUrl rev inputRev? subDir?
  @[inline] mkDep name relPkgDir remoteUrl src : LoggerIO MaterializedDep := do
    let pkgDir := wsDir / relPkgDir
    let some pkgDir ← resolvePath? pkgDir
      | error s!"{name}: package directory not found: {pkgDir}"
    return {
      pkgDir, relPkgDir, remoteUrl,
      manifest? :=  ← Manifest.load (pkgDir / defaultManifestFile) |>.toBaseIO
      manifestEntry := {name := dep.name, scope := dep.scope, inherited, src}
      shared := (← sharedSourceRoot? pkgDir).isSome
    }

/--
Materializes a manifest package entry, cloning and/or checking it out as necessary.
-/
public def PackageEntry.materialize
  (manifestEntry : PackageEntry)
  (lakeEnv : Env) (wsDir relPkgsDir : FilePath)
: LoggerIO MaterializedDep := do
  match manifestEntry.src with
  | .path (dir := relSrc) (copy := copy) .. =>
    let relPath ← mkPath wsDir relPkgsDir relSrc manifestEntry.dirName copy (update := false)
    mkDep relPath ""
  | .git (url := url) (rev := rev) (subDir? := subDir?) .. =>
    let relGitDir := relPkgsDir / manifestEntry.dirName
    let repo := GitRepo.mk (wsDir / relGitDir)
    let url := lakeEnv.pkgUrlMap.getD manifestEntry.name url
    materializeDependencyGit manifestEntry.prettyName repo lakeEnv url rev
    let relPkgDir := match subDir? with | .some subDir => relGitDir / subDir | .none => relGitDir
    mkDep relPkgDir (Git.filterUrl? url |>.getD "")
where
  @[inline] mkDep relPkgDir remoteUrl : LoggerIO MaterializedDep := do
    let pkgDir := wsDir / relPkgDir
    let some pkgDir ← resolvePath? pkgDir
      | error s!"{manifestEntry.prettyName}: package directory not found: {pkgDir}"
    let manifest? ← id do
      if let some manifestFile := manifestEntry.manifestFile? then
        Manifest.load (pkgDir / manifestFile) |>.toBaseIO
      else
        return .error (.noFileOrDirectory "" 0 "")
    return {
      pkgDir, relPkgDir, remoteUrl, manifest?, manifestEntry
      shared := (← sharedSourceRoot? pkgDir).isSome
    }
