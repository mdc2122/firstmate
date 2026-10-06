#!/usr/bin/env bash
# Tests for the scout recommendation gate: bin/fm-followup-ledger.sh and the
# scout completion gate in bin/fm-teardown.sh that runs it.
#
# The incident: two scout reports recommended ranking work (a per-window panel
# score, re-pointing ranking on early velocity) in their Recommendations and
# ranked-plan sections, the scouts were cleaned up, and neither recommendation
# ever became a backlog item, so nothing surfaced them again. Each case below
# drives a report shape through the public command, or through teardown
# itself, and asserts that a missing ledger or an unresolved, reasonless, or
# unknown-task line is refused by name while a resolved ledger passes.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER="$ROOT/bin/fm-followup-ledger.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-followup-ledger)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

axi() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  tasks-axi "$@" --file "$home/data/backlog.md" >/dev/null || fail "tasks-axi $* failed"
}

ledger() {  # <home> <scout-id>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" "$LEDGER" check "$2"
}

# A report shaped like the incident: a numbered recommendation list, a ranked
# plan table, and a promotion-candidates list restating two plan rows.
write_report() {  # <home> <scout-id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/report.md" <<'EOF'
# Is the ranking the bottleneck?

## Summary

Some context.

## 5. Recommendations, in order

### 1. Unstick review of draft-only top cards

- evidence bullet

### 2. Score each window on its own panel score

## A ranked plan

| # | Step | Expected |
|---|---|---|
| 1 | Finish the top card | +100K |
| 3 | Re-point ranking on early velocity | +50K |

## Promotion candidates

- Hit-reactive lane
EOF
}

append_ledger() {  # <home> <scout-id> <lines...>
  local file="$1/data/$2/report.md" line
  shift 2
  printf '\n## Follow-up ledger\n\n' >> "$file"
  for line in "$@"; do printf '%s\n' "$line" >> "$file"; done
}

test_report_with_recommendations_and_no_ledger_refuses() {
  local home err
  home=$(make_home no-ledger)
  write_report "$home" sample-scout
  if ledger "$home" sample-scout 2> "$home/err"; then
    fail "a report with recommendations and no ledger passed the gate"
  fi
  err=$(cat "$home/err")
  assert_contains "$err" '("5. Recommendations, in order") but no "## Follow-up ledger" section' \
    "the refusal did not name the recommendation section and the missing ledger"
  pass "a report with a recommendation section and no ledger is refused"
}

test_empty_ledger_refuses() {
  local home err
  home=$(make_home empty-ledger)
  write_report "$home" sample-scout
  append_ledger "$home" sample-scout
  if ledger "$home" sample-scout 2> "$home/err"; then
    fail "an empty ledger passed the gate"
  fi
  err=$(cat "$home/err")
  assert_contains "$err" 'its "## Follow-up ledger" is empty' "an empty ledger was not named"
  pass "a report with a recommendation section and an empty ledger is refused"
}

test_every_problem_line_is_named() {
  local home err
  home=$(make_home unfiled)
  write_report "$home" sample-scout
  axi "$home" add finish-top "finish the top card"
  append_ledger "$home" sample-scout \
    "- Finish the top card -> finish-top" \
    "- Score each window on its own panel score -> open" \
    "- Re-point ranking on early velocity" \
    "- Hit-reactive fast lane -> no-such-task" \
    "- Third slot -> declined:   " \
    "  indented note with no disposition"
  if ledger "$home" sample-scout 2> "$home/err"; then
    fail "a ledger with problem lines passed the gate"
  fi
  err=$(cat "$home/err")
  assert_not_contains "$err" "Finish the top card" "a line naming a backlog task was reported"
  assert_contains "$err" '"Score each window on its own panel score" is not filed' \
    "an open line was not named"
  assert_contains "$err" '"Re-point ranking on early velocity" is not filed' \
    "a line with no disposition was not named"
  assert_contains "$err" '"indented note with no disposition" is not filed' \
    "an indented line with no disposition was not checked"
  assert_contains "$err" "\"Hit-reactive fast lane\" names no-such-task, which is not a task in this home's backlog" \
    "an unknown task id was accepted"
  assert_contains "$err" '"Third slot" is declined without a reason' \
    "a reasonless decline was accepted"
  pass "every problem ledger line is named by its text with the reason"
}

test_task_and_declined_ledger_passes() {
  local home err
  home=$(make_home filed)
  write_report "$home" sample-scout
  axi "$home" add finish-top "finish the top card"
  axi "$home" add hit-lane "hit-reactive lane"
  axi "$home" add velocity "re-point on velocity"
  append_ledger "$home" sample-scout \
    "- Finish the top card -> finish-top" \
    "- Hit-reactive fast lane -> \`hit-lane\`, velocity" \
    "- Re-point ranking A -> B on early velocity -> velocity" \
    "* Hook score -> Declined: inverse at the tail, nothing to build" \
    "" \
    "1. Own scout -> sample-scout-missing -> declined: kept in the report"
  ledger "$home" sample-scout 2> "$home/err" \
    || fail "a fully resolved ledger was refused: $(cat "$home/err")"
  err=$(cat "$home/err")
  [ -z "$err" ] || fail "a passing gate printed diagnostics: $err"
  pass "lines naming backlog tasks or declined with a reason pass, whatever the report's shape"
}

test_report_without_recommendations_passes() {
  local home
  home=$(make_home plain)
  mkdir -p "$home/data/sample-scout"
  printf '# Findings\n\n## Test plan\n\n- step one\n\n~~~\n## Recommendations in a fence\n~~~\n' \
    > "$home/data/sample-scout/report.md"
  ledger "$home" sample-scout 2> "$home/err" \
    || fail "a report with no recommendation heading was refused: $(cat "$home/err")"
  pass "a report with no recommendation heading needs no ledger"
}

test_unreadable_backlog_is_not_filed() {
  local home rc=0
  home=$(make_home unreadable)
  write_report "$home" sample-scout
  append_ledger "$home" sample-scout "- a -> one"
  rm -f "$home/data/backlog.md"
  mkdir "$home/data/backlog.md"
  ledger "$home" sample-scout 2> "$home/err" || rc=$?
  [ "$rc" -eq 2 ] || fail "an unreadable backlog did not exit 2 (got $rc): $(cat "$home/err")"
  pass "a backlog the gate cannot read is 'cannot tell', never 'filed'"
}

# --- teardown runs the gate ---------------------------------------------------

write_scout_meta() {  # <home> <id>
  fm_write_meta "$1/state/$2.meta" \
    "window=firstmate:fm-$2" \
    "worktree=$1/projects/missing-$2" \
    "project=$1/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout" \
    "spawn_gen=fixture-$2"
}

run_teardown() {  # <home> <id> [--force]
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$@"
}

complete_none() {  # <home> <id>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$2" --none >/dev/null \
    || fail "the captain-call completion gate failed for $2"
}

test_teardown_refuses_unfiled_recommendations_then_proceeds() {
  local home id err show
  home=$(make_home teardown)
  id=sample-ranking-review
  axi "$home" add "$id" "Investigate the ranking" --kind scout --repo sample
  axi "$home" start "$id"
  write_scout_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  write_report "$home" "$id"
  append_ledger "$home" "$id" \
    "- Unstick draft-only review -> open" \
    "- Score each window on its own panel score -> open" \
    "- Re-point ranking on early velocity -> open" \
    "- Hook score -> declined: inverse at the tail"
  complete_none "$home" "$id"

  if run_teardown "$home" "$id" > "$home/out" 2> "$home/err"; then
    fail "cleanup proceeded with unfiled recommendations"
  fi
  err=$(cat "$home/err")
  assert_contains "$err" "has recommendations that are not filed or declined" \
    "the refusal did not say why"
  assert_contains "$err" '"Score each window on its own panel score" is not filed' \
    "the refusal did not name the unfiled item"
  assert_contains "$err" '"Re-point ranking on early velocity" is not filed' \
    "the refusal did not name every unfiled item"
  assert_not_contains "$err" "Hook score" "a declined item was named as unfiled"
  [ -f "$home/state/$id.meta" ] || fail "a refused cleanup removed the task record"
  show=$(tasks-axi show "$id" --file "$home/data/backlog.md") || fail "the scout row vanished"
  assert_contains "$show" "state: in_flight" "a refused cleanup moved the scout row"

  axi "$home" add review-unstick "unstick review"
  axi "$home" start review-unstick
  axi "$home" add ranking-shadow "per-window score and velocity shadow"
  axi "$home" hold ranking-shadow --reason "first readout needs the 10-07 matured clips"
  sed -i.bak \
    -e 's/Unstick draft-only review -> open/Unstick draft-only review -> review-unstick/' \
    -e 's/own panel score -> open/own panel score -> ranking-shadow/' \
    -e 's/early velocity -> open/early velocity -> ranking-shadow/' \
    "$home/data/$id/report.md"
  rm -f "$home/data/$id/report.md.bak"
  run_teardown "$home" "$id" > "$home/out" 2> "$home/err" \
    || fail "cleanup refused a fully filed ledger: $(cat "$home/err")"
  show=$(tasks-axi show "$id" --file "$home/data/backlog.md") || fail "the scout row vanished"
  assert_contains "$show" "state: done" "cleanup did not close the finished scout"
  pass "scout cleanup refuses, naming each unfiled recommendation, and proceeds once every one is filed or declined"
}

test_force_skips_the_ledger_like_the_other_scout_checks() {
  local home id
  home=$(make_home teardown-force)
  id=sample-forced-review
  axi "$home" add "$id" "Investigate the forced path" --kind scout --repo sample
  axi "$home" start "$id"
  write_scout_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  write_report "$home" "$id"
  run_teardown "$home" "$id" --force > "$home/out" 2> "$home/err" \
    || fail "discard-authorized cleanup was blocked by the ledger: $(cat "$home/err")"
  pass "explicit discard authority skips the ledger with the other scout report checks"
}

test_report_with_recommendations_and_no_ledger_refuses
test_empty_ledger_refuses
test_every_problem_line_is_named
test_task_and_declined_ledger_passes
test_report_without_recommendations_passes
test_unreadable_backlog_is_not_filed
test_teardown_refuses_unfiled_recommendations_then_proceeds
test_force_skips_the_ledger_like_the_other_scout_checks
