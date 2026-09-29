#!/usr/bin/env bash
# Run named test functions from one tests/*.test.sh file: source the file with
# its trailing bare invocation lines removed, then call each requested test.
set -u
ROOTDIR=$1; file=$2; shift 2
cd "$ROOTDIR" || exit 1
tmp=$(mktemp "${TMPDIR:-/tmp}/nm-runner.XXXXXX")
sed '/^test_[a-z_0-9]*$/d' "$file" > "$tmp"
# the sourced file resolves ROOT from BASH_SOURCE of tests/lib.sh; keep dirname valid
sed -i '' "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$ROOTDIR/tests#g" "$tmp"
start=$(date +%s)
bash -c '. "$1"; shift; for t in "$@"; do "$t" || exit 1; done' _ "$tmp" "$@"
rc=$?
echo "exit=$rc took $(( $(date +%s) - start ))s"
rm -f "$tmp"
exit $rc
