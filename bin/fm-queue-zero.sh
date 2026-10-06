#!/usr/bin/env bash
# fm-queue-zero.sh - queue inbox zero: name every queued row that must leave
# the queue now, and wake firstmate once per episode with those exact rows.
#
# Usage:
#   fm-queue-zero.sh scan [--local] [--json]
#   fm-queue-zero.sh check
#   fm-queue-zero.sh --help
#
# THE RULE (AGENTS.md section 10 points here): every row this script lists
# leaves the queue in the turn that sees it - dispatched, held with
# `tasks-axi hold <id> --until <date> --reason "<named blocker or owner>"`, or
# closed. A watch-only row ("watch Paperclip FIR-x") is no exception: it is
# held with its owner and a dated check, or converted into real work. A row
# held that way drops off until its date arrives, then comes back for a fresh
# decision, so nothing parks in Charted Next indefinitely.
#
# THE QUEUED-ROW RULE: every queued row carries a named blocker or dependency
# (an open `blocked-by` task, or a fresh genuine captain call, whose blocker is
# the captain) or a dated next check (`hold-until` today or later). A dated next
# check is a near one: a date more than FM_FAR_HOLDS_DAYS out without the
# captain's own deferral words is bin/fm-far-holds.sh's row, so dating a row
# here never parks it far away unseen.
#
# Rows from this home's backlog (source "queue"):
#   ready    queued, every blocker done, no active hold or its date has passed
#            (exactly bin/fm-tasks-axi.sh ready), excluding captain holds,
#            which Captain's Call owns
#   undated  queued, not ready, filed at least FM_QUEUE_ZERO_AGE_DAYS ago
#            (default 1), and not held with an --until date still ahead;
#            captain holds again excluded
#   nocheck  a queued captain hold with no open blocker and no --until date
#            ahead, aged from its hold-set stamp (hold_age_days) or, once a
#            past --until date has lapsed, from that date: one whose hold
#            reason begins "owner:" (firstmate- or secondmate-owned work) gets
#            no grace and is listed after FM_QUEUE_ZERO_AGE_DAYS like any
#            undated row; a genuine captain call after FM_FAR_HOLDS_DAYS
#            (default 2, bin/fm-far-holds.sh's window). It waits on nobody
#            and nothing checks it, so it is worked, dated, brought back to
#            the captain through bin/fm-captain-hold.sh hold (recording the
#            captain's own deferral date), or closed
#   orphan   in flight in the backlog with no live task record: the
#            "(main-inventory)" Bearings warning; close it or re-dispatch it
# Rows from the Paperclip board (source "paperclip"), only when this home
# configures the sweep: every row bin/fm-paperclip-sweep.sh scan prints.
#
# `scan` is read-only and prints one line per row,
# "<source> <class> <id> - <title> [<detail>]", or nothing when the queue is
# at zero; --json prints the row array; --local skips Paperclip (the teardown
# path uses it).
#
# `check` is the watcher's heartbeat hook (bin/fm-watch.sh queue_zero_tick).
# When it reports, it first appends one durable `check` wake (key
# queue-zero) naming every current row, then records the report and prints
# that same wake reason; otherwise it prints nothing. It reports only when a
# row appears that the last report did not carry, or when the set is unchanged
# but FM_QUEUE_ZERO_RENAG_HOURS (default 24) have passed since that report; a
# row that leaves and returns is a new episode. The report record is
# state/.queue-zero, written only after the wake is durably queued, so a
# failed append is retried rather than suppressed. The reason names rows by
# id only and is bounded by FM_QUEUE_ZERO_MAX_CHARS (default 1500) with a
# "+N more" tail.
#
# A home whose state directory is overridden without a matching data
# directory (FM_STATE_OVERRIDE set, FM_DATA_OVERRIDE unset) cannot pair its
# backlog with its task records, so both commands stay silent there.
# FM_QUEUE_ZERO_NOW (UTC ISO-8601) pins the clock for tests.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RECORD="$STATE/.queue-zero"
RECORD_SCHEMA=fm-queue-zero-v1

usage() {
  cat <<'EOF'
Usage:
  fm-queue-zero.sh scan [--local] [--json]   list queued rows that must leave the queue now
  fm-queue-zero.sh check                      heartbeat hook: one wake line per new episode
  fm-queue-zero.sh --help                     print this help

Every listed row is dispatched, held with --until and a reason naming its
blocker or owner, or closed in the turn that sees it.
EOF
}

die() { printf 'fm-queue-zero: %s\n' "$1" >&2; exit "${2:-1}"; }

whole_setting() {  # <name> <default>
  local v=${!1:-$2}
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  printf '%s' "$v"
}
AGE_DAYS=$(whole_setting FM_QUEUE_ZERO_AGE_DAYS 1)
CAPTAIN_DAYS=$(whole_setting FM_FAR_HOLDS_DAYS 2)
RENAG_HOURS=$(whole_setting FM_QUEUE_ZERO_RENAG_HOURS 24)
MAX_CHARS=$(whole_setting FM_QUEUE_ZERO_MAX_CHARS 1500)
NOW=${FM_QUEUE_ZERO_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
NOW_EPOCH=$(jq -nr --arg now "$NOW" '$now | fromdateiso8601' 2>/dev/null) || die "invalid FM_QUEUE_ZERO_NOW: $NOW" 2
TODAY=${NOW%%T*}

home_paired() {
  [ -z "${FM_STATE_OVERRIDE:-}" ] || [ -n "${FM_DATA_OVERRIDE:-}" ] \
    || [ "$FM_STATE_OVERRIDE" = "$FM_HOME/state" ]
}

error_row() {  # <source> <detail>
  jq -nc --arg s "$1" --arg d "$2" '[{source:$s,class:"error",ref:$s,title:"could not read",detail:$d}]'
}

# queue_rows: this home's backlog rows as a JSON array.
queue_rows() {
  local input ready_out ready_ids
  [ -f "$DATA/backlog.md" ] || { printf '[]'; return 0; }
  input=$(FM_SNAPSHOT_NOW="$NOW" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input 2>/dev/null) \
    || { error_row queue "the backlog could not be parsed"; return 0; }
  ready_out=$("$SCRIPT_DIR/fm-tasks-axi.sh" ready 2>&1) \
    || { error_row queue "tasks-axi ready failed: $(printf '%s' "$ready_out" | head -n 1)"; return 0; }
  # Rows of the TOON ready[N]{id,...} table: two-space indent, id first.
  ready_ids=$(printf '%s\n' "$ready_out" \
    | awk '/^ready\[[0-9]+\]/ { t = 1; next } t && /^  / { sub(/^  /, ""); split($0, f, ","); print f[1]; next } { t = 0 }' \
    | jq -Rsc 'split("\n") | map(select(. != ""))')
  printf '%s' "$input" | jq -c --argjson ready "$ready_ids" --arg today "$TODAY" \
    --argjson age_days "$AGE_DAYS" --argjson captain_days "$CAPTAIN_DAYS" '
    def day_epoch: try ((. // "") + "T00:00:00Z" | fromdateiso8601) catch null;
    ($today | day_epoch) as $t
    | ([.tasks[].id]) as $live
    | [ .backlog.records[]
        | select(.structured == true)
        | . as $r
        | ($r.hold_kind == "captain") as $captain
        | (($r.hold_until // "") > $today) as $dated
        | (($r.since | day_epoch) as $s | $s != null and ($t - $s) >= ($age_days * 86400)) as $aged
        | {source:"queue", ref:$r.id, title:($r.title // "")}
          + if $r.state == "queued" and ($ready | index($r.id)) != null and ($captain | not) then
              {class:"ready", detail:("filed " + ($r.since // "undated"))}
            elif $r.state == "queued" and ($captain | not) and ($dated | not) and $aged
                 and ($ready | index($r.id)) == null then
              {class:"undated",
               detail:((if ($r.blocked_by_ids | length) > 0 then "blocked-by " + ($r.blocked_by_ids | join(","))
                        elif $r.hold_reason != null then "held: " + $r.hold_reason
                        else "waiting" end) + "; no --until date; filed " + ($r.since // "undated"))}
            elif $r.state == "queued" and ($r.hold_bucket == "live" or $r.hold_bucket == "aged")
                 and ($dated | not)
                 and ((if $r.hold_until != null then ($r.hold_until | day_epoch) as $u
                         | if $u == null then null else (($t - $u) / 86400 | floor) end
                       else $r.hold_age_days end) as $lapsed
                      | $lapsed != null
                        and $lapsed >= (if ($r.hold_reason | startswith("owner:")) then $age_days
                                        else $captain_days end)) then
              {class:"nocheck",
               detail:("captain hold with no blocker and "
                       + (if $r.hold_until != null then "a lapsed --until " + $r.hold_until
                          else "no --until date, aged \($r.hold_age_days)d" end)
                       + ": " + $r.hold_reason)}
            elif $r.state == "in_flight" and $r.requires_child_metadata == true
                 and ($live | index($r.id)) == null then
              {class:"orphan", detail:"in flight with no live task record"}
            else empty end ]
    | map(.title |= (gsub("\\s+"; " ") | if length > 70 then .[:69] + "…" else . end))'
}

paperclip_rows() {
  "$SCRIPT_DIR/fm-paperclip-sweep.sh" configured || { printf '[]'; return 0; }
  "$SCRIPT_DIR/fm-paperclip-sweep.sh" scan --json | jq -c 'map({source:"paperclip"} + .)' \
    || error_row paperclip "the sweep output could not be read"
}

all_rows() {  # [--local]
  local q p='[]'
  home_paired || { printf '[]'; return 0; }
  q=$(queue_rows)
  [ "${1:-}" = --local ] || p=$(paperclip_rows)
  jq -nc --argjson q "$q" --argjson p "$p" '$q + $p'
}

action_scan() {
  local local_only='' json=0 rows
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --local) local_only=--local ;;
      --json) json=1 ;;
      *) die "unknown scan flag: $1" 2 ;;
    esac
    shift
  done
  rows=$(all_rows $local_only)
  if [ "$json" = 1 ]; then
    printf '%s\n' "$rows"
  else
    printf '%s\n' "$rows" | jq -r '.[] | "\(.source) \(.class) \(.ref) - \(.title) [\(.detail)]"'
  fi
}

action_check() {
  local rows keys prev_keys='' prev_epoch=0 news reason
  rows=$(all_rows)
  keys=$(printf '%s' "$rows" | jq -r '.[] | "\(.source)/\(.class)/\(.ref)"' | sort -u)
  if [ -f "$RECORD" ] && [ "$(head -n 1 "$RECORD")" = "$RECORD_SCHEMA" ]; then
    prev_epoch=$(sed -n 's/^epoch=//p' "$RECORD" | head -n 1)
    case "$prev_epoch" in ''|*[!0-9]*) prev_epoch=0 ;; esac
    prev_keys=$(sed -n 's/^row=//p' "$RECORD" | sort -u)
  fi
  news=$(comm -23 <(printf '%s\n' "$keys" | sed '/^$/d') <(printf '%s\n' "$prev_keys" | sed '/^$/d'))
  if [ -z "$keys" ] || { [ -z "$news" ] && [ $((NOW_EPOCH - prev_epoch)) -lt $((RENAG_HOURS * 3600)) ]; }; then
    # Nothing new to report. Recording the current set keeps a row that
    # leaves and later returns a new episode.
    record_write "$prev_epoch" "$keys" || true
    return 0
  fi
  reason=$(printf '%s' "$rows" | jq -r --argjson max "$MAX_CHARS" '
    (map(select(.source == "queue")) | length) as $q
    | (map(select(.source == "paperclip")) | length) as $p
    | (map("\(.source) \(.class) \(.ref)")) as $items
    | (reduce $items[] as $i ({text:"", n:0};
        if (.text | length) + ($i | length) + 2 <= $max
        then .text += (if .n > 0 then "; " else "" end) + $i | .n += 1 else . end)) as $kept
    | "check: queue-zero: \($q) queue row(s) and \($p) Paperclip item(s) must leave the queue this turn"
      + " (work it now, hold --until a near date (bin/fm-far-holds.sh window) with a named blocker or owner, or close;"
      + " Paperclip: release, date, or decide; bin/fm-queue-zero.sh scan shows details): " + $kept.text
      + (if ($items | length) > $kept.n then "; +\(($items | length) - $kept.n) more" else "" end)')
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_wake_append check queue-zero "$reason" || die "could not queue the queue-zero wake; it is retried next heartbeat"
  record_write "$NOW_EPOCH" "$keys" || true
  printf '%s\n' "$reason"
}

record_write() {  # <epoch> <keys>
  local tmp
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  if ! {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$1"
    printf '%s\n' "$2" | sed '/^$/d; s/^/row=/'
  } > "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

command -v jq >/dev/null 2>&1 || die "jq not found"
case "${1:-}" in
  scan) shift; action_scan "$@" ;;
  check) action_check ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
