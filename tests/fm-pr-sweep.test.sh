#!/usr/bin/env bash
# Tests for bin/fm-pr-sweep.sh, the forge-side merge-poll backstop: a green PR
# on a live task's branch gets its merge poll armed (yolo) or one wake
# (non-yolo) with no `done: PR <url>` line at all, across every registered
# repository when its head commit proves it is the task's, and an armed, red,
# draft, or foreign PR is never armed.
#
# The incident: a worker's green yolo PR sat unarmed because arming depended
# on firstmate reading the worker's prose. Each case drives the public `check`
# command against a fake `gh` that answers `gh pr list` per repository from
# fixture files, so no case reaches GitHub; the arm itself runs the real
# bin/fm-pr-check.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

SWEEP="$ROOT/bin/fm-pr-sweep.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-sweep)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REAL_JQ=$(command -v jq) || fail "the sweep reads gh's JSON with the real jq, which was not found"
REAL_GIT=$(command -v git) || fail "the sweep reads task branches with git, which was not found"

GREEN='[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-01T00:00:00Z"}]'
RED='[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-01T00:00:00Z"}]'
PENDING='[{"__typename":"CheckRun","name":"ci","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-10-01T00:00:00Z"}]'

# A home with a fake gh: `gh pr list --repo <owner>/<repo>` prints
# $home/forge/<owner>__<repo>.json (or fails when that file is absent), and
# `gh pr view` (fm-pr-check.sh's head lookup) prints nothing, so no pr_head is
# recorded.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/forge" "$home/fakebin"
  ln -sf "$REAL_JQ" "$home/fakebin/jq"
  ln -sf "$REAL_GIT" "$home/fakebin/git"
  cat > "$home/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/forge/gh.log"
[ "\${1:-} \${2:-}" = "pr list" ] || exit 1
while [ \$# -gt 0 ]; do [ "\$1" = --repo ] && repo=\$2; shift; done
f="$home/forge/\${repo//\//__}.json"
[ -f "\$f" ] || exit 1
cat "\$f"
SH
  chmod +x "$home/fakebin/gh"
  printf '%s\n' "$home"
}

commit() {  # <dir> <message>
  git -C "$1" -c user.name=fm -c user.email=fm@example.invalid commit -q --allow-empty -m "$2"
}

# A registered clone whose origin is https://github.com/<owner>/<repo>.git.
add_project() {  # <home> <name> <owner/repo>
  local dir="$1/projects/$2"
  git init -q -b main "$dir"
  git -C "$dir" remote add origin "https://github.com/$3.git"
  commit "$dir" "init $3"
}

# A live task whose worktree of project <name> is checked out on <branch>,
# with a commit of its own.
add_task() {  # <home> <task> <branch> <yolo> <project> [kind]
  local home=$1 task=$2 branch=$3 yolo=$4 project="$1/projects/$5" kind=${6:-ship} wt="$1/wt-$2"
  git -C "$project" worktree add -q -b "$branch" "$wt"
  commit "$wt" "work $task"
  fm_write_meta "$home/state/$task.meta" \
    "window=fm-$task" "endpoint_task_id=$task" "worktree=$wt" "project=$project" \
    "kind=$kind" "mode=no-mistakes" "yolo=$yolo"
}

head_of() {  # <home> <task>
  git -C "$1/wt-$2" rev-parse HEAD
}

# Open PRs for one repository: rows of "<number>|<branch>|<rollup>|<head sha>[|draft]".
forge_prs() {  # <home> <owner/repo> <row>...
  local home=$1 repo=$2 row number branch rollup sha draft json='[]'
  shift 2
  for row in "$@"; do
    IFS='|' read -r number branch rollup sha draft <<EOF
$row
EOF
    json=$(printf '%s' "$json" | jq -c --arg url "https://github.com/$repo/pull/$number" \
      --arg b "$branch" --argjson r "$rollup" --arg sha "$sha" --arg d "${draft:-}" \
      '. + [{url:$url, headRefName:$b, headRefOid:$sha, isDraft:($d == "draft"), isCrossRepository:false, statusCheckRollup:$r}]')
  done
  printf '%s\n' "$json" > "$home/forge/${repo//\//__}.json"
}

sweep() {  # <home>
  local home=$1
  PATH="$home/fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SWEEP" check > "$home/sweep.out" 2> "$home/sweep.err" \
    || fail "sweep exited non-zero: $(cat "$home/sweep.err")"
}

armed_url() {  # <home> <task>
  fm_pr_poll_artifacts_valid "$1/state" "$2" "$POLL" || return 1
  printf '%s' "$FM_PR_DATA_URL"
}

sweep_rows() {  # <home>
  [ -f "$1/state/.wake-queue" ] || { printf '0'; return 0; }
  grep -c "$(printf '\tcheck\tpr-sweep-')" "$1/state/.wake-queue" || true
}

test_green_unarmed_branch_pr_is_armed_with_no_done_line() {
  local home url
  home=$(make_home green-yolo)
  add_project "$home" viral-moment o/viral-moment
  add_project "$home" trending-moment o/trending-moment
  add_task "$home" t1 fm/t1 on viral-moment
  url=https://github.com/o/trending-moment/pull/7
  forge_prs "$home" o/viral-moment "3|fm/other|$GREEN|$(head_of "$home" t1)"
  forge_prs "$home" o/trending-moment "7|fm/t1|$GREEN|$(head_of "$home" t1)"
  [ ! -e "$home/state/t1.status" ] || fail "fixture unexpectedly has a status log"

  sweep "$home"
  [ "$(armed_url "$home" t1)" = "$url" ] \
    || fail "a green PR in another registered repo at a commit in the task's clone was not armed: $(cat "$home/sweep.err")"
  grep -qxF "pr=$url" "$home/state/t1.meta" || fail "arming did not record pr= through fm-pr-check.sh"
  [ "$(sweep_rows "$home")" = 0 ] || fail "a successful yolo arm queued a wake"
  [ ! -s "$home/sweep.out" ] || fail "a successful yolo arm printed a wake: $(cat "$home/sweep.out")"
  pass "a green unarmed cross-repo PR whose head commit is in the yolo task's clone is armed with no done line"
}

test_already_armed_pr_is_a_noop() {
  local home before
  home=$(make_home armed-noop)
  add_project "$home" viral-moment o/viral-moment
  add_task "$home" t1 fm/t1 on viral-moment
  forge_prs "$home" o/viral-moment "5|fm/t1|$GREEN|$(head_of "$home" t1)"
  sweep "$home"
  [ -n "$(armed_url "$home" t1)" ] || fail "fixture arm failed"
  before=$(cat "$home/state/t1.pr-poll-registration" "$home/state/t1.meta" | shasum -a 256)

  sweep "$home"
  [ "$(cat "$home/state/t1.pr-poll-registration" "$home/state/t1.meta" | shasum -a 256)" = "$before" ] \
    || fail "a second sweep re-registered an already armed PR"
  [ "$(sweep_rows "$home")" = 0 ] || fail "an already armed PR queued a wake"
  pass "an already armed PR is a no-op"
}

test_red_pending_draft_and_scout_prs_are_not_armed() {
  local home
  home=$(make_home not-green)
  add_project "$home" viral-moment o/viral-moment
  for task in red pending draft empty; do add_task "$home" "$task" "fm/$task" on viral-moment; done
  add_task "$home" scout fm/scout on viral-moment scout
  forge_prs "$home" o/viral-moment \
    "1|fm/red|$RED|$(head_of "$home" red)" "2|fm/pending|$PENDING|$(head_of "$home" pending)" \
    "3|fm/draft|$GREEN|$(head_of "$home" draft)|draft" "4|fm/empty|[]|$(head_of "$home" empty)" \
    "5|fm/scout|$GREEN|$(head_of "$home" scout)"

  sweep "$home"
  for task in red pending draft empty scout; do
    ! armed_url "$home" "$task" >/dev/null || fail "$task: a non-green or non-ship PR was armed"
    ! grep -q '^pr=' "$home/state/$task.meta" || fail "$task: a non-green PR recorded pr="
  done
  [ "$(sweep_rows "$home")" = 0 ] || fail "a non-green PR queued a wake"
  pass "red, pending, draft, empty-rollup, and scout PRs are never armed or reported"
}

test_non_yolo_green_pr_wakes_once() {
  local home url sha
  home=$(make_home non-yolo)
  add_project "$home" viral-moment o/viral-moment
  add_task "$home" t1 fm/t1 off viral-moment
  url=https://github.com/o/viral-moment/pull/9
  sha=$(head_of "$home" t1)
  forge_prs "$home" o/viral-moment "9|fm/t1|$GREEN|$sha"

  sweep "$home"
  ! armed_url "$home" t1 >/dev/null || fail "a non-yolo task's PR was armed by the sweep"
  [ "$(sweep_rows "$home")" = 1 ] || fail "a non-yolo green PR did not queue exactly one wake"
  grep -F "$url" "$home/sweep.out" >/dev/null || fail "the wake did not name the PR: $(cat "$home/sweep.out")"

  sweep "$home"
  [ "$(sweep_rows "$home")" = 1 ] || fail "a repeat sweep re-woke for the same PR"

  forge_prs "$home" o/viral-moment "9|fm/t1|$RED|$sha"
  sweep "$home"
  forge_prs "$home" o/viral-moment "9|fm/t1|$GREEN|$sha"
  sweep "$home"
  [ "$(sweep_rows "$home")" = 2 ] || fail "a PR that went red and green again was not reported anew"
  pass "a non-yolo green PR wakes once, and again only after it leaves and returns"
}

test_unreadable_repo_keeps_earlier_reports() {
  local home
  home=$(make_home unreadable)
  add_project "$home" viral-moment o/viral-moment
  add_task "$home" t1 fm/t1 off viral-moment
  forge_prs "$home" o/viral-moment "9|fm/t1|$GREEN|$(head_of "$home" t1)"
  sweep "$home"
  [ "$(sweep_rows "$home")" = 1 ] || fail "fixture wake missing"
  rm -f "$home/forge/o__viral-moment.json"
  sweep "$home"
  grep -F 'could not read open pull requests for o/viral-moment' "$home/sweep.err" >/dev/null \
    || fail "an unreadable repository was not reported"
  forge_prs "$home" o/viral-moment "9|fm/t1|$GREEN|$(head_of "$home" t1)"
  sweep "$home"
  [ "$(sweep_rows "$home")" = 1 ] || fail "an unreadable sweep turned into a repeat wake"
  pass "an unreadable repository is reported and never causes a repeat wake"
}

test_same_name_branch_with_foreign_commits_is_never_armed() {
  local home foreign
  home=$(make_home foreign)
  add_project "$home" viral-moment o/viral-moment
  add_project "$home" trending-moment o/trending-moment
  add_task "$home" t1 fix-readme on viral-moment
  commit "$home/projects/trending-moment" "someone else's readme fix"
  foreign=$(git -C "$home/projects/trending-moment" rev-parse HEAD)
  forge_prs "$home" o/trending-moment "12|fix-readme|$GREEN|$foreign"
  forge_prs "$home" o/viral-moment "13|fix-readme|$GREEN|$(git -C "$home/projects/viral-moment" rev-parse main)"

  sweep "$home"
  ! armed_url "$home" t1 >/dev/null || fail "a PR proven by branch name alone was armed: $(armed_url "$home" t1)"
  ! grep -q '^pr=' "$home/state/t1.meta" || fail "an unowned PR recorded pr="
  [ "$(sweep_rows "$home")" = 2 ] || fail "each unowned green PR did not queue exactly one wake"
  grep -F 'pull/12 on branch fix-readme was not armed: its head commit is in no clone recorded for t1' "$home/sweep.out" >/dev/null \
    || fail "the foreign cross-repo PR wake did not explain itself: $(cat "$home/sweep.out")"
  grep -F "pull/13 on branch fix-readme was not armed: its head commit is not t1's worktree HEAD" "$home/sweep.out" >/dev/null \
    || fail "the same-repo PR at another commit did not explain itself: $(cat "$home/sweep.out")"
  pass "a same-name branch PR whose head commit the task does not hold is woken about, never armed"
}

test_tasks_sharing_a_branch_name_in_different_repos_each_match() {
  local home
  home=$(make_home shared-name)
  add_project "$home" viral-moment o/viral-moment
  add_project "$home" trending-moment o/trending-moment
  add_task "$home" a fm/x on viral-moment
  add_task "$home" b fm/x on trending-moment
  forge_prs "$home" o/viral-moment "1|fm/x|$GREEN|$(head_of "$home" a)"
  forge_prs "$home" o/trending-moment "2|fm/x|$GREEN|$(head_of "$home" b)"

  sweep "$home"
  [ "$(armed_url "$home" a)" = https://github.com/o/viral-moment/pull/1 ] \
    || fail "task a was not armed for its own repo's PR: $(cat "$home/sweep.err" "$home/sweep.out")"
  [ "$(armed_url "$home" b)" = https://github.com/o/trending-moment/pull/2 ] \
    || fail "task b was not armed for its own repo's PR: $(cat "$home/sweep.err" "$home/sweep.out")"
  [ "$(sweep_rows "$home")" = 0 ] || fail "two correctly owned PRs queued a wake"
  pass "two tasks sharing a branch name in different repos are each matched to their own PR"
}

test_green_unarmed_branch_pr_is_armed_with_no_done_line
test_already_armed_pr_is_a_noop
test_red_pending_draft_and_scout_prs_are_not_armed
test_non_yolo_green_pr_wakes_once
test_unreadable_repo_keeps_earlier_reports
test_same_name_branch_with_foreign_commits_is_never_armed
test_tasks_sharing_a_branch_name_in_different_repos_each_match
