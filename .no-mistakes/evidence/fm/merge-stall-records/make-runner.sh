#!/usr/bin/env bash
# usage: make-runner.sh <tree-root> <test-file-to-take-helpers-from> <out> <tests...>
root=$1 src=$2 out=$3; shift 3
last=$(awk '/^test_[a-z_]+$/ {print NR; exit}' "$src")
{ head -n $((last-1)) "$src" | sed "s#^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"#. \"$root/tests/lib.sh\"#"
  cat "$(dirname "$0")/extra-scenarios.sh"
  printf '%s\n' "$@"; } > "$out"
