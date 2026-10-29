import Dep

/-! Uses `Dep.bogus` but not `Dep.cheat`, so it is accepted exactly when `Dep` is trusted. -/

theorem good : False := Dep.bogus
