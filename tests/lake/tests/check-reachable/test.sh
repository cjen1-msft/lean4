#!/usr/bin/env bash
source ../common.sh

./clean.sh

if [ "`uname`" != Linux ]; then
  echo "Skipping test: lake check needs Linux namespaces"
  exit 0
fi

# User namespaces cannot be assumed available in CI containers; see `../fake-bwrap.sh`.
export COMPARATOR_BWRAP="$PWD/../fake-bwrap.sh"

# The project is edited below, so work on a copy.
copy_to_work lakefile.toml Solution.lean dep

# `--reachable` builds its own export, so it does not take one.
test_status_out 2 'builds its own export' check --reachable --from-export no-such.export

# `lake check` builds inside the sandbox, which can write only to the root package's `.lake`, so
# build the dependency (and write the manifest) first.
test_run build

# By default, everything in scope is checked, including the unused `Dep.bad`.
test_status_out 1 "Axiom 'sorryAx' is not permitted" check
match_text "it is used by 'Dep.bad'" produced.out

# With `--reachable`, only the root package's declarations and what they use are checked.
test_status_out 0 'Lean default kernel accepts the solution' check --reachable
match_text 'Uses no axioms' produced.out

# Once the root package uses `Dep.bad`, its `sorry` is caught.
echo 'theorem uses_bad : False := Dep.bad' >> Solution.lean
test_status_out 1 "Axiom 'sorryAx' is not permitted" check --reachable
match_text "it is used by 'Dep.bad'" produced.out