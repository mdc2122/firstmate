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
#   - Score each window on its own panel score -> task: ranking-shadow-v2
#   - Hit-reactive fast lane -> task: hit-reactive-lane, slot-conveyor-defer
#   - Leave out the hook score -> declined: inverse at the tail, no work to do
#   - De-duplicate the top 12 -> open
#
# One top-level list item (`-`, `*`, `+`, or `1.`) per recommendation; nested
# or indented lines are ignored. The scout writes each line ending `-> open`;
# firstmate replaces that disposition with one of:
#   -> task: <id>[, <id>...]   every id is a task in this home's backlog that
#                              is filed: in flight (dispatched), done, or queued
#                              while held or blocked-by another task. A queued
#                              row with no active hold or blocker is not filed
#                              yet (bin/fm-queue-zero.sh names it as ready).
#                              The scout's own task id counts only while it is
#                              held for the captain, because cleanup closes it
#                              otherwise and the recommendation would vanish.
#   -> declined: <reason>      an explicit, non-empty reason.
# The disposition marker is the last ` -> task:` or ` -> declined:` on the line
# (case-insensitive); anything else, including `-> open`, is unresolved.
#
# WHEN THE LEDGER IS REQUIRED. A report needs one when it has a recommendation
# section: a heading (outside fenced code) whose text contains "recommend",
# "promotion candidate", "next step", or the word "plan". Such a section runs to
# the next heading of the same or a higher level. Its item count is its table
# body rows when it has a table (a ranked plan; bullets beside the table are
# commentary), else its top-level list items. The ledger must list at least
# as many entries as the largest recommendation section has items, so a ledger
# cannot silently cover only part of a list; sections are compared one at a
# time rather than summed because two sections often restate one item (a plan
# row and its promotion candidate). A report with no recommendation section and
# no ledger passes; a ledger that exists is always checked.
#
# `check` prints nothing and exits 0 when every entry is resolved. Otherwise it
# prints one line per problem on stderr - naming each unfiled item by its text -
# and exits 1. It exits 2 on usage errors, an unreadable report, or a backlog it
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

Ledger lines under "## Follow-up ledger" end "-> task: <id>[, <id>...]" or
"-> declined: <reason>"; the script header owns the full format.
EOF
}

die() { printf 'fm-followup-ledger: %s\n' "$1" >&2; exit "${2:-2}"; }

# Emit the report's structure as tab-separated records:
#   section <items> <heading>   one per recommendation section
#   ledger                      once, when the ledger heading exists
#   entry <text>                one per top-level ledger list item
scan_report() {  # <report>
  awk '
    function heading_level(s) { match(s, /^#+/); return RLENGTH }
    function close_section() {
      if (sec_open) { printf "section\t%d\t%s\n", (sec_rows > 0 ? sec_rows : sec_list), sec_title }
      sec_open = 0
    }
    BEGIN { fence = 0; sec_open = 0; in_ledger = 0; prev_table = 0 }
    /^[ \t]*(```|~~~)/ { fence = !fence; prev_table = 0; next }
    fence { next }
    /^#+[ \t]/ {
      level = heading_level($0)
      title = $0; sub(/^#+[ \t]+/, "", title); sub(/[ \t#]+$/, "", title)
      low = tolower(title)
      if (sec_open && level <= sec_level) close_section()
      if (in_ledger && level <= ledger_level) in_ledger = 0
      prev_table = 0
      if (low ~ /^follow-up ledger$/) {
        in_ledger = 1; ledger_level = level; print "ledger"; next
      }
      if (!sec_open && (low ~ /recommend/ || low ~ /promotion candidate/ || low ~ /next step/ \
          || low ~ /(^|[^a-z])plan([^a-z]|$)/)) {
        sec_open = 1; sec_level = level; sec_list = 0; sec_rows = 0; sec_title = title
      }
      next
    }
    {
      top_item = ($0 ~ /^([-*+]|[0-9]+[.)])[ \t]+[^ \t]/)
      if (in_ledger && top_item) {
        text = $0; sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", text)
        printf "entry\t%s\n", text
      }
      if (sec_open) {
        if (top_item) sec_list++
        else if ($0 ~ /^\|/) {
          # A separator row means the row before it was the header, not an item.
          if ($0 ~ /^\|[ \t:|-]*-[ \t:|-]*$/) { if (prev_table) sec_rows-- }
          else sec_rows++
        }
      }
      prev_table = ($0 ~ /^\|/)
    }
    END { close_section() }
  ' "$1"
}

# Prints "<state>|<held>|<blocked>|<hold_kind>" for a task, or returns 1 when
# the backlog has no such task; exits 2 when the backlog cannot be read.
task_facts() {  # <id>
  local out rc=0
  out=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *NOT_FOUND*) return 1 ;;
      *) die "cannot read task $1 from this home's backlog: $(printf '%s' "$out" | head -n 1)" ;;
    esac
  fi
  printf '%s\n' "$out" | awk '
    /^  state: / { s = $2 } /^  held: / { h = $2 } /^  blocked: / { b = $2 } /^  hold_kind: / { k = $2 }
    END { gsub(/"/, "", k); printf "%s|%s|%s|%s\n", s, h, b, k }'
}

# Empty when <id> is filed; otherwise why it is not. Exits 2 when the backlog
# cannot be read (task_facts dies inside the substitution).
task_problem() {  # <scout-id> <id>
  local scout=$1 id=$2 facts state held blocked kind rc=0
  case "$id" in
    *[!A-Za-z0-9._-]*) printf 'names "%s", which is not a task id' "$id"; return ;;
  esac
  facts=$(task_facts "$id") || rc=$?
  case "$rc" in
    0) ;;
    1) printf 'names %s, which is not a task in this home'"'"'s backlog' "$id"; return ;;
    *) exit "$rc" ;;
  esac
  IFS='|' read -r state held blocked kind <<EOF
$facts
EOF
  if [ "$id" = "$scout" ]; then
    [ "$held" = yes ] && [ "$kind" = captain ] && return
    printf 'names this scout'"'"'s own task %s, which cleanup closes unless it is held for the captain' "$id"
    return
  fi
  case "$state" in
    in_flight|done) return ;;
    queued)
      { [ "$held" = yes ] || [ "$blocked" = yes ]; } && return
      printf 'names %s, which is queued with no active hold or blocker - dispatch it or hold it with its blocker' "$id"
      ;;
    *) printf 'names %s, whose state %s could not be read as filed' "$id" "${state:-unknown}" ;;
  esac
}

check() {  # <scout-id>
  local scout=$1 report scan line kind rest items title text disposition value ids id problem
  local ledger=0 entries=0 max_items=0 max_title='' sections=0 problems=0
  local marker_re='^(.*[^[:space:]])[[:space:]]+-\>[[:space:]]*([Tt][Aa][Ss][Kk]|[Dd][Ee][Cc][Ll][Ii][Nn][Ee][Dd]):[[:space:]]*(.*)$'
  case "$scout" in ''|*[!A-Za-z0-9._-]*) die "scout task id must be a slug: $scout" ;; esac
  report="$DATA/$scout/report.md"
  [ -f "$report" ] || die "no report at $report"
  scan=$(scan_report "$report") || die "cannot read $report"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind=${line%%$'\t'*}
    rest=${line#*$'\t'}
    case "$kind" in
      section)
        sections=$((sections + 1))
        items=${rest%%$'\t'*}
        title=${rest#*$'\t'}
        if [ "$items" -gt "$max_items" ]; then max_items=$items; max_title=$title; fi
        ;;
      ledger) ledger=1 ;;
      entry)
        entries=$((entries + 1))
        text=$rest
        if [[ "$text" =~ $marker_re ]]; then
          disposition=$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')
          value=${BASH_REMATCH[3]}
          text=${BASH_REMATCH[1]}
        else
          disposition=''
          value=''
          text=${text%%[[:space:]]->*}
        fi
        value=${value%"${value##*[![:space:]]}"}
        case "$disposition" in
          declined)
            if [ -z "$value" ]; then
              printf '  "%s" is declined without a reason\n' "$text" >&2
              problems=$((problems + 1))
            fi
            ;;
          task)
            ids=$(printf '%s' "$value" | tr -d '`' | tr ',' ' ')
            if [ -z "${ids// /}" ]; then
              printf '  "%s" names no task id\n' "$text" >&2
              problems=$((problems + 1))
              continue
            fi
            for id in $ids; do
              problem=$(task_problem "$scout" "$id") || exit $?
              if [ -n "$problem" ]; then
                printf '  "%s" %s\n' "$text" "$problem" >&2
                problems=$((problems + 1))
              fi
            done
            ;;
          *)
            printf '  "%s" is not filed: end its line with "-> task: <id>" or "-> declined: <reason>"\n' "$text" >&2
            problems=$((problems + 1))
            ;;
        esac
        ;;
    esac
  done <<EOF
$scan
EOF

  if [ "$sections" -gt 0 ] && [ "$ledger" = 0 ]; then
    printf '  the report has recommendation sections (largest: "%s", %s item(s)) but no "## Follow-up ledger" section\n' \
      "$max_title" "$max_items" >&2
    problems=$((problems + 1))
  elif [ "$entries" -lt "$max_items" ]; then
    printf '  the ledger lists %s item(s) but "%s" lists %s; give every recommendation its own ledger line\n' \
      "$entries" "$max_title" "$max_items" >&2
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
