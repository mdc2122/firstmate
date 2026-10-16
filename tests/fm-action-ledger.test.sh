#!/usr/bin/env bash
# Tests for the supervisor action ledger (bin/fm-action-ledger-lib.sh owns the
# format): every supervisor verb invocation leaves exactly one direct row naming
# its time, task, verb, and target; a verb another firstmate script runs on its
# behalf records that script as its origin, so it never reads as a second
# supervisor action; read-only queries leave no row; and an unwritable ledger
# never changes the verb's own outcome.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-action-ledger-tests)
URL=https://github.com/example/repo/pull/7

# A home with one recorded task. Each case gets its own so row counts are exact.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/task-a1.meta" \
    "window=firstmate:fm-task-a1" \
    "endpoint_task_id=task-a1" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=ledger-test-task-a1"
  printf '%s\n' "$home"
}

verb() {  # <home> <script> [args...]
  local home=$1 script=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/$script" "$@"
}

ledger_rows() {  # <home>
  local f="$1/state/supervisor-actions.jsonl"
  [ -f "$f" ] || { printf '0'; return 0; }
  awk 'END { print NR + 0 }' "$f"
}

direct_rows() {  # <home>
  local f="$1/state/supervisor-actions.jsonl"
  [ -f "$f" ] || { printf '0'; return 0; }
  jq -s '[.[] | select(.origin == "direct")] | length' "$f"
}

# Assert the ledger holds exactly one direct row carrying the given fields, and
# that every other row names a firstmate bin script as its origin.
assert_one_row() {  # <home> <label> <verb> <action> <task> <target>
  local home=$1 label=$2 f
  f="$home/state/supervisor-actions.jsonl"
  assert_equals 1 "$(direct_rows "$home")" "$label: one invocation must leave exactly one direct ledger row"
  jq -s -e --arg verb "$3" --arg action "$4" --arg task "$5" --arg target "$6" '
    ([.[] | select(.origin == "direct")][0]) as $r
    | $r.verb == $verb and $r.action == $action and $r.task == $task and $r.target == $target
    and ($r.epoch | type) == "number"
    and ($r.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (($r.at | fromdateiso8601) == $r.epoch)
    and all(.[] | select(.origin != "direct"); .origin | test("^fm-[a-z-]+\\.sh$"))
  ' "$f" >/dev/null || fail "$label: ledger rows are wrong: $(cat "$f")"
}

test_each_verb_leaves_exactly_one_row() {
  local home rc

  home=$(make_home send)
  verb "$home" fm-send.sh task-a1 'continue with the "plan"' >/dev/null 2>&1
  assert_one_row "$home" fm-send send steer task-a1 task-a1

  home=$(make_home control)
  # The fixture endpoint cannot be interrupted, so the action is refused after
  # it is attempted - an attempted lifecycle action is still one ledger row.
  rc=0
  verb "$home" fm-control.sh task-a1 interrupt >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-control: the fixture interrupt was expected to be refused"
  assert_one_row "$home" fm-control control interrupt task-a1 task-a1

  home=$(make_home merge-line)
  verb "$home" fm-merge-line.sh front "$URL" >/dev/null 2>&1 || true
  assert_one_row "$home" fm-merge-line merge-line front '' "$URL"

  home=$(make_home pr-merge)
  # fm-pr-merge re-arms through fm-pr-check, which enqueues through
  # fm-merge-line: those nested rows name their calling script, not "direct".
  verb "$home" fm-pr-merge.sh task-a1 "$URL" >/dev/null 2>&1 || true
  assert_one_row "$home" fm-pr-merge pr-merge merge task-a1 "$URL"
  jq -s -e '[.[] | select(.origin == "fm-pr-merge.sh" and .verb == "pr-check")] | length == 1' \
    "$home/state/supervisor-actions.jsonl" >/dev/null \
    || fail "fm-pr-merge's own re-arm was not attributed to fm-pr-merge.sh: $(cat "$home/state/supervisor-actions.jsonl")"

  home=$(make_home captain-hold)
  printf 'go ahead\n' > "$home/decision.txt"
  verb "$home" fm-captain-hold.sh answer task-a1 --decision-file "$home/decision.txt" >/dev/null 2>&1 || true
  assert_one_row "$home" fm-captain-hold captain-hold answer task-a1 task-a1

  pass "send, control, merge-line, pr-merge, and captain-hold each leave exactly one direct ledger row"
}

test_script_origin_is_not_a_supervisor_touch() {
  local home f
  home=$(make_home pr-check)
  # Declaring a line first makes fm-pr-check's own enqueue a real line change,
  # so the nested call records a row of its own.
  verb "$home" fm-merge-line.sh declare "$URL" >/dev/null 2>&1 \
    || fail "fixture: could not declare a merge line"
  verb "$home" fm-pr-check.sh task-a1 "$URL" >/dev/null 2>&1 || true
  f="$home/state/supervisor-actions.jsonl"
  assert_equals 3 "$(ledger_rows "$home")" "declare + pr-check + its nested enqueue must be three rows"
  jq -s -e --arg url "$URL" '
    .[1].verb == "pr-check" and .[1].action == "arm" and .[1].task == "task-a1"
    and .[1].target == $url and .[1].origin == "direct"
    and .[2].verb == "merge-line" and .[2].action == "enqueue" and .[2].task == "task-a1"
    and .[2].origin == "fm-pr-check.sh"
  ' "$f" >/dev/null || fail "pr-check rows are wrong: $(cat "$f")"
  pass "fm-pr-check leaves one direct row, and the merge-line enqueue it runs names fm-pr-check.sh as its origin and the armed task"
}

test_read_only_queries_leave_no_row() {
  local home
  home=$(make_home queries)
  verb "$home" fm-merge-line.sh show >/dev/null 2>&1 || true
  verb "$home" fm-merge-line.sh gate "$URL" >/dev/null 2>&1 || true
  verb "$home" fm-captain-hold.sh open task-a1 >/dev/null 2>&1 || true
  verb "$home" fm-control.sh task-a1 >/dev/null 2>&1 || true
  assert_equals 0 "$(ledger_rows "$home")" "read-only queries and usage errors must not be recorded as actions"
  pass "read-only queries and usage errors leave no ledger row"
}

test_ledger_failure_never_changes_the_verb() {
  local home out rc
  home=$(make_home unwritable)
  # A directory where the ledger file belongs makes every append fail.
  mkdir "$home/state/supervisor-actions.jsonl"
  rc=0
  out=$(verb "$home" fm-send.sh task-a1 'still delivered' 2>&1) || rc=$?
  expect_code 0 "$rc" "fm-send with an unwritable ledger"
  assert_not_contains "$out" supervisor-actions "an unwritable ledger must not print into the verb"
  ls "$home/state/task-a1.inbox/"*.msg >/dev/null 2>&1 \
    || fail "fm-send with an unwritable ledger did not deliver the steer"
  pass "an unwritable ledger neither fails nor blocks the verb that records it"
}

test_each_verb_leaves_exactly_one_row
test_script_origin_is_not_a_supervisor_touch
test_read_only_queries_leave_no_row
test_ledger_failure_never_changes_the_verb
