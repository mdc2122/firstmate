#!/bin/bash
# Real fm-watch.sh in an isolated home: a turn-ended marker and routine status
# for task id "paperclip-legacy-recovery-repair" that has NO state/<id>.meta
# (written by another worker's sub-agent), then a captain-relevant line for it.
set -u
ROOT=$1; LABEL=$2
H=$(mktemp -d /tmp/fmhome.XXXXXX); S=$H/state; mkdir -p $S $H/config
G=paperclip-legacy-recovery-repair
run_watch() {
  FM_HOME=$H FM_STATE_OVERRIDE=$S FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_HOME_SUMMARY_INTERVAL=999999 "$ROOT/bin/fm-watch.sh" > $H/watch.out 2> $H/watch.err &
  pid=$!
  for i in $(seq 1 ${1:-80}); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  if kill -0 $pid 2>/dev/null; then echo "   watcher still running after $(( ${1:-80} / 10 ))s - no wake"; kill $pid; wait $pid 2>/dev/null; else wait $pid; echo "   watcher exited rc=$? - WAKE"; fi
  echo "   stdout: $(cat $H/watch.out)"
}
ack() {
  local err=$H/drain.err seq gen
  FM_HOME=$H FM_STATE_OVERRIDE=$S "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>$err
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) .*/\1/p' $err)
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' $err)
  [ -n "$seq" ] && FM_HOME=$H FM_STATE_OVERRIDE=$S "$ROOT/bin/fm-wake-drain.sh" --ack-through $seq --recovery-generation $gen >/dev/null 2>&1
}
echo "== $LABEL"
echo "-- 1) bare turn-ended + 'working:' for unrecorded task $G"
: > $S/$G.turn-ended; printf 'working: helper chatter\n' > $S/$G.status
run_watch; ack
echo "-- 2) another turn-end + routine append for the same unrecorded task"
sleep 1.1; touch $S/$G.turn-ended; printf 'working: more chatter\n' >> $S/$G.status
run_watch; ack
echo "-- 3) adversarial: 'blocked:' line for the unrecorded task must still surface"
printf 'blocked: need the captain\n' >> $S/$G.status
run_watch; ack
echo "-- triage log:"; cat $S/.watch-triage.log 2>/dev/null | sed "s#$S#\$STATE#g"
rm -rf $H
