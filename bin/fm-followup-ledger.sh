#!/usr/bin/env bash
# fm-followup-ledger.sh - the scout recommendation gate: every recommendation a
# scout report makes is filed as backlog work or explicitly declined before the
# scout can be cleaned up.
#
# Usage:
#   fm-followup-ledger.sh check <scout-task-id>
#   fm-followup-ledger.sh --help
#
# Why: a report's recommendations are evidence firstmate reads once, at
# completion. Nothing loads them again at session start, so a recommendation
# that never became a backlog item silently disappears from every surface that
# drives work. This gate makes filing part of completing the scout.
#
# THE LEDGER (bin/fm-brief.sh's scout template asks scouts to write it):
#
#   ## Follow-up ledger
#
#   - Score each window on its own panel score -> ranking-shadow-v2
#   - Hit-reactive fast lane -> hit-reactive-lane, slot-conveyor-defer
#   - Leave out the hook score -> declined: inverse at the tail, no work to do
#   - De-duplicate the top 12 -> open
#
# Every non-blank line in the section is one recommendation (a leading list
# marker is ignored). The scout writes each line ending `-> open`; firstmate
# replaces that with one of:
#   -> <task-id>[, <task-id>...]   every id is a task in this home's backlog
#   -> declined: <reason>          an explicit, non-empty reason
# The disposition is whatever follows the last ` -> ` on the line. A line with
# no arrow, nothing after it, or `open` is unresolved.
#
# The gate does not count recommendations from the report's structure: firstmate
# reads the ledger against the report. It checks only that a report with a
# recommendation heading (outside fenced code, text containing "recommend",
# "promotion candidate", or "next step") has a non-empty ledger, and that every
# ledger line is resolved. A report with neither passes; a ledger that exists is
# always checked.
#
# `check` prints nothing and exits 0 when the ledger passes. Otherwise it prints
# one line per problem on stderr - naming each problem line by its text - and
# exits 1. It exits 2 on usage errors, an unreadable report, or a backlog it
# cannot read, so a caller never mistakes "cannot tell" for "filed".
# bin/fm-teardown.sh runs it in the scout completion gate beside
# bin/fm-captain-hold.sh verify; --force skips both.
#
# Paths: the report is <data>/<id>/report.md, where <data> is FM_DATA_OVERRIDE,
# else $FM_HOME/data; task ids are read through bin/fm-tasks-axi.sh, so they
# resolve in that same home's backlog.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  cat <<'EOF'
Usage:
  fm-followup-ledger.sh check <scout-task-id>   refuse while a report recommendation is unfiled
  fm-followup-ledger.sh --help                  print this help

Ledger lines under "## Follow-up ledger" end "-> <task-id>[, <task-id>...]" or
"-> declined: <reason>"; the script header owns the full format.
EOF
}

die() { printf 'fm-followup-ledger: %s\n' "$1" >&2; exit "${2:-2}"; }

# Emit the report's structure as tab-separated records:
#   section <heading>   once, for the first recommendation heading
#   ledger              once, when the ledger heading exists
#   entry <text>        one per non-blank ledger line
scan_report() {  # <report>
  awk '
    BEGIN { fence = 0; in_ledger = 0; seen_section = 0 }
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^#+[ \t]/ {
      match($0, /^#+/); level = RLENGTH
      title = $0; sub(/^#+[ \t]+/, "", title); sub(/[ \t#]+$/, "", title)
      low = tolower(title)
      if (in_ledger && level <= ledger_level) in_ledger = 0
      if (low ~ /^follow-up ledger$/) {
        in_ledger = 1; ledger_level = level; print "ledger"; next
      }
      if (!seen_section && (low ~ /recommend/ || low ~ /promotion candidate/ || low ~ /next step/)) {
        seen_section = 1; printf "section\t%s\n", title
      }
      next
    }
    in_ledger && /[^ \t]/ {
      text = $0; sub(/^[ \t]*(([-*+]|[0-9]+[.)])[ \t]+)?/, "", text); sub(/[ \t]+$/, "", text)
      printf "entry\t%s\n", text
    }
  ' "$1"
}

# Returns 0 when <id> is a task in this home's backlog, 1 when it is not; exits
# 2 when the backlog cannot be read.
task_exists() {  # <id>
  local out rc=0
  out=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] && return 0
  case "$out" in
    *NOT_FOUND*) return 1 ;;
    *) die "cannot read task $1 from this home's backlog: $(printf '%s' "$out" | head -n 1)" ;;
  esac
}

check() {  # <scout-id>
  local scout=$1 report scan line kind rest text target reason ids id
  local ledger=0 entries=0 section='' problems=0
  case "$scout" in ''|*[!A-Za-z0-9._-]*) die "scout task id must be a slug: $scout" ;; esac
  report="$DATA/$scout/report.md"
  [ -f "$report" ] || die "no report at $report"
  scan=$(scan_report "$report") || die "cannot read $report"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind=${line%%$'\t'*}
    rest=${line#*$'\t'}
    case "$kind" in
      section) section=$rest ;;
      ledger) ledger=1 ;;
      entry)
        entries=$((entries + 1))
        case "$rest" in
          *[[:space:]]-\>*)
            text=${rest%[[:space:]]-\>*}
            target=${rest##*[[:space:]]-\>}
            ;;
          *) text=$rest; target='' ;;
        esac
        target=${target#"${target%%[![:space:]]*}"}
        case "$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')" in
          declined:*)
            reason=${target#*:}
            if [ -z "${reason//[[:space:]]/}" ]; then
              printf '  "%s" is declined without a reason\n' "$text" >&2
              problems=$((problems + 1))
            fi
            ;;
          ''|open)
            printf '  "%s" is not filed: end its line with "-> <task-id>" or "-> declined: <reason>"\n' "$text" >&2
            problems=$((problems + 1))
            ;;
          *)
            ids=$(printf '%s' "$target" | tr -d '`' | tr ',' ' ')
            for id in $ids; do
              case "$id" in
                *[!A-Za-z0-9._-]*)
                  printf '  "%s" names "%s", which is not a task id\n' "$text" "$id" >&2
                  problems=$((problems + 1))
                  ;;
                *)
                  task_exists "$id" && continue
                  printf '  "%s" names %s, which is not a task in this home'"'"'s backlog\n' "$text" "$id" >&2
                  problems=$((problems + 1))
                  ;;
              esac
            done
            ;;
        esac
        ;;
    esac
  done <<EOF
$scan
EOF

  if [ -n "$section" ] && [ "$ledger" = 0 ]; then
    printf '  the report has a recommendation section ("%s") but no "## Follow-up ledger" section\n' "$section" >&2
    problems=$((problems + 1))
  elif [ -n "$section" ] && [ "$entries" = 0 ]; then
    printf '  the report has a recommendation section ("%s") but its "## Follow-up ledger" is empty\n' "$section" >&2
    problems=$((problems + 1))
  fi

  if [ "$problems" -gt 0 ]; then
    printf '  Report: %s\n' "$report" >&2
    return 1
  fi
}

case "${1:-}" in
  check)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    check "$2"
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
