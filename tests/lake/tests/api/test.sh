#!/usr/bin/env bash
source ../common.sh

./clean.sh

# Run DSL tests
test_run -f keys.lean resolve-deps

# Run Lean tests
test_run env lean vers.lean

# Directory cleanup must unlink root symlinks without touching their targets.
mkdir -p work/remove-dir-all/ordinary/nested work/remove-dir-all/target/nested
echo keep > work/remove-dir-all/target/nested/file
echo remove > work/remove-dir-all/ordinary/nested/file
test_run -f io.lean script run cleanup work/remove-dir-all/ordinary work/remove-dir-all/absent
test_exp ! -e work/remove-dir-all/ordinary
test_exp ! -e work/remove-dir-all/absent
if [ "$OS" != Windows_NT ]; then
  ln -s target work/remove-dir-all/root-link
  ln -s missing work/remove-dir-all/dangling
  test_run -f io.lean script run cleanup work/remove-dir-all/root-link work/remove-dir-all/dangling
  test_exp ! -L work/remove-dir-all/root-link
  test_exp ! -L work/remove-dir-all/dangling
  test_exp "$(cat work/remove-dir-all/target/nested/file)" = keep
fi
