#!/bin/bash
# Drive the real fm-watch.sh against the real Orca app (read-only) in an isolated
# home. Task "fin" (done:) and task "mid" (working:) each record an Orca terminal
# that no longer exists, with leftover stale/wedge markers from before a reboot.
# Usage: drive-watcher-orca-gone.sh <repo-root> <label>
set -u
ROOT=$1; LABEL=$2
H=$(mktemp -d /tmp/fmhome.XXXXXX); S=$H/state; mkdir -p $S $H/config
for pair in fin:term_31857703:'done: shipped' mid:term_e91c7fe1:'working: step 3'; do
  id=${pair%%:*}; rest=${pair#*:}; t=${rest%%:*}; st=${rest#*:}
  printf 'window=fm-%s\nendpoint_task_id=%s\nbackend=orca\nterminal=%s\nkind=ship\nharness=omp\n' $id $id $t > $S/$id.meta
  printf '%s\n' "$st" > $S/$id.status
  for m in hash count stale stale-since wedge-escalations; do echo 1 > $S/.$m-$t; done
done
run_watch() {
  FM_HOME=$H FM_STATE_OVERRIDE=$S FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
    FM_HOME_SUMMARY_INTERVAL=999999 "$ROOT/bin/fm-watch.sh" > $H/watch.out 2> $H/watch.err &
  pid=$!
  for i in $(seq 1 150); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  if kill -0 $pid 2>/dev/null; then echo "== watcher still running after 15s (no wake)"; kill $pid; wait $pid 2>/dev/null; else wait $pid; echo "== watcher exited rc=$?"; fi
}
ack() {
  local err=$H/drain.err seq gen
  FM_HOME=$H FM_STATE_OVERRIDE=$S "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>$err
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) .*/\1/p' $err)
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' $err)
  [ -n "$seq" ] && FM_HOME=$H FM_STATE_OVERRIDE=$S "$ROOT/bin/fm-wake-drain.sh" --ack-through $seq --recovery-generation $gen >/dev/null 2>&1
}
# Phase 0: let the watcher surface and record the seeded status files, then ack,
# and re-seed the pre-reboot pane markers so the sweep below starts from them.
run_watch >/dev/null; ack
for t in term_31857703 term_e91c7fe1; do for m in hash count stale stale-since wedge-escalations; do echo 1 > $S/.$m-$t; done; done
rm -f $S/.endpoint-gone-*
echo "== $LABEL: markers before"; ls -a $S | grep -E '^\.(hash|count|stale|wedge|endpoint)' | sort
run_watch
echo "== watcher stdout:"; cat $H/watch.out
echo "== markers after"; ls -a $S | grep -E '^\.(hash|count|stale|wedge|endpoint)' | sort
for f in $S/.endpoint-gone-*; do [ -e "$f" ] && echo "$(basename $f): $(cat $f)"; done
echo "== triage log"; cat $S/.watch-triage.log 2>/dev/null | tail -5
ack
echo "== second sweep after ack (expect no repeat wake for gone endpoints)"; run_watch
echo "== watcher stdout:"; cat $H/watch.out
rm -rf $H
