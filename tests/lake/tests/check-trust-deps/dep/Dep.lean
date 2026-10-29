import Lean.Elab.BuiltinEvalCommand
import Lean.AddDecl

/-!
A dependency with two flaws that only checking the dependency itself finds: `Dep.bogus` is ill-typed
but never reached the kernel, and `Dep.cheat` rests on `sorry`. Without `--trust-deps`, `lake check`
re-checks everything in scope, so this imports only what `run_elab` and `addDecl` need.
-/

open Lean

set_option debug.skipKernelTC true in
run_elab
  addDecl <| .thmDecl {
    name        := `Dep.bogus
    levelParams := []
    type        := .const ``False []
    value       := .const ``True.intro []
  }

theorem Dep.cheat : False := sorry
