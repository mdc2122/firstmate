#!/usr/bin/env bash
# fm-resume-cond.sh - deterministic, read-only condition reads for a resume
# watch (bin/fm-resume-watch.sh) and for any condition->action watch armed by
# hand through bin/fm-procevent-when.sh.
#
# Usage:
#   fm-resume-cond.sh pr-merged    <pr-url>
#   fm-resume-cond.sh pr-live      <pr-url> <repo-dir> <pointer-file>
#   fm-resume-cond.sh commit-live  <repo-dir> <pointer-file> <sha40>
#   fm-resume-cond.sh verdict      <result-file>
#   fm-resume-cond.sh task-waiting <state-dir> <task-id> <pr-url>
#
# Exit status follows the `when` adapter's condition contract: 0 the fact is
# true, 1 it is cleanly false for now, and anything else is an error that is
# never read as true. 3 means the fact can never become true (the PR closed
# unmerged, the job failed, the task moved on), so a watch polling it ends in
# condition-error and wakes firstmate rather than waiting out its deadline. 2
# means the fact could not be read (a forge or git failure, a malformed
# argument); a run of them exhausts the watch's error budget and wakes
# firstmate the same way.
#
# pr-merged    0 merged | 1 still open | 3 closed unmerged | 2 read error.
#              The forge state comes from bin/fm-pr-lib.sh's GitHub and GitLab
#              record readers, so GitHub and GitLab URLs are both accepted.
# pr-live      pr-merged first (open is 1, closed unmerged is 3), then
#              commit-live on the PR's merge commit.
# commit-live  0 when <sha40> is an ancestor of the commit named by the tag on
#              the first line of <pointer-file>, resolved inside <repo-dir>.
#              A commit <repo-dir> does not know is 1 (not live yet); an
#              unreadable pointer or an unresolvable tag is 2.
# verdict      0 when a bin/fm-durable-job.sh verdict file's first line reads
#              `result=ok `, 1 while the file is absent, 3 for `result=error `,
#              2 for anything else.
# task-waiting 0 while the task is still waiting on that PR: its record exists,
#              it has not recorded `done: verified:` (bin/fm-dod-lib.sh
#              fm_verify_recorded), and its newest status line is either its
#              ready line naming exactly <pr-url> (`done: PR <pr-url> ...`) or a
#              `paused:` line. Anything else - a `working:`, `needs-decision:`,
#              or `blocked:` line, or a ready line for another PR - is 3, so a
#              worker that already resumed or moved on is never resumed again.
#              bin/fm-resume-action.sh re-checks it immediately before sending.
#
# Every form is read-only and idempotent; nothing here writes state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() { sed -n '2,43p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# pr_record <pr-url>: set FM_PR_RECORD_STATE and FM_PR_RECORD_MERGED from the
# forge; return 1 on any read failure or a URL that is not canonical.
pr_record() {
  fm_pr_url_parse "$1" && [ "$FM_PR_URL" = "$1" ] || return 1
  case "$FM_PR_PROVIDER" in
    github) fm_pr_github_read_record "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER" ;;
    gitlab) fm_pr_gitlab_read_record "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" ;;
    *) return 1 ;;
  esac
}

# pr_state_rc: map the record just read onto this script's exit contract.
pr_state_rc() {
  [ "$FM_PR_RECORD_MERGED" = true ] && return 0
  case "$FM_PR_RECORD_STATE" in
    OPEN|opened|locked) return 1 ;;
    CLOSED|closed) return 3 ;;
  esac
  return 2
}

pr_merged() {  # <pr-url>
  pr_record "$1" || return 2
  pr_state_rc
}

# merge_commit <pr-url>: print the 40-hex commit the merge put on the base
# branch (GitHub's merge commit, which is the squash commit for a squash merge;
# GitLab's merge commit, else its squash commit, else for a fast-forward merge
# the MR's head commit). Return 1 when it cannot be read.
merge_commit() {
  local sha=''
  case "$FM_PR_PROVIDER" in
    github)
      command -v gh >/dev/null 2>&1 || return 1
      # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
      sha=$(gh api graphql \
        -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){mergeCommit{oid}}}}' \
        -F "owner=$FM_PR_OWNER" -F "repo=$FM_PR_REPO" -F "number=$FM_PR_NUMBER" \
        --jq '.data.repository.pullRequest.mergeCommit.oid // ""' 2>/dev/null) || return 1
      ;;
    gitlab)
      command -v glab >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
      sha=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$FM_PR_NUMBER" -R "https://$FM_PR_HOST/$FM_PR_PATH" -F json 2>/dev/null \
        | jq -r 'if type == "object" then (.merge_commit_sha // .squash_commit_sha // .sha // "") else "" end' 2>/dev/null) || return 1
      ;;
    *) return 1 ;;
  esac
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$sha"
}

commit_live() {  # <repo-dir> <pointer-file> <sha40>
  local repo=$1 pointer=$2 sha=$3 tag='' live
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  [ -d "$repo" ] || return 2
  [ -f "$pointer" ] && [ -s "$pointer" ] || return 2
  IFS= read -r tag < "$pointer" || [ -n "$tag" ] || return 2
  tag=${tag//[[:space:]]/}
  [[ "$tag" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] || return 2
  live=$(git -C "$repo" rev-parse -q --verify "refs/tags/$tag^{commit}" 2>/dev/null) \
    || live=$(git -C "$repo" rev-parse -q --verify "$tag^{commit}" 2>/dev/null) \
    || return 2
  git -C "$repo" rev-parse -q --verify "$sha^{commit}" >/dev/null 2>&1 || return 1
  git -C "$repo" merge-base --is-ancestor "$sha" "$live" 2>/dev/null && return 0
  return 1
}

pr_live() {  # <pr-url> <repo-dir> <pointer-file>
  local rc sha
  pr_record "$1" || return 2
  pr_state_rc
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  sha=$(merge_commit) || return 2
  commit_live "$2" "$3" "$sha"
}

verdict() {  # <result-file>
  local f=$1 first=''
  [ -e "$f" ] || [ -L "$f" ] || return 1
  [ -f "$f" ] && [ ! -L "$f" ] || return 2
  IFS= read -r first < "$f" || [ -n "$first" ] || return 2
  case "$first" in
    'result=ok '*) return 0 ;;
    'result=error '*) return 3 ;;
  esac
  return 2
}

task_waiting() {  # <state-dir> <task-id> <pr-url>
  local state=$1 id=$2 url=$3 status meta line last='' verb
  fm_pr_task_id_valid "$id" || return 2
  fm_pr_url_parse "$url" && [ "$FM_PR_URL" = "$url" ] || return 2
  meta="$state/$id.meta"
  status="$state/$id.status"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 3
  [ -f "$status" ] && [ ! -L "$status" ] || return 3
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  # shellcheck source=bin/fm-dod-lib.sh
  . "$SCRIPT_DIR/fm-dod-lib.sh"
  fm_verify_recorded "$status" >/dev/null && return 3
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) last=$line ;; esac
  done < "$status"
  [ -n "$last" ] || return 3
  verb=$(status_line_verb "$last")
  if [ "$verb" = "done" ]; then
    [ "$(status_line_ready_pr_url "$last" 2>/dev/null)" = "$url" ] && return 0
    return 3
  fi
  status_is_paused "$last" && return 0
  return 3
}

case "${1-}" in
  pr-merged)    [ "$#" -eq 2 ] || usage; pr_merged "$2" ;;
  pr-live)      [ "$#" -eq 4 ] || usage; pr_live "$2" "$3" "$4" ;;
  commit-live)  [ "$#" -eq 4 ] || usage; commit_live "$2" "$3" "$4" ;;
  verdict)      [ "$#" -eq 2 ] || usage; verdict "$2" ;;
  task-waiting) [ "$#" -eq 4 ] || usage; task_waiting "$2" "$3" "$4" ;;
  *) usage ;;
esac
