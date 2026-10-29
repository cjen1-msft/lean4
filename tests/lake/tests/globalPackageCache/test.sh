#!/usr/bin/env bash
source ../common.sh

# Tests the opt-in global package cache (`lake cache share`)

./clean.sh
copy_to_work dep Root.lean
TEST_DIR="$(pwd)"
export LAKE_CACHE_DIR="$TEST_DIR/cache"
ENTRIES="$LAKE_CACHE_DIR/packages"

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
make_workspace third

# Without `lake cache share`, dependencies are private as before
pushd first
test_run build
test_exp -d .lake/packages/dep
test_exp ! -L .lake/packages/dep
test_exp -f .lake/packages/dep/.lake/build/lib/lean/Dep.olean
test_exp ! -e "$ENTRIES"
popd

if [ "$OS" = Windows_NT ]; then
  pushd first
  test_err "not supported on Windows" cache share
  test_exp ! -L .lake/packages/dep
  popd
  exit 0
fi

# Sharing publishes the built package as a read-only cache entry and links to it
pushd first
test_out "published to" cache share
test_exp -L .lake/packages/dep
entry="$(realpath .lake/packages/dep)"
test_exp "$(dirname "$entry")" = "$(realpath "$ENTRIES")"
test_exp -f "$entry/Dep.lean"
test_exp -f "$entry/.lake/build/lib/lean/Dep.olean"
test_run build --no-build
popd

# The entry must never be modified after it is published
(cd "$entry" && find . -print | sort) > entry.files
touch entry.stamp
check_entry() {
  echo "# check that the cache entry is unchanged"
  (cd "$entry" && find . -print | sort) > entry.now
  test_cmd diff entry.files entry.now
  test_exp -z "$(find "$entry" -newer entry.stamp -print)"
  test_exp -z "$(find "$entry" -perm -u=w -print)"
}
check_entry

# Another workspace with the same dependency links to the same entry
# and builds without rebuilding (or writing to) the dependency
pushd second
test_out "linked to" cache share
test_exp -L .lake/packages/dep
test_exp "$(realpath .lake/packages/dep)" = "$entry"
test_run build @dep/Dep --no-build
test_not_out "caching not supported" build
test_exp -f .lake/build/lib/lean/Root.olean
popd
check_entry

# `lake clean` unlinks the package (rather than cleaning the entry)
pushd second
test_run clean
test_exp ! -e .lake/packages/dep
test_exp ! -L .lake/packages/dep
popd
check_entry
pushd first
test_run build --no-build
popd
pushd second
# Re-running the command shares the package again
test_out "linked to" cache share
test_exp "$(realpath .lake/packages/dep)" = "$entry"
test_run clean dep
test_exp ! -e .lake/packages/dep
# Without the command, the package is private again
test_run build
test_exp -d .lake/packages/dep
test_exp ! -L .lake/packages/dep
test_exp -f .lake/packages/dep/.lake/build/lib/lean/Dep.olean
test_out "linked to" cache share
test_exp "$(realpath .lake/packages/dep)" = "$entry"
popd
check_entry

# Building an output missing from the entry makes the package private
pushd third
test_out "linked to" cache share
test_exp "$(realpath .lake/packages/dep)" = "$entry"
test_status 3 build @dep/Extra --no-build
test_exp -L .lake/packages/dep
test_out "dep: caching not supported for built outputs" build @dep/Extra
test_exp -d .lake/packages/dep
test_exp ! -L .lake/packages/dep
test_exp -w .lake/packages/dep/Dep.lean
test_exp -f .lake/packages/dep/.lake/build/lib/lean/Extra.olean
test_run build @dep/Extra --no-build
test_run build
popd
test_exp ! -e "$entry/.lake/build/lib/lean/Extra.olean"
check_entry

# A new revision of the dependency
pushd dep
echo 'def newValue : Nat := 2' >> Dep.lean
git commit -am "second commit"
rev2="$(git rev-parse HEAD)"
popd

# `lake update` unlinks the package and materializes a private checkout
pushd first
sed_i "s/$rev1/$rev2/" lakefile.toml
test_out "unlinking" update dep
test_exp -d .lake/packages/dep
test_exp ! -L .lake/packages/dep
test_exp "$(git -C .lake/packages/dep rev-parse HEAD)" = "$rev2"
test_run build
popd
test_exp "$(git -C "$entry" rev-parse HEAD)" = "$rev1"
check_entry

# A manifest revision change (e.g., from `git pull`) also does so
pushd second
sed_i "s/$rev1/$rev2/" lakefile.toml lake-manifest.json
test_out "unlinking" build
test_exp ! -L .lake/packages/dep
test_exp "$(git -C .lake/packages/dep rev-parse HEAD)" = "$rev2"
popd
check_entry
