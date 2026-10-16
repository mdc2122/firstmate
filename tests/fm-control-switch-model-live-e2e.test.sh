#!/usr/bin/env bash
# tests/fm-control-switch-model-live-e2e.test.sh - live guard for the in-place
# model switch (live-harness-optin family).
#
# `fm-control.sh <id> switch-model` proves a switch only from omp's own
# session record (a model_change entry under ~/.omp/agent/sessions/<encoded
# worktree>/), and its notice is gated on that proof. The record's location,
# its entry shape, and /switch's popup and refusal behavior are all vendor
# facts, so per .agents/skills/firstmate-coding-guidelines they are proven here
# against the INSTALLED omp: a real omp idles in an isolated tmux server, one
# short turn flushes its session file, then the REAL fm-control must refuse an
# unknown model with no inbox notice and switch a real model with exactly one
# notice naming both models. Fails naming omp and its version.
#
# Opt-in with FM_CONTROL_SWITCH_LIVE_E2E=1: it spends one short model turn.
# FM_CONTROL_SWITCH_LIVE_MODEL picks the switch target (a listed
# <provider>/<id> different from omp's default; default
# glm-cliproxy/zai-glm53flash-max). Record the dated result in
# docs/verification/runtime-backends.md ("In-place model switch").
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_CONTROL_SWITCH_LIVE_E2E tmux omp jq

unset NO_MISTAKES_GATE

TARGET=${FM_CONTROL_SWITCH_LIVE_MODEL:-glm-cliproxy/zai-glm53flash-max}
SOCKET="fm-switch-live-$$"
# omp keys its session directory on the worktree's path under $HOME, so the
# lab lives there; the guard removes it and its session directory on exit.
LAB=$(mktemp -d "$HOME/.fm-switch-live.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
VERSION=$(omp --version 2>/dev/null | head -n 1)
SESSIONS="$HOME/.omp/agent/sessions/-$(printf '%s' "${LAB#"$(cd "$HOME" && pwd -P)"/}/wt" | tr '/:' '--')"

cleanup() {
  local i=0
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  # omp flushes its session file while shutting down, which can recreate the
  # directory after an early rm; wait for no omp to run in the lab first.
  while [ "$i" -lt 20 ] && pgrep -f -- "--cwd $LAB/wt" >/dev/null 2>&1; do
    sleep 0.5
    i=$((i + 1))
  done
  rm -rf "$LAB" "$SESSIONS"
}
trap cleanup EXIT

bad() { printf 'not ok - omp (%s): %s\n' "$VERSION" "$1" >&2; exit 1; }

SHIM="$LAB/shim"
mkdir -p "$SHIM" "$LAB/home/state" "$LAB/home/data/t1" "$LAB/wt"
REAL_TMUX=$(command -v tmux)
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"
PATH="$SHIM:$PATH"

SPAWN_EPOCH=$(date +%s)
git -C "$LAB/wt" init -q && git -C "$LAB/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
tmux new-session -d -s lab -n fm-t1 -x 200 -y 50 -c "$LAB/wt" \
  "env OMP_SKIP_SETUP=1 FM_OMP_HARNESS=omp omp --config $ROOT/.omp/fm-worker-overlay.yml --cwd $LAB/wt" \
  || bad "could not launch in the isolated tmux server"
printf 'window=lab:fm-t1\nendpoint_task_id=t1\nworktree=%s\nproject=%s\nharness=omp\nkind=ship\nmodel=default\neffort=default\nspawn_gen=s%s.123.456\n' \
  "$LAB/wt" "$LAB/wt" "$SPAWN_EPOCH" > "$LAB/home/state/t1.meta"
printf 'brief\n' > "$LAB/home/data/t1/brief.md"

wait_for() {  # <seconds> <command...>
  local i=0
  while [ "$i" -lt "$1" ]; do
    "${@:2}" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}
composer_empty() { . "$ROOT/bin/fm-tmux-lib.sh"; [ "$(fm_tmux_composer_state lab:fm-t1)" = empty ]; }
session_written() { ls "$SESSIONS"/*.jsonl >/dev/null 2>&1; }

wait_for 60 composer_empty || bad "idle composer never classified empty"
tmux send-keys -t lab:fm-t1 -l 'Reply with exactly: pong'
sleep 0.5
tmux send-keys -t lab:fm-t1 Enter
wait_for 120 session_written || bad "no session file appeared under $SESSIONS after one turn"
wait_for 60 composer_empty || bad "composer did not return to empty after the flush turn"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/home/state" t1 --state idle --source fm-spawn --event seed)
printf 'busy_gen=%s\n' "$gen" >> "$LAB/home/state/t1.meta"

out=$(FM_HOME="$LAB/home" "$ROOT/bin/fm-control.sh" t1 switch-model \
  --model nosuch-provider/nosuch-model --reason "live guard refusal" 2>&1) \
  && bad "an unknown model was reported switched: $out"
[ ! -d "$LAB/home/state/t1.inbox" ] || bad "a refused switch wrote an inbox notice"
printf 'ok - omp (%s): an unknown model records no switch and sends no notice\n' "$VERSION"

wait_for 30 composer_empty || bad "composer did not return to empty after the refused switch"
out=$(FM_HOME="$LAB/home" "$ROOT/bin/fm-control.sh" t1 switch-model \
  --model "$TARGET" --reason "live guard switch" 2>&1) || bad "switch to $TARGET failed: $out"
n=$(find "$LAB/home/state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
[ "$n" = 1 ] || bad "expected exactly one inbox notice, found $n"
body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$LAB/home/state/t1.inbox/001.msg")
case "$body" in
  "Your model was switched in place from "*" to $TARGET."*) ;;
  *) bad "notice does not name the switch to $TARGET: $body" ;;
esac
printf 'ok - omp (%s): a recorded switch to %s sends exactly one notice naming both models\n' "$VERSION" "$TARGET"
