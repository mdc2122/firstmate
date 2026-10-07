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
  PATH="$home/fakebin:$PATH" HOME="$home" FM_HOME="$home" FM_ATTENTION_NOW="${AC_NOW:-$NOW}" "$AC" "$@"
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

test_lightweight_prod_tag_has_no_release_time() {
  local home repo out
  home=$(make_home s4-lightweight)
  prod_repo "$home" 241
  repo="$home/projects/app"
  git -C "$repo" tag prod-5
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S4 red "a lightweight tag on the unreleased commit counted as its release"
  assert_contains "$out" "1 lightweight prod tag(s) ignored" "the ignored lightweight tag was not named"

  home=$(make_home s4-only-lightweight)
  repo="$home/projects/app"
  fm_git_init_commit "$repo" >/dev/null
  commit_at "$repo" $((NOW_EPOCH - 600 * 60)) old
  git -C "$repo" tag prod-1
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S4 unknown "a project whose only prod tag is lightweight"
  assert_contains "$out" "app unknown (only lightweight prod tags" "the unknown release time was not named"
  pass "S4 never treats a lightweight prod tag as a release and says so on the line"
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

test_unreadable_backlog_rates_s8_and_s11_unknown() {
  local home out
  home=$(make_home unreadable)
  inflight_row "$home" lost
  gone_task "$home" lost 2000
  steer "$home" other 2026-10-03T09:00:00Z
  steer "$home" other 2026-10-02T09:00:00Z
  printf 'https://github.com/o/r/pull/7 abc %s 0\n' $((NOW_EPOCH - 3600)) > "$home/state/t1.pr-green-blocked"
  printf '%s\n' '## In flight' '- [ ] broken (' > "$home/data/backlog.md"
  chmod 000 "$home/data/backlog.md"
  out=$(ac "$home" scan) || { chmod 644 "$home/data/backlog.md"; fail "scan failed: $out"; }
  chmod 644 "$home/data/backlog.md"
  assert_rating "$out" S8 unknown "an unreadable backlog"
  assert_rating "$out" S11 unknown "an unreadable backlog"
  assert_contains "$out" "backlog unreadable" "the unreadable backlog was not named"
  assert_contains "$out" "AMBER (S3):" "an unreadable backlog moved the verdict"
  pass "an unreadable backlog rates S8 and S11 unknown and keeps them out of the verdict"
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
  fm_write_meta "$home/state/a.meta" kind=ship
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
  assert_contains "$out" "; attention 10-03 13:05Z RED (S1,S3):" "the first check after 13:00Z did not wake on RED"
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

# A forced-red day: the binding wake fires once per window, carries the owed
# action, and the handling turn's act records it against that same line; act
# refuses a non-binding or unrecorded day. S11 red alone (two windows under
# 40%) also binds even though the verdict is only AMBER.
test_binding_line_wakes_once_and_records_the_action() {
  local home out
  home=$(make_home bind-red)
  open_decision "$home" t1 k1 0
  printf 'https://github.com/o/r/pull/7 abc %s 0\n' $((NOW_EPOCH - 3 * 3600)) > "$home/state/t1.pr-green-blocked"
  AC_NOW=2026-10-03T11:00:00Z ac "$home" check >/dev/null || fail "morning sample failed"
  out=$(AC_NOW=2026-10-03T13:05:00Z ac "$home" act drain "early" 2>&1) && fail "act before any line was recorded succeeded: $out"
  out=$(AC_NOW=2026-10-03T13:05:00Z ac "$home" check) || fail "binding check failed"
  assert_contains "$out" "check: attention: BINDING (RED verdict) - act on it this turn" "a RED day did not queue a binding wake"
  assert_contains "$out" "fm-attention-check.sh act reallocate|drain" "the binding wake did not name the action it owes"
  out=$(AC_NOW=2026-10-03T16:00:00Z ac "$home" check) || fail "repeat check failed"
  [ -z "$out" ] || fail "a binding window woke twice: $out"
  [ "$(grep -c $'\tcheck\tattention\t' "$home/state/.wake-queue")" = 1 ] || fail "the binding wake was not queued exactly once"
  out=$(AC_NOW=2026-10-03T16:05:00Z ac "$home" act drain "answered k1 and two other decisions") || fail "act failed: $out"
  grep -F 'action=2026-10-03T16:05:00Z drain answered k1 and two other decisions' "$home/state/.attention-check" >/dev/null \
    || fail "the action was not recorded against the day's line"
  grep -F 'bound=RED verdict' "$home/state/.attention-check" >/dev/null || fail "the binding reason was lost by act"
  out=$(AC_NOW=2026-10-03T16:06:00Z ac "$home" act sleep "nothing" 2>&1) && fail "an unknown act kind was accepted: $out"
  out=$(AC_NOW=2026-10-04T09:00:00Z ac "$home" act drain "late" 2>&1) && fail "act against yesterday's line succeeded: $out"

  home=$(make_home bind-green)
  AC_NOW=2026-10-03T13:05:00Z ac "$home" check >/dev/null || fail "green check failed"
  out=$(AC_NOW=2026-10-03T13:10:00Z ac "$home" act reallocate "x" 2>&1) && fail "act against a non-binding line succeeded: $out"
  assert_contains "$out" "not binding" "a non-binding act refusal did not say why"

  home=$(make_home bind-s11)
  constraint_row "$home" finish
  inflight_row "$home" other
  fm_write_meta "$home/state/finish.meta" kind=ship
  fm_write_meta "$home/state/other.meta" kind=ship
  steer "$home" finish 2026-10-03T09:00:00Z
  steer "$home" other 2026-10-03T09:10:00Z
  steer "$home" other 2026-10-03T09:20:00Z
  steer "$home" other 2026-10-02T10:10:00Z
  out=$(AC_NOW=2026-10-03T13:05:00Z ac "$home" check) || fail "S11 check failed"
  assert_contains "$out" "BINDING (S11 red two windows running)" "S11 red on its own did not bind"
  assert_contains "$out" "AMBER (S11):" "S11 alone changed the verdict"
  pass "a binding line wakes once per window, names its owed action, and act records it against that line"
}

test_br_items_without_a_backlog_row_are_flagged() {
  local home mate out
  home=$(make_home beads)
  mkdir -p "$home/data/beads/.beads"
  : > "$home/data/beads/.beads/beads.db"
  inflight_row "$home" mapped-row
  cat > "$home/fakebin/br" <<'SH'
#!/usr/bin/env bash
case " $* " in *" list "*) ;; *) exit 9 ;; esac
case " $* " in *" create "*|*" update "*|*" close "*) exit 9 ;; esac
filter='map(select(.status == "open" or .status == "in_progress"))'
case " $* " in *" -s all "*) filter='.' ;; esac
jq -c "{issues: (.issues | $filter)}" <<'JSON'
{"issues":[
 {"id":"b-1","status":"open","labels":["mirror:mapped-row"]},
 {"id":"b-2","status":"in_progress","labels":["mirror:gone-row"]},
 {"id":"b-3","status":"open","labels":["row:mapped-row"],"external_ref":"mapped-row"},
 {"id":"b-4","status":"open","labels":[]},
 {"id":"b-5","status":"deferred","labels":["ops"]},
 {"id":"b-6","status":"blocked","labels":["mirror:mapped-row"]},
 {"id":"b-7","status":"closed","labels":[]}]}
JSON
SH
  chmod +x "$home/fakebin/br"
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_contains "$out" "br-xcheck home 4/6 br-only (b-2, b-3, b-4 +1) (info) [amber]" "br items with no mirror: label naming an open backlog row were not flagged"
  assert_contains "$out" "not seen: br crew queue 1 blocked, 1 deferred, 1 in_progress, 3 open units" "the br crew queue was not named as a blind spot with every non-closed status"
  assert_contains "$out" "GREEN:" "the informational cross-check moved the verdict"

  mate=$(make_home beads-mate)
  mkdir -p "$mate/data/beads/.beads"
  : > "$mate/data/beads/.beads/beads.db"
  inflight_row "$mate" gone-row
  printf -- '- mate1 - a mate (home: %s; scope: ops; projects: x; added 2026-10-01)\n' "$mate" > "$home/data/secondmates.md"
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_contains "$out" "mate1 3/6 br-only (b-3, b-4, b-5)" "a secondmate's br queue was not matched against its own and the parent home's backlog"

  mkdir -p "$mate/fakebin"
  cp "$home/fakebin/br" "$mate/fakebin/br"
  printf 'mate1\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home" > "$mate/.fm-secondmate-parent"
  out=$(ac "$mate" scan) || fail "scan failed: $out"
  assert_contains "$out" "br-xcheck home 3/6 br-only (b-3, b-4, b-5)" "a secondmate's own check did not match its br queue against its parent home's backlog"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$mate/.fm-secondmate-parent"
  out=$(ac "$mate" scan) || fail "scan failed: $out"
  assert_contains "$out" "br-xcheck home 5/6 br-only (b-1, b-3, b-4 +2), parent not checked (info) [amber]" "a secondmate with a remote parent did not match its br queue against its own backlog and say the parent was not checked"

  cat > "$home/fakebin/br" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  out=$(FM_ATTENTION_BR_TIMEOUT=1 ac "$home" scan) || fail "scan failed: $out"
  assert_contains "$out" "not seen: br crew queue unreadable units" "a hung br call was not bounded"
  assert_contains "$out" "home br unreadable" "an unreadable br queue was not named in the cross-check"
  home=$(make_home no-beads)
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_not_contains "$out" "not seen" "a home without a br queue named a blind spot"
  assert_not_contains "$out" "br-xcheck" "a home without a br queue ran the cross-check"
  pass "non-closed br items with no mirror: row in their own or the parent home are flagged on the line, read-only and bounded"
}

# --- S12 supervisor load and Class E -------------------------------------------

queued_row() {  # <home> <id> <since> [extra-row-suffix]
  local home=$1 tmp
  tmp=$(mktemp)
  awk -v row="- [ ] $2 - work $2 (repo: x) (kind: ship) (since $3)${4:-}" '
    { print }
    /^## Queued/ { print row }' "$home/data/backlog.md" > "$tmp"
  mv "$tmp" "$home/data/backlog.md"
}

test_load_numbers_per_home_and_red_after_a_day() {
  local home mate out
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found; S12 cases not run"; return 0; }
  home=$(make_home s12)
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  queued_row "$home" fresh 2026-10-03 " (hold: later) (hold-until: 2026-10-04)"
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S12 amber "a row unowned under a day"
  assert_contains "$out" "S12 load home unowned 1 (0 >24h: fresh), median age 0d, re-dates without progress 0" \
    "the three numbers were not on the line"

  queued_row "$home" stale 2026-09-25
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S12 red "a row unowned over a day"
  assert_contains "$out" "unowned 2 (1 >24h: " "the over-a-day count was not on the line"
  assert_contains "$out" "AMBER (S12):" "a red S12 did not count toward the verdict"

  mate=$(make_home s12-mate)
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  queued_row "$mate" mate-row 2026-09-20
  printf -- '- mate1 - a mate (home: %s; scope: ops; projects: x; added 2026-10-01)\n' "$mate" > "$home/data/secondmates.md"
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_contains "$out" "; mate1 unowned 1 (1 >24h: mate-row), median age 13d" "a secondmate home's load was not on the line"

  fm_write_meta "$home/state/stale.meta" kind=ship
  fm_write_meta "$home/state/fresh.meta" kind=ship
  rm "$home/data/secondmates.md"
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_rating "$out" S12 green "every row has a running owner"
  pass "S12 shows unowned rows, median open age, and re-dates without progress per home, red after a day"
}

test_class_e_applications_are_counted_from_the_fleet_pins_log() {
  local home out log
  home=$(make_home class-e)
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_not_contains "$out" "class-e" "a host without the Class E log showed a Class E segment"
  log="$home/.fleet-backup/pins/class-e.log"
  mkdir -p "${log%/*}"
  {
    printf '2026-10-03T09:00:00Z\tclass-e\tpackage=omp\tversion=1->2\ttarget=omp:studio2\twindow=open(x)\thealth=pass\treceipt=r1\n'
    printf '2026-10-03T10:00:00Z\tclass-e\tpackage=omp\tversion=2->3\ttarget=omp:studio1\twindow=open(x)\thealth=pass\treceipt=r2\n'
    printf '2026-10-02T13:00:00Z\tclass-e\tpackage=omp\tversion=0->1\ttarget=omp:studio2\twindow=open(x)\thealth=pass\treceipt=r0\n'
    printf '2026-10-03T11:00:00Z\tclass-x\tpackage=omp\thealth=pass\n'
    printf 'garbage line\n'
  } > "$log"
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_contains "$out" "class-e applied 2 (pass=2) (info) [green]" "Class E applications in the window were not counted"
  printf '2026-10-03T12:00:00Z\tclass-e\tpackage=herdr\tversion=1->2\ttarget=herdr:tmuxbot\twindow=open(x)\thealth=fail-rolled-back\treceipt=r3\n' >> "$log"
  out=$(ac "$home" scan) || fail "scan failed: $out"
  assert_contains "$out" "class-e applied 3 (fail-rolled-back=1 pass=2) (info) [amber]" "a failed Class E application was not flagged"
  assert_contains "$out" "GREEN:" "the informational Class E count moved the verdict"
  pass "Class E applications in the window are counted from the fleet-pins log, split by health, and never move the verdict"
}
test_decision_count_and_longest_wait_thresholds
test_three_open_at_once_threshold
test_sampled_decision_keeps_its_wait_after_it_closes
test_green_blocked_pr_age_threshold
test_merged_not_live_oldest_unreleased_threshold
test_merged_not_live_slow_share_threshold
test_lightweight_prod_tag_has_no_release_time
test_ownerless_inflight_threshold_and_dated_waits
test_unreadable_backlog_rates_s8_and_s11_unknown
test_constraint_share_threshold_and_two_day_rule
test_release_sequencing_steers_are_informational
test_verdict_counts_red_signals
test_scan_writes_nothing
test_daily_check_runs_once_after_1300_and_wakes_only_on_red
test_binding_line_wakes_once_and_records_the_action
test_br_items_without_a_backlog_row_are_flagged
test_load_numbers_per_home_and_red_after_a_day
test_class_e_applications_are_counted_from_the_fleet_pins_log
