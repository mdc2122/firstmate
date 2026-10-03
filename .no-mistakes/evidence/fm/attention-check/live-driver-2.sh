#!/usr/bin/env bash
set -u
W=/Users/studio2/.no-mistakes/worktrees/662ae98237ac/01M41RRYWA7PSK10QJBFTA2R8H
AC=$W/bin/fm-attention-check.sh; VIEW=$W/bin/fm-fleet-view.sh
ROOT=/tmp/fm-attn-live/run2; rm -rf "$ROOT"; mkdir -p "$ROOT/fakebin"; FAKEBIN=$ROOT/fakebin
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/no-mistakes"; printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/tmux"; chmod +x "$FAKEBIN"/*
ep() { jq -nr --arg t "$1" '$t | fromdateiso8601'; }
run() { local h=$1 now=$2; shift 2; PATH="$FAKEBIN:$PATH" FM_HOME="$h" FM_ATTENTION_NOW="$now" "$AC" "$@"; }
H=$ROOT/home; mkdir -p "$H/state" "$H/data" "$H/projects"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Done' > "$H/data/backlog.md"
N=$(ep 2026-10-03T14:00:00Z)
printf 'https://github.com/o/r/pull/7 abc %s 0\n' $((N - 3600)) > "$H/state/t1.pr-green-blocked"

echo "### S-J checks at 09:00Z and 12:59Z only sample"
for t in 2026-10-03T09:00:00Z 2026-10-03T12:59:00Z; do out=$(run "$H" $t check); echo "check $t rc=$? output='$out'"; done
ls -1a "$H/state" | grep '^\.attention'
[ -e "$H/state/.attention-check" ] && echo "daily record: YES (bad)" || echo "daily record: none yet"

echo; echo "### S-D AMBER day (green PR blocked 60 min): first check after 13:00Z at 14:00Z"
out=$(run "$H" 2026-10-03T14:00:00Z check); echo "check rc=$? output='$out'"
cat "$H/state/.attention-check"
[ -e "$H/state/.wake-queue" ] && cat "$H/state/.wake-queue" || echo "wake queue: absent (no wake)"
echo "-- fleet view, Attention section:"
PATH="$FAKEBIN:$PATH" FM_HOME="$H" "$VIEW" | sed -n '/^## Attention/,$p'
