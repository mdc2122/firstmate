#!/usr/bin/env bash
# Drives the real bin/fm-afk-launch.sh with real harness detection against
# disposable FM_HOME dirs. "$OMP" is a symlink to /bin/bash named `omp`, so the
# launcher runs with a genuine omp process in its ancestry plus OMPCODE=1 (the
# marker omp sets on its tool children) - fm-harness.sh then reports omp.
set -u
WT=/Users/studio2/.no-mistakes/worktrees/662ae98237ac/01M46BCD2K0H5GHSZVEH9K1FG3
L="$WT/bin/fm-afk-launch.sh"
D=$(mktemp -d /tmp/ompbin.XXXX); ln -s /bin/bash "$D/omp"; OMP="$D/omp"
unset PI_CODING_AGENT FM_PI_HARNESS FM_OMP_HARNESS CLAUDECODE
run() { echo "\$ $*"; "$@" 2>&1; echo "[rc=$?]"; }
omp_run() { echo "\$ [under omp] $* fm-afk-launch.sh ${SUB[*]}"; env OMPCODE=1 "$@" "$OMP" -c '"$0" "$@"; exit $?' "$L" "${SUB[@]}" 2>&1; echo "[rc=$?]"; }
state() { echo "  state files: $(cd "$H/state" && ls -A | tr '\n' ' ')"; }
fresh() { [ -n "${H:-}" ] && rm -rf "$H"; H=$(mktemp -d /tmp/fmq.XXXX); mkdir -p "$H/state"; export FM_HOME="$H" FM_STATE_OVERRIDE="$H/state"; }
fresh
echo "== harness detected under omp: $(env OMPCODE=1 "$OMP" "$WT/bin/fm-harness.sh")"
echo; echo "== S1: /quiet on omp, FM_AFK_MODE=quiet exported before propose (skill step 1)"
for s in propose confirm start start-native; do SUB=($s); omp_run FM_AFK_MODE=quiet; state; done
echo; echo "== S2: adversarial - quiet confirm on omp with a proposal already pending (from a propose run without quiet)"
SUB=(propose); omp_run >/dev/null; state
SUB=(confirm); omp_run FM_AFK_MODE=quiet; state
fresh
echo; echo "== S3: /afk (away) on omp records the posture; start/start-native refuse to launch a daemon; stop archives"
SUB=(propose); omp_run >/dev/null; SUB=(confirm); omp_run; SUB=(start); omp_run; SUB=(start-native); omp_run; state
SUB=(stop); omp_run; state
fresh
echo; echo "== S4: regression - /quiet on claude still enters quiet mode via start-native"
for s in propose confirm start-native; do CLAUDECODE=1 FM_AFK_MODE=quiet "$L" $s >/dev/null 2>&1; done
echo "  .afk first line: $(head -1 "$H/state/.afk")"; state
run env CLAUDECODE=1 "$L" stop; state
rm -rf "$H" "$D"
