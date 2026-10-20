#!/usr/bin/env bash
# Mark a seeded home's status logs as already presented so a real watcher pass
# is not cut short by a signal wake; also stop the queue-stall and inactive
# scans from firing. Usage: quiet-home.sh <product-root> <home>
set -eu
ROOT=$1; H=$2
cd "$ROOT"
env FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" bash -c '
  . bin/fm-watch.sh >/dev/null 2>&1
  for f in "$STATE"/*.status; do
    [ -f "$f" ] || continue
    fm_wake_status_mark_current "$STATE" "$f" || true
  done
'
rm -f "$H/state/.wake-queue" "$H/state/.wake-queue.lock"
touch "$H/state/.inactive-outcome-reconcile" "$H/state/.last-check" "$H/state/.last-heartbeat" \
  "$H/state/home-summary.json"