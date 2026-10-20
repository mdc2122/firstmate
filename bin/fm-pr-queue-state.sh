#!/usr/bin/env bash
# Read-only probe: where is one GitHub pull request that bin/fm-pr-merge.sh
# handed to a merge-queue app through GitHub auto-merge? bin/fm-watch.sh runs
# it beside an armed merge poll while state/<id>.queue-merge names that pull
# request, and owns what each answer means for the poll and the one ejection
# wake; this script only reads the forge and classifies what it saw.
#
# Prints exactly one line:
#   waiting <head-sha> <reported> <detail>
#                     the pull request is open with auto-merge still enabled,
#                     so the queue still holds it; <reported> is true when any
#                     queue check has a status of its own and false when none
#                     does (unreported, or only the EXPECTED placeholder), and
#                     <detail> names each queue check with its latest
#                     conclusion, state, or status, so the caller can tell a
#                     queue that is moving from one that never answered
#   off <head-sha> <detail>
#                     the pull request is open and auto-merge is no longer
#                     enabled; <detail> names each queue check with its latest
#                     conclusion or status and, when the forge reports one, the
#                     check's own title, which is where a queue app states why
#                     it ejected the pull request
#   merged <head-sha> the pull request has merged at that head
#   closed            the pull request was closed without merging
# and nothing when the answer is unknown: a failed read, an unreadable payload,
# or a missing jq. The caller changes nothing on silence.
# It never merges, enables or disables auto-merge, or writes anything.
#
# With --unhanded it instead reads a pull request with no recorded queue
# hand-off and prints exactly one line:
#   unhanded <head-sha> <auto-merge-enabled> <detail>
#                     the pull request is open, not a draft, and green apart
#                     from its base branch's merge-queue app checks (the same
#                     rule bin/fm-pr-merge.sh verifies before a hand-off: every
#                     other check green and every other required check
#                     reported), its base branch requires such a check, and no
#                     queue check has any status of its own;
#                     <auto-merge-enabled> is true or false and <detail> names
#                     each queue check as the waiting line does
#   clear             any of that does not hold: merged, closed, a draft, a
#                     red or pending check, no merge-queue app on the base, or
#                     a queue check that has reported
# and nothing when the answer is unknown, exactly as above.
#
# With --disable-auto it instead disables GitHub auto-merge on the pull
# request, which the watcher does when the queue holds a head other than the
# one bin/fm-pr-merge.sh verified, and exits nonzero when that fails.
#
# Usage: fm-pr-queue-state.sh <github-pull-request-url> <queue-check-names-json>
#        fm-pr-queue-state.sh --unhanded <github-pull-request-url>
#        fm-pr-queue-state.sh --disable-auto <github-pull-request-url>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"
  exit 0
fi
if [ "${1:-}" = --disable-auto ]; then
  [ "$#" -eq 2 ] && fm_pr_url_parse "$2" && [ "$FM_PR_PROVIDER" = github ] || exit 2
  gh pr merge "$FM_PR_URL" --disable-auto >/dev/null || exit 1
  exit 0
fi

# Every check outside <names> that is red, pending, or required but not yet
# reported, one per line; exits nonzero when that cannot be read.
not_green_outside() {  # <pull-request-json> <base> <head> <names-json>
  local json=$1 base=$2 head=$3 names=$4 red producers missing
  red=$(fm_pr_github_checks_not_green "$json") || return 1
  fm_pr_github_read_required_contexts "$FM_PR_OWNER" "$FM_PR_REPO" "$base" || return 1
  producers=$(fm_pr_github_read_check_producers "$FM_PR_OWNER" "$FM_PR_REPO" "$head" "$FM_PR_GITHUB_REQUIRED") || return 1
  missing=$(fm_pr_github_required_checks_missing "$json" "$FM_PR_GITHUB_REQUIRED" "$producers") || return 1
  printf '%s\n%s\n' "$red" "$missing" | jq -Rr --argjson names "$names" \
    'select(length > 0) | select(. as $n | any($names[]; . == $n) | not)' 2>/dev/null || return 1
}

if [ "${1:-}" = --unhanded ]; then
  [ "$#" -eq 2 ] || exit 0
  fm_pr_url_parse "$2" && [ "$FM_PR_PROVIDER" = github ] || exit 0
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0
  json=$(gh pr view "$FM_PR_URL" --json state,isDraft,headRefOid,baseRefName,autoMergeRequest,statusCheckRollup 2>/dev/null) || exit 0
  base=$(printf '%s' "$json" | jq -r 'if type == "object" then (.baseRefName // "" | tostring) else error("unreadable") end' 2>/dev/null) || exit 0
  [ -n "$base" ] || exit 0
  fm_pr_github_read_queue_app_checks "$FM_PR_OWNER" "$FM_PR_REPO" "$base" "$json" || exit 0
  names=$FM_PR_GITHUB_QUEUE_APP_CHECKS
  fm_pr_github_auto_merge_parse "$json" "$names" || exit 0
  [ "$FM_PR_GITHUB_AUTO_STATE" = OPEN ] && [ "$names" != '[]' ] \
    && [ "$FM_PR_GITHUB_AUTO_REPORTED" = false ] || { echo clear; exit 0; }
  case "$(fm_pr_json_draft_state "$json")" in
    false) ;;
    true) echo clear; exit 0 ;;
    *) exit 0 ;;
  esac
  blocking=$(not_green_outside "$json" "$base" "$FM_PR_GITHUB_AUTO_HEAD" "$names") || exit 0
  [ -z "$blocking" ] || { echo clear; exit 0; }
  echo "unhanded $FM_PR_GITHUB_AUTO_HEAD $FM_PR_GITHUB_AUTO_ENABLED ${FM_PR_GITHUB_AUTO_DETAIL:-no queue check reported}"
  exit 0
fi

[ "$#" -eq 2 ] || exit 0
fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ] || exit 0
command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0
names=$2
printf '%s' "$names" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1 || exit 0

fm_pr_github_read_auto_merge "$FM_PR_URL" "$names" || exit 0
case "$FM_PR_GITHUB_AUTO_STATE" in
  MERGED) echo "merged $FM_PR_GITHUB_AUTO_HEAD"; exit 0 ;;
  CLOSED) echo closed; exit 0 ;;
esac
if [ "$FM_PR_GITHUB_AUTO_ENABLED" = true ]; then
  echo "waiting $FM_PR_GITHUB_AUTO_HEAD $FM_PR_GITHUB_AUTO_REPORTED ${FM_PR_GITHUB_AUTO_DETAIL:-no queue check reported}"
  exit 0
fi

head=$FM_PR_GITHUB_AUTO_HEAD
detail=$FM_PR_GITHUB_AUTO_DETAIL
# The rollup carries no check title, so the queue's own explanation is read
# from the check runs at the head; without it the rollup detail still stands.
if titled=$(gh api --paginate "repos/$FM_PR_OWNER/$FM_PR_REPO/commits/$head/check-runs" 2>/dev/null \
  | jq -rs --argjson names "$names" '
    [.[] | .check_runs[]?] as $runs
    | [$names[] | . as $name
      | ([$runs[] | select(.name == $name)] | max_by(.id)) as $run
      | select($run != null)
      | $name + " " + ($run.conclusion // $run.status // "unknown")
        + (if ($run.output.title // "") != "" then ": " + $run.output.title else "" end)]
    | join(", ") | gsub("[\r\n\t]"; " ")' 2>/dev/null) && [ -n "$titled" ]; then
  detail=$titled
fi
echo "off $head ${detail:-no queue check reported}"
