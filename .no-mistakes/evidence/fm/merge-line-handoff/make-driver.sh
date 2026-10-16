#!/usr/bin/env bash
# make-driver.sh <tree> <out> <extra-file> : prefix of the tree's test file (helpers only, no runner list) + extra file
tree=$1 out=$2 extra=$3
n=$(grep -n '^test_parser_matrix$' "$tree/tests/fm-pr-check-security.test.sh" | cut -d: -f1)
head -n $((n - 1)) "$tree/tests/fm-pr-check-security.test.sh" \
  | sed "s|^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"|. \"$tree/tests/lib.sh\"|" > "$out"
cat "$extra" >> "$out"
