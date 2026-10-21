import Lake
open Lake DSL

/-! Dependency configuration used to test build-option cache invalidation. -/

package dep where
  moreLeanArgs := if get_config? alternate |>.isSome then #["-DautoImplicit=false"] else #[]

@[default_target]
lean_lib Dep

lean_lib Extra

target configuredDir _pkg : System.FilePath := pure (Job.pure __dir__)

target generated pkg : System.FilePath := Job.async do
  let output := pkg.buildDir / "generated.txt"
  createParentDirs output
  IO.FS.writeFile output "private generated output"
  return output

target sourceWrite pkg : Unit := Job.async do
  IO.FS.writeFile (pkg.dir / "generated-source.txt") "requires private sources"

post_update pkg do
  let output := pkg.lakeDir / "post-update.txt"
  createParentDirs output
  IO.FS.writeFile output "private post-update output"
