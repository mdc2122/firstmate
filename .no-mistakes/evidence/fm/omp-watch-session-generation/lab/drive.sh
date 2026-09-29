#!/usr/bin/env bash
# Drives a real omp 18.2.6 rpc session against the lab clone with a scripted
# OpenAI-compatible model: arm the watcher, run one in-process task helper that
# itself calls fm_watch_arm_omp, let omp dispose the helper, re-arm from main,
# then shut the owner down.
set -u
LAB=$(cat /tmp/fm-omp-helper-lab.path)
PROJECT="$LAB/project"
RPC_IN="$LAB/rpc.in"; RPC_LOG="$LAB/rpc.log"; RPC_ERR="$LAB/rpc.err"
GENLOG="$PROJECT/state/extensions/omp-primary-watch/session-generations.log"
rm -f "$RPC_IN" "$RPC_LOG" "$RPC_ERR" "$LAB/requests.jsonl" "$LAB/tools.json"
rm -rf "$PROJECT/state"; mkdir -p "$PROJECT/state"
mkfifo "$RPC_IN"
: > "$RPC_LOG"
(
  cd "$PROJECT" &&
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
      PI_CODING_AGENT_DIR="$LAB/agent" OMP_SKIP_SETUP=1 \
      FM_OMP_HARNESS=omp FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 \
      omp --mode rpc --no-session --cwd "$PROJECT" --config "$PROJECT/.omp/fm-worker-overlay.yml" --auto-approve \
        --model fake/fake-model --thinking off < "$RPC_IN" > "$RPC_LOG" 2> "$RPC_ERR"
) &
OMP_PID=$!
exec 3> "$RPC_IN"
send() { printf '%s\n' "$1" >&3; }
wait_log() { local i=0; while [ $i -lt "${2:-120}" ]; do grep -Fq -- "$1" "$RPC_LOG" 2>/dev/null && return 0; sleep 0.5; i=$((i+1)); done; return 1; }
wait_file() { local i=0; while [ $i -lt "${2:-60}" ]; do [ -f "$1" ] && return 0; sleep 0.5; i=$((i+1)); done; return 1; }
arm_ends() { jq -r 'select(.type=="tool_execution_end" and .toolName=="fm_watch_arm_omp")|.result.content[0].text' "$RPC_LOG" 2>/dev/null; }
wait_arm_ends() { local i=0; while [ $i -lt "${2:-240}" ]; do [ "$(arm_ends | grep -c .)" -ge "$1" ] && return 0; sleep 0.5; i=$((i+1)); done; return 1; }
task_ends() { jq -r 'select(.type=="tool_execution_end" and .toolName=="task")|.type' "$RPC_LOG" 2>/dev/null | grep -c . || true; }
watcher() { local p; p=$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null); printf 'watcher pid=%s alive=%s' "${p:-none}" "$( [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo yes || echo no)"; }
step() { printf '\n## %s\n' "$1"; }

step "startup: omp $(omp --version | head -1) in rpc mode, scripted model, lab clone at $PROJECT"
wait_log '"type":"ready"' 120 || { echo "FAIL: no ready frame"; tail -20 "$RPC_ERR"; exit 1; }
wait_file "$PROJECT/state/.omp-watch-extension-loaded" 60 || { echo "FAIL: watch extension not loaded"; tail -20 "$RPC_ERR"; exit 1; }
omp_real_pid=$(pgrep -P "$OMP_PID" | head -1)
echo "extension at $(git -C "$PROJECT" log --oneline -1) writes session-generations.log: $([ -f "$GENLOG" ] && echo yes || echo no)"
printf '%s\n' "$omp_real_pid" > "$PROJECT/state/.lock"
echo "watch extension auto-discovered; lab session lock now names omp pid $omp_real_pid ($(ps -p "$omp_real_pid" -o comm= 2>/dev/null))"

step "p1: main session arms the watcher through fm_watch_arm_omp"
send '{"id":"p1","type":"prompt","message":"CALL_ARM"}'
wait_arm_ends 1 240 || { echo "FAIL: p1 arm tool never returned"; tail -20 "$RPC_ERR"; exit 1; }
echo "tool result: $(arm_ends | sed -n 1p)"
sleep 2; echo "$(watcher)"; W1=$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null)

step "p2: main spawns one in-process task helper; the helper's model calls fm_watch_arm_omp itself"
send '{"id":"p2","type":"prompt","message":"SPAWN_HELPER"}'
i=0; while [ $i -lt 240 ]; do [ "$(task_ends)" -ge 1 ] && break; sleep 0.5; i=$((i+1)); done
[ "$(task_ends)" -ge 1 ] || { echo "FAIL: task tool never returned"; exit 1; }
echo "task tool result (first line): $(jq -r 'select(.type=="tool_execution_end" and .toolName=="task")|.result.content[0].text' "$RPC_LOG" | head -1)"
i=0; while [ $i -lt 40 ]; do grep -q 'session_shutdown inert' "$GENLOG" 2>/dev/null && break; sleep 0.5; i=$((i+1)); done
grep -q 'session_shutdown inert' "$GENLOG" 2>/dev/null && echo "helper session_shutdown observed $((i/2))s after spawn (task.agentIdleTtlMs=3000 lets omp dispose the idle helper)" || echo "WARN: helper session_shutdown not observed within 120s"
echo "helper's own fm_watch_arm_omp result, taken from the helper's next model request: $(jq -r 'select(.messages[-1].role=="tool" and (.messages | map(select(.role=="user" and ((.content|tostring)|test("HELPER-TASK")))) | length) > 0) | .messages[-1].content' "$LAB/requests.jsonl" | head -1)"
echo "omp's own log for pid $omp_real_pid:"; grep -h 'Session exit recorded' ~/.omp/logs/omp.*."$omp_real_pid".log 2>/dev/null | jq -c '{timestamp,message,sessionId,reason,kind}'
echo "$(watcher) (same pid as after p1: $([ "$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null)" = "$W1" ] && echo yes || echo NO))"

step "p3: main calls fm_watch_arm_omp again after the helper started and was disposed"
sleep 2
send '{"id":"p3","type":"prompt","message":"CALL_ARM"}'
wait_arm_ends 2 240 || { echo "FAIL: p3 arm tool never returned"; tail -20 "$RPC_ERR"; exit 1; }
echo "tool result: $(arm_ends | sed -n 2p)"
echo "$(watcher) (same pid as after p1: $([ "$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null)" = "$W1" ] && echo yes || echo NO))"

step "session-generations.log before owner shutdown"
cat "$GENLOG" 2>/dev/null || echo "(no session-generations.log at this commit)"

step "shutdown: rpc close command, then close rpc stdin, then SIGINT if omp lingers"
send '{"id":"c1","type":"close"}'
sleep 3; grep -n '"id":"c1"' "$RPC_LOG" | cut -c1-200
exec 3>&-
i=0; while [ $i -lt 30 ]; do kill -0 "$OMP_PID" 2>/dev/null || break; grep -q 'session_shutdown owner' "$GENLOG" 2>/dev/null && break; sleep 0.5; i=$((i+1)); done
if ! grep -q 'session_shutdown owner' "$GENLOG" 2>/dev/null; then
  echo "no owner shutdown ${i}s after stdin close; sending SIGINT to omp pid $omp_real_pid"
  kill -INT "$omp_real_pid" 2>/dev/null
  i=0; while [ $i -lt 40 ]; do grep -q 'session_shutdown owner' "$GENLOG" 2>/dev/null && break; sleep 0.5; i=$((i+1)); done
fi
grep -q 'session_shutdown owner' "$GENLOG" 2>/dev/null && echo "owner session_shutdown logged" || echo "WARN: owner session_shutdown never logged"
sleep 2
i=0; while [ $i -lt 20 ]; do kill -0 "$OMP_PID" 2>/dev/null || break; sleep 0.5; i=$((i+1)); done
kill -0 "$OMP_PID" 2>/dev/null && { echo "omp still running; terminating lab omp"; kill -TERM "$OMP_PID" 2>/dev/null; }
echo "$(watcher) after owner shutdown"

step "session-generations.log final"
cat "$GENLOG" 2>/dev/null || echo "(no session-generations.log at this commit)"
step "omp stderr tail"
tail -5 "$RPC_ERR"
