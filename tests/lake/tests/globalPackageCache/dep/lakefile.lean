import Lake
open Lake DSL

package dep

@[default_target]
lean_lib Dep

-- Not a default target, so it is not built when the package is shared
lean_lib Extra
