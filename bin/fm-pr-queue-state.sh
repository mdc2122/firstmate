#!/usr/bin/env bash
# Read-only probe: where is one GitHub pull request that bin/fm-pr-merge.sh
# handed to a merge-queue app through GitHub auto-merge? bin/fm-watch.sh runs
# it beside an armed merge poll while state/<id>.queue-merge names that pull
# request, and owns what each answer means for the poll and the one ejection
# wake; this script only reads the forge and classifies what it saw.
#
# Prints exactly one line:
#   waiting <head-sha>
#                     the pull request is open with auto-merge still enabled,
#                     so the queue still holds it
#   off <head-sha> <detail>
#                     the pull request is open and auto-merge is no longer
#                     enabled; <detail> names each queue check with its latest
#                     conclusion or status and, when the forge reports one, the
#                     check's own title, which is where a queue app states why
#                     it ejected the pull request
#   merged            the pull request has merged
#   closed            the pull request was closed without merging
# and nothing when the answer is unknown: a failed read, an unreadable payload,
# or a missing jq. The caller changes nothing on silence.
# It never merges, enables or disables auto-merge, or writes anything.
#
# Usage: fm-pr-queue-state.sh <github-pull-request-url> <queue-check-names-json>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"
  exit 0
fi
[ "$#" -eq 2 ] || exit 0
fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ] || exit 0
command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0
names=$2
printf '%s' "$names" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1 || exit 0

fm_pr_github_read_auto_merge "$FM_PR_URL" "$names" || exit 0
case "$FM_PR_GITHUB_AUTO_STATE" in
  MERGED) echo merged; exit 0 ;;
  CLOSED) echo closed; exit 0 ;;
esac
if [ "$FM_PR_GITHUB_AUTO_ENABLED" = true ]; then
  echo "waiting $FM_PR_GITHUB_AUTO_HEAD"
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
