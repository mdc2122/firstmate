#!/usr/bin/env bash
# Focused live lab for the omp supervision-branch quiet-routine change.
# Drives real omp (rpc mode) with config/omp-supervision-branch=on in a
# disposable clone that acts as its own FM_HOME, then fires one no-change
# status wake and one change-reporting status wake and records what reached
# main's conversation versus the durable outcome store.
# Adapted from tests/fm-omp-branch-live-e2e.test.sh (stage 2 plumbing).
set -u
ROOT=${1:?worktree root}
EVID=${2:?evidence dir}
MODEL=${FM_OMP_BRANCH_LIVE_MODEL:-claude-opus55-cliproxy/claude-opus-5-5[1m]}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/omp-quiet-lab.XXXXXX")
PROJECT="$LAB/project"; STATE="$PROJECT/state"
RPC_IN="$LAB/rpc.in"; RPC_LOG="$LAB/rpc.log"; RPC_ERR="$LAB/rpc.err"
OMP_PID=
log() { printf '# %s\n' "$*"; }
fail() { printf 'FAIL - %s\n' "$*"; exit 1; }
lab_pids() { ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) { print $1 }'; }
cleanup() {
  { exec 3>&-; } 2>/dev/null || true
  [ -n "$OMP_PID" ] && kill -TERM "$OMP_PID" 2>/dev/null
  tmux kill-server 2>/dev/null
  sleep 1; for p in $(lab_pids); do kill -KILL "$p" 2>/dev/null; done
  mkdir -p "$EVID/lab"
  cp "$RPC_LOG" "$EVID/lab/main-rpc.log" 2>/dev/null
  cp "$STATE/branch-outcomes.jsonl" "$EVID/lab/branch-outcomes.jsonl" 2>/dev/null
  cat "$STATE"/branch-session/*.jsonl > "$EVID/lab/branch-session.jsonl" 2>/dev/null
  cp "$STATE/.watch-cycle-exits.log" "$EVID/lab/watch-cycle-exits.log" 2>/dev/null
  cp "$STATE/qwen-fix.status" "$EVID/lab/qwen-fix.status" 2>/dev/null
  rm -rf "$LAB"
}
trap cleanup EXIT
wait_until() { local n=$1 i=0; shift; while [ $i -lt $n ]; do "$@" && return 0; sleep 0.5; i=$((i+1)); done; return 1; }
agent_ends() { jq -r 'select(.type=="agent_end")|.type' "$RPC_LOG" 2>/dev/null | grep -c . || true; }
rpc_turn() { local e; e=$(agent_ends); printf '%s\n' "$(jq -cn --arg id "$1" --arg m "$2" '{id:$id,type:"prompt",message:$m,streamingBehavior:"followUp"}')" >&3
  local want=$((e+1)); wait_until 480 sh -c "[ \$(jq -r 'select(.type==\"agent_end\")|.type' '$RPC_LOG' 2>/dev/null | grep -c .) -ge $want ]" || fail "$1 turn did not finish"; }
rows() { [ -f "$STATE/branch-outcomes.jsonl" ] && grep -c . "$STATE/branch-outcomes.jsonl" || echo 0; }
successor() { grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$STATE/.watch-cycle-exits.log" 2>/dev/null; }

git clone -q "$ROOT" "$PROJECT" || fail clone
git -C "$PROJECT" checkout -q "$(git -C "$ROOT" rev-parse HEAD)" || fail checkout
log "lab at commit $(git -C "$PROJECT" rev-parse --short HEAD), omp $(omp --version | head -1), model $MODEL"
mkdir -p "$STATE" "$PROJECT/config" "$PROJECT/data"
printf 'on\n' > "$PROJECT/config/omp-supervision-branch"
# A live (idle) worker pane on an isolated tmux server so fm-crew-state.sh
# reports the task as working rather than gone.
export TMUX_TMPDIR="$LAB/tmux"; mkdir -p "$TMUX_TMPDIR" "$LAB/wt"; unset TMUX; git init -q "$LAB/wt"
tmux new-session -d -s qwen -x 120 -y 40 "printf 'Grok: ran the dead-frames repro; next run queued\\n> '; sleep 100000"
printf 'project=x\nharness=grok\nbackend=tmux\nwindow=qwen:0\nworktree=%s\nkind=ship\n' "$LAB/wt" > "$STATE/qwen-fix.meta"
log "crew state before wakes: $(cd "$PROJECT" && FM_HOME="$PROJECT" bin/fm-crew-state.sh qwen-fix)"
printf 'working: reproducing the Qwen dead-frames bug\n' > "$STATE/qwen-fix.status"
mkfifo "$RPC_IN"; : > "$RPC_LOG"
( cd "$PROJECT" && env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u NO_MISTAKES_GATE -u TMUX \
    FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 \
    omp --mode rpc --no-session --cwd "$PROJECT" --config "$PROJECT/.omp/fm-worker-overlay.yml" --auto-approve \
      --model "$MODEL" --thinking low < "$RPC_IN" > "$RPC_LOG" 2> "$RPC_ERR" ) &
OMP_PID=$!
exec 3> "$RPC_IN"
wait_until 240 grep -Fq '"type":"ready"' "$RPC_LOG" || fail "no rpc ready: $(tail -5 "$RPC_ERR")"
rpc_turn t1 'Reply with exactly READY and nothing else.'
wait_until 60 test -f "$STATE/.omp-branch-extension-loaded" || fail "branch did not activate"
rpc_turn arm 'Call the fm_watch_arm_omp tool exactly once now, then reply with its result text verbatim. Never run bin/fm-watch-arm.sh through bash.'
wait_until 60 grep -Fq "watcher: started omp extension arm child" "$RPC_LOG" || fail "watcher not armed"
log "branch active, watcher armed"

exits() { [ -f "$STATE/.watch-cycle-exits.log" ] || { echo 0; return; }; awk '/reason=actionable-signal.*successor=started:[0-9]+/ {n++} END {print n+0}' "$STATE/.watch-cycle-exits.log"; }
fire() { local n i=0; n=$(exits); printf '%s\n' "$1" >> "$STATE/qwen-fix.status"
  while [ "$(exits)" -le "$n" ]; do i=$((i+1)); [ $i -gt 480 ] && { log "watch-cycle-exits:"; cat "$STATE/.watch-cycle-exits.log"; fail "status did not end a watcher cycle"; }; sleep 0.5; done; }

# Wake A: a no-change progress note
before=$(rows)
fire 'working: still fixing the Qwen dead-frames bug; nothing new since the last note'
wait_until 900 sh -c "[ \$(grep -c . '$STATE/branch-outcomes.jsonl' 2>/dev/null || echo 0) -gt $before ]" || fail "no outcome for wake A"
sleep 8
log "wake A outcome: $(tail -1 "$STATE/branch-outcomes.jsonl")"
log "wake A: fm-branch-merge frames in main rpc log so far: $(grep -c 'fm-branch-merge' "$RPC_LOG")"

# Wake B: a change-reporting progress note
before=$(rows)
fire 'working: opened PR https://github.com/example/qwen/pull/12 with the dead-frames fix; CI is running'
wait_until 900 sh -c "[ \$(grep -c . '$STATE/branch-outcomes.jsonl' 2>/dev/null || echo 0) -gt $before ]" || fail "no outcome for wake B"
sleep 8
# settle: wait until the store has been quiet for 45s (cap 300s) so a follow-up report lands
last=$(rows); quiet=0; t=0
while [ $quiet -lt 90 ] && [ $t -lt 600 ]; do sleep 0.5; t=$((t+1)); now=$(rows); if [ "$now" = "$last" ]; then quiet=$((quiet+1)); else last=$now; quiet=0; fi; done
log "wake B outcomes:"; tail -n +$((before+1)) "$STATE/branch-outcomes.jsonl" | jq -c '{seq,verdict,silent,summary}' 
log "main rpc fm-branch-merge note contents:"
jq -rc 'select((tostring|test("fm-branch-merge")))' "$RPC_LOG" | jq -rc '.. | objects | select(.customType? == "fm-branch-merge") | {content, display}' | sort -u
log "watcher wakes reaching main: $(grep -c 'FIRSTMATE WATCHER WAKE' "$RPC_LOG")"
log "cursor=$(cat "$STATE/.branch-outcomes-cursor" 2>/dev/null) rows=$(rows)"
log DONE
