#!/usr/bin/env bash
. /tmp/fmst/shim-setup.sh
. "$ROOT/bin/fm-tmux-lib.sh"; . "$ROOT/bin/fm-task-inbox-lib.sh"
H=/tmp/fmst/home-pi; rm -rf "$H"; mkdir -p "$H/state"
printf 'window=s:fm-pi\nkind=ship\nharness=pi\n' > "$H/state/pi1.meta"
echo "## pre: composer state empty-pane = $(fm_tmux_composer_state s:fm-pi)"
DRAFT=$(printf '\xe2\x81\xa3FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: s:fm-pi')
tmux send-keys -t s:fm-pi -l "$DRAFT"; sleep 1.5
echo "## after typing stranded draft (no Enter): composer state = $(fm_tmux_composer_state s:fm-pi fm-pi)"
c=$(fm_backend_composer_content tmux s:fm-pi fm-pi); echo "## composer content = [$c] (U+2063 count: $(printf '%s' "$c" | grep -o $'\xe2\x81\xa3' | wc -l | tr -d ' '))"
echo "## screen bottom:"; tmux capture-pane -p -t s:fm-pi | grep -v '^\s*$' | tail -5 | cut -c1-120
echo "## run real fm-send"
FM_HOME="$H" FM_ROOT_OVERRIDE="$H" "$ROOT/bin/fm-send.sh" pi1 "Firstmate live check: run exactly this shell command now: touch /tmp/fmst/acted-pi - then follow the mv instruction you were given for this message. Reply with one short line."; echo "fm-send exit=$?"
sleep 2
echo "## screen after fm-send:"; tmux capture-pane -p -t s:fm-pi | grep -v '^\s*$' | tail -12 | cut -c1-140
echo "## composer state now = $(fm_tmux_composer_state s:fm-pi fm-pi)"
ls -R "$H/state/pi1.inbox"
