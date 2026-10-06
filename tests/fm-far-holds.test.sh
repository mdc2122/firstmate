#!/usr/bin/env bash
# Tests for the far-date hold check: bin/fm-far-holds.sh (which backlog items
# are held more than FM_FAR_HOLDS_DAYS out without the captain's own deferral,
# and one wake per episode) and the captain-words record that
# bin/fm-captain-hold.sh hold --captain-words-file writes to exempt one.
#
# The incident: firstmate parked follow-up work behind a date about two weeks
# out although the captain had said never to defer work weeks into the future,
# and nothing surfaced the parked item until the captain asked. Each case
# drives a hold shape through the public commands and asserts whether the item
# is named.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FAR="$ROOT/bin/fm-far-holds.sh"
TMP_ROOT=$(fm_test_tmproot fm-far-holds)
NOW=2026-10-05T12:00:00Z

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

axi() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  tasks-axi "$@" --file "$home/data/backlog.md" >/dev/null || fail "tasks-axi $* failed"
}

far() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_FAR_HOLDS_NOW="$NOW" "$FAR" "$@"
}

captain_hold() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" hold "$@" >/dev/null
}

test_far_holds_without_captain_words_are_named() {
  local home out words
  home=$(make_home scan)
  # Firstmate's own deferral, about two weeks out: the incident shape.
  axi "$home" add ranking-followup "follow up the ranking work"
  axi "$home" hold ranking-followup --reason "first fair test when clips mature" --until 2026-10-16
  # A captain hold whose date carries no recorded captain words.
  captain_hold "$home" wordless-call --title "an undocumented captain date" \
    --reason "revisit later" --until 2026-11-01
  # The captain's own deferral, recorded with his words.
  words="$home/words.txt"
  printf 'Not now - bring it back on Nov 1.\n' > "$words"
  captain_hold "$home" captain-deferred --title "a captain deferral" \
    --reason "captain tabled until Nov 1" --until 2026-11-01 --captain-words-file "$words"
  # Inside the window: exactly two days out is not far.
  axi "$home" add near-hold "waits two days"
  axi "$home" hold near-hold --reason "upstream reply due" --until 2026-10-07
  # A lapsed date is queue inbox zero's concern, not this check's.
  axi "$home" add lapsed-hold "date already passed"
  axi "$home" hold lapsed-hold --reason "old" --until 2026-10-01
  # A finished item is never named.
  axi "$home" add finished "done work"
  axi "$home" hold finished --reason "old" --until 2026-12-01
  axi "$home" start finished
  axi "$home" "done" finished

  out=$(far "$home" scan) || fail "scan failed"
  assert_contains "$out" "ranking-followup until 2026-10-16" "firstmate's far deferral was not named"
  assert_contains "$out" "wordless-call until 2026-11-01" "a captain hold with no recorded words was exempted"
  assert_not_contains "$out" "captain-deferred" "the captain's recorded deferral was named"
  assert_not_contains "$out" "near-hold" "a hold inside the window was named"
  assert_not_contains "$out" "lapsed-hold" "a lapsed hold was named"
  assert_not_contains "$out" "finished" "a finished item was named"
  pass "far holds without the captain's words are named; recorded captain deferrals, near, lapsed, and finished holds are not"
}

test_redating_a_captain_deferral_needs_new_words() {
  local home out words
  home=$(make_home redate)
  words="$home/words.txt"
  printf 'Bring it back on Nov 1.\n' > "$words"
  captain_hold "$home" deferred --title "a captain deferral" \
    --reason "captain tabled it" --until 2026-11-01 --captain-words-file "$words"
  captain_hold "$home" deferred --reason "pushed again" --until 2026-12-01
  out=$(far "$home" scan) || fail "scan failed"
  assert_contains "$out" "deferred until 2026-12-01" \
    "a re-dated captain hold kept its exemption without the captain's words for the new date"
  printf 'Fine, December.\n' > "$words"
  captain_hold "$home" deferred --reason "captain moved it" --until 2026-12-01 --captain-words-file "$words"
  out=$(far "$home" scan) || fail "scan failed"
  [ -z "$out" ] || fail "the captain's words for the new date did not exempt it: $out"
  pass "the captain's words exempt only the date they were recorded for"
}

test_captain_words_need_until() {
  local home words
  home=$(make_home words-need-until)
  words="$home/words.txt"
  printf 'later\n' > "$words"
  if captain_hold "$home" no-date --title "x" --reason "r" --captain-words-file "$words" 2>/dev/null; then
    fail "captain words were accepted without a deferral date"
  fi
  pass "captain words record a deferral and require --until"
}

test_check_wakes_once_per_episode() {
  local home out
  home=$(make_home check)
  axi "$home" add far-a "far work"
  axi "$home" hold far-a --reason "parked" --until 2026-10-20

  out=$(far "$home" check) || fail "first check failed"
  assert_contains "$out" "check: far-holds:" "the first sighting did not wake"
  assert_contains "$out" "far-a until 2026-10-20" "the wake did not name its item"
  grep -F $'\tcheck\tfar-holds\t' "$home/state/.wake-queue" >/dev/null \
    || fail "the wake was printed but not durably queued"

  out=$(far "$home" check) || fail "repeat check failed"
  [ -z "$out" ] || fail "an unchanged far-hold set woke again: $out"

  axi "$home" hold far-a --reason "parked longer" --until 2026-10-25
  out=$(far "$home" check) || fail "re-dated check failed"
  assert_contains "$out" "far-a until 2026-10-25" "re-dating a far hold did not start a new episode"

  axi "$home" unhold far-a
  out=$(far "$home" check) || fail "cleared check failed"
  [ -z "$out" ] || fail "a cleared set woke: $out"
  axi "$home" hold far-a --reason "parked again" --until 2026-10-25
  out=$(far "$home" check) || fail "returning check failed"
  assert_contains "$out" "far-a until 2026-10-25" "an item that left and returned was suppressed"
  pass "check wakes once per episode, queues durably, and treats a re-dated or returning item as new"
}

test_failed_append_is_retried() {
  local home out
  home=$(make_home append-fail)
  axi "$home" add far-a "far work"
  axi "$home" hold far-a --reason "parked" --until 2026-10-20
  mkdir "$home/state/.wake-queue"
  if out=$(far "$home" check 2>&1); then fail "check succeeded although its wake could not be queued: $out"; fi
  assert_not_contains "$out" "check: far-holds:" "a wake that was never queued was still printed"
  rmdir "$home/state/.wake-queue"
  out=$(far "$home" check) || fail "retry check failed"
  assert_contains "$out" "far-a until 2026-10-20" "a failed append suppressed the episode instead of retrying it"
  pass "a wake that could not be queued is retried on the next check"
}

test_far_holds_without_captain_words_are_named
test_redating_a_captain_deferral_needs_new_words
test_captain_words_need_until
test_check_wakes_once_per_episode
test_failed_append_is_retried
