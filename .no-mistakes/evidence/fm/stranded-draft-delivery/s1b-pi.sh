#!/usr/bin/env bash
. /tmp/fmst/shim-setup.sh
. "$ROOT/bin/fm-tmux-lib.sh"; . "$ROOT/bin/fm-task-inbox-lib.sh"
H=/tmp/fmst/home-pi; rec="$H/state/pi1.inbox/001.msg"
for i in $(seq 1 90); do st=$(fm_backend_agent_state tmux s:fm-pi 2>/dev/null); cs=$(fm_tmux_composer_state s:fm-pi fm-pi); [ "$cs" = empty ] && [ "$st" != busy ] && break; sleep 2; done
echo "## pi idle after draft turn (agent_state=$st composer=$cs) after ~$((i*2))s"
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" fm_task_inbox_ring tmux s:fm-pi "$rec" fm-pi; echo "## watcher-role re-ring rc=$?"
for i in $(seq 1 120); do [ -f "$H/state/pi1.inbox/handled/001.msg" ] && [ -e /tmp/fmst/acted-pi ] && break; sleep 2; done
echo "## acted=$([ -e /tmp/fmst/acted-pi ] && echo yes || echo no) acked=$([ -f "$H/state/pi1.inbox/handled/001.msg" ] && echo yes || echo no) after ~$((i*2))s"
tmux capture-pane -p -J -S -60 -t s:fm-pi | grep -v '^\s*$' | grep -v '^─' | tail -25 | cut -c1-160
