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
# shellcheck source=bin/fm-wip-caps-lib.sh
. "$ROOT/bin/fm-wip-caps-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

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

# ship_brief <home> <id>: a spawn brief with the completion observation a
# fresh ship needs.
ship_brief() {
  fm_test_spawn_brief "$1" "$2"
  printf '\n# Completion observation\nverify: the fixture worker is running in its own endpoint\n' >> "$1/data/$2/brief.md"
}

# spawn_task <home> <id> [fm-spawn args...]: brief, isolated worktree, and one
# real fm-spawn of <id>. Prints combined output; returns fm-spawn's status.
spawn_task() {
  local home=$1 id=$2 proj wt
  shift 2
  proj="$home/proj-$id"
  wt="$home/wt-$id"
  ship_brief "$home" "$id"
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
  fm_pr_poll_merge_mark_notified "$home/state" ship-a github github.com example/repo 1 \
    || fail "could not record the delivered merge identity"
  out=$(spawn_ship "$home" ship-b); rc=$?
  expect_code 0 "$rc" "a delivered merge frees the merges slot"$'\n'"$out"
  pass "a ship moves validations -> merges at its PR and frees its slot at its merge outcome"
}

test_merge_notification_is_scoped_to_the_current_pr() {
  local home out rc provider host path url
  for provider in github gitlab; do
    home=$(new_home "replacement-$provider")
    printf 'validations=1\nmerges=1\n' > "$home/config/wip-caps"
    if [ "$provider" = github ]; then
      host=github.com
      path=example/repo
      url="https://$host/$path/pull"
    else
      host=gitlab.example.com
      path=group/subgroup/repo
      url="https://$host/$path/-/merge_requests"
    fi
    occupy "$home" ship-a "pr=$url/1"
    : > "$home/state/ship-a.pr-poll-merge-notified"
    out=$(spawn_ship "$home" ship-b); rc=$?
    expect_code 5 "$rc" "an empty marker must not free a merge slot"

    fm_pr_poll_merge_mark_notified "$home/state" ship-a "$provider" "$host" "$path" 1 \
      || fail "could not record the first merge"
    out=$(fm_wip_free_json "$home/config" "$home/state")
    [ "$(printf '%s' "$out" | jq -r '.merges')" = 1 ] || fail "matching marker must free the merge slot"

    printf 'pr=%s/2\n' "$url" >> "$home/state/ship-a.meta"
    out=$(fm_wip_free_json "$home/config" "$home/state")
    [ "$(printf '%s' "$out" | jq -r '.merges')" = 0 ] || fail "replacement PR must occupy the merge slot"
    out=$(spawn_ship "$home" ship-b); rc=$?
    expect_code 5 "$rc" "a stale notification must not release the replacement PR's slot"
    assert_contains "$out" "lane merges is at its cap of 1 with 1 in flight: ship-a" "replacement PR must block admission"

    fm_pr_poll_merge_mark_notified "$home/state" ship-a "$provider" "$host" "$path" 2 \
      || fail "could not record the replacement merge"
    out=$(spawn_ship "$home" ship-b); rc=$?
    expect_code 0 "$rc" "the replacement's delivered merge frees its slot"$'\n'"$out"
  done
  pass "merge slots release only for a matching current GitHub or GitLab PR identity"
}

run_transition() {
  local home=$1 command=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" HOME="$home/user-home" \
    PATH="$home/fake/fakebin:$PATH" "$ROOT/bin/$command" "$@" 2>&1
}

test_promotion_requires_capacity() {
  local home out rc lock
  home=$(new_home transitions)
  printf 'validations=1\nmerges=1\n' > "$home/config/wip-caps"
  occupy "$home" merging "pr=https://github.com/example/repo/pull/1"
  occupy "$home" validating
  occupy "$home" scouting kind=scout
  fm_test_spawn_brief "$home" scouting

  out=$(run_transition "$home" fm-promote.sh scouting --mode local-only --yolo off --verify "the promoted worker is running"); rc=$?
  expect_code 5 "$rc" "promotion into a full validations lane"$'\n'"$out"
  assert_grep 'kind=scout' "$home/state/scouting.meta" "refused promotion must retain scout kind"

  lock=$(fm_task_set_lock_path "$home/state")
  fm_lock_try_acquire "$lock" || fail "could not stage task-set lock"
  out=$(run_transition "$home" fm-promote.sh scouting --mode local-only --yolo off --verify "the promoted worker is running"); rc=$?
  expect_code 1 "$rc" "promotion must serialize with spawn's task-set lock"
  fm_lock_release "$lock"
  rm "$home/state/validating.meta"
  out=$(run_transition "$home" fm-promote.sh scouting --mode local-only --yolo off --verify "the promoted worker is running"); rc=$?
  expect_code 5 "$rc" "promotion must also respect a full downstream merge lane"$'\n'"$out"
  rm "$home/state/merging.meta"
  out=$(run_transition "$home" fm-promote.sh scouting --mode local-only --yolo off --verify "the promoted worker is running"); rc=$?
  expect_code 0 "$rc" "promotion after destination capacity frees"$'\n'"$out"
  assert_grep 'kind=ship' "$home/state/scouting.meta" "successful promotion must publish ship kind"
  pass "scout promotion requires a free validations slot and a merges lane below its cap"
}

# The review finding's sequence at the measured defaults: four merges and
# three admitted validations go green. The first registration takes the one
# free merges slot (the 5th); the other two queue durably without arming, so
# the lane never holds a 6th PR. Each finish arms exactly one queued
# registration, in order, through the retry the watcher, teardown, and sweep
# all run.
test_registrations_never_exceed_the_merges_cap_at_defaults() {
  local home out rc i merges queue occupants=FM_WIP_OCCUPANTS_validations
  home=$(new_home finding-sequence)
  for i in 1 2 3 4; do occupy "$home" "merging-$i" "pr=https://github.com/example/repo/pull/$i"; done
  for i in 1 2 3; do occupy "$home" "validating-$i"; done
  queue="$home/state/.wip-pr-queue"
  merges=FM_WIP_COUNT_merges

  out=$(run_transition "$home" fm-pr-check.sh validating-1 https://github.com/example/repo/pull/11); rc=$?
  expect_code 0 "$rc" "the 5th registration takes the last merges slot"$'\n'"$out"
  assert_present "$home/state/validating-1.check.sh" "an admitted registration arms its merge poll"
  for i in 2 3; do
    out=$(run_transition "$home" fm-pr-check.sh "validating-$i" "https://github.com/example/repo/pull/1$i"); rc=$?
    expect_code 5 "$rc" "registration of validating-$i into a full merges lane"$'\n'"$out"
    assert_contains "$out" "lane merges is at its cap of 5 with 5 in flight" "the queued registration must name lane, cap, and occupancy"
    assert_absent "$home/state/validating-$i.check.sh" "a queued registration must not arm a merge poll"
    assert_no_grep "pr=" "$home/state/validating-$i.meta" "a queued registration must not record its PR in the task"
  done
  [ "$(cut -f2 "$queue" | tr '\n' ' ')" = "validating-2 validating-3 " ] || fail "both refusals must be queued in order; got: $(cat "$queue")"
  fm_wip_caps_load "$home/config"
  fm_wip_scan "$home/state"
  [ "${!merges}" = 5 ] || fail "the merges lane must hold exactly its cap of 5, got ${!merges}"
  assert_contains "${!occupants}" "validating-2 [PR registration queued]" "a queued task must report the queued state"

  # A queued task cannot jump the line by retrying out of order.
  out=$(run_transition "$home" fm-pr-check.sh validating-3 https://github.com/example/repo/pull/13); rc=$?
  expect_code 5 "$rc" "a later queued registration while the head still waits"

  # One merge finishes: the retry arms exactly the queue head.
  rm -f "$home/state/merging-1.meta"
  out=$(run_transition "$home" fm-pr-check.sh --retry-queued); rc=$?
  expect_code 0 "$rc" "the retry after one finish"$'\n'"$out"
  assert_contains "$out" "check: wip-queue: validating-2's queued PR registration" "the armed registration must be reported"
  assert_present "$home/state/validating-2.check.sh" "the queue head arms once a merges slot frees"
  assert_absent "$home/state/validating-3.check.sh" "exactly one queued registration may arm per finish"
  [ "$(cut -f2 "$queue")" = validating-3 ] || fail "only the armed head leaves the queue; got: $(cat "$queue")"
  assert_grep "wip-queue-validating-2" "$home/state/.wake-queue" "the armed registration must queue a durable wake"
  fm_wip_scan "$home/state"
  [ "${!merges}" = 5 ] || fail "the merges lane must never exceed its cap, got ${!merges}"

  # The next finish arms the last one and empties the queue.
  rm -f "$home/state/merging-2.meta"
  out=$(run_transition "$home" fm-pr-check.sh --retry-queued); rc=$?
  expect_code 0 "$rc" "the retry after the second finish"
  assert_present "$home/state/validating-3.check.sh" "the next finish arms the next queued registration"
  assert_absent "$queue" "the queue is removed once empty"
  pass "at the defaults, 4 merges + 3 validations: the 5th registers, the 6th and 7th queue, and each finish arms exactly one in order"
}

# Registration admission must not stall a merge behind an unrelated spawn: a
# task already in merges re-records its PR (as bin/fm-pr-merge.sh does before
# every merge) without the task-set lock, while a task entering merges under a
# lock that stays busy is queued rather than refused silently.
test_registration_and_the_task_set_lock() {
  local home out rc lock
  home=$(new_home registration-lock)
  occupy "$home" merging-a "pr=https://github.com/example/repo/pull/21"
  occupy "$home" validating-b
  lock=$(fm_task_set_lock_path "$home/state")
  fm_lock_try_acquire "$lock" || fail "could not stage task-set lock"
  out=$(run_transition "$home" fm-pr-check.sh merging-a https://github.com/example/repo/pull/21); rc=$?
  expect_code 0 "$rc" "a same-lane re-registration while a spawn holds the task-set lock"$'\n'"$out"
  out=$(FM_WIP_LOCK_WAIT=1 run_transition "$home" fm-pr-check.sh validating-b https://github.com/example/repo/pull/22); rc=$?
  expect_code 5 "$rc" "an entering registration whose lock stays busy"$'\n'"$out"
  assert_contains "$out" "task-set lock stayed busy" "the queued registration must say why"
  assert_grep "validating-b" "$home/state/.wip-pr-queue" "a lock-busy registration is queued, not dropped"
  fm_lock_release "$lock"
  out=$(run_transition "$home" fm-pr-check.sh --retry-queued); rc=$?
  expect_code 0 "$rc" "the retry once the lock is free"
  assert_present "$home/state/validating-b.check.sh" "the queued registration arms once the lock frees and a slot is free"
  pass "a same-lane re-registration never waits on the task-set lock; a busy lock queues an entering registration"
}

# A merge order (bin/fm-pr-merge.sh registers with --merge-order) completes
# work, so it is never queued behind a full merges lane: it arms, takes its
# merges slot, and leaves the queue it was waiting in.
test_a_merge_order_registers_past_a_full_merges_lane() {
  local home out rc
  home=$(new_home merge-order)
  printf 'merges=1\n' > "$home/config/wip-caps"
  occupy "$home" merging-a "pr=https://github.com/example/repo/pull/31"
  occupy "$home" validating-b
  out=$(run_transition "$home" fm-pr-check.sh validating-b https://github.com/example/repo/pull/32); rc=$?
  expect_code 5 "$rc" "an ordinary registration into a full merges lane"$'\n'"$out"
  assert_grep "validating-b" "$home/state/.wip-pr-queue" "the ordinary registration is queued"
  out=$(run_transition "$home" fm-pr-check.sh --merge-order validating-b https://github.com/example/repo/pull/32); rc=$?
  expect_code 0 "$rc" "a merge-order registration into a full merges lane"$'\n'"$out"
  assert_present "$home/state/validating-b.check.sh" "a merge order arms its poll"
  assert_grep "pr=https://github.com/example/repo/pull/32" "$home/state/validating-b.meta" "a merge order records its PR"
  assert_absent "$home/state/.wip-pr-queue" "a merge order leaves the registration queue"
  pass "a merge order registers past a full merges lane and leaves the queue"
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

# The bypass log line is written only once the spawn succeeds: a spawn that
# passes admission under a bypass and then fails leaves no line, and its
# successful retry leaves exactly one.
test_bypass_log_is_written_only_after_spawn_success() {
  local home out rc proj wt log
  home=$(new_home bypass-fail)
  printf 'validations=1\n' > "$home/config/wip-caps"
  occupy "$home" ship-a
  log="$home/data/wip-cap-bypasses.log"
  proj="$home/proj-urgent-f"
  wt="$home/wt-urgent-f"
  ship_brief "$home" urgent-f
  fm_git_worktree "$proj" "$wt" wt-urgent-f >/dev/null 2>&1

  # The pane reports the spawning project itself, never an isolated worktree,
  # so the spawn fails after the cap check has admitted it under the bypass.
  # A no-op sleep keeps the 60-poll worktree wait instant.
  mkdir -p "$home/fail-fake"
  cp "$home/fake/fakebin/"* "$home/fail-fake/"
  fm_test_fake_sleep_noop "$home/fail-fake"
  out=$(FM_FAKE_LAUNCH_LOG="$home/launch-urgent-f.log" \
    fm_test_run_spawn "$home" "$proj" "$home/fail-fake" urgent-f "$proj" --harness codex \
      --mode no-mistakes --yolo on --cap-bypass outage --cap-bypass-reason "prod renderer down"); rc=$?
  [ "$rc" -ne 0 ] || fail "the spawn should fail when the pane never reaches an isolated worktree"$'\n'"$out"
  assert_contains "$out" "bypasses the work-in-progress cap" "the failing spawn must have passed admission under its bypass"
  assert_absent "$log" "a spawn that fails after admission must leave no bypass log line"

  out=$(FM_FAKE_LAUNCH_LOG="$home/launch-urgent-f.log" \
    fm_test_run_spawn "$home" "$wt" "$home/fake/fakebin" urgent-f "$proj" --harness codex \
      --mode no-mistakes --yolo on --cap-bypass outage --cap-bypass-reason "prod renderer down"); rc=$?
  expect_code 0 "$rc" "the retried bypassed spawn"$'\n'"$out"
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ] || fail "a failed spawn and its successful retry must leave exactly one line; got: $(cat "$log")"
  assert_grep "urgent-f	validations	outage	1/1	prod renderer down" "$log" "the one line must describe the successful spawn"
  pass "the bypass log line is written only after spawn success: none on failure, exactly one after a retry"
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
test_merge_notification_is_scoped_to_the_current_pr
test_promotion_requires_capacity
test_registrations_never_exceed_the_merges_cap_at_defaults
test_registration_and_the_task_set_lock
test_a_merge_order_registers_past_a_full_merges_lane
test_lanes_are_independent
test_bypass_records_itself_and_still_holds_its_slot
test_bypass_log_is_written_only_after_spawn_success
test_bypass_needs_a_known_class_and_a_reason
test_secondmate_spawn_is_exempt_and_refuses_bypass_flags
test_invalid_caps_refuse_instead_of_defaulting
test_measured_defaults_apply_without_config
test_a_review_scout_enters_the_reviews_lane

echo "# all fm-wip-caps tests passed"
