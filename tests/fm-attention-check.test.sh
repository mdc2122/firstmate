#!/usr/bin/env bash
# Tests for bin/fm-attention-check.sh: each signal is driven to just under and
# just past its threshold through the public command, and the verdict, the
# once-a-day check record, and the durable RED wake are observed from outside.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AC="$ROOT/bin/fm-attention-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-attention-check)
NOW=2026-10-03T14:00:00Z
NOW_EPOCH=$(jq -nr --arg t "$NOW" '$t | fromdateiso8601')

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/fakebin"
  printf '%s\n' '# Backlog' '' '## In flight' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

ac() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ATTENTION_NOW="${AC_NOW:-$NOW}" "$AC" "$@"
}

# The rating a signal segment carries, e.g. "red" for "S1 ... [red]".
rating() {  # <line> <signal>
  printf '%s\n' "${1#*: }" | tr '|' '\n' | sed -n "s/^ *$2 .*\[\([a-z]*\)\] *\$/\1/p" | head -n 1
}

assert_rating() {  # <line> <signal> <want> <message>
  local got
  got=$(rating "$1" "$2")
  [ "$got" = "$3" ] || fail "$4: $2 rated '${got:-missing}', want $3 in: $1"
}

open_decision() {  # <home> <task> <key> <minutes-ago>
  printf 'needs-decision [key=%s]: pick one\n' "$3" > "$1/state/$2.status"
  fm_touch_epoch $((NOW_EPOCH - $4 * 60)) "$1/state/$2.status"
}

inflight_row() {  # <home> <id> [extra-row-suffix]
  local home=$1 id=$2 tmp
  tmp=$(mktemp)
  awk -v row="- [ ] $id - work $id (repo: x) (kind: ship) (since 2026-10-01)${3:-}" -v id="$id" '
    { print }
    /^## In flight/ { print row; print "  verify: ship it" }' "$home/data/backlog.md" > "$tmp"
  mv "$tmp" "$home/data/backlog.md"
}

constraint_row() {  # <home> <id>
  local home=$1 tmp
  tmp=$(mktemp)
  awk -v id="$2" '
    { print }
    /^## In flight/ { print "- [ ] " id " - finishing work (repo: x) (kind: ship) (since 2026-10-01)"; print "  verify: every top card gets a product review verdict" }' \
    "$home/data/backlog.md" > "$tmp"
  mv "$tmp" "$home/data/backlog.md"
}

steer() {  # <home> <task> <iso-at> [body]
  local dir="$1/state/$2.inbox/handled" n
  mkdir -p "$dir"
  n=$(find "$dir" -name '*.msg' | wc -l | tr -d ' ')
  printf 'schema=fm-task-inbox.v1\nat=%s\n--\n%s\n' "$3" "${4:-carry on}" > "$dir/$(printf '%03d' $((n + 1))).msg"
}

# --- S1 / S2 ------------------------------------------------------------------

test_decision_count_and_longest_wait_thresholds() {
  local home out i
  home=$(make_home s1-count)
  for i in 1 2 3 4; do open_decision "$home" "t$i" "k$i" 40; done
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S1 amber "four decisions over 30 min"
  assert_contains "$out" "decisions>30m 4" "the count over 30 min was not reported"
  open_decision "$home" t5 k5 31
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S1 red "five decisions over 30 min"

  home=$(make_home s1-max)
  open_decision "$home" t1 k1 120
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S1 amber "one decision at exactly 2 h"
  open_decision "$home" t1 k1 121
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S1 red "one decision past 2 h"
  assert_contains "$out" "max 2h" "the longest wait was not reported"

  home=$(make_home s1-fresh)
  open_decision "$home" t1 k1 30
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S1 green "a decision at exactly 30 min"
  pass "S1 turns amber past 30 min and red at five such decisions or one past 2 h"
}

test_three_open_at_once_threshold() {
  local home out
  home=$(make_home s2)
  open_decision "$home" t1 k1 30
  open_decision "$home" t2 k2 30
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S2 green "two decisions open together"
  open_decision "$home" t3 k3 30
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S2 amber "three open for exactly 30 min"
  open_decision "$home" t3 k3 31
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S2 amber "the third decision is only 30 min old, so three were open 30 min"
  open_decision "$home" t1 k1 31
  open_decision "$home" t2 k2 31
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S2 red "three open for 31 min"
  pass "S2 turns red only once three decisions are open together for over 30 min"
}

test_sampled_decision_keeps_its_wait_after_it_closes() {
  local home out
  home=$(make_home s1-closed)
  open_decision "$home" t1 k1 0
  AC_NOW=2026-10-03T10:00:00Z ac "$home" check >/dev/null || fail "first sample failed"
  printf 'resolved [key=k1]: answered\n' >> "$home/state/t1.status"
  AC_NOW=2026-10-03T12:30:00Z ac "$home" check >/dev/null || fail "closing sample failed"
  printf 'working: next\n' >> "$home/state/t1.status"
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S1 red "a closed decision that waited from its first sample to its closing sample (2.5 h)"
  assert_contains "$out" "sampled since 10:00Z" "a record younger than the window did not say so"
  pass "a decision's wait is the span from first sample to first sample closed, even after it closes"
}

# --- S3 -----------------------------------------------------------------------

test_green_blocked_pr_age_threshold() {
  local home out
  home=$(make_home s3)
  printf 'https://github.com/o/r/pull/7 abc %s 0\n' $((NOW_EPOCH - 1800)) > "$home/state/t1.pr-green-blocked"
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S3 amber "a green-blocked PR at exactly 30 min"
  printf 'https://github.com/o/r/pull/7 abc %s 0\n' $((NOW_EPOCH - 1801)) > "$home/state/t1.pr-green-blocked"
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S3 red "a green-blocked PR past 30 min"
  assert_contains "$out" "o/r/pull/7" "the blocked PR was not named"
  pass "S3 turns red when a green PR has been unable to merge for over 30 min"
}

# --- S4 -----------------------------------------------------------------------

commit_at() {  # <repo> <epoch> <message>
  printf '%s\n' "$3" >> "$1/README.md"
  git -C "$1" add README.md
  GIT_COMMITTER_DATE="@$2 +0000" GIT_AUTHOR_DATE="@$2 +0000" \
    git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -qm "$3"
}

# One unreleased main commit <minutes> old behind four window merges that each
# went live in 10 min, so the slow share stays at or under a quarter and only
# the oldest-unreleased leg decides.
prod_repo() {  # <home> <unreleased-minutes-ago>
  local repo="$1/projects/app" i
  fm_git_init_commit "$repo" >/dev/null
  for i in 1 2 3 4; do
    commit_at "$repo" $((NOW_EPOCH - (12 - i) * 3600)) "released$i"
    GIT_COMMITTER_DATE="@$((NOW_EPOCH - (12 - i) * 3600 + 600)) +0000" \
      git -C "$repo" -c user.name=t -c user.email=t@example.invalid tag -a "prod-$i" -m "prod-$i"
  done
  commit_at "$repo" $((NOW_EPOCH - $2 * 60)) unreleased
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
}

test_merged_not_live_oldest_unreleased_threshold() {
  local home out
  home=$(make_home s4-under)
  prod_repo "$home" 240
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S4 amber "an unreleased commit at exactly 4 h"
  assert_contains "$out" "app oldest 4h" "the oldest unreleased age was not reported"

  home=$(make_home s4-over)
  prod_repo "$home" 241
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S4 red "an unreleased commit past 4 h"

  home=$(make_home s4-none)
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S4 green "a home with no prod-tagged project"
  pass "S4 turns red when main holds a commit the newest prod tag lacks for over 4 h"
}

test_merged_not_live_slow_share_threshold() {
  local home repo out i
  home=$(make_home s4-share)
  repo="$home/projects/app"
  fm_git_init_commit "$repo" >/dev/null
  for i in 1 2 3; do commit_at "$repo" $((NOW_EPOCH - (20 - i) * 3600)) "fast$i"; done
  commit_at "$repo" $((NOW_EPOCH - 20 * 3600 + 600)) slow1
  GIT_COMMITTER_DATE="@$((NOW_EPOCH - 10 * 3600)) +0000" \
    git -C "$repo" -c user.name=t -c user.email=t@example.invalid tag -a prod-1 -m prod-1
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  out=$(ac "$home" scan) || fail "scan failed: $out"
  # Every merge reached prod-1 more than 2 h later here, so 4/4 are slow.
  assert_rating "$out" S4 red "every one of the window's merges took over 2 h to go live"
  assert_contains "$out" "4/4 >2h" "the slow share was not reported"

  home=$(make_home s4-quarter)
  repo="$home/projects/app"
  fm_git_init_commit "$repo" >/dev/null
  commit_at "$repo" $((NOW_EPOCH - 10 * 3600)) slow
  GIT_COMMITTER_DATE="@$((NOW_EPOCH - 7 * 3600)) +0000" \
    git -C "$repo" -c user.name=t -c user.email=t@example.invalid tag -a prod-1 -m prod-1
  for i in 1 2 3; do
    commit_at "$repo" $((NOW_EPOCH - (6 - i) * 3600)) "fast$i"
    GIT_COMMITTER_DATE="@$((NOW_EPOCH - (6 - i) * 3600 + 600)) +0000" \
      git -C "$repo" -c user.name=t -c user.email=t@example.invalid tag -a "prod-$((i + 1))" -m x
  done
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S4 amber "exactly a quarter of the window's merges took over 2 h"
  assert_contains "$out" "1/4 >2h" "the slow share was not reported"
  pass "S4 turns red when over a quarter of the window's merges took over 2 h to go live"
}

# --- S8 -----------------------------------------------------------------------

gone_task() {  # <home> <id> <marker-minutes-ago>
  fm_write_meta "$1/state/$2.meta" "window=fm-$2" kind=ship
  printf 'notified\n' > "$1/state/.endpoint-gone-fm-$2"
  fm_touch_epoch $((NOW_EPOCH - $3 * 60)) "$1/state/.endpoint-gone-fm-$2"
}

test_ownerless_inflight_threshold_and_dated_waits() {
  local home out
  home=$(make_home s8)
  inflight_row "$home" lost
  gone_task "$home" lost 720
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S8 amber "an endpoint gone exactly 12 h"
  gone_task "$home" lost 721
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S8 red "an endpoint gone over 12 h"
  assert_contains "$out" "ownerless in-flight 1 (lost 12h)" "the ownerless row was not named"

  printf 'paused: waiting on upstream until 2026-10-04T09:00Z\n' > "$home/state/lost.status"
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S8 green "a task paused until a future time"
  printf 'paused: waiting on upstream until 2026-10-03T09:00Z\n' > "$home/state/lost.status"
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S8 red "a pause whose until time has passed"

  home=$(make_home s8-held)
  inflight_row "$home" held " (hold: restart after the load settles) (hold-kind: captain) (hold-until: 2026-10-06)"
  gone_task "$home" held 2000
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S8 green "a row held until a future date"

  home=$(make_home s8-notinflight)
  gone_task "$home" queuedonly 2000
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S8 green "a gone endpoint with no In-flight row"
  pass "S8 names In-flight rows gone over 12 h and skips dated waits"
}

# --- S11 and release sequencing ----------------------------------------------

test_constraint_share_threshold_and_two_day_rule() {
  local home out
  home=$(make_home s11)
  constraint_row "$home" finish
  inflight_row "$home" other
  steer "$home" finish 2026-10-03T09:00:00Z
  steer "$home" finish 2026-10-03T09:10:00Z
  steer "$home" other 2026-10-03T09:20:00Z
  steer "$home" other 2026-10-03T09:30:00Z
  steer "$home" other 2026-10-03T09:40:00Z
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S11 green "40% of steers on the constraint"
  assert_contains "$out" "constraint steers 40% (2/5)" "the share was not reported"

  steer "$home" other 2026-10-03T09:50:00Z
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S11 amber "33% today with no prior-day steers"

  steer "$home" finish 2026-10-02T10:00:00Z
  steer "$home" other 2026-10-02T10:10:00Z
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S11 amber "under 40% today but 50% the day before"

  steer "$home" other 2026-10-02T10:20:00Z
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S11 red "under 40% on both days"
  pass "S11 turns red only when the constraint share is under 40% for two days running"
}

test_release_sequencing_steers_are_informational() {
  local home out
  home=$(make_home release)
  inflight_row "$home" a
  steer "$home" a 2026-10-03T09:00:00Z "Merged. Release it after ballot-top-finishing deploys prod-6."
  steer "$home" a 2026-10-03T09:10:00Z "You are next in line for the release."
  steer "$home" a 2026-10-03T09:20:00Z "Thanks, good work."
  steer "$home" a 2026-10-01T09:20:00Z "Old: you are next in line."
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_contains "$out" "release-seq steers 2 (info) [amber]" "release-sequencing steers were not counted"
  assert_contains "$out" "GREEN" "informational release steers changed the verdict"
  pass "release-sequencing steers in the window are counted but never move the verdict"
}

# --- verdict, daily check, blind spots ---------------------------------------

test_verdict_counts_red_signals() {
  local home out
  home=$(make_home verdict)
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_contains "$out" "attention 10-03 14:00Z GREEN:" "an empty home was not GREEN"
  open_decision "$home" t1 k1 121
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_contains "$out" "AMBER (S1):" "one red signal did not make the verdict AMBER"
  printf 'https://github.com/o/r/pull/7 abc %s 0\n' $((NOW_EPOCH - 3600)) > "$home/state/t1.pr-green-blocked"
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_contains "$out" "RED (S1,S3):" "two red signals did not make the verdict RED"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "scan printed more than one line: $out"
  pass "the verdict is RED at two red signals, AMBER at one, GREEN otherwise, on one line"
}

test_scan_writes_nothing() {
  local home before after
  home=$(make_home readonly)
  open_decision "$home" t1 k1 10
  before=$(find "$home" -type f | sort)
  ac "$home" scan >/dev/null || fail "scan failed"
  after=$(find "$home" -type f | sort)
  [ "$before" = "$after" ] || fail "scan created files: $(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
  pass "an on-demand scan writes nothing"
}

test_daily_check_runs_once_after_1300_and_wakes_only_on_red() {
  local home out
  home=$(make_home daily-red)
  open_decision "$home" t1 k1 0
  printf 'https://github.com/o/r/pull/7 abc %s 0\n' $((NOW_EPOCH - 3 * 3600)) > "$home/state/t1.pr-green-blocked"
  out=$(AC_NOW=2026-10-03T11:00:00Z ac "$home" check) || fail "morning check failed"
  [ -z "$out" ] || fail "a check before 13:00Z reported: $out"
  [ ! -e "$home/state/.attention-check" ] || fail "a check before 13:00Z recorded a daily line"
  [ -e "$home/state/.attention-first-seen" ] || fail "a morning check did not sample decisions"

  out=$(AC_NOW=2026-10-03T13:05:00Z ac "$home" check) || fail "afternoon check failed"
  assert_contains "$out" "check: attention: attention 10-03 13:05Z RED (S1,S3):" "the first check after 13:00Z did not wake on RED"
  grep -F $'\tcheck\tattention\t' "$home/state/.wake-queue" >/dev/null \
    || fail "the RED wake was printed but not durably queued"
  out=$(AC_NOW=2026-10-03T15:00:00Z ac "$home" check) || fail "repeat check failed"
  [ -z "$out" ] || fail "a second check the same day woke again: $out"
  out=$(AC_NOW=2026-10-04T13:00:00Z ac "$home" check) || fail "next-day check failed"
  assert_contains "$out" "check: attention:" "the next day's first check after 13:00Z did not run"

  home=$(make_home daily-green)
  out=$(AC_NOW=2026-10-03T13:05:00Z ac "$home" check) || fail "green check failed"
  [ -z "$out" ] || fail "a GREEN daily line woke firstmate: $out"
  grep -F 'line=attention 10-03 13:05Z GREEN:' "$home/state/.attention-check" >/dev/null \
    || fail "the GREEN daily line was not recorded"
  [ ! -e "$home/state/.wake-queue" ] || ! grep -q attention "$home/state/.wake-queue" \
    || fail "a GREEN daily line was queued as a wake"
  pass "check samples every run, records the line once a day after 13:00Z, and wakes only on RED"
}

test_beads_crew_queue_is_named_as_not_seen() {
  local home out
  home=$(make_home beads)
  mkdir -p "$home/data/beads/.beads"
  : > "$home/data/beads/.beads/beads.db"
  cat > "$home/fakebin/br" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"total":9,"groups":[{"group":"open","count":7},{"group":"in_progress","count":2}]}'
SH
  chmod +x "$home/fakebin/br"
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_contains "$out" "not seen: br crew queue 7 open, 2 in_progress units" "the br crew queue was not named as a blind spot"
  home=$(make_home no-beads)
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_not_contains "$out" "not seen" "a home without a br queue named a blind spot"
  pass "a home with a br crew queue names its units as not seen instead of guessing"
}

test_decision_count_and_longest_wait_thresholds
test_three_open_at_once_threshold
test_sampled_decision_keeps_its_wait_after_it_closes
test_green_blocked_pr_age_threshold
test_merged_not_live_oldest_unreleased_threshold
test_merged_not_live_slow_share_threshold
test_ownerless_inflight_threshold_and_dated_waits
test_constraint_share_threshold_and_two_day_rule
test_release_sequencing_steers_are_informational
test_verdict_counts_red_signals
test_scan_writes_nothing
test_daily_check_runs_once_after_1300_and_wakes_only_on_red
test_beads_crew_queue_is_named_as_not_seen
