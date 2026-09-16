#!/usr/bin/env bash
# Live end-to-end drive of the proof-gated post-interrupt composer clear.
#
# Product: real muse 1.3.0 (Muse Code 1.3.0-R3057.1) TUI in a real tmux server
# on an isolated socket, driven by the REAL bin/fm-send.sh --key Escape and
# bin/fm-control.sh <id> interrupt through a real firstmate home (state/meta +
# muse-session binding). No stubs on the product path; the only PATH shim is a
# tmux wrapper pinning the isolated -L socket (the technique of
# tests/fm-muse-signals-live-e2e.test.sh).
#
# muse only restores the cancelled prompt into its composer when the cancel
# lands in the model step. The echo provider's turns close in ~300ms (cancels
# there land in the end-of-turn reminder wait and restore nothing - observed
# live while building this drive), so the drive uses the default meta provider
# with the host's stored credential copied into the isolated config home, the
# method docs/verification/muse.md's credentialed smoke prescribes. The
# credential never enters argv or any evidence file.
#
# Steps:
#   control  direct Escape (no product): muse restores the prompt - the fact
#            the product's clear must prove, and the thing a blind C-u would
#            use to clobber the captain's typing.
#   A        fm-send --key Escape, empty composer at cancel: the proven
#            restore IS cleared (C-u fires, composer left empty).
#   B        fm-send --key Escape, FRESH typed input at cancel: the interrupt
#            lands in-flight but the captain's text SURVIVES untouched.
#   D        fm-control interrupt, empty composer at cancel: proven restore
#            cleared.
#   C        fm-control interrupt, FRESH typed input at cancel: text survives.
set -u

EVID=/Users/Morley/.no-mistakes/evidence/01M2MJEBHN3K1Y9N0136SVCEWA
ROOT=/Users/Morley/.no-mistakes/worktrees/62b3bc0be3e5/01M2MJEBHN3K1Y9N0136SVCEWA
REAL_TMUX=$(command -v tmux)
MUSE_BIN=$(command -v muse)
export FM_GATE_REFUSE_BYPASS=1

DRIVE_LOG="$EVID/live-drive.log"
: > "$DRIVE_LOG"
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$DRIVE_LOG" >&2; }
ok() { log "ok - $*"; }
dfail() { log "FAIL - $*"; exit 1; }

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

# ---------------------------------------------------------------- helpers ----
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-clobber-live.XXXXXX")
SOCKET="fm-clobber-live-$$"
SESS=fmclob
TARGET="$SESS:fm-livemuse"
HOME1="$LAB/home"
mkdir -p "$LAB/bin" "$LAB/config/muse" "$LAB/data/muse/sessions" "$HOME1/state" "$HOME1/data" "$LAB/ws"
git -C "$LAB/ws" init -q || dfail "workspace git init"
WS=$(cd "$LAB/ws" && pwd -P) || dfail "resolve workspace"
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
printf 'window=%s\nkind=ship\nharness=muse\nworktree=%s\nproject=%s\n' \
  "$TARGET" "$WS" "$WS" > "$HOME1/state/livemuse.meta"
printf 'sessions_root=%s/muse/sessions\nworkspace_root=%s\nbinding_id=live1\n' \
  "$LAB/data" "$WS" > "$HOME1/state/livemuse.muse-session"
PATH_ASSERT="$LAB/bin:$PATH"

cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

LOG=
wait_log() {
  local i
  LOG=
  for i in $(seq 1 250); do
    LOG=$(PATH="$PATH_ASSERT" fm_busy_muse_matching_logs "$LAB/data/muse/sessions" "$WS" 2>/dev/null | head -1)
    [ -n "$LOG" ] && return 0
    sleep 0.2
  done
  return 1
}
run_state() { PATH="$PATH_ASSERT" fm_busy_muse_run_state "$LOG" 2>/dev/null || true; }
last_terminal() {
  node - "$LOG" <<'NODE'
const fs = require("fs");
let runId = "", out = "none";
for (const line of fs.readFileSync(process.argv[2], "utf8").split("\n")) {
  if (!line.includes('"kind":"run"')) continue;
  try {
    const r = JSON.parse(line);
    if (r?.payload?.kind !== "run") continue;
    const e = r.payload.event;
    if (e?.kind === "started") { runId = r.payload.run_id; out = "none"; }
    if (e?.kind === "terminal" && r.payload.run_id === runId)
      out = (e.terminal || "?") + "/" + (e.reason || "-");
  } catch {}
}
process.stdout.write(out);
NODE
}
wait_state() { # <wanted> <tries> <sleep>
  local i
  for i in $(seq 1 "$2"); do
    [ "$(run_state)" = "$1" ] && return 0
    sleep "$3"
  done
  return 1
}
TT() { PATH="$PATH_ASSERT" tmux "$@"; }
submit_turn() { # <prompt>
  TT send-keys -t "$TARGET" -l "$1"
  sleep 0.4
  TT send-keys -t "$TARGET" Enter
}
composer_content() { PATH="$PATH_ASSERT" fm_tmux_composer_content "$TARGET" 2>/dev/null || true; }
composer_state() { PATH="$PATH_ASSERT" fm_tmux_composer_state "$TARGET" 2>/dev/null || true; }
clear_composer() {
  local i
  for i in 1 2 3 4 5; do
    [ -z "$(composer_content)" ] && return 0
    TT send-keys -t "$TARGET" C-u
    sleep 0.3
  done
  dfail "could not reset the composer to empty"
}
sampler_start() { # <out-file>
  ( n=0
    while :; do
      n=$((n + 1))
      printf '=== sample %s ===\n' "$n"
      PATH="$PATH_ASSERT" tmux capture-pane -p -t "$TARGET" 2>/dev/null | tail -5
      sleep 0.08
    done ) > "$1" &
  printf '%s' "$!"
}
fm_send_escape() { # <tag>
  PATH="$PATH_ASSERT" FM_HOME="$HOME1" FM_STATE_OVERRIDE="$HOME1/state" \
    FM_SEND_RESTORE_WAIT=8 "$ROOT/bin/fm-send.sh" livemuse --key Escape \
    > "$EVID/$1-fmsend.out" 2> "$EVID/$1-fmsend.err"
}
fm_control_interrupt() { # <tag>
  PATH="$PATH_ASSERT" FM_HOME="$HOME1" FM_STATE_OVERRIDE="$HOME1/state" \
    FM_CONTROL_RESTORE_WAIT=8 FM_CONTROL_SETTLE_WAIT=25 \
    "$ROOT/bin/fm-control.sh" livemuse interrupt \
    > "$EVID/$1-fmcontrol.out" 2> "$EVID/$1-fmcontrol.err"
}
settle_and_reset() {
  wait_state settled 400 0.15 || dfail "never settled after a cancel"
  clear_composer
}

FRESH="fresh captain typing survives"

# ---------------------------------------------------------------- launch -----
[ -f "$HOME/.config/muse/auth.json" ] || dfail "no stored muse credential at ~/.config/muse/auth.json"
cp "$HOME/.config/muse/auth.json" "$LAB/config/muse/auth.json" || dfail "could not stage credential"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESS" -n control -c "$WS" -x 110 -y 40 \
  || dfail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESS:" -n fm-livemuse -c "$WS" -- \
  env -u NO_COLOR XDG_CONFIG_HOME="$LAB/config" XDG_DATA_HOME="$LAB/data" \
  TERM=xterm-256color COLORTERM=truecolor \
  MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on \
  "$MUSE_BIN" --provider meta --yolo "count slowly from one to thirty, one number per line" \
  || dfail "could not launch real muse"
log "launched: $("$MUSE_BIN" --version 2>&1 | head -1) (meta provider, credentialed per docs/verification/muse.md)"
wait_log || dfail "no workspace-bound session.jsonl"
log "session log: $LOG"
wait_state busy 500 0.2 || dfail "model turn never went busy"

# --- control: direct Escape (no product) must leave the restored prompt ------
TT send-keys -t "$TARGET" Escape
CSTATE=
for _ in $(seq 1 40); do
  sleep 0.15
  CSTATE=$(composer_state)
  [ "$CSTATE" = pending ] && break
done
TT capture-pane -e -p -t "$TARGET" -S 0 -E - > "$EVID/control-restore.ansi"
CC=$(composer_content)
log "control: terminal=$(last_terminal) state=$CSTATE content='$CC'"
case "$(last_terminal)" in
  cancelled*model\ step*) ;;
  *) dfail "control: cancel did not land in the model step ($(last_terminal))" ;;
esac
case "$CC" in
  *"count slowly from one to thirty"*) ok "control: muse 1.3.0 restored the cancelled prompt into the composer" ;;
  *) dfail "control: composer after direct model-step Escape holds '$CC'" ;;
esac
settle_and_reset

# --- scenario A: fm-send --key Escape clears the PROVEN restored prompt ------
A_DONE=0
for attempt in 1 2 3; do
  tag=turnA
  submit_turn "write four short lines about rivers flowing to the sea"
  wait_state busy 500 0.2 || dfail "A: model turn never went busy (attempt $attempt)"
  [ "$(composer_state)" = empty ] || dfail "A: composer not empty while busy ($(composer_state))"
  SAMPLER=$(sampler_start "$EVID/turnA-sampler.txt")
  fm_send_escape "$tag"; RC=$?
  kill "$SAMPLER" 2>/dev/null || true
  TERM_KIND=$(last_terminal); AC=$(composer_content)
  log "A attempt $attempt: rc=$RC terminal=$TERM_KIND after-state=$(composer_state) content='$AC' err: $(cat "$EVID/turnA-fmsend.err")"
  case "$TERM_KIND" in
    cancelled*) ;;
    *)
      log "A attempt $attempt: turn closed before Escape; retrying"
      settle_and_reset
      continue
      ;;
  esac
  [ "$RC" = 0 ] || dfail "A: fm-send --key Escape exited $RC"
  grep -q "left untouched" "$EVID/turnA-fmsend.err" \
    && dfail "A: a proven restore was misclassified as fresh input"
  [ -z "$AC" ] || dfail "A: composer still holds the restored prompt '$AC' after the product's clear"
  TT capture-pane -e -p -t "$TARGET" -S 0 -E - > "$EVID/turnA-after.ansi"
  ok "A: fm-send --key Escape proved the restored prompt and cleared it (composer empty)"
  A_DONE=1
  break
done
[ "$A_DONE" = 1 ] || dfail "A: no attempt reached an in-flight cancel"
settle_and_reset

# --- scenario B: fm-send --key Escape preserves FRESH input in-flight --------
B_DONE=0
for attempt in 1 2 3; do
  tag=turnB
  submit_turn "list the primary colors and their complements"
  wait_state busy 500 0.2 || dfail "B: model turn never went busy (attempt $attempt)"
  TT send-keys -t "$TARGET" -l "$FRESH"
  sleep 0.4
  BC=$(composer_content)
  case "$BC" in
    *"$FRESH"*) log "B attempt $attempt: busy with fresh input in composer ('$BC')" ;;
    *) dfail "B: fresh input never landed in the composer (holds '$BC')" ;;
  esac
  SAMPLER=$(sampler_start "$EVID/turnB-sampler.txt")
  fm_send_escape "$tag"; RC=$?
  kill "$SAMPLER" 2>/dev/null || true
  TERM_KIND=$(last_terminal); BC2=$(composer_content)
  log "B attempt $attempt: rc=$RC terminal=$TERM_KIND after-content='$BC2' err: $(cat "$EVID/turnB-fmsend.err")"
  case "$TERM_KIND" in
    cancelled*) ;;
    *)
      log "B attempt $attempt: turn closed before Escape; retrying"
      settle_and_reset
      continue
      ;;
  esac
  [ "$RC" = 0 ] || dfail "B: fm-send --key Escape exited $RC"
  grep -q "left untouched" "$EVID/turnB-fmsend.err" \
    || dfail "B: no skip warning on stderr"
  case "$BC2" in
    *"$FRESH"*) ok "B: the captain's fresh input SURVIVED the in-flight interrupt ('$BC2')" ;;
    *) dfail "B: FRESH INPUT CLOBBERED - composer holds '$BC2' after fm-send --key Escape" ;;
  esac
  TT capture-pane -e -p -t "$TARGET" -S 0 -E - > "$EVID/turnB-after.ansi"
  B_DONE=1
  break
done
[ "$B_DONE" = 1 ] || dfail "B: no attempt reached an in-flight cancel with fresh input"
settle_and_reset

# --- scenario D: fm-control interrupt clears the PROVEN restored prompt ------
D_DONE=0
for attempt in 1 2 3; do
  tag=turnD
  submit_turn "write four short lines about wind over open water"
  wait_state busy 500 0.2 || dfail "D: model turn never went busy (attempt $attempt)"
  [ "$(composer_state)" = empty ] || dfail "D: composer not empty while busy"
  fm_control_interrupt "$tag"; RC=$?
  TERM_KIND=$(last_terminal); DC=$(composer_content)
  log "D attempt $attempt: rc=$RC terminal=$TERM_KIND after-state=$(composer_state) content='$DC' out: $(cat "$EVID/turnD-fmcontrol.out") err: $(cat "$EVID/turnD-fmcontrol.err")"
  case "$TERM_KIND" in
    cancelled*) ;;
    *)
      log "D attempt $attempt: turn closed before the interrupt; retrying"
      settle_and_reset
      continue
      ;;
  esac
  [ "$RC" = 0 ] || dfail "D: fm-control interrupt exited $RC"
  grep -q "interrupt-delivered" "$EVID/turnD-fmcontrol.out" || dfail "D: no delivery line"
  [ -z "$DC" ] || dfail "D: composer still holds '$DC' after the control-plane clear"
  TT capture-pane -e -p -t "$TARGET" -S 0 -E - > "$EVID/turnD-after.ansi"
  ok "D: fm-control interrupt proved the restored prompt and cleared it (composer empty)"
  D_DONE=1
  break
done
[ "$D_DONE" = 1 ] || dfail "D: no attempt reached an in-flight cancel"
settle_and_reset

# --- scenario C: fm-control interrupt preserves FRESH input in-flight --------
C_DONE=0
for attempt in 1 2 3; do
  tag=turnC
  submit_turn "name three mountain ranges on three continents"
  wait_state busy 500 0.2 || dfail "C: model turn never went busy (attempt $attempt)"
  TT send-keys -t "$TARGET" -l "$FRESH control"
  sleep 0.4
  CC1=$(composer_content)
  case "$CC1" in
    *"$FRESH control"*) log "C attempt $attempt: busy with fresh input in composer ('$CC1')" ;;
    *) dfail "C: fresh input never landed (holds '$CC1')" ;;
  esac
  SAMPLER=$(sampler_start "$EVID/turnC-sampler.txt")
  fm_control_interrupt "$tag"; RC=$?
  kill "$SAMPLER" 2>/dev/null || true
  TERM_KIND=$(last_terminal); CC2=$(composer_content)
  log "C attempt $attempt: rc=$RC terminal=$TERM_KIND after-content='$CC2' out: $(cat "$EVID/turnC-fmcontrol.out") err: $(cat "$EVID/turnC-fmcontrol.err")"
  case "$TERM_KIND" in
    cancelled*) ;;
    *)
      log "C attempt $attempt: turn closed before the interrupt; retrying"
      settle_and_reset
      continue
      ;;
  esac
  [ "$RC" = 0 ] || dfail "C: fm-control interrupt exited $RC"
  grep -q "left untouched" "$EVID/turnC-fmcontrol.out" "$EVID/turnC-fmcontrol.err" \
    || dfail "C: no skip warning from fm-control"
  case "$CC2" in
    *"$FRESH control"*) ok "C: fm-control interrupt preserved fresh input ('$CC2')" ;;
    *) dfail "C: FRESH INPUT CLOBBERED by fm-control interrupt - holds '$CC2'" ;;
  esac
  TT capture-pane -e -p -t "$TARGET" -S 0 -E - > "$EVID/turnC-after.ansi"
  C_DONE=1
  break
done
[ "$C_DONE" = 1 ] || dfail "C: no attempt reached an in-flight cancel with fresh input"

log "ALL LIVE SCENARIOS PASSED"
printf 'DRIVE-OK\n'
