#!/usr/bin/env bash
# Behavior tests for the resume watch (bin/fm-resume-watch.sh, its condition
# bin/fm-resume-cond.sh, and its action bin/fm-resume-action.sh).
#
# Every case arms the watch through its public command, runs it under the real
# `when` adapter and process-event runner, and delivers through the real
# bin/fm-send.sh over a stub tmux, with the forge stubbed by a fake `gh` that
# reads the PR's state from a file. The suite pins the consumer-visible
# contract: a merged PR lands exactly one fixed-template resume record in the
# worker's inbox and wakes nobody; a PR closed unmerged, a worker that moved
# on, and a worker that already recorded its observation get nothing and wake
# firstmate; a live watch waits for the release pointer to contain the merge;
# re-arming the same PR never resumes twice; and retire removes the watch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-resume-watch-tests)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export FM_SEND_SETTLE=0
export FM_RESUME_WATCH_INTERVAL=0.1 FM_RESUME_WATCH_STABLE=2 FM_RESUME_WATCH_ERROR_BUDGET=3

URL=https://github.com/o/r/pull/7
MERGE_SHA=

# make_home <name> <status-line>... -> echoes the home, with task t1 recorded.
make_home() {
  local h="$TMP_ROOT/$1" fb
  shift
  fb="$h/fakebin"
  mkdir -p "$h/state" "$h/data/t1" "$h/config" "$fb"
  fm_test_track_procevent_home "$h" "$FM_PROCEVENT_CLAIM_ROOT"
  fm_write_meta "$h/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  printf '%s\n' "$@" > "$h/state/t1.status"
  printf 'open\n' > "$h/pr-state"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys)
    shift; l=0
    while [ $# -gt 0 ]; do case "$1" in -t) shift 2 ;; -l) l=1; shift ;; *) break ;; esac; done
    [ "$l" = 1 ] && printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
    exit 0 ;;
  display-message) for a in "$@"; do case "$a" in *cursor_y*) echo 1; exit 0 ;; esac; done; echo fakepane; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) echo fm-t1; exit 0 ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
dir=$(cd "$(dirname "$0")/.." && pwd)
for a in "$@"; do
  case "$a" in *mergeCommit*) cat "$dir/merge-sha"; exit 0 ;; esac
done
case "$(cat "$dir/pr-state")" in
  merged) printf 'state=MERGED\nmerged=true\n' ;;
  open) printf 'state=OPEN\nmerged=false\n' ;;
  closed) printf 'state=CLOSED\nmerged=false\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/tmux" "$fb/gh"
  printf '%s\n' "$h"
}

in_home() {  # <home> <command...>
  local h=$1
  shift
  PATH="$h/fakebin:$PATH" FM_HOME="$h" FM_SEND_LOG="$h/typed.log" "$@"
}

watch() { local h=$1; shift; in_home "$h" "$ROOT/bin/fm-resume-watch.sh" "$@"; }
sid_of() { printf 'when-%s\n' "$(sed -n 's/^name=//p' "$1/state/t1.resume-watch")"; }

start_runner() { in_home "$1" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1; }

# wait_result <home>: wait until the watch's outcome is captured AND its
# registration is retired, which the runner does only after publishing (or
# silently recording) that outcome, then print the captured result path.
wait_result() {
  local h=$1 sid g found=''
  sid=$(sid_of "$h")
  for _ in $(seq 1 200); do
    for g in "$h/state/procevent-inbox/$sid".*.result; do
      [ -e "$g" ] && found=$g
    done
    if [ -n "$found" ] && [ ! -e "$h/state/procevent/$sid.source" ]; then
      printf '%s\n' "$found"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

outcome() { in_home "$1" "$ROOT/bin/fm-procevent-when.sh" classify "$2"; }
inbox_count() { local n=0 f; for f in "$1/state/t1.inbox/"*.msg; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
wake_rows() {
  local n=0
  [ -f "$1/state/.wake-queue" ] && n=$(grep -c 'procevent when' "$1/state/.wake-queue")
  echo "$n"
}

# --- retiring without a record must not recreate a removed home or state ----
H="$TMP_ROOT/removed-home"
watch "$H" retire t1 >/dev/null || fail "retire failed for a removed home"
assert_absent "$H" "retire without a watch recreated the removed home"
mkdir -p "$H/state"
watch "$H" retire t1 >/dev/null || fail "retire failed without a watch record"
assert_equals 0 "$(find "$H/state" -mindepth 1 | wc -l | tr -d ' ')" \
  "retire without a record created state artifacts"
pass "retire without a watch record touches nothing"

# --- a merged PR resumes a worker on its ready line exactly once, silently ----
H=$(make_home merged "working: implementing" "done: PR $URL checks green")
out=$(watch "$H" arm t1 "$URL") || fail "arm failed: $out"
assert_contains "$out" "on $URL" "arm names the PR"; assert_contains "$out" "(merged)" "a repository without a pointer arms merged"
start_runner "$H"
sleep 0.5
assert_equals 0 "$(inbox_count "$H")" "an open PR sends nothing"
printf 'merged\n' > "$H/pr-state"
R=$(wait_result "$H") || fail "no outcome after the PR merged"
assert_equals fired "$(outcome "$H" "$R")" "a merged PR fires the resume"
assert_equals 1 "$(inbox_count "$H")" "exactly one resume record lands in the worker inbox"
body=$(cat "$H/state/t1.inbox/"*.msg)
assert_contains "$body" "Resume fact (watch): PR $URL merged. The wait you declared has cleared; continue with the next step your brief or your own last status line already names, and append working: when you resume." \
  "the record carries the fixed template and the fact"
assert_equals 0 "$(wake_rows "$H")" "a delivered resume wakes nobody"
handled=$(in_home "$H" "$ROOT/bin/fm-procevent.sh" handled "$(sid_of "$H")" 1)
assert_contains "$handled" "already-handled" "the silent outcome is recorded as handled"
grep -q '"verb":"send".*"origin":"fm-resume-action.sh"' "$H/state/supervisor-actions.jsonl" \
  || fail "the ledger row is not attributed to fm-resume-action.sh: $(cat "$H/state/supervisor-actions.jsonl")"
# Re-arming the same PR (a re-run of fm-pr-check) never resumes twice.
out=$(watch "$H" arm t1 "$URL") || fail "re-arm failed"
assert_contains "$out" "already armed" "re-arming the same PR is a no-op"
start_runner "$H"; sleep 0.5
assert_equals 1 "$(inbox_count "$H")" "re-arming after the fire sends no second record"
pass "a merged PR lands exactly one silent resume record, attributed to the watch"

# --- a paused worker resumes whether or not its pause names the PR -----------
for case in named bare; do
  case "$case" in
    named) last="paused: waiting for $URL to merge, then I run the proof" ;;
    bare) last="paused: waiting for my PR to merge, then I verify" ;;
  esac
  H=$(make_home "paused-$case" "done: PR $URL checks green" "$last")
  printf 'merged\n' > "$H/pr-state"
  watch "$H" arm t1 "$URL" >/dev/null || fail "arm failed ($case)"
  start_runner "$H"
  R=$(wait_result "$H") || fail "no outcome for the paused worker ($case)"
  assert_equals fired "$(outcome "$H" "$R")" "a $case pause is resumed"
  assert_equals 1 "$(inbox_count "$H")" "the paused worker gets one record ($case)"
  assert_equals 0 "$(wake_rows "$H")" "a resumed pause wakes nobody ($case)"
done
pass "a paused worker is resumed whether or not its pause names the PR"

# --- a worker that already moved on, or recorded its observation, gets none ----
for case in working needs-decision verified; do
  case "$case" in
    working) last="working: rebased and continuing" ;;
    needs-decision) last="needs-decision: pick A or B" ;;
    verified) last="done: verified: saw it live" ;;
  esac
  H=$(make_home "moved-$case" "done: PR $URL checks green" "$last")
  printf 'merged\n' > "$H/pr-state"
  watch "$H" arm t1 "$URL" >/dev/null || fail "arm failed ($case)"
  start_runner "$H"
  R=$(wait_result "$H") || fail "no outcome ($case)"
  assert_equals action-failed "$(outcome "$H" "$R")" "a $case worker is not resumed"
  assert_grep "not sent: t1 is no longer waiting" "$R" "the outcome says why nothing was sent ($case)"
  assert_equals 0 "$(inbox_count "$H")" "a $case worker gets no record"
  assert_equals 1 "$(wake_rows "$H")" "the refused resume wakes firstmate ($case)"
done
pass "a worker no longer waiting on its PR is never resumed"

# --- a PR closed unmerged ends the watch with no steer and wakes firstmate -----
H=$(make_home closed "done: PR $URL checks green")
printf 'closed\n' > "$H/pr-state"
watch "$H" arm t1 "$URL" >/dev/null || fail "arm failed"
start_runner "$H"
R=$(wait_result "$H") || fail "no outcome for the closed PR"
assert_equals condition-error "$(outcome "$H" "$R")" "a closed-unmerged PR is a condition error"
assert_equals 0 "$(inbox_count "$H")" "a closed-unmerged PR sends nothing"
assert_equals 1 "$(wake_rows "$H")" "a closed-unmerged PR wakes firstmate"
pass "a PR closed unmerged ends in condition-error with no steer"

# --- live waits for the release pointer to contain the merge commit ------------
H=$(make_home live "done: PR $URL checks green")
REPO="$H/release-store"
fm_git_init_commit "$REPO" >/dev/null
git -C "$REPO" tag rel-1
printf 'change\n' > "$REPO/change.txt"
git -C "$REPO" add change.txt
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -qm merged-change
MERGE_SHA=$(git -C "$REPO" rev-parse HEAD)
printf '%s\n' "$MERGE_SHA" > "$H/merge-sha"
printf 'rel-1\n' > "$H/deployed_tag"
printf 'https://github.com/o/r %s %s\n' "$REPO" "$H/deployed_tag" > "$H/config/resume-live-pointers"
printf '# Completion observation\nverify: the fix is visible in production\n' > "$H/data/t1/brief.md"
printf 'merged\n' > "$H/pr-state"
out=$(watch "$H" arm t1 "$URL") || fail "live arm failed: $out"
assert_contains "$out" "(live)" "a pointer plus a production verify line selects live"
start_runner "$H"
sleep 0.8
assert_equals 0 "$(inbox_count "$H")" "a merge not yet in the live tag sends nothing"
git -C "$REPO" tag rel-2
printf 'rel-2\n' > "$H/deployed_tag"
R=$(wait_result "$H") || fail "no outcome once the release contained the merge"
assert_equals fired "$(outcome "$H" "$R")" "the live watch fires once the tag contains the merge"
assert_contains "$(cat "$H/state/t1.inbox/"*.msg)" "PR $URL live in production." "the live record names the live fact"
pass "a live watch fires only once the release pointer contains the merge"

# A GitLab fast-forward merge records no merge or squash commit; the MR's head
# commit is what landed, so pr-live reads it rather than failing every poll.
cat > "$H/fakebin/glab" <<SH
#!/usr/bin/env bash
printf '{"state":"merged","merge_commit_sha":null,"squash_commit_sha":null,"sha":"%s"}\n' "$MERGE_SHA"
SH
chmod +x "$H/fakebin/glab"
rc=0
in_home "$H" "$ROOT/bin/fm-resume-cond.sh" pr-live https://gitlab.com/o/r/-/merge_requests/7 "$REPO" "$H/deployed_tag" || rc=$?
assert_equals 0 "$rc" "a fast-forward GitLab merge in the live tag reads live"
pass "pr-live reads a GitLab fast-forward merge through the MR head commit"

# --- only a verify line naming production selects live ------------------------
for case in staging preview suite; do
  case "$case" in
    staging) verify="the fix is deployed to staging" ;;
    preview) verify="the live preview shows the new banner" ;;
    suite) verify="the new test passes in the suite" ;;
  esac
  H=$(make_home "select-$case" "done: PR $URL checks green")
  printf 'https://github.com/o/r %s %s\n' "$H" "$H/deployed_tag" > "$H/config/resume-live-pointers"
  printf '# Completion observation\nverify: %s\n' "$verify" > "$H/data/t1/brief.md"
  out=$(watch "$H" arm t1 "$URL") || fail "arm failed ($case): $out"
  assert_contains "$out" "(merged)" "a verify line not naming production stays merged ($case)"
  assert_grep "form=merged" "$H/state/t1.resume-watch" "the record carries the merged form ($case)"
done
pass "a verify line that does not name production keeps the merged form"

# --- arming a new PR replaces the old watch, and retire removes it ------------
H=$(make_home replace "done: PR $URL checks green")
watch "$H" arm t1 "$URL" >/dev/null || fail "arm failed"
NEW=https://github.com/o/r/pull/8
out=$(watch "$H" arm t1 "$NEW") || fail "re-arm for a new PR failed"
assert_contains "$out" "armed: resume watch" "a new PR re-arms"
assert_grep "url=$NEW" "$H/state/t1.resume-watch" "the record follows the new PR"
SID=$(sid_of "$H")
assert_present "$H/state/when/$SID.spec" "the replacement watch is registered"
watch "$H" retire t1 >/dev/null || fail "retire failed"
assert_absent "$H/state/when/$SID.spec" "retire removes the spec"
assert_absent "$H/state/procevent/$SID.source" "retire drops the registration"
assert_absent "$H/state/t1.resume-watch" "retire removes the record"
watch "$H" retire t1 >/dev/null || fail "retire is not idempotent"
pass "a new PR replaces the watch and retire removes it"
