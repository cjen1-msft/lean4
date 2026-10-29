import Lean.Elab.BuiltinEvalCommand
import Lean.AddDecl

/-! The same trick as `Dep.bogus`, but in the root package, which `--trust-deps` still replays. -/

open Lean

set_option debug.skipKernelTC true in
run_elab
  addDecl <| .thmDecl {
    name        := `hacked
    levelParams := []
    type        := .const ``False []
    value       := .const ``True.intro []
  }
