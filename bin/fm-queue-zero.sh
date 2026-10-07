#!/usr/bin/env bash
# fm-queue-zero.sh - queue inbox zero: name every queued row that must leave
# the queue now, and wake firstmate once per episode with those exact rows.
# It is also the single owner of row OWNERSHIP and of the RE-DATE LEDGER.
#
# Usage:
#   fm-queue-zero.sh scan [--local] [--json]
#   fm-queue-zero.sh check
#   fm-queue-zero.sh observe
#   fm-queue-zero.sh hold-gate <task-id> <YYYY-MM-DD>
#   fm-queue-zero.sh load
#   fm-queue-zero.sh --help
#
# THE RULE (AGENTS.md section 10 points here): every row this script lists
# leaves the queue in the turn that sees it. A ready row is dispatched. An
# unowned or redated row is started (given a running owner), closed with a
# reason, or held for the captain's own decision - a date alone never clears
# it. A genuine captain call is answered, brought back to the captain, or
# deferred with the captain's own words. An orphan is closed or re-dispatched.
#
# THE SUPERVISOR OWNS NO WORK. Every open row has a running owner:
#   worker      a live task record (state/<id>.meta) for the row
#   crew        an open beads (br) item in this home's crew queue
#               (data/beads/.beads/beads.db) labelled mirror:<id>, read with one
#               bounded read-only call (FM_QUEUE_ZERO_BR_TIMEOUT, default 5 s)
#   secondmate  a hold reason beginning "owner: <secondmate-id>" naming a
#               secondmate registered in data/secondmates.md
#   watch       a registered condition watch (bin/fm-procevent-when.sh) named
#               <id> or <id>--<suffix>, so its source is when-<id>[--<suffix>]
#   captain     a genuine captain call: a captain hold whose reason does not
#               begin "owner:"
#   blocked-by  an unresolved blocked-by edge to a row that itself has an owner
#               (followed transitively)
# Anything else - a dated hold, an "owner: firstmate" hold, a row waiting on
# nothing - is owned only by the supervisor, which is to say by nobody.
#
# ALARMS FORCE AN END. The ledger state/.queue-zero-holds.json remembers each
# open row's last hold-until date and an evidence fingerprint taken when that
# date was set: the row's status-log size (a status line), whether it has a
# live task record (a linked worker), its blocked-by ids (a blocker change),
# and its count of captain deferral records (the captain's words). Moving a
# row's date while the fingerprint is unchanged is a re-date without new
# evidence; the second such re-date in a row is refused by `hold-gate` and,
# when it happened anyway (a direct tasks-axi hold), lists the row as
# `redated`. New evidence resets the count. A date that carries the captain's
# own deferral record (bin/fm-captain-hold.sh --captain-words-file) is never
# counted. Every observed re-date is appended to state/.queue-zero-redates.jsonl
# (kept seven days), with kind progress, none, captain, or refused.
#
# Rows from this home's backlog (source "queue"):
#   ready    queued, every blocker done, no active hold or its date has passed
#            (exactly bin/fm-tasks-axi.sh ready), excluding captain holds
#   redated  an open row re-dated twice running with no new evidence; listed
#            until it gains evidence, is started, or is closed
#   unowned  queued, not ready, filed at least FM_QUEUE_ZERO_AGE_DAYS ago
#            (default 1), and with no owner above, whatever its hold date
#   nocheck  a genuine captain call with no open blocker and no --until date
#            ahead, aged from its hold-set stamp (hold_age_days) or, once a
#            past --until date has lapsed, from that date, after
#            FM_FAR_HOLDS_DAYS (default 2, bin/fm-far-holds.sh's window). It
#            is answered, brought back to the captain through
#            bin/fm-captain-hold.sh hold, deferred with his words, or closed
#   orphan   in flight in the backlog with no live task record: the
#            "(main-inventory)" Bearings warning; close it or re-dispatch it
# Rows from the Paperclip board (source "paperclip"), only when this home
# configures the sweep: every row bin/fm-paperclip-sweep.sh scan prints.
#
# `scan` is read-only and prints one line per row,
# "<source> <class> <id> - <title> [<detail>]", or nothing when the queue is
# at zero; --json prints the row array; --local skips Paperclip (the teardown
# path uses it). It folds the current backlog into the ledger in memory.
#
# `check` is the watcher's heartbeat hook (bin/fm-watch.sh queue_zero_tick).
# It first folds the backlog into the ledger (as `observe`). When it reports,
# it appends one durable `check` wake (key queue-zero) naming every current
# row, then records the report and prints that same wake reason; otherwise it
# prints nothing. It reports only when a row appears that the last report did
# not carry, or when the set is unchanged but FM_QUEUE_ZERO_RENAG_HOURS
# (default 24) have passed since that report; a row that leaves and returns is
# a new episode. The report record is state/.queue-zero, written only after
# the wake is durably queued, so a failed append is retried rather than
# suppressed. The reason names rows by id only and is bounded by
# FM_QUEUE_ZERO_MAX_CHARS (default 1500) with a "+N more" tail.
#
# `observe` folds the current backlog into the ledger and prints nothing:
# bin/fm-captain-hold.sh runs it after every hold so the new date's evidence
# fingerprint is the one taken at hold time.
#
# `hold-gate <id> <date>` is asked before a hold sets <id>'s --until to <date>.
# It folds the current backlog into the ledger, then exits 0 when the hold may
# proceed, or exits 3 naming the only answers when it would be the second
# re-date running without new evidence since the last hold (and logs the
# refusal). Exit 2 means it could not read the backlog. bin/fm-captain-hold.sh
# hold asks it for every --until that is not the captain's own deferral; a
# direct tasks-axi re-date is caught by the fold as `redated` instead.
#
# `load` prints this home's attention numbers as one JSON object:
# {open, unowned, unowned_ids, unowned_over_day, unowned_over_day_ids,
# median_open_age_days, redates_no_progress}. unowned counts every open row
# with no owner (ready rows and orphans included); unowned_over_day those the
# ledger has seen unowned for 24 h or more; median_open_age_days is the median
# filed age of open rows (null when none); redates_no_progress counts ledger
# events of kind none or refused in the trailing 24 h. Read-only.
# bin/fm-attention-check.sh renders it per home.
#
# A home whose state directory is overridden without a matching data
# directory (FM_STATE_OVERRIDE set, FM_DATA_OVERRIDE unset) cannot pair its
# backlog with its task records, so every command stays silent (and
# hold-gate allows) there. FM_QUEUE_ZERO_NOW (UTC ISO-8601) pins the clock for
# tests.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RECORD="$STATE/.queue-zero"
RECORD_SCHEMA=fm-queue-zero-v1
LEDGER="$STATE/.queue-zero-holds.json"
LEDGER_SCHEMA=fm-queue-zero-holds-v1
EVENTS="$STATE/.queue-zero-redates.jsonl"
LEDGER_LOCKDIR="$STATE/.queue-zero-holds.lock"

usage() {
  cat <<'EOF'
Usage:
  fm-queue-zero.sh scan [--local] [--json]   list queued rows that must leave the queue now
  fm-queue-zero.sh check                      heartbeat hook: fold the re-date ledger, one wake per new episode
  fm-queue-zero.sh observe                    fold the re-date ledger now (run after every hold)
  fm-queue-zero.sh hold-gate <id> <date>      exit 0 when a hold may set <id>'s --until to <date>,
                                              3 when it is a second re-date without new evidence
  fm-queue-zero.sh load                       this home's attention numbers as JSON
  fm-queue-zero.sh --help                     print this help

Every listed row leaves the queue in the turn that sees it: dispatch a ready
row; start (give a running owner), close with a reason, or hold for the
captain's own decision an unowned or redated row - a date alone never clears it.
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
BR_TIMEOUT=$(whole_setting FM_QUEUE_ZERO_BR_TIMEOUT 5)
[ "$BR_TIMEOUT" -gt 0 ] || BR_TIMEOUT=5
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

json_lines() {  # stdin lines -> JSON string array
  jq -Rsc 'split("\n") | map(select(. != ""))'
}

# --- running owners -------------------------------------------------------------

# Row ids this home's beads crew queue mirrors through an open item's
# mirror:<id> label; [] when br or the queue is absent or unreadable in time.
crew_ids() {
  local db="$DATA/beads/.beads/beads.db" out
  if ! command -v br >/dev/null 2>&1 || [ ! -f "$db" ]; then
    printf '[]'
    return 0
  fi
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  out=$(fm_run_timed "$BR_TIMEOUT" br --db "$db" --no-auto-import --no-auto-flush \
    list --json -s all --limit 0 2>/dev/null) || { printf '[]'; return 0; }
  printf '%s' "$out" | jq -c '[.issues[]? | select(.status != "closed" and .status != "tombstone")
    | .labels[]? | select(startswith("mirror:")) | ltrimstr("mirror:")] | unique' 2>/dev/null \
    || printf '[]'
}

# Secondmate ids registered in data/secondmates.md.
secondmate_ids() {
  local line
  [ -f "$DATA/secondmates.md" ] || { printf '[]'; return 0; }
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" 2>/dev/null || continue
    printf '%s\n' "$SECONDMATE_REGISTRY_ID"
  done < "$DATA/secondmates.md" | json_lines
}

# Registered condition-watch names (process-event sources when-<name>).
watch_names() {
  local f name
  for f in "$STATE"/procevent/when-*.source; do
    [ -f "$f" ] || continue
    name=${f##*/when-}
    printf '%s\n' "${name%.source}"
  done | json_lines
}

# Per open row, the status-log size and whether a live task record exists:
# {"<id>": {"status": <bytes>, "worker": <bool>}}.
evidence_json() {  # <snapshot>
  local id size worker
  printf '%s' "$1" | jq -r '.backlog.records[] | select(.structured == true and .state != "done") | .id' \
    | while IFS= read -r id; do
        [ -n "$id" ] || continue
        size=0
        [ ! -f "$STATE/$id.status" ] || size=$(wc -c < "$STATE/$id.status" | tr -d ' ')
        worker=false
        [ ! -f "$STATE/$id.meta" ] || worker=true
        printf '%s\t%s\t%s\n' "$id" "$size" "$worker"
      done | jq -Rsc 'split("\n") | map(select(. != "") | split("\t")
        | {key:.[0], value:{status:(.[1] | tonumber), worker:(.[2] == "true")}}) | from_entries'
}

# --- the model --------------------------------------------------------------------

# MODEL is {rows, ledger, new_events, folded, load} for this home, computed from
# one backlog snapshot, the live owners, and the stored ledger. Nothing is
# written here; persist_model writes the ledger and its events.
MODEL=
MODEL_ERROR=
build_model() {
  local input ready_out ready_ids prev_ledger='{}' events='[]'
  MODEL=
  MODEL_ERROR=
  if [ ! -f "$DATA/backlog.md" ]; then
    input='{"backlog":{"records":[]},"tasks":[]}'
    ready_ids='[]'
  else
    input=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_SNAPSHOT_NOW="$NOW" \
      "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input 2>/dev/null) \
      || { MODEL_ERROR="the backlog could not be parsed"; return 1; }
    ready_out=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks-axi.sh" ready 2>&1) \
      || { MODEL_ERROR="tasks-axi ready failed: $(printf '%s' "$ready_out" | head -n 1)"; return 1; }
    # Rows of the TOON ready[N]{id,...} table: two-space indent, id first.
    ready_ids=$(printf '%s\n' "$ready_out" \
      | awk '/^ready\[[0-9]+\]/ { t = 1; next } t && /^  / { sub(/^  /, ""); split($0, f, ","); print f[1]; next } { t = 0 }' \
      | json_lines)
  fi
  if [ -f "$LEDGER" ] && jq -e --arg s "$LEDGER_SCHEMA" '.schema == $s' "$LEDGER" >/dev/null 2>&1; then
    prev_ledger=$(jq -c '.rows // {}' "$LEDGER")
  fi
  if [ -f "$EVENTS" ]; then
    events=$(jq -sc '.' "$EVENTS" 2>/dev/null) || events='[]'
  fi
  MODEL=$(printf '%s' "$input" | jq -c \
    --argjson ready "$ready_ids" --argjson ledger "$prev_ledger" --argjson events "$events" \
    --argjson evidence "$(evidence_json "$input")" --argjson crew "$(crew_ids)" \
    --argjson mates "$(secondmate_ids)" --argjson watches "$(watch_names)" \
    --arg today "$TODAY" --arg now "$NOW" --argjson now_epoch "$NOW_EPOCH" \
    --argjson age_days "$AGE_DAYS" --argjson captain_days "$CAPTAIN_DAYS" '
    def day_epoch: try ((. // "") + "T00:00:00Z" | fromdateiso8601) catch null;
    def owner_word: (.hold_reason // "") | (capture("^owner:[[:space:]]*(?<w>[A-Za-z0-9._-]+)").w // null);
    def direct($live):
      . as $r
      | if ($live | index($r.id)) != null then "worker"
        elif ($crew | index($r.id)) != null then "crew"
        elif ($r | owner_word) as $w | $w != null and ($mates | index($w)) != null then "secondmate"
        elif any($watches[]; . == $r.id or startswith($r.id + "--")) then "watch"
        elif $r.hold_kind == "captain" and (($r.hold_reason // "") | startswith("owner:") | not) then "captain"
        else null end;
    def owner($live; $by_id; $seen):
      . as $r
      | ($r | direct($live)) // (
          [ ($r.unresolved_blocker_ids // [])[] as $b
            | select(($seen | index($b)) == null)
            | $by_id[$b] | select(. != null and .state != "done")
            | owner($live; $by_id; $seen + [$b]) | select(. != null) ]
          | if length > 0 then "blocked-by" else null end);
    ($today | day_epoch) as $t
    | ([.tasks[].id]) as $live
    | ([.backlog.records[] | select(.structured == true)]) as $all
    | ([$all[] | {key:.id, value:.}] | from_entries) as $by_id
    | [$all[] | select(.state != "done")] as $open
    # Fold the ledger: a moved hold-until date is a re-date, scored against
    # the evidence fingerprint stored when the previous date was set.
    | [ $open[] | . as $r
        | ($evidence[$r.id] // {status:0, worker:false}) as $e
        | {status:$e.status, worker:$e.worker,
           blockers:(($r.blocked_by_ids // []) | sort | join(",")),
           deferrals:([($r.body_lines // [])[] | select(test("^Captain deferral until [0-9-]+:$"))] | length)} as $fp
        | ($ledger[$r.id]) as $prev
        | ($r.hold_until // "") as $until
        | ($r | owner($live; $by_id; [$r.id])) as $owner
        | (if $prev == null then {entry:{until:$until, fp:$fp, strikes:0}, event:null}
           elif $until != "" and ($prev.until // "") != "" and $until != $prev.until then
             (if any(($r.body_lines // [])[]; . == "Captain deferral until \($until):") then "captain"
              elif $fp != $prev.fp then "progress" else "none" end) as $kind
             | {entry:{until:$until, fp:$fp,
                       strikes:(if $kind == "none" then ($prev.strikes // 0) + 1 else 0 end)},
                event:{at:$now, id:$r.id, from:$prev.until, to:$until, kind:$kind}}
           elif $until != "" and ($prev.until // "") == "" then
             {entry:{until:$until, fp:$fp, strikes:($prev.strikes // 0)}, event:null}
           else {entry:{until:$prev.until, fp:$prev.fp, strikes:($prev.strikes // 0)}, event:null} end) as $step
        | {id:$r.id, row:$r, owner:$owner, cur_fp:$fp, event:$step.event,
           entry:($step.entry + {unowned_since:(
             if $owner != null then null
             elif $prev == null then (($r.since | day_epoch) // $now_epoch)
             else ($prev.unowned_since // $now_epoch) end)})} ] as $folded
    | ([$folded[] | .event | select(. != null)]) as $new_events
    | ($events + $new_events) as $all_events
    # Rows that must leave the queue now.
    | [ $folded[] | . as $f | $f.row as $r
        | (($r.hold_until // "") > $today) as $dated
        | (($r.since | day_epoch) as $s | $s != null and ($t - $s) >= ($age_days * 86400)) as $aged
        | ($ready | index($r.id)) as $is_ready
        | {source:"queue", ref:$r.id, title:($r.title // "")}
          + if $r.state == "queued" and $is_ready != null and $r.hold_kind != "captain" then
              {class:"ready", detail:("filed " + ($r.since // "undated"))}
            elif ($f.entry.strikes // 0) >= 2 and $f.owner != "worker" then
              {class:"redated",
               detail:("re-dated \($f.entry.strikes) times running with no new evidence, now until "
                       + ($r.hold_until // "-"))}
            elif $r.state == "queued" and $f.owner == null and $aged and $is_ready == null then
              {class:"unowned",
               detail:("no running owner"
                       + (if $r.hold_reason != null then "; held: " + $r.hold_reason else "" end)
                       + (if $dated then "; a date is not an owner (until " + $r.hold_until + ")" else "" end)
                       + "; filed " + ($r.since // "undated"))}
            elif $r.state == "queued" and $f.owner == "captain"
                 and ($r.hold_bucket == "live" or $r.hold_bucket == "aged") and ($dated | not)
                 and ((if $r.hold_until != null then ($r.hold_until | day_epoch) as $u
                         | if $u == null then null else (($t - $u) / 86400 | floor) end
                       else $r.hold_age_days end) as $lapsed
                      | $lapsed != null and $lapsed >= $captain_days) then
              {class:"nocheck",
               detail:("captain call with no blocker and "
                       + (if $r.hold_until != null then "a lapsed --until " + $r.hold_until
                          else "no --until date, aged \($r.hold_age_days)d" end)
                       + ": " + $r.hold_reason)}
            elif $r.state == "in_flight" and $r.requires_child_metadata == true and ($live | index($r.id)) == null then
              {class:"orphan", detail:"in flight with no live task record"}
            else empty end ]
    | map(.title |= (gsub("\\s+"; " ") | if length > 70 then .[:69] + "…" else . end)) as $rows
    | ([$folded[] | select(.owner == null)]) as $unowned
    | ([$unowned[] | select(($now_epoch - .entry.unowned_since) >= 86400)]) as $unowned_day
    | ([$open[] | .since | day_epoch | select(. != null) | ($t - .) / 86400 | floor] | sort) as $ages
    | ($ages | length) as $n
    | {rows:$rows,
       ledger:([$folded[] | {key:.id, value:.entry}] | from_entries),
       new_events:$new_events,
       folded:[$folded[] | {id, owner, until:.entry.until, fp:.entry.fp, cur_fp, strikes:.entry.strikes}],
       load:{open:($open | length),
             unowned:($unowned | length), unowned_ids:[$unowned[].id],
             unowned_over_day:($unowned_day | length), unowned_over_day_ids:[$unowned_day[].id],
             median_open_age_days:(if $n == 0 then null
                                   elif $n % 2 == 1 then $ages[($n - 1) / 2]
                                   else ($ages[$n / 2 - 1] + $ages[$n / 2]) / 2 end),
             redates_no_progress:([$all_events[]
               | select((.kind == "none" or .kind == "refused")
                        and ((.at | fromdateiso8601) > ($now_epoch - 86400)))] | length)}}') \
    || { MODEL=; MODEL_ERROR="the queue model could not be computed"; return 1; }
}

# --- the ledger -------------------------------------------------------------------

# One writer at a time, so a watcher fold and a hold gate cannot lose each
# other's ledger write.
LEDGER_LOCK_HELD=0
ledger_lock() {
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait "$LEDGER_LOCKDIR"
  LEDGER_LOCK_HELD=1
  trap ledger_unlock EXIT
}
ledger_unlock() {
  [ "$LEDGER_LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$LEDGER_LOCKDIR" || true
  LEDGER_LOCK_HELD=0
}

write_atomic() {  # <path> <content>
  local tmp
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$1.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$2" > "$tmp" || ! mv -f -- "$tmp" "$1"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Append events (a JSON array), keeping only the trailing seven days.
append_events() {  # <json-array>
  local kept
  kept=$( { [ ! -f "$EVENTS" ] || cat "$EVENTS"; printf '%s' "$1" | jq -c '.[]'; } \
    | jq -c --argjson cut $((NOW_EPOCH - 7 * 86400)) 'select((.at | fromdateiso8601) >= $cut)' 2>/dev/null) \
    || return 1
  write_atomic "$EVENTS" "$kept"
}

persist_model() {
  local new
  write_atomic "$LEDGER" "$(printf '%s' "$MODEL" | jq -c --arg s "$LEDGER_SCHEMA" '{schema:$s, rows:.ledger}')" \
    || return 1
  new=$(printf '%s' "$MODEL" | jq -c '.new_events')
  [ "$new" = '[]' ] || append_events "$new"
}

# Fold the current backlog into the stored ledger.
fold_ledger() {
  home_paired || return 0
  ledger_lock
  if build_model; then
    persist_model || printf 'fm-queue-zero: could not record the re-date ledger; the next fold retries it\n' >&2
  else
    printf 'fm-queue-zero: %s; the re-date ledger was not folded\n' "$MODEL_ERROR" >&2
  fi
  ledger_unlock
}

# --- commands -----------------------------------------------------------------------

paperclip_rows() {
  "$SCRIPT_DIR/fm-paperclip-sweep.sh" configured || { printf '[]'; return 0; }
  "$SCRIPT_DIR/fm-paperclip-sweep.sh" scan --json | jq -c 'map({source:"paperclip"} + .)' \
    || error_row paperclip "the sweep output could not be read"
}

all_rows() {  # [--local]
  local q p='[]'
  home_paired || { printf '[]'; return 0; }
  if [ -n "$MODEL" ] || build_model; then
    q=$(printf '%s' "$MODEL" | jq -c '.rows')
  else
    q=$(error_row queue "$MODEL_ERROR")
  fi
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
  fold_ledger
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
      + " (ready: dispatch it; unowned or redated: start it with a running owner, close it with a reason, or hold it"
      + " for the captain - a new date is not an answer; nocheck: answer or re-ask the captain; orphan: close or"
      + " re-dispatch; Paperclip: release, date, or decide; bin/fm-queue-zero.sh scan shows details): " + $kept.text
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

action_observe() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  fold_ledger
}

# A re-date is refused when the row was already re-dated once with no new
# evidence and nothing has changed since: same evidence fingerprint as when its
# current date was set. A live worker, a first date, or the same date passes.
action_hold_gate() {  # <id> <date>
  local id=${1:-} until=${2:-} verdict from
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  case "$until" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) die "hold-gate needs a YYYY-MM-DD date: $until" 2 ;;
  esac
  home_paired || return 0
  ledger_lock
  build_model || die "cannot judge re-dating $id: $MODEL_ERROR" 2
  persist_model || die "cannot record the re-date ledger before holding $id" 2
  verdict=$(printf '%s' "$MODEL" | jq -r --arg id "$id" --arg until "$until" '
    [.folded[] | select(.id == $id)][0] as $f
    | if $f == null or $f.owner == "worker" or ($f.until // "") == "" or $f.until == $until then "allow"
      elif ($f.strikes // 0) >= 1 and $f.cur_fp == $f.fp then "refuse \($f.until)"
      else "allow" end')
  if [ "${verdict%% *}" = refuse ]; then
    from=${verdict#refuse }
    append_events "$(jq -nc --arg now "$NOW" --arg id "$id" --arg from "$from" --arg to "$until" \
      '[{at:$now, id:$id, from:$from, to:$to, kind:"refused"}]')" || true
    ledger_unlock
    printf 'fm-queue-zero: refused: %s was already re-dated once with no new evidence, and nothing has changed since its last hold (no status line, linked worker, blocker change, or captain words); moving its date from %s to %s again is not an answer.\n' "$id" "$from" "$until" >&2
    printf 'fm-queue-zero: the only answers: start it (give it a running owner - dispatch a worker, hand it to the beads crew or a secondmate, or arm a condition watch named %s), close it with a reason, or hold it for the captain'"'"'s own decision (bin/fm-captain-hold.sh hold %s --reason "<the question>", or record his deferral with --until <date> --captain-words-file <file>).\n' "$id" "$id" >&2
    exit 3
  fi
  ledger_unlock
}

action_load() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  if ! home_paired; then
    jq -nc '{open:0, unowned:0, unowned_ids:[], unowned_over_day:0, unowned_over_day_ids:[],
      median_open_age_days:null, redates_no_progress:0}'
    return 0
  fi
  build_model || die "$MODEL_ERROR" 1
  printf '%s\n' "$MODEL" | jq -c '.load'
}

command -v jq >/dev/null 2>&1 || die "jq not found"
case "${1:-}" in
  scan) shift; action_scan "$@" ;;
  check) action_check ;;
  observe) shift; action_observe "$@" ;;
  hold-gate) shift; action_hold_gate "$@" ;;
  load) shift; action_load "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
