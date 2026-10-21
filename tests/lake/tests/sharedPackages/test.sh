#!/usr/bin/env bash
source ../common.sh

./clean.sh
copy_to_work dep Root.lean
TEST_DIR="$(pwd)"
export LAKE_CACHE_DIR="$TEST_DIR/cache"
export LAKE_SHARED_PACKAGES=true
unset LAKE_PRIVATE_PACKAGES

pushd dep
init_git
rev1="$(git rev-parse HEAD)"
popd

make_workspace() {
  mkdir "$1"
  cp Root.lean "$1/"
  cat > "$1/lakefile.toml" <<EOF
name = "root"
defaultTargets = ["Root"]
[[lean_lib]]
name = "Root"
[[require]]
name = "dep"
git = "$TEST_DIR/dep"
rev = "$rev1"
EOF
}
make_workspace first
make_workspace second

pushd first
test_run build
source1="$(realpath .lake/packages/dep)"
output1="$("$LAKE" query @dep/+Dep:olean)"
test_exp -f "$output1"
test_exp -d .lake/config
test_exp -f .lake/build/lib/lean/Root.olean
test_exp "$("$LAKE" query @dep/configuredDir)" = "$source1"
popd

if [ "$OS" = Windows_NT ]; then
  # Windows without directory-link support keeps private checkouts.
  test_exp ! -L first/.lake/packages/dep
  exit 0
fi

test_exp -L first/.lake/packages/dep
test_exp -f first/.lake/dependency-builds/dep/.lake/post-update.txt
test_exp "$source1" != "$TEST_DIR/first/.lake/packages/dep"
test_exp ! -w "$source1/Dep.lean"
test_exp ! -w "$source1"
test_exp ! -e "$source1/.lake/build"
test_exp "$(git -C "$source1" rev-parse HEAD)" = "$rev1"

# A pinned manifest must load without fetching the source repository again.
cp first/lake-manifest.json second/
mv dep dep-offline
pushd second
test_run build @dep/Dep --no-build
test_run build
source2="$(realpath .lake/packages/dep)"
output2="$("$LAKE" query @dep/+Dep:olean)"
test_exp "$source1" = "$source2"
test_exp "$output1" != "$output2"
test_exp "$output1" -ef "$output2"
test_exp "$(stat_ch "$output2")" -gt 1
test_exp -f .lake/build/lib/lean/Root.olean

# An absent target cannot succeed under --no-build; a normal build is private.
test_status 3 build @dep/+Extra --no-build
test_run build @dep/+Extra
test_exp ! -e "$source1/.lake/build"
extra="$("$LAKE" query @dep/+Extra:olean)"
test_exp -f "$extra"
test_run build @dep/generated
generated="$("$LAKE" query @dep/generated)"
test_exp -f "$generated"
test_exp ! -e "$source1/.lake"
test_fails build @dep/sourceWrite
test_exp ! -e "$source1/generated-source.txt"

# Cache deletion and workspace cleaning must leave other workspaces usable.
echo metadata > "$LAKE_CACHE_DIR/cache-metadata"
ln -s "$source1" "$LAKE_CACHE_DIR/source-link"
test_run cache clean
test_exp ! -e "$LAKE_CACHE_DIR/cache-metadata"
test_exp ! -L "$LAKE_CACHE_DIR/source-link"
test_exp -f "$source1/Dep.lean"
test_exp -f "$output1"
test_run clean dep
test_exp ! -f "$output2"
popd
pushd first
test_run build --no-build
test_exp "$(git -C .lake/packages/dep rev-parse HEAD)" = "$rev1"
popd
mv dep-offline dep

# Repository subdirectories must not cause another source checkout.
make_workspace subdirectory
cat >> subdirectory/lakefile.toml <<EOF
[[require]]
name = "subdep"
git = "$TEST_DIR/dep"
rev = "$rev1"
subDir = "nested"
EOF
pushd subdirectory
test_run build @subdep/Nested
test_exp "$(realpath .lake/packages/subdep)" = "$source1"
test_exp ! -e "$source1/nested/.lake/build"
popd

# Updating switches the link, never the checkout used by another workspace.
pushd dep
echo 'def anotherValue : Nat := 3' >> Dep.lean
git add Dep.lean
git commit -m second
rev2="$(git rev-parse HEAD)"
popd
pushd second
sed_i "s/$rev1/$rev2/" lakefile.toml
test_run update
test_run build
test_exp "$(realpath .lake/packages/dep)" != "$source1"
test_exp "$(git -C .lake/packages/dep rev-parse HEAD)" = "$rev2"
test_exp "$(git -C "$source1" rev-parse HEAD)" = "$rev1"
popd

# An explicit private override detaches a shared dependency for editing.
pushd first
LAKE_PRIVATE_PACKAGES=dep test_run resolve-deps
test_exp ! -L .lake/packages/dep
test_exp -w .lake/packages/dep/Dep.lean
test_exp "$("$LAKE" query @dep/configuredDir)" = "$TEST_DIR/first/.lake/packages/dep"
echo 'def localEdit : Nat := 4' >> .lake/packages/dep/Dep.lean
test_run build
test_cmd grep -F localEdit .lake/packages/dep/Dep.lean
test_exp "$(git -C "$source1" rev-parse HEAD)" = "$rev1"
test_cmd_fails grep -F localEdit "$source1/Dep.lean"
test_run build @dep/sourceWrite
test_exp -f .lake/packages/dep/generated-source.txt
sed_i "s/$rev1/$rev2/" lakefile.toml
test_err "refusing to change revisions" update dep
test_exp "$(git -C .lake/packages/dep rev-parse HEAD)" = "$rev1"
test_cmd grep -F localEdit .lake/packages/dep/Dep.lean
sed_i "s/$rev2/$rev1/" lakefile.toml
popd

# Disabling the cache also detaches existing shared dependencies.
pushd second
LAKE_SHARED_PACKAGES=false test_run build
test_exp ! -L .lake/packages/dep
test_exp -w .lake/packages/dep/Dep.lean
popd

# Different build options must not reuse incompatible compiled modules.
make_workspace configured
cp first/lake-manifest.json configured/
pushd configured
test_run build @dep/Dep --no-build
echo 'options = { alternate = "" }' >> lakefile.toml
test_status 3 build -R @dep/Dep --no-build
test_run build @dep/Dep
# The toolchain hash participates in the native artifact trace too.
LEAN_GITHASH=shared-packages-other-toolchain test_status 3 build @dep/Dep --no-build
LEAN_GITHASH=shared-packages-other-toolchain test_run build @dep/Dep
test_run build @dep/Dep --no-build
popd

# Independent processes publish just one complete, read-only source entry.
make_workspace concurrent1
make_workspace concurrent2
export LAKE_CACHE_DIR="$TEST_DIR/concurrent-cache"
(
  cd concurrent1
  "$LAKE" build > build.log 2>&1
) &
pid1=$!
(
  cd concurrent2
  "$LAKE" build > build.log 2>&1
) &
pid2=$!
if ! wait "$pid1"; then cat concurrent1/build.log; exit 1; fi
if ! wait "$pid2"; then cat concurrent2/build.log; exit 1; fi
test_exp "$(realpath concurrent1/.lake/packages/dep)" = \
  "$(realpath concurrent2/.lake/packages/dep)"
test_exp -f concurrent1/.lake/build/lib/lean/Root.olean
test_exp -f concurrent2/.lake/build/lib/lean/Root.olean

# A separate cache root must not alias source storage in the first cache.
test_exp "$(realpath concurrent1/.lake/packages/dep)" != "$source1"

# Sharing is automatic when the flag is absent, and an empty cache path disables it.
make_workspace automatic
(
  unset LAKE_SHARED_PACKAGES
  cd automatic
  test_run build @dep/Dep
  test_exp -L .lake/packages/dep
  LAKE_CACHE_DIR= test_run resolve-deps
  test_exp ! -L .lake/packages/dep
  test_exp -w .lake/packages/dep/Dep.lean
)

# Recover a read-only staging directory left by an interrupted preparer.
source3="$(realpath concurrent1/.lake/packages/dep)"
repository="$(dirname "$(dirname "$source3")")"
mkdir -p "$repository/prepare/source"
echo incomplete > "$repository/prepare/source/Partial.lean"
chmod -R a-w "$repository/prepare"
test_exp ! -e "$repository/$rev2"
make_workspace recovered
sed_i "s/$rev1/$rev2/" recovered/lakefile.toml
pushd recovered
test_run build
test_exp "$(git -C .lake/packages/dep rev-parse HEAD)" = "$rev2"
test_exp ! -e .lake/packages/dep/Partial.lean
test_exp ! -e "$repository/prepare"
popd

# Replacing a shared Git dependency with a copied path must unlink only this reference.
make_workspace copied
pushd copied
test_run build @dep/Dep
sed_i '/git = /c path = "../dep"\ncopy = true' lakefile.toml
sed_i '/rev = /d' lakefile.toml
test_run update
test_run build @dep/Dep
test_exp ! -L .lake/packages/dep
test_exp -f "$source3/Dep.lean"
test_exp "$(git -C "$source3" rev-parse HEAD)" = "$rev1"
popd

# Standalone local dependencies retain their original source and build locations.
make_workspace local
sed_i '/git = /c path = "../dep"' local/lakefile.toml
sed_i '/rev = /d' local/lakefile.toml
pushd local
test_run build @dep/Dep
test_exp ! -e .lake/packages/dep
test_exp -f ../dep/.lake/build/lib/lean/Dep.olean
popd

# Parent-relative dependencies must keep their project-local sibling semantics.
cp -r dep external-dep
pushd external-dep
echo 'require sibling from "../sibling"' >> lakefile.lean
git add lakefile.lean
git commit -m 'require a workspace-relative sibling'
externalRev="$(git rev-parse HEAD)"
popd
make_workspace external
sed_i "s|$TEST_DIR/dep|$TEST_DIR/external-dep|" external/lakefile.toml
sed_i "s/$rev1/$externalRev/" external/lakefile.toml
mkdir -p external/.lake/packages/sibling
echo 'name = "sibling"' > external/.lake/packages/sibling/lakefile.toml
pushd external
test_run resolve-deps
test_exp ! -L .lake/packages/dep
test_exp -f .lake/packages/sibling/lakefile.toml
test_run build @dep/Dep
popd
