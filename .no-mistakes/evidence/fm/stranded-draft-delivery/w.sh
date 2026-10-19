#!/usr/bin/env bash
# usage: w.sh <name> <mode normal|stuck> <style> <composer-text-or-empty> <watch-secs>
. /tmp/fmst/shim-setup.sh
. "$ROOT/bin/fm-tmux-lib.sh"
name=$1 mode=$2 style=$3 text=$4 secs=$5
H=/tmp/fmst/home-$name; rm -rf "$H"; mkdir -p "$H/state"; log=/tmp/fmst/submit-$name.log; : > "$log"
tmux kill-window -t s:fm-$name 2>/dev/null
tmux new-window -d -t s: -n fm-$name -c /tmp/fmst -- python3 /tmp/fmst/fake-worker-tui.py "$log" "$mode" "$style"; sleep 1
printf 'window=s:fm-%s\nkind=ship\nharness=claude\n' "$name" > "$H/state/$name.meta"
FM_HOME="$H" FM_ROOT_OVERRIDE="$H" "$ROOT/bin/fm-send.sh" "$name" "please continue with step 2" 2>&1 | grep '^fm-send' ; echo "initial fm-send exit=${PIPESTATUS[0]}"
[ -n "$text" ] && { tmux send-keys -t s:fm-$name -l "$text"; sleep 0.7; }
echo "composer before watcher: $(fm_tmux_composer_state s:fm-$name fm-$name) :: $(tmux capture-pane -p -t s:fm-$name | grep '│\|❯' | head -1 | cut -c1-110)"
FM_HOME="$H" FM_ROOT_OVERRIDE="$H" FM_STATE_OVERRIDE="$H/state" FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_INBOX_RING_MAX=3 \
  FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_PAUSE_RESURFACE_SECS=999 "$ROOT/bin/fm-watch.sh" > /tmp/fmst/watch-$name.out 2>&1 &
pid=$!; sleep "$secs"; kill $pid 2>/dev/null; wait $pid 2>/dev/null
echo "--- triage log (steer-inbox):"; grep 'steer-inbox' "$H/state/.watch-triage.log"
echo "--- watcher stdout:"; grep -v '^\s*$' /tmp/fmst/watch-$name.out | head -8 | cut -c1-400
echo "--- worker submit log:"; cat "$log"
echo "--- composer after: $(fm_tmux_composer_state s:fm-$name fm-$name)"
