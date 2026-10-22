module

import Lake

/-! Test directory cleanup, including root symlinks and missing paths. -/

open Lake DSL

package test

script cleanup (args) do
  args.forM fun path => Lake.removeDirAllIfExists path
  return 0
