#!/usr/bin/env bash
# Behavior tests for per-lane work-in-progress caps (bin/fm-wip-caps-lib.sh)
# as enforced by bin/fm-spawn.sh.
#
# Each case drives the real fm-spawn through a fake tmux pane and real isolated
# git worktrees. Lane occupants are ordinary task records in the home's state/,
# so the cases exercise exactly what a live home holds. Relaunch exemption is
# covered beside the other relaunch refusals in tests/fm-control-relaunch.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-wip-caps)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
export FM_BACKEND=tmux

# new_home <name> -> echoes a home with a fakebin under it.
new_home() {
  local home="$TMP_ROOT/$1"
  fm_test_spawn_home "$home" codex
  fm_test_make_spawn_fakebin "$home/fake" >/dev/null
  printf '%s\n' "$home"
}

# occupy <home> <id> [key=value...]: a live task record holding a lane slot.
# With no fields it is a ship before its pull request (lane validations).
occupy() {
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" "window=fm-$id" "endpoint_task_id=$id" \
    "worktree=/nonexistent/$id" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=on" "$@"
}

# spawn_task <home> <id> [fm-spawn args...]: brief, isolated worktree, and one
# real fm-spawn of <id>. Prints combined output; returns fm-spawn's status.
spawn_task() {
  local home=$1 id=$2 proj wt
  shift 2
  proj="$home/proj-$id"
  wt="$home/wt-$id"
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$id" >/dev/null 2>&1
  FM_FAKE_LAUNCH_LOG="$home/launch-$id.log" \
    fm_test_run_spawn "$home" "$wt" "$home/fake/fakebin" "$id" "$proj" --harness codex "$@"
}

spawn_ship() {
  local home=$1 id=$2
  shift 2
  spawn_task "$home" "$id" --mode no-mistakes --yolo on "$@"
}

test_at_cap_refusal_names_lane_cap_and_occupants_and_creates_nothing() {
  local home out rc
  home=$(new_home at-cap)
  printf 'validations=2\n' > "$home/config/wip-caps"
  occupy "$home" busy-a
  occupy "$home" parked-b
  printf 'working: started\npaused: waiting on the release window\n' > "$home/state/parked-b.status"

  out=$(spawn_ship "$home" new-c); rc=$?
  expect_code 5 "$rc" "a dispatch into a full lane"
  assert_contains "$out" "lane validations is at its cap of 2 with 2 in flight" \
    "the refusal must name the lane, its cap, and its occupancy"
  assert_contains "$out" "busy-a" "the refusal must name every task occupying the lane"
  assert_contains "$out" "parked-b [last event: paused]" \
    "a paused task still holds its slot and the refusal shows why it is there"
  assert_absent "$home/state/new-c.meta" "a refused dispatch must not publish a task record"
  [ ! -s "$home/launch-new-c.log" ] || fail "a refused dispatch must not launch a worker"
  pass "at cap: the refusal names the lane, its cap, and its occupants, and nothing is created"
}

test_a_finish_frees_exactly_one_slot() {
  local home out rc
  home=$(new_home finish)
  printf 'validations=2\n' > "$home/config/wip-caps"
  occupy "$home" done-a
  occupy "$home" running-b

  out=$(spawn_ship "$home" next-c); rc=$?
  expect_code 5 "$rc" "the lane is full before any finish"

  # done-a finishes: cleanup removes its record.
  rm -f "$home/state/done-a.meta"
  out=$(spawn_ship "$home" next-c); rc=$?
  expect_code 0 "$rc" "the first dispatch after a finish"$'\n'"$out"
  assert_contains "$out" "spawned next-c" "the freed slot should admit one dispatch"

  out=$(spawn_ship "$home" next-d); rc=$?
  expect_code 5 "$rc" "the second dispatch after one finish"
  assert_contains "$out" "next-c" "the task that took the freed slot now occupies it"
  pass "a finish frees exactly one slot: one dispatch is admitted and the next is refused"
}

test_a_green_pr_moves_the_ship_from_validations_to_merges() {
  local home out rc
  home=$(new_home green)
  printf 'validations=1\nmerges=1\n' > "$home/config/wip-caps"
  occupy "$home" ship-a

  out=$(spawn_ship "$home" ship-b); rc=$?
  expect_code 5 "$rc" "validations full"

  # ship-a reaches its ready line: its pull request is recorded.
  printf 'pr=https://github.com/example/repo/pull/1\n' >> "$home/state/ship-a.meta"
  out=$(spawn_ship "$home" ship-b); rc=$?
  expect_code 5 "$rc" "a ship needs the merges lane below its cap too"
  assert_contains "$out" "lane merges is at its cap of 1 with 1 in flight: ship-a" \
    "a full merge line must refuse new ships and name what holds it"

  # ship-a's merge outcome is delivered: it holds no slot any more.
  : > "$home/state/ship-a.pr-poll-merge-notified"
  out=$(spawn_ship "$home" ship-b); rc=$?
  expect_code 0 "$rc" "a delivered merge frees the merges slot"$'\n'"$out"
  pass "a ship moves validations -> merges at its PR and frees its slot at its merge outcome"
}

test_lanes_are_independent() {
  local home out rc
  home=$(new_home independent)
  printf 'validations=1\ninvestigations=1\n' > "$home/config/wip-caps"
  occupy "$home" ship-a

  out=$(spawn_task "$home" scout-b --scout); rc=$?
  expect_code 0 "$rc" "a scout while validations is full"$'\n'"$out"

  out=$(spawn_task "$home" scout-c --scout); rc=$?
  expect_code 5 "$rc" "a second scout"
  assert_contains "$out" "lane investigations is at its cap of 1 with 1 in flight: scout-b" \
    "the scout lane must refuse on its own occupancy"
  assert_not_contains "$out" "lane validations" "a scout must not be refused by the ship lane"
  pass "lanes are independent: a full ship lane does not block a scout, and vice versa"
}

test_bypass_records_itself_and_still_holds_its_slot() {
  local home out rc log
  home=$(new_home bypass)
  printf 'validations=1\n' > "$home/config/wip-caps"
  occupy "$home" ship-a

  out=$(spawn_ship "$home" urgent-b --cap-bypass security --cap-bypass-reason "token leak in prod logs"); rc=$?
  expect_code 0 "$rc" "a recorded security bypass"$'\n'"$out"
  assert_contains "$out" "bypasses the work-in-progress cap (security: token leak in prod logs)" \
    "the bypass must say so at dispatch"
  assert_grep "wip_cap_bypass=security" "$home/state/urgent-b.meta" "the task record must carry its bypass"
  log="$home/data/wip-cap-bypasses.log"
  assert_present "$log" "the bypass must be appended to the durable bypass log"
  [ "$(cut -f2- "$log")" = "$(printf 'urgent-b\tvalidations\tsecurity\t1/1\ttoken leak in prod logs')" ] \
    || fail "the bypass log line must name task, lane, class, occupancy/cap, and reason; got: $(cat "$log")"

  out=$(spawn_ship "$home" next-c); rc=$?
  expect_code 5 "$rc" "a dispatch after the bypass"
  assert_contains "$out" "urgent-b [bypass: security]" "the bypassed task must still hold its slot"
  pass "a bypass records itself in the task record and the bypass log, and still holds its slot"
}

test_bypass_needs_a_known_class_and_a_reason() {
  local home out rc
  home=$(new_home bypass-args)
  out=$(spawn_ship "$home" b1 --cap-bypass urgent --cap-bypass-reason x); rc=$?
  expect_code 1 "$rc" "an unknown bypass class"
  assert_contains "$out" "must be one of captain" "the refusal should name the accepted classes"
  out=$(spawn_ship "$home" b2 --cap-bypass captain); rc=$?
  expect_code 1 "$rc" "a bypass with no reason"
  assert_contains "$out" "requires a non-empty --cap-bypass-reason" "a bypass must carry its reason"
  assert_absent "$home/state/b1.meta" "a malformed bypass must create nothing"
  assert_absent "$home/state/b2.meta" "a reasonless bypass must create nothing"
  pass "a bypass is refused without a known class and a non-empty reason"
}

test_secondmate_spawn_is_exempt_and_refuses_bypass_flags() {
  local home sm out rc lane
  home=$(new_home secondmate)
  printf 'validations=1\nmerges=1\nreviews=1\ninvestigations=1\n' > "$home/config/wip-caps"
  occupy "$home" ship-a
  occupy "$home" ship-b pr=https://github.com/example/repo/pull/2
  occupy "$home" scout-c kind=scout
  occupy "$home" review-d kind=scout wip_lane=reviews
  sm="$TMP_ROOT/secondmate-sm-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf 'mate-e\n' > "$sm/.fm-secondmate-home"
  printf 'charter for mate-e\n' > "$sm/data/charter.md"

  out=$(FM_FAKE_LAUNCH_LOG="$home/launch-mate-e.log" \
    fm_test_run_spawn "$home" "$sm" "$home/fake/fakebin" mate-e "$sm" --secondmate \
      --cap-bypass captain --cap-bypass-reason x); rc=$?
  expect_code 1 "$rc" "a bypass flag on an exempt spawn"
  assert_contains "$out" "exempt from work-in-progress caps" "the refusal should say why"

  out=$(FM_FAKE_LAUNCH_LOG="$home/launch-mate-e.log" \
    fm_test_run_spawn "$home" "$sm" "$home/fake/fakebin" mate-e "$sm" --secondmate); rc=$?
  expect_code 0 "$rc" "a secondmate spawn with every lane full"$'\n'"$out"
  for lane in validations merges reviews investigations; do
    assert_not_contains "$out" "lane $lane is at its cap" "a secondmate spawn must never consult a cap"
  done
  pass "a secondmate spawn is never capped, and refuses bypass flags it would never use"
}

test_invalid_caps_refuse_instead_of_defaulting() {
  local home out rc
  home=$(new_home invalid)
  printf 'validations=0\n' > "$home/config/wip-caps"
  out=$(spawn_ship "$home" t1); rc=$?
  expect_code 1 "$rc" "a zero cap"
  assert_contains "$out" "the validations cap must be a positive integer" "the refusal names the bad value"
  printf 'merge=3\n' > "$home/config/wip-caps"
  out=$(spawn_ship "$home" t1); rc=$?
  expect_code 1 "$rc" "an unknown lane"
  assert_contains "$out" "lane one of: validations merges reviews investigations" "the refusal names the lanes"
  assert_absent "$home/state/t1.meta" "an unreadable cap must create nothing"
  pass "an invalid config/wip-caps refuses the dispatch rather than silently using a default"
}

test_measured_defaults_apply_without_config() {
  local home out rc i
  home=$(new_home defaults)
  for i in 1 2 3; do occupy "$home" "ship-$i"; done
  out=$(spawn_ship "$home" ship-4); rc=$?
  expect_code 5 "$rc" "the fourth ship under the measured default"
  assert_contains "$out" "lane validations is at its cap of 3 with 3 in flight" \
    "an unconfigured home applies the measured validations cap"
  pass "with no config/wip-caps the measured default caps apply"
}

# A review lane needs the backlog item's kind, so this one case needs tasks-axi.
test_a_review_scout_enters_the_reviews_lane() {
  local home out rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    echo "skip: tasks-axi not found; review lane case not run"
    return 0
  fi
  home=$(new_home review)
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  tasks-axi add audit-a "audit a" --kind review --file "$home/data/backlog.md" >/dev/null
  tasks-axi add audit-b "audit b" --kind review --file "$home/data/backlog.md" >/dev/null
  tasks-axi add dig-c "dig c" --kind scout --file "$home/data/backlog.md" >/dev/null

  out=$(spawn_task "$home" audit-a --scout); rc=$?
  expect_code 0 "$rc" "the first review"$'\n'"$out"
  assert_grep "wip_lane=reviews" "$home/state/audit-a.meta" "a review scout must record its lane"
  out=$(spawn_task "$home" audit-b --scout); rc=$?
  expect_code 5 "$rc" "a second review under the measured cap of 1"
  assert_contains "$out" "lane reviews is at its cap of 1 with 1 in flight: audit-a" "the review lane names its occupant"
  tasks-axi show audit-b --file "$home/data/backlog.md" | grep -q '^  state: queued$' \
    || fail "a refused dispatch must leave its backlog item Queued"
  out=$(spawn_task "$home" dig-c --scout); rc=$?
  expect_code 0 "$rc" "an investigation while reviews is full"$'\n'"$out"
  pass "a scout from a review backlog item takes the reviews lane, and a refusal leaves it Queued"
}

test_at_cap_refusal_names_lane_cap_and_occupants_and_creates_nothing
test_a_finish_frees_exactly_one_slot
test_a_green_pr_moves_the_ship_from_validations_to_merges
test_lanes_are_independent
test_bypass_records_itself_and_still_holds_its_slot
test_bypass_needs_a_known_class_and_a_reason
test_secondmate_spawn_is_exempt_and_refuses_bypass_flags
test_invalid_caps_refuse_instead_of_defaulting
test_measured_defaults_apply_without_config
test_a_review_scout_enters_the_reviews_lane

echo "# all fm-wip-caps tests passed"
