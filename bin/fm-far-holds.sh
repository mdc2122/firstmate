#!/usr/bin/env bash
# fm-far-holds.sh - far-date hold check: name every backlog item held with an
# --until date more than FM_FAR_HOLDS_DAYS (default 2) days ahead that the
# captain did not set, and wake firstmate once per episode with those items.
#
# Usage:
#   fm-far-holds.sh scan
#   fm-far-holds.sh check
#   fm-far-holds.sh --help
#
# THE RULE: work worth doing is done now, not parked behind a date firstmate
# picked. A far --until date stands only when it is the captain's own
# deferral, recorded with his words through
#   bin/fm-captain-hold.sh hold <id> --reason "..." --until <date> \
#     --captain-words-file <file>
# which writes a `Captain deferral until <date>:` record into the task body.
# That record is bound to its date: re-dating the hold to anything else makes
# the item firstmate's deferral again. Every other far-dated hold - a captain
# hold carrying no such record, or any non-captain hold - is listed here, and
# the turn that sees it starts the item (dispatches it or gives it another
# running owner), closes it with a reason, or records the captain's own words
# for it. Shortening the date is not an answer on its own: a date is not an
# owner, and bin/fm-queue-zero.sh refuses a second re-date without new
# evidence and lists an ownerless row as `unowned` whatever its date.
#
# A listed row is any open backlog item (not Done) with a hold reason and a
# hold-until date more than FM_FAR_HOLDS_DAYS days after today (UTC), whose
# body has no captain deferral record for that same date. A hold whose date
# has passed is inactive and is bin/fm-queue-zero.sh's concern, not this one's.
#
# `scan` is read-only and prints one line per row,
# "<id> until <date> - <title> [<hold reason>]", or nothing.
#
# `check` is the watcher's heartbeat hook (bin/fm-watch.sh far_holds tick,
# every FM_FAR_HOLDS_INTERVAL seconds, default 900). When a row appears that
# the last report did not carry - an item and date pair, so re-dating an item
# is a new episode - it first appends one durable `check` wake (key
# far-holds) naming every current row, then records the report and prints
# that same wake reason; otherwise it prints nothing. An unchanged set never
# wakes again. The report record is state/.far-holds, written only after the
# wake is durably queued, so a failed append is retried rather than
# suppressed. The reason is bounded by FM_FAR_HOLDS_MAX_CHARS (default 1500)
# with a "+N more" tail.
#
# Only a markdown backlog at <data>/backlog.md is read; a home without one
# lists nothing. FM_FAR_HOLDS_NOW (UTC ISO-8601) pins the clock for tests.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RECORD="$STATE/.far-holds"
RECORD_SCHEMA=fm-far-holds-v1

usage() {
  cat <<'EOF'
Usage:
  fm-far-holds.sh scan            list items held more than FM_FAR_HOLDS_DAYS out without the captain's words
  fm-far-holds.sh check           heartbeat hook: one wake line per new episode
  fm-far-holds.sh --help          print this help

Every listed item is started (dispatched or given a running owner), closed
with a reason, or re-held with the captain's own words through
bin/fm-captain-hold.sh hold --until <date> --captain-words-file <file>.
A new date alone is not an answer (bin/fm-queue-zero.sh owns the re-date rule).
EOF
}

die() { printf 'fm-far-holds: %s\n' "$1" >&2; exit "${2:-1}"; }

whole_setting() {  # <name> <default>
  local v=${!1:-$2}
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  printf '%s' "$v"
}
DAYS=$(whole_setting FM_FAR_HOLDS_DAYS 2)
MAX_CHARS=$(whole_setting FM_FAR_HOLDS_MAX_CHARS 1500)
NOW=${FM_FAR_HOLDS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
# Today (UTC) plus FM_FAR_HOLDS_DAYS: an --until date after this is far.
HORIZON=$(jq -nr --arg now "$NOW" --argjson days "$DAYS" \
  '($now | fromdateiso8601 | strftime("%Y-%m-%d") + "T00:00:00Z" | fromdateiso8601) + $days * 86400
   | strftime("%Y-%m-%d")' 2>/dev/null) || die "invalid FM_FAR_HOLDS_NOW: $NOW" 2

# rows: the far-held items as a JSON array, or one error row.
rows() {
  local input
  [ -f "$DATA/backlog.md" ] || { printf '[]'; return 0; }
  input=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input 2>/dev/null) \
    || { jq -nc '[{ref:"backlog",until:"",title:"could not read",reason:"the backlog could not be parsed"}]'; return 0; }
  printf '%s' "$input" | jq -c --arg horizon "$HORIZON" '
    [ .backlog.records[]
      | select(.structured == true and .state != "done")
      | select(.hold_reason != null and (.hold_until // "") > $horizon)
      | . as $r
      | select(any($r.body_lines[]?; . == "Captain deferral until \($r.hold_until):") | not)
      | {ref:.id, until:.hold_until,
         title:((.title // "") | gsub("\\s+"; " ") | if length > 70 then .[:69] + "…" else . end),
         reason:((.hold_reason // "") | if length > 100 then .[:99] + "…" else . end)} ]'
}

action_scan() {
  [ "$#" -eq 0 ] || die "unknown scan flag: $1" 2
  rows | jq -r '.[] | "\(.ref) until \(.until) - \(.title) [\(.reason)]"'
}

record_write() {  # <keys>
  local tmp
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  if ! {
    printf '%s\n' "$RECORD_SCHEMA"
    printf '%s\n' "$1" | sed '/^$/d; s/^/row=/'
  } > "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

action_check() {
  local out keys prev_keys='' news reason
  out=$(rows)
  keys=$(printf '%s' "$out" | jq -r '.[] | "\(.ref)/\(.until)"' | sort -u)
  if [ -f "$RECORD" ] && [ "$(head -n 1 "$RECORD")" = "$RECORD_SCHEMA" ]; then
    prev_keys=$(sed -n 's/^row=//p' "$RECORD" | sort -u)
  fi
  news=$(comm -23 <(printf '%s\n' "$keys" | sed '/^$/d') <(printf '%s\n' "$prev_keys" | sed '/^$/d'))
  if [ -z "$news" ]; then
    # Recording the current set keeps an item that leaves and returns a new episode.
    record_write "$keys" || true
    return 0
  fi
  reason=$(printf '%s' "$out" | jq -r --argjson max "$MAX_CHARS" --argjson days "$DAYS" '
    (map("\(.ref) until \(.until)")) as $items
    | (reduce $items[] as $i ({text:"", n:0};
        if (.text | length) + ($i | length) + 2 <= $max
        then .text += (if .n > 0 then "; " else "" end) + $i | .n += 1 else . end)) as $kept
    | "check: far-holds: \($items | length) backlog item(s) held more than \($days) day(s) out without the captain'"'"'s own deferral"
      + " (start it - dispatch it or give it a running owner - close it with a reason, or record the captain'"'"'s words with"
      + " bin/fm-captain-hold.sh hold --until <date> --captain-words-file <file>; a new date alone is not an answer;"
      + " bin/fm-far-holds.sh scan shows details): "
      + $kept.text
      + (if ($items | length) > $kept.n then "; +\(($items | length) - $kept.n) more" else "" end)')
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_wake_append check far-holds "$reason" || die "could not queue the far-holds wake; it is retried next interval"
  record_write "$keys" || true
  printf '%s\n' "$reason"
}

command -v jq >/dev/null 2>&1 || die "jq not found"
case "${1:-}" in
  scan) shift; action_scan "$@" ;;
  check) action_check ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
