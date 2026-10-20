#!/usr/bin/env bash
# Run the real bin/fm-watch.sh against a disposable state dir already seeded by
# drive-tick-load.sh-style records, with a fake tmux, and watch it archive the
# settled history while beating. Usage: drive-watcher.sh <product-root> <state>
set -u
ROOT=$1; S=$2; W=$(dirname "$S")
FB="$W/fakebin"; mkdir -p "$FB"
printf '#!/usr/bin/env bash\n[ "${1:-}" = list-windows ] && exit 0\n[ "${1:-}" = capture-pane ] && exit 0\nexit 1\n' > "$FB/tmux"
printf '#!/usr/bin/env bash\necho "state: unknown · source: none · fake"\n' > "$FB/fm-crew-state.sh"
chmod +x "$FB"/*
mkdir -p "$W/notgit"
D="$S/pending-replies"
echo "before: scanned=$(find "$D" -maxdepth 1 -type f | wc -l | tr -d ' ') archived=$(find "$D/archive" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
start=$(date +%s)
PATH="$FB:$PATH" FM_STATE_OVERRIDE="$S" FM_ROOT_OVERRIDE="$W/notgit" FM_CREW_STATE_BIN="$FB/fm-crew-state.sh" \
  FM_PENDING_REPLY_NOW=8200 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_WEDGE_ALARM_EXEC=/usr/bin/true \
  "$ROOT/bin/fm-watch.sh" > "$W/watch.out" 2> "$W/watch.err" &
pid=$!
beats=0; last=''
for i in $(seq 1 600); do
  sleep 1
  m=$(stat -f %m "$S/.last-watcher-beat" 2>/dev/null || true)
  if [ -n "$m" ] && [ "$m" != "$last" ]; then beats=$((beats+1)); echo "t+$(( $(date +%s) - start ))s beat #$beats scanned=$(find "$D" -maxdepth 1 -type f | wc -l | tr -d ' ') archived=$(find "$D/archive" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"; last=$m; fi
  [ "$beats" -ge 4 ] && break
  kill -0 $pid 2>/dev/null || { echo "watcher exited early"; break; }
done
kill $pid 2>/dev/null; wait $pid 2>/dev/null
echo "after: scanned=$(find "$D" -maxdepth 1 -type f | wc -l | tr -d ' ') archived=$(find "$D/archive" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ') total=$(find "$D" -type f | wc -l | tr -d ' ')"
echo "scanned survivors:"; for f in "$D"/*; do [ -f "$f" ] && echo "  $(basename "$f") $(grep '^phase=' "$f") $(grep -E '^escalat' "$f" | tr '\n' ' ')"; done
echo "watcher stderr (tail):"; tail -5 "$W/watch.err"
