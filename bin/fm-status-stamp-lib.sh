# shellcheck shell=bash
# fm-status-stamp-lib.sh - write-time timestamps on status lines Firstmate's own
# scripts append. This header is the one owner of the stamp format and of the
# append primitives every firstmate-owned status writer uses; the status-line
# grammar itself stays owned by bin/fm-classify-lib.sh.
#
# Format: the line as before, then one space and a trailing UTC tag:
#   resolved [key=api-shape]: answered: use v2 [at=2026-10-16T05:12:00Z]
# The tag trails the note rather than sitting among the before-colon tags
# because an ISO time carries colons, and every status parser splits the verb
# and key prefix at the line's FIRST colon. At the tail it is note text to
# those parsers, so verb, key, and open-decision folds read a stamped line
# exactly as they read the unstamped one.
#
# Scope: lines a firstmate script writes (decision closes, captain-held
# transfers, pending-reply escalations, spawn failures, parent-channel
# reports). A worker's own `echo ... >> state/<id>.status` is not ours and
# stays unstamped; the supervisor action ledger (bin/fm-action-ledger-lib.sh)
# and the steering inbox's at= headers carry the supervisor side of that clock.
#
# Exact-line idempotence: an append-once writer compares lines with any trailing
# stamp removed, so a retry of the same event is still recognized as already
# written even though its stamp would differ.

# Print <line> with its write-time stamp.
fm_status_stamp() {  # <line>
  printf '%s [at=%s]' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Print <line> without a trailing stamp (unchanged when it carries none).
fm_status_unstamp() {  # <line>
  local line=$1 tail
  tail=${line##* \[at=}
  if [ "$tail" != "$line" ]; then
    case "$tail" in
      [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-6][0-9]Z\])
        printf '%s' "${line% \[at=*}"
        return 0
        ;;
    esac
  fi
  printf '%s' "$line"
}

# 0 when <file> already holds <line>, stamped or not.
fm_status_has_line() {  # <file> <line>
  [ -f "$1" ] || return 1
  LC_ALL=C awk -v want="$2" '
    {
      line = $0
      if (match(line, / \[at=[0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-6][0-9]Z\]$/))
        line = substr(line, 1, RSTART - 1)
      if (line == want) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$1" 2>/dev/null
}

# Append <line> to <file> with its stamp. Returns the write's own status.
fm_status_append() {  # <file> <line>
  printf '%s\n' "$(fm_status_stamp "$2")" >> "$1"
}

# Append <line> with its stamp unless <file> already holds it.
# Returns 0 appended, 1 already present, 2 the write itself failed.
fm_status_append_once() {  # <file> <line>
  fm_status_has_line "$1" "$2" && return 1
  fm_status_append "$1" "$2" || return 2
  return 0
}
