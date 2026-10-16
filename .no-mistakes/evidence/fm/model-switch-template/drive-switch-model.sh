#!/usr/bin/env bash
# Live driver for fm-control switch-model against the installed omp, in an
# isolated tmux server and a disposable firstmate home. Prints a transcript.
set -u
ROOT=${ROOT:?worktree}
E=${E:?evidence dir}
SOCKET="fm-switch-drive-$$"
LAB=$(mktemp -d "$HOME/.fm-switch-drive.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
SESSIONS="$HOME/.omp/agent/sessions/-$(printf '%s' "${LAB#"$(cd "$HOME" && pwd -P)"/}/wt" | tr '/:' '--')"
cleanup() {
  local i=0
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  while [ "$i" -lt 20 ] && pgrep -f -- "--cwd $LAB/wt" >/dev/null 2>&1; do sleep 0.5; i=$((i+1)); done
  rm -rf "$LAB" "$SESSIONS"
}
trap cleanup EXIT
SHIM="$LAB/shim"; mkdir -p "$SHIM" "$LAB/home/state" "$LAB/home/data/t1" "$LAB/wt"
REAL_TMUX=$(command -v tmux)
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
PATH="$SHIM:$PATH"
unset NO_MISTAKES_GATE
git -C "$LAB/wt" init -q && git -C "$LAB/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
tmux new-session -d -s lab -n fm-t1 -x 200 -y 50 -c "$LAB/wt" \
  "env OMP_SKIP_SETUP=1 FM_OMP_HARNESS=omp omp --config $ROOT/.omp/fm-worker-overlay.yml --cwd $LAB/wt"
META="$LAB/home/state/t1.meta"
printf 'window=lab:fm-t1\nendpoint_task_id=t1\nworktree=%s\nproject=%s\nharness=omp\nkind=ship\nmodel=default\neffort=default\n' "$LAB/wt" "$LAB/wt" > "$META"
printf 'brief\n' > "$LAB/home/data/t1/brief.md"
wait_for() { local i=0; while [ "$i" -lt "$1" ]; do "${@:2}" && return 0; sleep 1; i=$((i+1)); done; return 1; }
composer_empty() { . "$ROOT/bin/fm-tmux-lib.sh"; [ "$(fm_tmux_composer_state lab:fm-t1)" = empty ]; }
session_written() { ls "$SESSIONS"/*.jsonl >/dev/null 2>&1; }
ctl() { echo "\$ fm-control.sh t1 switch-model $*"; FM_HOME="$LAB/home" "$ROOT/bin/fm-control.sh" t1 switch-model "$@" 2>&1; echo "[exit $?]"; }
meta_show() { echo "meta: $(grep -E '^(kind|model|effort)=' "$META" | tr '\n' ' ')"; }
models() { echo "omp session model_change entries: $(grep -hF '"type":"model_change"' "$SESSIONS"/*.jsonl | jq -rc '[.model,.role] | join(" role=")' | tr '\n' ';')"; }
wait_for 60 composer_empty || { echo "FAIL idle never empty"; exit 1; }
tmux send-keys -t lab:fm-t1 -l 'Reply with exactly: pong'; sleep 0.5; tmux send-keys -t lab:fm-t1 Enter
wait_for 120 session_written || { echo "FAIL no session file"; exit 1; }
wait_for 60 composer_empty || { echo "FAIL not idle after flush"; exit 1; }
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/home/state" t1 --state idle --source fm-spawn --event seed)
printf 'busy_gen=%s\n' "$gen" >> "$META"
echo "omp: $(omp --version | head -1)"; meta_show; models

echo; echo "=== S1 ship task: switch with --effort high ==="
ctl --model glm-cliproxy/zai-glm53flash-max --effort high --reason "SWE-2 weekly quota is spent until 10-18"
meta_show; models
for f in "$LAB/home/state/t1.inbox"/*.msg; do echo "--- inbox $(basename "$f")"; cat "$f"; echo; done

echo; echo "=== S2 adversarial: switch to the model already running, no effort ==="
wait_for 30 composer_empty
ctl --model glm-cliproxy/zai-glm53flash-max --reason "noop"
echo "inbox count: $(ls "$LAB/home/state/t1.inbox"/*.msg | wc -l | tr -d ' ')"

echo; echo "=== S3 adversarial: invalid selectors refused before typing ==="
ctl --model opus --reason "x"
ctl --model a/b --reason "   "
ctl --model a/b --effort huge --reason "x"
ctl --model a/b --harness claude --reason "x"

echo; echo "=== S4 secondmate kind, no --effort: keep recorded effort, carrier-prefixed notice ==="
sed -i '' 's/^kind=ship$/kind=secondmate/' "$META"
wait_for 30 composer_empty
PRIOR=$(grep -hF '"type":"model_change"' "$SESSIONS"/*.jsonl | head -1 | jq -r .model)
ctl --model "$PRIOR" --reason "GLM Flash cooling down; back to the launch model"
meta_show; models
last=$(ls "$LAB/home/state/t1.inbox"/*.msg | sort | tail -1); echo "--- inbox $(basename "$last")"; cat -v "$last"; echo

echo; echo "=== S5 adversarial: harness without in-place switch (claude) ==="
sed -i '' 's/^harness=omp$/harness=claude/' "$META"
n0=$(ls "$LAB/home/state/t1.inbox"/*.msg | wc -l | tr -d ' ')
ctl --model glm-cliproxy/zai-glm53flash-max --reason "x"
echo "inbox count before=$n0 after=$(ls "$LAB/home/state/t1.inbox"/*.msg | wc -l | tr -d ' ')"
sed -i '' 's/^harness=claude$/harness=omp/' "$META"

echo; echo "=== supervisor action ledger rows ==="
cat "$LAB/home/state/supervisor-actions.jsonl" 2>/dev/null
echo; echo "=== worker pane (tail) ==="
tmux capture-pane -p -t lab:fm-t1 | grep -v '^\s*$' | tail -25
mkdir -p "$E/live-home"
cp -R "$LAB/home/state" "$E/live-home/" 2>/dev/null
rm -rf "$E/live-home/state/"*.lock* 2>/dev/null
true
