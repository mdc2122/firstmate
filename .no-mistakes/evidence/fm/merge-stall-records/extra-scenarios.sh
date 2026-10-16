
# Adversarial: stall records that never alerted are cleared on a merged head, with no corrective wake.
scenario_unalerted_records_cleared_silently() {
  local dir state head=https://github.com/o/r/pull/679
  dir=$(make_case scen-unalerted); state="$dir/home/state"
  seed_two_yolo_prs "$dir" 1
  merge_line "$dir" front "$head" >/dev/null || fail "front refused"
  fake_line_head "$dir" "$head" OPEN FAILURE
  FM_MERGE_LINE_STALL_SECS=1800 merge_line_cycle "$dir" c1
  echo "--- records before merge:"; cat "$state"/*.merge-line-stall
  [ -e "$state/task-a.merge-line-stall" ] || fail "no stall record started"
  fake_line_head "$dir" "$head" MERGED SUCCESS
  FM_MERGE_LINE_STALL_SECS=1800 merge_line_cycle "$dir" c2
  echo "--- c2 stdout:"; cat "$dir/c2.out"
  ! grep -qF 'stall alarms stale' "$dir/c2.out" "$state/.watch-deliveries.log" || fail "a correction fired for alarms never raised"
  ls "$state"/*.merge-line-stall 2>/dev/null | grep -q . && { grep -lF " $head " "$state"/*.merge-line-stall && fail "record naming merged head survived"; }
  pass "un-alerted stall records naming a merged head are cleared with no corrective wake"
}

# Own-poll path: the head PR's own poll reports merged; another task's alerted record naming it is retired with a correction.
scenario_own_poll_merge_retires_other_records() {
  local dir state head=https://github.com/o/r/pull/1
  dir=$(make_case scen-own-poll); state="$dir/home/state"
  seed_two_yolo_prs "$dir" 1
  printf '%s %s %s 1\n' https://github.com/o/r/pull/7 "$head" "$(date +%s)" > "$state/task-x.merge-line-stall"
  printf '%s %s %s 1\n' https://github.com/o/r/pull/8 https://github.com/o/r/pull/900 "$(date +%s)" > "$state/task-y.merge-line-stall"
  rm -f "$state/.last-check"
  FM_TEST_WATCH_ALARM=120 FM_TEST_GH_STATE=OPEN FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
    FM_TEST_GLAB_LOG="$dir/glab.log" run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/c1.out" 2> "$dir/c1.err" \
    || fail "watcher failed: $(cat "$dir/c1.err")"
  echo "--- c1 watcher stdout:"; cat "$dir/c1.out"
  echo "--- firstmate wake drain (what firstmate receives):"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null | tee "$dir/drain.out"
  echo "--- triage log:"; grep -F 'stall record' "$state/.watch-triage.log" || true
  ack_watcher_cycle "$state" || true
  [ "$(forge_merges "$dir")" = '1 ' ] || fail "head did not merge: $(forge_merges "$dir")"
  [ ! -e "$state/task-x.merge-line-stall" ] || fail "other task's record naming merged head survived"
  [ -e "$state/task-y.merge-line-stall" ] || fail "record naming open head removed"
  grep -rqF "stall alarms stale: $head merged, so 1 earlier stall alarm(s) naming it no longer hold: merge-line stalled for green https://github.com/o/r/pull/7 behind it" "$dir/drain.out" \
    || fail "no corrective row queued on own-poll merge"
  pass "own-poll merge retires other tasks' alerted records naming it with one correction and leaves others"
}
