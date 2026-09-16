#!/usr/bin/env bash
# Addendum on the still-live lab from live-drive.sh: the unprovable boundary.
# With no muse-session binding, the restored prompt cannot be proven, so
# fm-send must skip the clear with a warning (composer untouched) and
# fm-control must refuse loudly after delivering the interrupt.
set -u
EVID=/Users/Morley/.no-mistakes/evidence/01M2MJEBHN3K1Y9N0136SVCEWA
ROOT=/Users/Morley/.no-mistakes/worktrees/62b3bc0be3e5/01M2MJEBHN3K1Y9N0136SVCEWA
REAL_TMUX=$(command -v tmux)

LAB=$(grep -o '/var[^ ]*fm-clobber-live[^ ]*/data' "$EVID/live-drive.log" | head -1 | sed 's|/data$||')
[ -n "$LAB" ] || { echo "no live lab found"; exit 1; }
SOCKET=$(ls /private/tmp/tmux-502/ | grep "fm-clobber-live" | head -1)
TARGET="fmclob:fm-livemuse"
HOME1="$LAB/home"
export FM_GATE_REFUSE_BYPASS=1
PATH="$LAB/bin:$PATH"

. "$ROOT/bin/fm-busy-lib.sh"
. "$ROOT/bin/fm-tmux-lib.sh"

LOG=$(fm_busy_muse_matching_logs "$LAB/data/muse/sessions" "$(cd "$LAB/ws" && pwd -P)" 2>/dev/null | head -1)
echo "lab: $LAB  log: $LOG"
BIND="$HOME1/state/livemuse.muse-session"
[ -f "$BIND" ] || { echo "binding missing already"; exit 1; }

wait_state() {
  for _ in $(seq 1 "$2"); do
    [ "$(fm_busy_muse_run_state "$LOG" 2>/dev/null || true)" = "$1" ] && return 0
    sleep "$3"
  done
  return 1
}
composer_content() { fm_tmux_composer_content "$TARGET" 2>/dev/null || true; }

wait_state settled 400 0.15 || true
# clean composer
for _ in 1 2 3; do [ -z "$(composer_content)" ] || { tmux send-keys -t "$TARGET" C-u; sleep 0.3; }; done

# Break provability: remove the session-log binding.
mv "$BIND" "$BIND.hidden"
tmux send-keys -t "$TARGET" -l "summarize the plot of hamlet in two sentences"
sleep 0.4
tmux send-keys -t "$TARGET" Enter
wait_state busy 500 0.2 || { echo "never busy"; mv "$BIND.hidden" "$BIND"; exit 1; }

# E: fm-send --key Escape with an unprovable restored prompt
PATH="$LAB/bin:$PATH" FM_HOME="$HOME1" FM_STATE_OVERRIDE="$HOME1/state" \
  FM_SEND_RESTORE_WAIT=3 "$ROOT/bin/fm-send.sh" livemuse --key Escape \
  > "$EVID/turnE-fmsend.out" 2> "$EVID/turnE-fmsend.err"
RC=$?
CONTENT=$(composer_content)
echo "E: rc=$RC content='$CONTENT'"
echo "E stderr: $(grep fm-send: "$EVID/turnE-fmsend.err" | head -2)"
[ "$RC" = 0 ] || { echo "E FAILED rc"; mv "$BIND.hidden" "$BIND"; exit 1; }
grep -q "cannot be proven" "$EVID/turnE-fmsend.err" || { echo "E FAILED: no unprovable warning"; mv "$BIND.hidden" "$BIND"; exit 1; }
case "$CONTENT" in
  *"summarize the plot of hamlet"*) : ;;
  *) echo "E FAILED: composer holds '$CONTENT' (expected the untouched restored prompt)"; mv "$BIND.hidden" "$BIND"; exit 1 ;;
esac
echo "ok - E: fm-send skipped the unprovable clear with a warning; the restored prompt sits untouched"

# F: fm-control interrupt with an unprovable restored prompt dies loudly
wait_state settled 400 0.15 || true
for _ in 1 2 3; do [ -z "$(composer_content)" ] || { tmux send-keys -t "$TARGET" C-u; sleep 0.3; }; done
tmux send-keys -t "$TARGET" -l "name two moons of jupiter"
sleep 0.4
tmux send-keys -t "$TARGET" Enter
wait_state busy 500 0.2 || { echo "never busy"; mv "$BIND.hidden" "$BIND"; exit 1; }
PATH="$LAB/bin:$PATH" FM_HOME="$HOME1" FM_STATE_OVERRIDE="$HOME1/state" \
  FM_CONTROL_RESTORE_WAIT=3 FM_CONTROL_SETTLE_WAIT=25 \
  "$ROOT/bin/fm-control.sh" livemuse interrupt \
  > "$EVID/turnF-fmcontrol.out" 2> "$EVID/turnF-fmcontrol.err"
RC=$?
CONTENT=$(composer_content)
echo "F: rc=$RC content='$CONTENT'"
echo "F stderr: $(cat "$EVID/turnF-fmcontrol.err" | head -3)"
mv "$BIND.hidden" "$BIND"
[ "$RC" = 1 ] || { echo "F FAILED: expected loud refusal (rc=$RC)"; exit 1; }
grep -q "cannot be proven" "$EVID/turnF-fmcontrol.err" || { echo "F FAILED: refusal does not name the unprovable proof"; exit 1; }
case "$CONTENT" in
  *"two moons of jupiter"*) : ;;
  *) echo "F FAILED: composer holds '$CONTENT' (expected the untouched restored prompt)"; exit 1 ;;
esac
echo "ok - F: fm-control refused loudly on the unprovable path (exit 1); the restored prompt sits untouched"
tmux capture-pane -e -p -t "$TARGET" -S 0 -E - > "$EVID/turnF-after.ansi"
echo "ADDENDUM-OK"
