#!/usr/bin/env bash
# Tests for the release-stopped alarm: bin/fm-release-stopped.sh (which
# release queue ledger outcomes form a failure episode, and one wake per
# episode) and its every-cycle tick in bin/fm-watch.sh.
#
# The incident: a project's release chain refused three times in a row with
# "cannot move canary worktree" (a stale index.lock), and merged fixes sat
# 6-12 hours not live with no alarm. Each case replays ledger lines through the
# public commands and asserts which checks wake.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RS="$ROOT/bin/fm-release-stopped.sh"
TMP_ROOT=$(fm_test_tmproot fm-release-stopped)
REPO=https://github.com/owner/app

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/ledger"
  : > "$home/ledger/queue.jsonl"
  printf '# repository ledger\n%s %s\n' "$REPO" "$home/ledger/queue.jsonl" > "$home/config/release-ledgers"
  printf '%s\n' "$home"
}

rs() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" "$RS" "$@"
}

ledger() {  # <home> <json-line>
  printf '%s\n' "$2" >> "$1/ledger/queue.jsonl"
}

refuse() {  # <home> <epoch> <ticket>
  ledger "$1" "{\"epoch\":$2,\"ticket\":\"$3\",\"event\":\"join\",\"owner\":\"release-advance\"}"
  ledger "$1" "{\"epoch\":$2,\"ticket\":\"$3\",\"event\":\"release\",\"result\":\"refused\",\"step\":\"canary\",\"error\":\"cannot move canary worktree: '.git/worktrees/canary/index.lock' exists\"}"
}

release_done() {  # <home> <epoch> <ticket>
  ledger "$1" "{\"epoch\":$2,\"ticket\":\"$3\",\"event\":\"step\",\"step\":\"canary\"}"
  ledger "$1" "{\"epoch\":$2,\"ticket\":\"$3\",\"event\":\"release\",\"result\":\"done\",\"proof\":\"live (abcdef12)\"}"
}

queued_rows() {  # <home>
  grep -c 'release-stopped' "$1/state/.wake-queue" 2>/dev/null || true
}

test_three_refusals_wake_once_after_the_second_and_none_after_recovery() {
  local home out
  home=$(make_home replay)
  release_done "$home" 100 t0

  refuse "$home" 200 t1
  out=$(rs "$home" check) || fail "check after the first refusal failed"
  [ -z "$out" ] || fail "a single refusal woke: $out"

  refuse "$home" 300 t2
  out=$(rs "$home" check) || fail "check after the second refusal failed"
  assert_contains "$out" "check: release-stopped $REPO: release stopped after 2 consecutive failed or refused release attempts" \
    "the second consecutive refusal did not wake"
  assert_contains "$out" "step canary: cannot move canary worktree: '.git/worktrees/canary/index.lock' exists" \
    "the wake did not name the failing step and error text"
  [ "$(queued_rows "$home")" -eq 1 ] || fail "the second refusal did not queue exactly one durable wake"

  refuse "$home" 400 t3
  out=$(rs "$home" check) || fail "check after the third refusal failed"
  [ -z "$out" ] || fail "the third refusal in the same episode woke again: $out"
  out=$(rs "$home" check) || fail "repeat check failed"
  [ -z "$out" ] || fail "an unchanged episode woke again: $out"
  [ "$(queued_rows "$home")" -eq 1 ] || fail "one episode queued more than one wake"

  release_done "$home" 500 t4
  out=$(rs "$home" check) || fail "check after recovery failed"
  [ -z "$out" ] || fail "a recovered release woke: $out"
  out=$(rs "$home" scan) || fail "scan after recovery failed"
  assert_equals "$out" "$REPO ok" "scan did not report the recovered release"
  [ "$(queued_rows "$home")" -eq 1 ] || fail "recovery queued a wake"

  refuse "$home" 600 t5
  refuse "$home" 700 t6
  out=$(rs "$home" check) || fail "check for a new episode failed"
  assert_contains "$out" "release-stopped $REPO" "a new failure run after recovery did not wake"
  pass "three consecutive refusals wake once after the second, none after recovery, and a later run is a new episode"
}

test_step_and_error_fall_back_to_ticket_context() {
  local home out
  home=$(make_home fallback)
  ledger "$home" '{"epoch":1,"ticket":"a","event":"step","step":"promote"}'
  ledger "$home" 'not json at all'
  ledger "$home" '{"epoch":2,"ticket":"a","event":"release","result":"failed","detail":"promote   timed out\nafter 600s"}'
  ledger "$home" '{"epoch":3,"ticket":"b","event":"step","step":"deploy"}'
  ledger "$home" '{"epoch":4,"ticket":"b","event":"release","result":"failed"}'
  out=$(rs "$home" check) || fail "check failed"
  assert_contains "$out" "step deploy: (no error text)" "the latest failure's step was not read from its ticket's step event"
  out=$(rs "$home" scan) || fail "scan failed"
  assert_equals "$out" "$REPO failing 2 step deploy: (no error text)" "scan did not report the failing run"
  pass "the failing step falls back to the ticket's latest step and a missing error is named"
}

test_unreadable_ledger_wakes_once_and_clears() {
  local home out
  home=$(make_home unreadable)
  rm -f "$home/ledger/queue.jsonl"
  out=$(rs "$home" check) || fail "check of a missing ledger failed"
  assert_contains "$out" "release ledger $home/ledger/queue.jsonl cannot be read" "a missing ledger was silent"
  out=$(rs "$home" check) || fail "repeat check of a missing ledger failed"
  [ -z "$out" ] || fail "a missing ledger woke twice: $out"
  : > "$home/ledger/queue.jsonl"
  out=$(rs "$home" check) || fail "check of a restored ledger failed"
  [ -z "$out" ] || fail "a restored empty ledger woke: $out"
  [ ! -e "$home/state/release-stopped/$(printf '%s' "$REPO" | tr -c 'A-Za-z0-9._-' '_')" ] \
    || fail "a restored ledger kept its unreadable episode"
  pass "an unreadable ledger wakes once and its episode clears when it reads again"
}

test_failed_append_is_retried() {
  local home out
  home=$(make_home append-fail)
  refuse "$home" 1 t1
  refuse "$home" 2 t2
  mkdir "$home/state/.wake-queue"
  if out=$(rs "$home" check 2>&1); then fail "check succeeded although its wake could not be queued: $out"; fi
  assert_not_contains "$out" "check: release-stopped" "a wake that was never queued was still printed"
  rmdir "$home/state/.wake-queue"
  out=$(rs "$home" check) || fail "retry check failed"
  assert_contains "$out" "release-stopped $REPO" "a failed append suppressed the episode instead of retrying it"
  pass "a wake that could not be queued is retried on the next check"
}

test_watcher_wakes_within_one_cycle() {
  local home first second
  home=$(make_home watcher)
  refuse "$home" 1 t1
  refuse "$home" 2 t2
  run_watch() {  # <out>
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 4 > "$1" 2> "$1.err" || true
  }
  first="$home/first.out"
  second="$home/second.out"
  run_watch "$first"
  grep -F "check: release-stopped $REPO: release stopped after 2 consecutive" "$first" >/dev/null \
    || fail "the watcher did not wake on a stopped release within one cycle: $(cat "$first" "$first.err")"
  run_watch "$second"
  ! grep -F 'release-stopped' "$second" >/dev/null || fail "the watcher woke twice for one episode: $(cat "$second")"
  [ "$(queued_rows "$home")" -eq 1 ] || fail "the watcher queued more than one wake for one episode"
  pass "the watcher wakes once within one cycle of a stopped release"
}

test_three_refusals_wake_once_after_the_second_and_none_after_recovery
test_step_and_error_fall_back_to_ticket_context
test_unreadable_ledger_wakes_once_and_clears
test_failed_append_is_retried
test_watcher_wakes_within_one_cycle
