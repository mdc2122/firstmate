#!/usr/bin/env bash
# tests/fm-wake-coalesce.test.sh - routine-wake coalescing, cross-surface
# presented-outcome dedupe, and the idle-after-done stale class. Real
# processes everywhere: a real
# fm-watch.sh subprocess against fake tmux, the real drain, and the real
# inactive reconcile scanner.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
RECON="$ROOT/bin/fm-inactive-reconcile.sh"
PUSH_LIB="$ROOT/bin/fm-push-transition-lib.sh"
CLASSIFY_LIB="$ROOT/bin/fm-classify-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-coalesce)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

classify_lib() {  # <state> <function> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$CLASSIFY_LIB" "$@"
}

# --- fixture ---------------------------------------------------------------

# One-window fake tmux. FM_FAKE_TMUX_CAPTURE holds the pane text.
make_case() {  # <name> -> dir with state/, fakebin/, meta
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] || printf 'fm-t1\n'; exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '%s\n' "${FM_FAKE_TMUX_CURSOR_Y:-2}"; exit 0 ;;
        *pane_current_command*) printf 'claude\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -f "$FM_FAKE_TMUX_CAPTURE" ]; then
      cat "$FM_FAKE_TMUX_CAPTURE"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  make_fake_crew_state "$fakebin" >/dev/null
  printf '%s\n' "$dir"
}

make_meta() {  # <state> <task>
  fm_write_meta "$1/$2.meta" "window=sess:fm-t1" "kind=ship" "harness=grok"
}

watch_bg() {  # <state> <fakebin> <out> [extra env...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · fake default' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=1 FM_STALE_ESCALATE_SECS=2 FM_PAUSE_RESURFACE_SECS=3 \
    env "$@" "$WATCH" > "$out" 2>/dev/null &
}

wait_watcher_gone() {  # <pid> [limit-ticks]
  local pid=$1 limit=${2:-120} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

age_path() {  # <path>...
  local p
  for p in "$@"; do touch -t 202001010000 "$p"; done
}

# A status file whose LAST line is `done:` plus the presentation cursor that
# marks the whole log already presented (ident+offset committed by
# status_commit_presentation_snapshot through the real drain helper).
presented_status() {  # <state> <task> <line>
  local state=$1 task=$2 line=$3
  printf '%s\n' "$line" > "$state/$task.status"
  age_path "$state/$task.status"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    STATE=$2
    snap=$(status_presentation_snapshot "$STATE")
    ack=$(status_acknowledge_presented_snapshot "$STATE" "$snap" "$3")
    status_commit_presentation_snapshot "$STATE" "$ack"
  ' _ "$CLASSIFY_LIB" "$state" "$task"
}

# Emit one wake through the real watcher wake(), which records the queue
# sequence it covers.
emit_wake() {  # <state> <reason>
  FM_STATE_OVERRIDE="$1" bash -c '. "$1"; wake "$2"' _ "$PUSH_LIB" "$2" > /dev/null
}

# Seed one unheld queue row as already DELIVERED: its wake was emitted, the
# durable episode is mid-handling (pending:handling), and the watcher starts as
# the handling successor, so startup emits no resurface wake and the poll loop
# reaches the routine batch. This mirrors a wake delivered to a busy main whose
# drain has not yet claimed its rows.
seed_unheld_delivered_row() {  # <state>
  append_wake "$1" check "wake-queue-stall-5" "check: wake-queue stalled"
  emit_wake "$1" "check: wake-queue stalled"
  printf 'pending:handling:gen-delivered\n' > "$1/.watcher-down"
}

# The coalescing cases below launch the watcher as a handling successor so the
# seeded episode stays pending:handling and no rearm-resurface close fires.
COALESCE_ENV=FM_WATCH_HANDLING_SUCCESSOR=1

# --- (1) routine-wake coalescing ---------------------------------------------

test_routine_turnend_coalesces_with_pending_row() {
  local dir state out pid
  dir=$(make_case coalesce1); state="$dir/state"
  make_meta "$state" t1
  # A queued row still waiting on the drain of its already-delivered wake.
  seed_unheld_delivered_row "$state"
  # A bare turn-end signal pending detection.
  : > "$state/t1.turn-ended"
  watch_bg "$state" "$dir/fakebin" "$dir/watch.out" \
    FM_FAKE_TMUX_CAPTURE= $COALESCE_ENV
  pid=$!
  # A coalesced routine batch leaves the watcher ALIVE (no close was
  # delivered); poll until the row lands, then assert no signal close escaped.
  local i=0
  while [ "$i" -lt 120 ]; do
    grep -qF 'turn-ended' "$state/.wake-queue" 2>/dev/null && break
    sleep 0.25
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null \
    || fail "the watcher exited on a coalesced routine batch (a wake escaped): $(cat "$dir/watch.out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  # The turn-end row MUST be in the durable queue (durable, ack-granular),
  # but the batch must not have re-delivered as its own wake close - the
  # pending wake for the earlier row covers it. (The worker's later stale
  # pane is a separate, ordinary surface and may still wake.)
  grep -qF 'turn-ended' "$state/.wake-queue" \
    || fail "the routine turn-end row was lost from the durable queue"
  ! grep -q '^signal:' "$dir/watch.out" \
    || fail "a routine signal still emitted its own wake: $(cat "$dir/watch.out")"
  # The NEXT drain must present the coalesced row: coalescing defers delivery,
  # it never drops the row from presentation.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2>/dev/null
  grep -qF 'turn-ended' "$dir/drain.out" \
    || fail "the next drain did not present the coalesced row: $(cat "$dir/drain.out")"
  pass "watcher: a bare turn-end batch coalesces into the already-queued wake rows with no separate delivery"
}

test_routine_turnend_wakes_when_queue_empty() {
  local dir state out pid
  dir=$(make_case coalesce2); state="$dir/state"
  make_meta "$state" t1
  : > "$state/t1.turn-ended"
  watch_bg "$state" "$dir/fakebin" "$dir/watch.out" \
    FM_FAKE_TMUX_CAPTURE= $COALESCE_ENV
  pid=$!
  wait_watcher_gone "$pid" 80 || { kill "$pid" 2>/dev/null; fail "watcher did not exit" ; }
  wait "$pid" 2>/dev/null || true
  grep -q '^signal:' "$dir/watch.out" \
    || fail "a lone routine signal must still wake with an empty queue: $(cat "$dir/watch.out")"
  grep -qF 'turn-ended' "$state/.wake-queue" \
    || fail "the lone routine row was lost from the durable queue"
  pass "watcher: a bare turn-end still wakes when no pending wake already covers the queue"
}

test_turnend_behind_unwoken_row_still_wakes() {
  # A row an external producer queued without a wake (fm-inbox.sh note) is
  # unheld but no wake covers it: a bare turn-end must still close the cycle
  # so both rows reach the conversation now, not at the stall alarm.
  local dir state pid
  dir=$(make_case coalesce7); state="$dir/state"
  make_meta "$state" t1
  # An earlier wake was emitted, drained, and acknowledged.
  append_wake "$state" check "earlier" "check: earlier"
  emit_wake "$state" "check: earlier"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > /dev/null 2> "$dir/drain.err"
  ack_drain_err "$state" "$dir/drain.err" > /dev/null 2>&1 || fail "fixture: the earlier wake could not be acknowledged"
  ! grep -qF 'check: earlier' "$state/.wake-queue" || fail "fixture: the earlier row survived its ack"
  append_wake "$state" check "inbox:note-1" "check inbox:note-1"
  printf 'pending:handling:gen-unwoken\n' > "$state/.watcher-down"
  : > "$state/t1.turn-ended"
  watch_bg "$state" "$dir/fakebin" "$dir/watch.out" \
    FM_FAKE_TMUX_CAPTURE= $COALESCE_ENV
  pid=$!
  wait_watcher_gone "$pid" 80 || { kill "$pid" 2>/dev/null; fail "a turn-end behind an unwoken row was coalesced: $(cat "$dir/watch.out")" ; }
  wait "$pid" 2>/dev/null || true
  grep -q '^signal:' "$dir/watch.out" \
    || fail "a turn-end behind a row queued without a wake must wake: $(cat "$dir/watch.out")"
  grep -qF 'turn-ended' "$state/.wake-queue" \
    || fail "the routine turn-end row was lost from the durable queue"
  pass "watcher: a bare turn-end behind a row no emitted wake covers still wakes"
}

test_status_signal_never_coalesces() {
  local dir state out pid
  dir=$(make_case coalesce3); state="$dir/state"
  make_meta "$state" t1
  seed_unheld_delivered_row "$state"
  printf 'done: shipped\n' > "$state/t1.status"
  watch_bg "$state" "$dir/fakebin" "$dir/watch.out" \
    FM_FAKE_TMUX_CAPTURE= $COALESCE_ENV
  pid=$!
  wait_watcher_gone "$pid" 80 || { kill "$pid" 2>/dev/null; fail "watcher did not exit" ; }
  wait "$pid" 2>/dev/null || true
  grep -q '^signal:' "$dir/watch.out" \
    || fail "a captain-facing status signal must never be batched: $(cat "$dir/watch.out")"
  pass "watcher: a status-carrying signal always wakes even with queued rows"
}

test_mixed_signal_batch_never_coalesces() {
  local dir state out pid
  dir=$(make_case coalesce4); state="$dir/state"
  make_meta "$state" t1; make_meta "$state" t2
  seed_unheld_delivered_row "$state"
  : > "$state/t1.turn-ended"
  printf 'needs-decision: which branch\n' > "$state/t2.status"
  watch_bg "$state" "$dir/fakebin" "$dir/watch.out" \
    FM_FAKE_TMUX_CAPTURE= $COALESCE_ENV
  pid=$!
  wait_watcher_gone "$pid" 80 || { kill "$pid" 2>/dev/null; fail "watcher did not exit" ; }
  wait "$pid" 2>/dev/null || true
  grep -q '^signal:' "$dir/watch.out" \
    || fail "a mixed batch containing a decision must wake: $(cat "$dir/watch.out")"
  pass "watcher: a batch containing needs-decision is never batched as routine"
}

test_two_bare_turnends_without_pending_row_wake_together() {
  # Independence: the coalescing decision reads the durable queue, not the
  # batch size. Two bare turn-ends in one batch with NO unheld row must still
  # close the cycle exactly once, so the routine path cannot swallow the very
  # first routine event.
  local dir state out pid
  dir=$(make_case coalesce5); state="$dir/state"
  make_meta "$state" t1; make_meta "$state" t2
  : > "$state/t1.turn-ended"
  : > "$state/t2.turn-ended"
  watch_bg "$state" "$dir/fakebin" "$dir/watch.out" FM_FAKE_TMUX_CAPTURE=
  pid=$!
  wait_watcher_gone "$pid" 80 || { kill "$pid" 2>/dev/null; fail "watcher did not exit" ; }
  wait "$pid" 2>/dev/null || true
  grep -q '^signal:' "$dir/watch.out" \
    || fail "two bare turn-ends with an empty queue must wake: $(cat "$dir/watch.out")"
  if ! grep -qF 't1.turn-ended' "$state/.wake-queue" \
    || ! grep -qF 't2.turn-ended' "$state/.wake-queue"; then
    fail "both routine rows must stay durable: $(cat "$state/.wake-queue")"
  fi
  pass "watcher: routine coalescing reads the queue, so an empty-queue routine batch still wakes once"
}

test_stale_pane_still_closes_beside_coalesced_turnend() {
  # Independence: stale is outside the enumerated routine set. With an unheld
  # row present, a bare turn-end coalesces, but the same task's pane-staleness
  # backbone must still close the cycle with its own stale wake.
  local dir state out pid
  dir=$(make_case coalesce6); state="$dir/state"
  make_meta "$state" t1
  seed_unheld_delivered_row "$state"
  : > "$state/t1.turn-ended"
  watch_bg "$state" "$dir/fakebin" "$dir/watch.out" \
    FM_FAKE_TMUX_CAPTURE= $COALESCE_ENV
  pid=$!
  wait_watcher_gone "$pid" 160 || { kill "$pid" 2>/dev/null; fail "watcher did not exit" ; }
  wait "$pid" 2>/dev/null || true
  grep -q '^stale:' "$dir/watch.out" \
    || fail "a stale-pane wake must never be swallowed by turn-end coalescing: $(cat "$dir/watch.out")"
  pass "watcher: a stale-pane wake keeps its own close even beside a coalesced turn-end batch"
}


# --- (1) per-row ack granularity after interruption ---------------------------

test_ack_through_leaves_unacked_rows() {
  local dir state out err seq gen
  dir=$(make_case ackrows); state="$dir/state"
  append_wake "$state" signal "a.turn-ended" "signal: a.turn-ended"
  append_wake "$state" signal "b.turn-ended" "signal: b.turn-ended"
  append_wake "$state" check "k1" "check: k1"
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN" 2>"$dir/drain.err")
  err="$dir/drain.err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || fail "no ack boundary: $err"
  # Acknowledge only through the first row's sequence.
  first_seq=$(awk -F '\t' 'NR==1{print $2}' "$state/.wake-queue")
  [ "$first_seq" -le "$seq" ] || fail "fixture: first row seq $first_seq > presented $seq"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$first_seq" --recovery-generation "$gen"
  # Rows after the cutoff must still be queued.
  [ "$(awk -F '\t' 'NF>=5' "$state/.wake-queue" | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "rows above the cutoff were consumed: $(cat "$state/.wake-queue")"
  # Re-drain presents only the still-unacknowledged rows, not the burst -
  # the acknowledged a.turn-ended row must never re-present.
  out2=$(FM_STATE_OVERRIDE="$state" "$DRAIN" 2>/dev/null)
  printf '%s\n' "$out2" | grep -qF 'b.turn-ended' \
    || fail "redrain lost the unacknowledged signal row: $out2"
  printf '%s\n' "$out2" | grep -qF 'check: k1' \
    || fail "redrain lost the unacknowledged check row: $out2"
  ! printf '%s\n' "$out2" | grep -qF 'a.turn-ended' \
    || fail "redrain re-presented the already-acknowledged row: $out2"
  pass "drain: ack-through consumes only its rows; unacked rows re-present alone"
}

test_ack_through_is_not_circular() {
  # Independence of the acknowledgement circuit from the interrupt atom: a
  # monotonic --ack-through must consume exactly the rows at or below its
  # cutoff and never a higher one, so a replayed/stale ack can never eat a
  # later wake that arrived after presentation.
  local dir state out err seq gen low mid high remaining
  dir=$(make_case ackcircuit); state="$dir/state"
  append_wake "$state" signal "a.turn-ended" "signal: a"
  append_wake "$state" signal "b.turn-ended" "signal: b"
  append_wake "$state" signal "c.turn-ended" "signal: c"
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN" 2>"$dir/drain.err")
  err="$dir/drain.err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || fail "no ack boundary: $err"
  low=$(awk -F '\t' 'NR==1{print $2}' "$state/.wake-queue")
  mid=$(awk -F '\t' 'NR==2{print $2}' "$state/.wake-queue")
  high=$(awk -F '\t' 'NR==3{print $2}' "$state/.wake-queue")
  [ "$low" -lt "$mid" ] && [ "$mid" -lt "$high" ] \
    || fail "fixture: queue sequences are not monotonic: $low $mid $high"
  # Acknowledge only the middle cutoff while the top row stays presented.
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$mid" --recovery-generation "$gen"
  remaining=$(awk -F '\t' 'NF>=5 {print $4}' "$state/.wake-queue" | tr '\n' ' ')
  [ "$remaining" = 'c.turn-ended ' ] \
    || fail "ack-through $mid must leave only the higher row: got '$remaining'"
  # A replay of the SAME cutoff must still not consume the higher row.
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$mid" --recovery-generation "$(recovery_marker_generation "$state/.watcher-down")" 2>/dev/null || true
  remaining=$(awk -F '\t' 'NF>=5 {print $4}' "$state/.wake-queue" | tr '\n' ' ')
  [ "$remaining" = 'c.turn-ended ' ] \
    || fail "a replayed ack-through $mid consumed a higher row: got '$remaining'"
  pass "drain: ack-through is monotonic per actor and a replay cannot consume a higher wake"
}

# --- (2) cross-surface presented-outcome dedupe --------------------------------

test_inactive_reconcile_skips_presented_outcome() {
  local dir state out
  dir=$(make_case crossdedupe); state="$dir/state"
  make_meta "$state" t1
  # Task done, status presented through the drain's manifest.
  presented_status "$state" t1 'done: PR https://github.com/x/y/pull/1 checks green'
  age_path "$state/t1.meta"
  out=$(FM_STATE_OVERRIDE="$state" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: done · source: fake' \
    "$RECON" scan 2>/dev/null || true)
  [ -z "$out" ] || fail "an already-presented outcome queued a repeat notice: $out"
  [ ! -s "$state/.wake-queue" ] \
    || fail "an already-presented outcome queued a check row: $(cat "$state/.wake-queue")"
  pass "inactive-reconcile: a presented terminal outcome never queues its own wake"
}

test_inactive_reconcile_queues_unannounced_finish() {
  # The log's last line is a presented `working:` while crew-state reports
  # done from run/PR state: the completion itself was never announced, so the
  # presentation row must still be queued.
  local dir state out
  dir=$(make_case crossdedupe3); state="$dir/state"
  make_meta "$state" t1
  presented_status "$state" t1 'working: running validation'
  age_path "$state/t1.meta"
  out=$(FM_STATE_OVERRIDE="$state" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: done · source: fake' \
    "$RECON" scan 2>/dev/null || true)
  grep -qF 'inactive-outcome:' "$state/.wake-queue" \
    || fail "an unannounced finish behind a presented working line was swallowed: out=$out queue=$(cat "$state/.wake-queue" 2>/dev/null)"
  ! ls "$state/terminal-outcomes/"*.presented >/dev/null 2>&1 \
    || fail "an unannounced finish was marked presented: $(ls "$state/terminal-outcomes")"
  pass "inactive-reconcile: a crew-state done behind a presented non-terminal line still queues its presentation"
}

test_inactive_reconcile_queues_unpresented_outcome() {
  local dir state out
  dir=$(make_case crossdedupe2); state="$dir/state"
  make_meta "$state" t1
  printf 'done: work complete\n' > "$state/t1.status"
  age_path "$state/t1.status" "$state/t1.meta"
  out=$(FM_STATE_OVERRIDE="$state" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: done · source: fake' \
    "$RECON" scan 2>/dev/null || true)
  printf '%s' "$out" | grep -q 'inactive terminal outcome' \
    || fail "an unpresented terminal outcome was silently dropped: $out"
  grep -qF 'inactive-outcome:' "$state/.wake-queue" \
    || fail "an unpresented outcome queued no durable row: $(cat "$state/.wake-queue")"
  pass "inactive-reconcile: an unpresented terminal outcome still queues its presentation wake"
}

# --- (3) idle-after-done: one low-priority notice, no wedge ---------------------

test_done_outcome_absorbs_stale_pane() {
  local dir state out pid i
  dir=$(make_case donestale); state="$dir/state"
  make_meta "$state" t1
  # done + already presented through the cursor (age_path inside keeps the
  # identity stable for the watcher's own read).
  presented_status "$state" t1 'done: finished, awaiting teardown'
  # Prime the signal seen-markers so the append is not the surface under test.
  prime_status_seen "$state" "$state/t1.status"
  watch_bg "$state" "$dir/fakebin" "$dir/watch.out" FM_FAKE_TMUX_CAPTURE=
  pid=$!
  # Two stable idle polls trip the stale backbone; the done-outcome bound must
  # then absorb rather than escalate. Poll for the triage line that proves the
  # bound engaged, so a slow start cannot pass this vacuously.
  i=0
  while [ "$i" -lt 200 ]; do
    grep -q 'terminal outcome already presented' "$dir/watch.out" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null \
    || fail "the watcher exited instead of absorbing a cleanup-pending done pane: $(cat "$dir/watch.out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  grep -q 'terminal outcome already presented' "$dir/watch.out" \
    || fail "the done-outcome stale bound never engaged: out=$(cat "$dir/watch.out")"
  # At most one low-priority recheck notice per resurface window, never a run.
  [ "$(grep -c '^stale:' "$dir/watch.out")" -le 1 ] \
    || fail "a cleanup-pending done worker kept re-surfacing: $(cat "$dir/watch.out")"
  ! grep -qF 'possible wedge' "$dir/watch.out" \
    || fail "a done worker awaiting cleanup produced a wedge escalation: $(cat "$dir/watch.out")"
  ! grep -qF 'demand-deep-inspection' "$dir/watch.out" \
    || fail "a done worker awaiting cleanup produced a wedge demand: $(cat "$dir/watch.out")"
  pass "watcher: a done worker awaiting firstmate cleanup absorbs to one low-priority recheck, never a wedge"
}

test_unpresented_done_stale_surfaces() {
  local dir state out pid
  dir=$(make_case undonestale); state="$dir/state"
  make_meta "$state" t1
  printf 'done: unpresented\n' > "$state/t1.status"
  age_path "$state/t1.status"
  # Prime the signal seen-markers so the append itself is not the surface
  # under test: the pane staleness path must surface the unpresented outcome.
  prime_status_seen "$state" "$state/t1.status"
  watch_bg "$state" "$dir/fakebin" "$dir/watch.out" \
    FM_FAKE_TMUX_CAPTURE= FM_INACTIVE_RECONCILE_SECS=60
  pid=$!
  # Poll until the outcome surfaces through either the pane-staleness path or
  # the inactive-reconcile path; either way it must never be silently dropped.
  local i=0
  while [ "$i" -lt 200 ]; do
    grep -q '^stale:\|inactive-outcome' "$dir/watch.out" "$state/.wake-queue" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  grep -q '^stale:' "$dir/watch.out" \
    || grep -q 'inactive-outcome' "$state/.wake-queue" \
    || fail "an unpresented terminal outcome was silently dropped: out=$(cat "$dir/watch.out") queue=$(cat "$state/.wake-queue")"
  pass "watcher: a terminal outcome never presented still surfaces (stale pane or inactive reconcile)"
}

test_coalescing_never_touches_branch_granted_rows() {
  # Independence from the supervision-branch contract: a branch-reserved row is
  # NOT counted as an unheld row for main's routine coalescing (the unheld count
  # excludes claimed and branch-granted rows), so a routine turn-end cannot be
  # silently batched behind a row the branch owns, and the grant row itself
  # survives untouched.
  local dir state pid
  dir=$(make_case branchgrant); state="$dir/state"
  make_meta "$state" t1
  append_wake "$state" signal "task-a.status" "signal: task-a"
  emit_wake "$state" "signal: task-a"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" activate "$$" branchgrant || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" publish branchgrant 1 || fail "branch grant publication failed"
  # A mid-handling episode with the handling-successor start, so the direct
  # append above does not force a resurface close before the scan.
  printf 'pending:handling:gen-grant\n' > "$state/.watcher-down"
  # A bare turn-end with ONLY the branch-granted row queued must still close:
  # the granted row reserves nothing for main, so it cannot cover the batch.
  : > "$state/t1.turn-ended"
  watch_bg "$state" "$dir/fakebin" "$dir/watch.out" \
    FM_FAKE_TMUX_CAPTURE= $COALESCE_ENV
  pid=$!
  wait_watcher_gone "$pid" 80 || { kill "$pid" 2>/dev/null; fail "watcher did not exit" ; }
  wait "$pid" 2>/dev/null || true
  grep -q '^signal:' "$dir/watch.out" \
    || fail "a branch-granted row must not cover a routine turn-end: $(cat "$dir/watch.out")"
  grep -qF 'task-a.status' "$state/.wake-queue" \
    || fail "the branch-granted row was consumed: $(cat "$state/.wake-queue")"
  pass "watcher: routine coalescing counts only main-unheld rows and never eats or covers a branch grant"
}

# --- runner -----------------------------------------------------------------

test_routine_turnend_coalesces_with_pending_row
test_routine_turnend_wakes_when_queue_empty
test_turnend_behind_unwoken_row_still_wakes
test_status_signal_never_coalesces
test_mixed_signal_batch_never_coalesces
test_two_bare_turnends_without_pending_row_wake_together
test_stale_pane_still_closes_beside_coalesced_turnend
test_ack_through_leaves_unacked_rows
test_ack_through_is_not_circular
test_inactive_reconcile_skips_presented_outcome
test_inactive_reconcile_queues_unannounced_finish
test_inactive_reconcile_queues_unpresented_outcome
test_done_outcome_absorbs_stale_pane
test_unpresented_done_stale_surfaces
test_coalescing_never_touches_branch_granted_rows

printf 'fm-wake-coalesce.test.sh: all tests passed\n'
