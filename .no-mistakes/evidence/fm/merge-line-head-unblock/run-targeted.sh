#!/usr/bin/env bash
# Runs only the named tests from tests/fm-pr-check-security.test.sh (definitions sourced, run list replaced).
WT=${WT:-/Users/studio2/.no-mistakes/worktrees/662ae98237ac/01M5BNEVVNP6J9HST6YW24VMYC}
src=$(mktemp)
head -n 4472 "$WT/tests/fm-pr-check-security.test.sh" | sed "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh#$WT/tests/lib.sh#" > "$src"
. "$src"
rm -f "$src"
for t in "$@"; do "$t"; done
echo "ALL SELECTED TESTS PASSED"
