queue_line_case() {  # <name> <pr-count> [<task-id per PR>...]
  local dir state i id url count=$2 ids
  dir=$(make_case "$1")
  shift 2
  ids=("$@")
  [ "${#ids[@]}" -gt 0 ] || ids=(task-a task-b task-c task-d)
  state="$dir/home/state"
  ln -sf "$REAL_JQ" "$dir/fakebin/jq"
  merge_line "$dir" declare https://github.com/o/r >/dev/null || fail "could not declare the line"
  i=0
  while [ "$i" -lt "$count" ]; do
    i=$((i + 1))
    id=${ids[$((i - 1))]-}
    [ -n "$id" ] || fail "no fixture task for PR $i"
    url=https://github.com/o/r/pull/$i
    write_poll_meta "$state" "$id" "$url" yolo=on
    run_check_entry "$dir" "$id" "$url" >/dev/null 2> "$dir/arm-$id.err" \
      || fail "could not arm $id: $(cat "$dir/arm-$id.err")"
  done
  add_stop_custom_check "$dir"
  cat > "$dir/rules.json" <<'JSON'
[{"type":"required_status_checks","ruleset_id":202,"parameters":{"required_status_checks":[{"context":"queue-mq","integration_id":5293819}]}},
 {"type":"pull_request","ruleset_id":101,"parameters":{}},
 {"type":"required_status_checks","ruleset_id":101,"parameters":{"required_status_checks":[{"context":"ci","integration_id":15368}]}}]
JSON
  printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","headRefOid":"%s","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"queue-mq","status":"IN_PROGRESS","conclusion":null}]}\n' \
    0123456789abcdef0123456789abcdef01234567 > "$dir/view.json"
  printf '{"state":"OPEN","headRefOid":"%s","autoMergeRequest":{"mergeMethod":"SQUASH"},"statusCheckRollup":[{"__typename":"CheckRun","name":"queue-mq","status":"IN_PROGRESS","conclusion":null}]}\n' \
    0123456789abcdef0123456789abcdef01234567 > "$dir/auto.json"
  : > "$dir/check-runs.json"
  printf '%s\n' "$dir"
}

queue_line_cycle() {  # <dir> <label> [gh-state]
  local dir=$1 label=$2 rc
  [ ! -s "$dir/home/state/.wake-queue" ] || ack_watcher_cycle "$dir/home/state" \
    || fail "$label: acknowledging the previous cycle failed"
  rm -f "$dir/home/state/.last-check"
  set +e
  FM_TEST_WATCH_ALARM=${FM_TEST_WATCH_ALARM:-240} \
    FM_TEST_GH_STATE=${3:-OPEN} FM_TEST_GH_GRAPHQL_STATE=OPEN FM_TEST_GH_GRAPHQL_MERGED=false \
    FM_TEST_GH_VIEW_JSON="$dir/view.json" FM_TEST_GH_AUTO_JSON="$dir/auto.json" \
    FM_TEST_GH_RULES_JSON="$dir/rules.json" FM_TEST_GH_CHECK_RUNS_JSON="$dir/check-runs.json" \
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" FM_TEST_GLAB_LOG="$dir/glab.log" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/$label.out" 2> "$dir/$label.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "$label: watcher cycle failed (rc=$rc): $(cat "$dir/$label.err")"
  cp "$dir/home/state/.wake-queue" "$dir/$label.queue" 2>/dev/null || : > "$dir/$label.queue"
  ack_watcher_cycle "$dir/home/state" || fail "$label: acknowledgement failed"
}

# One pull request's queue hand-off read is served its own file; every other
# gh call passes through: an ejected entry reads auto-merge off while its
# neighbours still read waiting.
