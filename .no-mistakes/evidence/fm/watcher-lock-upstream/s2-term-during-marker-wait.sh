#!/usr/bin/env bash
# Scenario 2: TERM a real fm-watch.sh while its startup recovery-marker section
# waits on a held .watcher-down.lock. Usage: <repo-root> <label> <holder-release-delay-s>
set -u
ROOT=$1; LABEL=$2; DELAY=$3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
run() { exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
S=$LAB/state
run bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2" || exit 10; echo held > "$3"; sleep 60' _ "$ROOT" "$S/.watcher-down.lock" "$LAB/held" &
for _ in $(seq 1 100); do [ -s "$LAB/held" ] && break; sleep 0.05; done
HP=$(cat "$S/.watcher-down.lock/pid")
run "$ROOT/bin/fm-watch.sh" > "$LAB/watch.out" 2>&1 &
W=$!
for _ in $(seq 1 200); do [ -s "$S/.watch.lock/pid" ] && [ -e "$S/.last-watcher-beat" ] && break; sleep 0.05; done
sleep 1
echo "[$LABEL] watcher pid=$W holds .watch.lock pid=$(cat "$S/.watch.lock/pid" 2>/dev/null); marker lock held by pid=$HP (alive: $(kill -0 $HP 2>/dev/null && echo yes || echo no))"
echo "[$LABEL] watcher in marker wait (still blocked, no poll loop yet): ps=$(ps -o stat= -p $W)"
kill -TERM $W; echo "[$LABEL] sent TERM to watcher; releasing marker holder after ${DELAY}s"
sleep "$DELAY"; kill $HP 2>/dev/null
for _ in $(seq 1 100); do kill -0 $W 2>/dev/null || break; sleep 0.1; done
wait $W; echo "[$LABEL] watcher exit status=$?"
if [ -e "$S/.watch.lock" ]; then
  P=$(cat "$S/.watch.lock/pid" 2>/dev/null); echo "[$LABEL] .watch.lock PRESENT (pid=$P alive: $(kill -0 "$P" 2>/dev/null && echo yes || echo no))"
else echo "[$LABEL] .watch.lock absent"; fi
echo "[$LABEL] watcher stderr/stdout:"; sed 's/^/    /' "$LAB/watch.out"
if [ -e "$S/.watch.lock" ]; then
  echo "[$LABEL] next arm against the leftover lock:"
  run "$ROOT/bin/fm-watch-arm.sh" > "$LAB/arm.out" 2>&1 & A=$!
  for _ in $(seq 1 400); do grep -q '^watcher: ' "$LAB/arm.out" && break; kill -0 $A 2>/dev/null || break; sleep 0.05; done
  echo "    $(grep '^watcher: ' "$LAB/arm.out" | head -1)"
  (run "$ROOT/bin/fm-watch-arm.sh" --stop) >/dev/null 2>&1; wait $A 2>/dev/null
fi
rm -rf "$LAB"
