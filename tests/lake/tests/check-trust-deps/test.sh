#!/usr/bin/env bash
source ../common.sh

./clean.sh

if [ "`uname`" != Linux ]; then
  echo "Skipping test: lake check needs Linux namespaces"
  exit 0
fi

# User namespaces cannot be assumed available in CI containers; see `../fake-bwrap.sh`.
export COMPARATOR_BWRAP="$PWD/../fake-bwrap.sh"

# `--trust-deps` is its own way of checking, so the options that pick another are refused up front.
test_status_out 2 'cannot be combined with `--from-export`' check --trust-deps --from-export x
test_status_out 2 'cannot be combined with `--paranoid`' check --trust-deps --paranoid

# Each case below selects its module through `defaultTargets`, so work on a copy.
copy_to_work lakefile.toml Good.lean Hacked.lean Cheat.lean dep

# `lake check` resolves dependencies inside the sandbox, which cannot write to the project
# directory, so the manifest has to be in place first. `dep` is a path dependency, which builds into
# its own directory rather than the project's `.lake`, so it is built here too.
"$LAKE" resolve-deps
"$LAKE" build Dep

# `Dep.bogus` is ill-typed and `Dep.cheat` rests on `sorry`. `Good` uses only the former, so trusting
# the dependency accepts it: `Dep` is not replayed, and `sorryAx` is not reachable from `Good`.
test_status_out 0 'Lean default kernel accepts the solution' check --trust-deps
match_text 'Uses no axioms' produced.out
match_text 'replaying Good' produced.out
no_match_text 'replaying Dep' produced.out
no_match_text 'Building and exporting' produced.out

# Without the flag, the whole dependency is still in scope.
test_status_out 1 "Axiom 'sorryAx' is not permitted; it is used by 'Dep.cheat'" check

# The root package's own modules are still replayed through the kernel.
sed_i 's/^defaultTargets = .*/defaultTargets = ["Hacked"]/' lakefile.toml
test_status_out 1 'leanchecker found a problem in Hacked' check --trust-deps
match_text 'Lean default kernel rejected the solution' produced.out

# Axioms are still policed through the dependencies they are reached by.
sed_i 's/^defaultTargets = .*/defaultTargets = ["Cheat"]/' lakefile.toml
test_status_out 1 "Axiom 'sorryAx' is not permitted; it is used by 'Dep.cheat'" check --trust-deps
no_match_text 'Running Lean default kernel' produced.out

rm -f produced.out
