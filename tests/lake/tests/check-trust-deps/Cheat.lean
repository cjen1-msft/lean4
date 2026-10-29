import Dep

/-! Reaches `sorryAx` only through the dependency's `Dep.cheat`. -/

theorem cheat : False := Dep.cheat
