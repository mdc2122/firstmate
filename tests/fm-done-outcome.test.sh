#!/usr/bin/env bash
# tests/fm-done-outcome.test.sh - the inactive-outcome backstop and the
# idle-after-done stale class. Real processes everywhere: a real fm-watch.sh
# subprocess against fake tmux, the real drain, and the real inactive
# reconcile scanner.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
RECON="$ROOT/bin/fm-inactive-reconcile.sh"
CLASSIFY_LIB="$ROOT/bin/fm-classify-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-done-outcome)
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

# Stop a background watcher. 0 iff it was still running (killed: non-zero
# status); a watcher that already closed a cycle on its own exits 0.
stop_watcher_was_running() {  # <pid>
  local rc=0
  kill "$1" 2>/dev/null
  wait "$1" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
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

# --- (1) inactive-outcome backstop is acknowledgement-bound ---------------------

test_inactive_reconcile_backstops_unacked_presentation() {
  # A drain prints the done line (committing the status presentation cursor)
  # and its handling turn is interrupted before --ack-through: print time is
  # not acknowledgement, so the backstop must still queue its check row.
  local dir state out
  dir=$(make_case unackedpresent); state="$dir/state"
  make_meta "$state" t1
  printf 'done: PR https://github.com/x/y/pull/1 checks green\n' > "$state/t1.status"
  age_path "$state/t1.status"
  append_wake "$state" signal "t1.status" "signal: $state/t1.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err"
  classify_lib "$state" status_presented_outcome_covers "$state/t1.status" \
    || fail "fixture: the drain did not print and commit the done line: $(cat "$dir/drain.out")"
  age_path "$state/t1.status" "$state/t1.meta"
  out=$(FM_STATE_OVERRIDE="$state" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: done · source: fake' \
    "$RECON" scan 2>/dev/null || true)
  grep -qF 'inactive-outcome:' "$state/.wake-queue" \
    || fail "an outcome printed but never acknowledged lost its backstop: out=$out queue=$(cat "$state/.wake-queue")"
  ! ls "$state/terminal-outcomes/"*.presented >/dev/null 2>&1 \
    || fail "an unacknowledged outcome was marked presented: $(ls "$state/terminal-outcomes")"
  pass "inactive-reconcile: an outcome printed by an interrupted, unacknowledged turn still queues its backstop"
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

# --- (2) idle-after-done: one low-priority notice, no wedge ---------------------

# Run the watcher over a presented done pane until it either closes a cycle on
# its own or absorbs a done-stale sighting (the triage line), then stop it.
# Prints `woke`, `absorbed`, or `idle` (neither happened); a wake is then drained and acknowledged, as
# firstmate's handling turn would.
done_stale_run() {  # <dir> <capture> <out>
  local dir=$1 cap=$2 out=$3 state="$1/state" pid i before now
  before=$(grep -c 'absorbed stale (done outcome' "$state/.watch-triage.log" 2>/dev/null)
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_FAKE_TMUX_CAPTURE="$cap" FM_PAUSE_RESURFACE_SECS=600
  pid=$!
  i=0
  while [ "$i" -lt 200 ]; do
    [ -s "$out" ] && break
    now=$(grep -c 'absorbed stale (done outcome' "$state/.watch-triage.log" 2>/dev/null)
    [ "${now:-0}" -gt "${before:-0}" ] && break
    sleep 0.25
    i=$((i + 1))
  done
  if stop_watcher_was_running "$pid"; then
    now=$(grep -c 'absorbed stale (done outcome' "$state/.watch-triage.log" 2>/dev/null)
    if [ "${now:-0}" -gt "${before:-0}" ]; then printf 'absorbed\n'; else printf 'idle\n'; fi
    return 0
  fi
  printf 'woke\n'
  FM_STATE_OVERRIDE="$state" "$DRAIN" > /dev/null 2> "$dir/drain.err"
  ack_drain_err "$state" "$dir/drain.err" > /dev/null 2>&1
}

test_done_outcome_absorbs_stale_pane() {
  local dir state r
  dir=$(make_case donestale); state="$dir/state"
  make_meta "$state" t1
  presented_status "$state" t1 'done: finished, awaiting teardown'
  prime_status_seen "$state" "$state/t1.status"
  printf 'idle pane A\n' > "$dir/capA"
  printf 'idle pane B\n' > "$dir/capB"
  # First sight: exactly one low-priority stale close.
  r=$(done_stale_run "$dir" "$dir/capA" "$dir/watch1.out")
  [ "$r" = woke ] || fail "the first done-stale sighting did not close the cycle: $(cat "$dir/watch1.out")"
  grep -q '^stale: .*terminal outcome already presented' "$dir/watch1.out" \
    || fail "the first sighting was not the bounded done-stale notice: $(cat "$dir/watch1.out")"
  # A new pane hash inside the resurface window is absorbed, never re-surfaced.
  r=$(done_stale_run "$dir" "$dir/capB" "$dir/watch2.out")
  [ "$r" = absorbed ] || fail "a new hash inside the window re-surfaced: $(cat "$dir/watch2.out")"
  [ ! -s "$dir/watch2.out" ] || fail "a new hash inside the window emitted a wake: $(cat "$dir/watch2.out")"
  ! grep -qF 'possible wedge' "$dir/watch1.out" \
    || fail "a done worker awaiting cleanup produced a wedge escalation: $(cat "$dir/watch1.out")"
  pass "watcher: a done worker awaiting firstmate cleanup wakes once, absorbs a new hash in the window, never a wedge"
}

test_done_stale_after_steer_wakes() {
  # Done presented, a follow-up steer delivered (and acknowledged), then the
  # worker idles on a new hash: it was re-engaged, so the stale wakes.
  local dir state r rec
  dir=$(make_case donesteer); state="$dir/state"
  make_meta "$state" t1
  presented_status "$state" t1 'done: finished, awaiting teardown'
  prime_status_seen "$state" "$state/t1.status"
  printf 'idle pane A\n' > "$dir/capA"
  printf 'blocked on a permission prompt\n' > "$dir/capB"
  r=$(done_stale_run "$dir" "$dir/capA" "$dir/watch1.out")
  [ "$r" = woke ] || fail "fixture: the first done-stale sighting did not wake: $(cat "$dir/watch1.out")"
  rec=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_task_inbox_write "$2" t1 "also fix the flaky test"' \
    _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state") || fail "fixture: steer write failed"
  mv "$rec" "$state/t1.inbox/handled/" || fail "fixture: steer acknowledgement failed"
  r=$(done_stale_run "$dir" "$dir/capB" "$dir/watch2.out")
  [ "$r" = woke ] || fail "a re-engaged worker's idle pane was absorbed: triage=$(cat "$state/.watch-triage.log" 2>/dev/null)"
  grep -q '^stale:' "$dir/watch2.out" \
    || fail "a re-engaged worker's idle pane did not wake stale: $(cat "$dir/watch2.out")"
  ! grep -q 'terminal outcome already presented' "$dir/watch2.out" \
    || fail "a re-engaged worker was still treated as cleanup-pending: $(cat "$dir/watch2.out")"
  pass "watcher: a steer delivered after the presented outcome makes the next idle sighting wake as ordinary stale"
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

# --- runner -----------------------------------------------------------------

test_inactive_reconcile_backstops_unacked_presentation
test_inactive_reconcile_queues_unannounced_finish
test_inactive_reconcile_queues_unpresented_outcome
test_done_outcome_absorbs_stale_pane
test_done_stale_after_steer_wakes
test_unpresented_done_stale_surfaces

printf 'fm-done-outcome.test.sh: all tests passed\n'
