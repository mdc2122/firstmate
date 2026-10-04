#!/usr/bin/env bash
# Opt-in credentialed omp (Oh My Pi) supervision-branch regression in an
# isolated lab checkout. It drives real omp through JSON-RPC stdio mode with
# the captain's existing omp login and the captain-approved openai-codex model,
# exactly like tests/fm-omp-primary-live-e2e.test.sh.
#
# The lab proves against the installed omp what the portable suite
# (tests/fm-omp-branch.test.sh) can only pin over a fake API:
#   1. config/omp-supervision-branch absent: no branch tools, no shadow log, and
#      every wake goes to main exactly as before;
#   2. report-only: main still handles the wake, the branch writes only the
#      report-only shadow log and never the real outcome store;
#   3. mode on: the same wake reaches the branch first (no main follow-up), the
#      durable outcome lands, and a second session run in the same process
#      replays a stored outcome after restart;
#   4. F5 live: exactly one fm-watch-arm.sh process runs with the branch present.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_OMP_BRANCH_LIVE_E2E omp node jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  if [ -f "${RPC_LOG:-}" ]; then
    printf '# rpc frame types seen:\n' >&2
    grep -o '"type":"[a-z_]*"' "$RPC_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -30 >&2
  fi
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

OMP_VERSION=$(omp --version 2>/dev/null | head -1)
MODEL=${FM_OMP_BRANCH_LIVE_MODEL:-openai-codex/gpt-6-astra}
LAB="$ROOT/.omp-branch-live-e2e.$$"
PROJECT="$LAB/project"
RPC_IN="$LAB/rpc.in"
RPC_LOG="$LAB/rpc.log"
RPC_ERR="$LAB/rpc.err"
OMP_PID=

lab_pids() {
  ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) { print $1 }'
}

reap_lab() {
  local pid
  for pid in $(lab_pids); do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in $(lab_pids); do kill -KILL "$pid" 2>/dev/null || true; done
}

cleanup() {
  { exec 3>&-; } 2>/dev/null || true
  if [ -n "$OMP_PID" ]; then kill -TERM "$OMP_PID" 2>/dev/null || true; fi
  reap_lab
  if [ "${FM_OMP_BRANCH_LIVE_KEEP:-0}" = 1 ]; then
    printf '# lab kept at %s\n' "$LAB" >&2
  else
    rm -rf "$LAB"
  fi
}
trap cleanup EXIT

# --- lab checkout: the tracked tree plus this working tree's pending edits ----
mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT" || fail "could not clone the repository into the lab"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -f "$ROOT/$path" ] || continue
  mkdir -p "$PROJECT/$(dirname "$path")"
  cp "$ROOT/$path" "$PROJECT/$path"
done <<EOF
$(git -C "$ROOT" ls-files --modified --others --exclude-standard)
EOF
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PROJECT/data"
[ -f "$PROJECT/.omp/extensions/fm-omp-branch-supervision.ts" ] || fail "lab checkout is missing the omp branch extension"
[ -f "$PROJECT/.omp/extensions/fm-primary-omp-watch.ts" ] || fail "lab checkout is missing the omp watch extension"

# --- rpc plumbing --------------------------------------------------------------
rpc_send() { printf '%s\n' "$1" >&3; }

wait_for_log() {  # <fixed-string> <attempts>
  local expected=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    grep -Fq -- "$expected" "$RPC_LOG" 2>/dev/null && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

wait_for_file() {  # <path> <attempts>
  local path=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -f "$path" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

agent_end_count() {
  local n
  n=$(jq -r 'select(.type == "agent_end") | .type' "$RPC_LOG" 2>/dev/null | grep -c . 2>/dev/null) || true
  printf '%s' "${n:-0}"
}

wait_for_agent_ends() {  # <count> <attempts>
  local want=$1 attempts=${2:-360} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ "$(agent_end_count)" -ge "$want" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

start_omp() {  # <mode-word-or-empty>
  local mode=$1
  if [ -n "$mode" ]; then
    printf '%s\n' "$mode" > "$PROJECT/config/omp-supervision-branch"
  else
    rm -f "$PROJECT/config/omp-supervision-branch"
  fi
  rm -f "$PROJECT/state/.watch-cycle-exits.log"
  [ ! -s "$RPC_LOG" ] || cp "$RPC_LOG" "$RPC_LOG.$(date +%s%N)"
  mkfifo "$RPC_IN" || fail "could not create the rpc fifo"
  : > "$RPC_LOG"
  (
    cd "$PROJECT" &&
      env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
        FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 \
        omp --mode rpc --no-session --cwd "$PROJECT" --config "$PROJECT/.omp/fm-worker-overlay.yml" --auto-approve \
          --model "$MODEL" --thinking low < "$RPC_IN" > "$RPC_LOG" 2> "$RPC_ERR"
  ) &
  OMP_PID=$!
  exec 3> "$RPC_IN"
  wait_for_log '"type":"ready"' 240 || fail "omp $OMP_VERSION did not print its rpc ready frame: $(tail -5 "$RPC_ERR")"
  wait_for_file "$PROJECT/state/.omp-turnend-extension-loaded" 60 || fail "omp $OMP_VERSION did not load the turn-end guard extension"
  wait_for_file "$PROJECT/state/.omp-watch-extension-loaded" 60 || fail "omp $OMP_VERSION did not load the watch extension"
}

stop_omp() {
  # Close only fd 3: a bare `exec 3>&- 2>/dev/null` would also send every
  # later line of this script's stderr, including fail(), to /dev/null.
  { exec 3>&-; } 2>/dev/null || true
  sleep 2
  if [ -n "$OMP_PID" ]; then kill -TERM "$OMP_PID" 2>/dev/null || true; wait "$OMP_PID" 2>/dev/null || true; fi
  OMP_PID=
  reap_lab
  rm -f "$RPC_IN" "$PROJECT/state/.lock"
}

# A cold start acquires the fleet lock through its first turn's digest; the
# branch activates at that run boundary, then the watcher is armed.
first_turn_then_arm() {  # <label>
  local label=$1
  rpc_send '{"id":"t1","type":"prompt","message":"Reply with exactly READY and nothing else."}'
  wait_for_agent_ends 1 360 || fail "$label did not finish its first turn"
  wait_for_file "$PROJECT/state/.omp-branch-extension-loaded" 60 || fail "$label did not activate the branch after the lock-acquiring first turn"
  rpc_send '{"id":"t2","type":"prompt","message":"Call the fm_watch_arm_omp tool exactly once now, then reply with its result text verbatim. Never run bin/fm-watch-arm.sh through bash."}'
  wait_for_log "watcher: started omp extension arm child" 360 || fail "$label did not arm the watcher"
  wait_for_agent_ends 2 360 || fail "$label did not finish the arm turn"
  [ "$(pgrep -f "$PROJECT/bin/fm-watch-arm.sh" | grep -c .)" -eq 1 ] || fail "$label runs more than one watcher arm (F5)"
}

seed_watched_task() {
  printf 'project=x\nharness=omp\n' > "$PROJECT/state/e2e-task.meta"
}

# --- 0. mode absent: the branch is entirely absent ---------------------------
start_omp ""
seed_watched_task
rpc_send '{"id":"p0","type":"prompt","message":"Reply with exactly OK and nothing else."}'
wait_for_agent_ends 1 360 || fail "mode-absent omp did not finish the first turn"
[ ! -f "$PROJECT/state/.omp-branch-extension-loaded" ] || fail "mode-absent wrote the branch loaded marker"
[ ! -f "$PROJECT/state/omp-branch-shadow.jsonl" ] || fail "mode-absent wrote a shadow log"
stop_omp
pass "omp $OMP_VERSION: config absent keeps every wake on main and writes no branch state"

# --- 1. report-only: main handles the wake, the shadow logs the intent --------
start_omp report-only
seed_watched_task
first_turn_then_arm "report-only"
printf 'done: e2e report-only fire\n' >> "$PROJECT/state/e2e-task.status"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$PROJECT/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$PROJECT/state/.watch-cycle-exits.log" \
  || fail "report-only did not spawn a successor watcher"
wait_for_log "FIRSTMATE WATCHER WAKE: signal:" 240 || fail "report-only wake did not reach main"
i=0
while [ "$i" -lt 240 ]; do
  [ -s "$PROJECT/state/omp-branch-shadow.jsonl" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -s "$PROJECT/state/omp-branch-shadow.jsonl" ] || fail "report-only wrote no shadow log"
[ ! -f "$PROJECT/state/branch-outcomes.jsonl" ] || fail "report-only wrote the real outcome store"
pass "omp $OMP_VERSION: report-only keeps the wake on main and records the intended action in the shadow log"
stop_omp

# --- 2. mode on: the branch takes the wake, main is not woken -----------------
start_omp on
seed_watched_task
first_turn_then_arm "mode-on"
printf 'done: e2e mode-on fire\n' >> "$PROJECT/state/e2e-task.status"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$PROJECT/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$PROJECT/state/.watch-cycle-exits.log" \
  || fail "mode-on did not spawn a successor watcher"
# The branch is active (its marker exists), so the status wake must reach the
# branch and never main; a fallback here is a failed proof, not a pass.
i=0
while [ "$i" -lt 240 ]; do
  [ -s "$PROJECT/state/branch-outcomes.jsonl" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -s "$PROJECT/state/branch-outcomes.jsonl" ] || fail "mode-on: the branch wrote no durable outcome for the status wake"
grep -q '"task":"e2e-task"' "$PROJECT/state/branch-outcomes.jsonl" || fail "mode-on: the branch outcome names the wrong task"
! grep -Fq "FIRSTMATE WATCHER WAKE: signal:" "$RPC_LOG" || fail "mode-on: a watcher wake reached main as well as the branch"
pass "omp $OMP_VERSION: mode on hands the wake to the branch, which drains it and stores a durable outcome, and main is not woken"

# --- 3. F4: a stored outcome survives restart and replays ----------------------
# An unprocessed captain outcome left behind when the session ends must be
# replayed by the next owning session start, exactly as on Pi.
FM_HOME="$PROJECT" "$PROJECT/bin/fm-branch-outcome.sh" append \
  --task e2e-task --verdict captain --summary "PR https://example.com/pr/e2e is green" >/dev/null \
  || fail "could not seed the restart-replay outcome"
printf 'branch\t%s\t123\n' 999999 > "$PROJECT/state/.lease-e2e-dead"
ends=$(agent_end_count)
rpc_send '{"id":"p3","type":"prompt","message":"Reply with exactly RESTART and nothing else."}'
wait_for_agent_ends "$((ends + 1))" 360 || fail "omp did not finish the pre-restart turn"
stop_omp
rm -f "$PROJECT/state/.omp-branch-extension-loaded"
start_omp on
rpc_send '{"id":"r1","type":"prompt","message":"Reply with exactly READY and nothing else."}'
wait_for_agent_ends 1 360 || fail "the restarted session did not finish its first turn"
wait_for_file "$PROJECT/state/.omp-branch-extension-loaded" 60 || fail "restarted omp did not reactivate the branch"
i=0
while [ "$i" -lt 240 ]; do
  [ "$(cat "$PROJECT/state/.branch-outcomes-cursor" 2>/dev/null)" = "$(grep -c . "$PROJECT/state/branch-outcomes.jsonl")" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ "$(cat "$PROJECT/state/.branch-outcomes-cursor" 2>/dev/null)" = "$(grep -c . "$PROJECT/state/branch-outcomes.jsonl")" ] \
  || fail "the restart did not deliver every stored outcome (cursor $(cat "$PROJECT/state/.branch-outcomes-cursor" 2>/dev/null))"
[ ! -e "$PROJECT/state/.lease-e2e-dead" ] || fail "the restart kept a dead branch lease"
pass "omp $OMP_VERSION: stored branch outcomes replay across a session restart and dead leases are swept"
stop_omp

note "omp $OMP_VERSION model=$MODEL: every live omp branch assertion passed"
