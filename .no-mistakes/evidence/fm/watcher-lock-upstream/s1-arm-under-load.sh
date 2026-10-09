#!/usr/bin/env bash
# Scenario 1: a real fm-watch-arm.sh under CPU load AND a held recovery-marker
# lock confirms quickly. Usage: s1-arm-under-load.sh <repo-root> <label>
set -u
ROOT=$1; LABEL=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
run() { exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
NCPU=$(sysctl -n hw.ncpu); LOADERS=()
for _ in $(seq 1 $((NCPU * 2))); do ( while :; do :; done ) & LOADERS+=($!); done
echo "[$LABEL] cpu load: $((NCPU*2)) busy loops on $NCPU cpus"
# Hold the watcher's recovery-marker lock for 45s (a contended marker path).
run bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2" || exit 10; echo held > "$3"; sleep 45' _ "$ROOT" "$LAB/state/.watcher-down.lock" "$LAB/held" &
HOLDER=$!
for _ in $(seq 1 100); do [ -s "$LAB/held" ] && break; sleep 0.05; done
echo "[$LABEL] marker lock held by pid $HOLDER: $(cat "$LAB/state/.watcher-down.lock/pid" 2>/dev/null)"
T0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
run "$ROOT/bin/fm-watch-arm.sh" > "$LAB/arm.out" 2>&1 &
ARM=$!
while :; do
  if grep -q '^watcher: ' "$LAB/arm.out" 2>/dev/null; then break; fi
  kill -0 $ARM 2>/dev/null || break
  sleep 0.05
done
T1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
echo "[$LABEL] arm status after $(perl -e "printf '%.2f', $T1-$T0")s: $(grep '^watcher: ' "$LAB/arm.out" | head -1)"
kill "${LOADERS[@]}" 2>/dev/null; wait "${LOADERS[@]}" 2>/dev/null
HP=$(cat "$LAB/state/.watcher-down.lock/pid" 2>/dev/null); kill $HOLDER $HP 2>/dev/null; wait $HOLDER 2>/dev/null; sleep 0.3
echo "[$LABEL] stop: $( (run "$ROOT/bin/fm-watch-arm.sh" --stop) 2>&1 | tail -1)"
for _ in $(seq 1 100); do kill -0 $ARM 2>/dev/null || break; sleep 0.1; done
kill $ARM 2>/dev/null; wait $ARM 2>/dev/null
echo "[$LABEL] arm output:"; sed 's/^/    /' "$LAB/arm.out"
echo "[$LABEL] .watch.lock after stop: $([ -e "$LAB/state/.watch.lock" ] && echo PRESENT || echo absent)"
rm -rf "$LAB"
