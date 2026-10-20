#!/usr/bin/env bash
# Read-only probe: did a merge-queue app just eject this GitHub pull request,
# and on what did its queue run fail? bin/fm-watch.sh runs it when its
# merge-queue hand-off reads that auto-merge was cancelled while the pull
# request stayed open, and owns the single worker steer per ejection; this
# script only reads the forge and the failing run's own log.
#
# Prints exactly one line:
#   ejection <head-sha> <run-url> <failure>
#                     a queue check at <head-sha> completed with a failing
#                     conclusion, so that queue run has finished and the
#                     queue has ejected the pull request; <run-url> is the
#                     failing run or job URL and <failure> is a
#                     "; "-joined list of the failing test ids read from that
#                     run's failed log, or "check <name>" when the log names
#                     no test id
# and nothing when the answer is unknown or a queue run is still in flight:
# no queue check reported at that head, every queue check is still running or
# completed without a failing conclusion, the pull request URL or head is
# invalid, or a forge read failed. The caller changes nothing on silence.
#
# Queue checks are the given check names (the base branch's merge-queue app
# checks) and every check the app mirrors under "<name>/<context>". The run URL
# comes from the queue app's own most recent ejection comment on the pull
# request, which names the failing check and links the run - gitea-mq posts
# "Removed from merge queue: Check failed: [<check>](<run url>)" - and falls
# back to the failing mirrored check's own details URL. The failing test ids
# come from that run's `gh run view --log-failed` output, bounded by
# FM_MQ_EJECTION_LOG_TIMEOUT seconds (default 15, capped at 25 to fit the
# watcher's per-check bound). It never merges, updates a branch, or writes
# anything.
#
# Usage: fm-mq-ejection.sh <github-pull-request-url> <head-sha> <queue-check-names-json>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"
  exit 0
fi
[ "$#" -eq 3 ] || exit 0
fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ] || exit 0
fm_pr_head_valid "$2" || exit 0
command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0
names=$3
printf '%s' "$names" | jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' \
  >/dev/null 2>&1 || exit 0
head=$2
owner=$FM_PR_OWNER
repo=$FM_PR_REPO
number=$FM_PR_NUMBER

log_timeout=${FM_MQ_EJECTION_LOG_TIMEOUT:-15}
case "$log_timeout" in ''|*[!0-9]*|0) log_timeout=15 ;; esac
[ "$log_timeout" -le 25 ] || log_timeout=25

# The latest check run per name at the head, as one JSON array. A failed read
# leaves the answer unknown.
runs=$(gh api --paginate "repos/$owner/$repo/commits/$head/check-runs" 2>/dev/null \
  | jq -sc --argjson names "$names" --arg head "$head" '
    [.[] | (if type == "array" then .[] else . end) | .check_runs[]?]
    | group_by(.name)
    | map(max_by(.id))
    | map(select(.head_sha == $head))
    | map(select(.name as $n
        | any($names[]; . as $q | $n == $q or ($n | startswith($q + "/")))))
  ' 2>/dev/null) || exit 0
[ -n "$runs" ] && [ "$runs" != '[]' ] || exit 0

# Only a settled failing queue check means the queue ejected; a run still in
# flight is never this probe's business.
failing=$(printf '%s' "$runs" | jq -r '
  [.[] | select(.conclusion == "failure" or .conclusion == "cancelled"
    or .conclusion == "timed_out")]
  | .[] | [.name, (.details_url // ""), (.started_at // "")] | @tsv
' 2>/dev/null) || exit 0
[ -n "$failing" ] || exit 0
first_name=$(printf '%s\n' "$failing" | awk -F '\t' 'NR == 1 { print $1 }')
first_started=$(printf '%s\n' "$failing" | awk -F '\t' 'NR == 1 { print $3 }')

# The queue app's own ejection comment names the failing check and links the
# merge-branch run; only a comment posted at or after the failing check run
# started describes this ejection, never an earlier one on the same head.
run_url=''
comment_check=''
if comments=$(gh api --paginate "repos/$owner/$repo/issues/$number/comments?per_page=100" 2>/dev/null); then
  rec=$(printf '%s' "$comments" | jq -r --arg since "$first_started" '
    [ .[] | select(type == "object")
      | select((.created_at // "") >= $since)
      | .body // ""
      | select(test("Removed from merge queue"))
    ] | last // empty' 2>/dev/null) || rec=''
  if [ -n "$rec" ]; then
    run_url=$(printf '%s' "$rec" | sed -n \
      's/.*[Cc]heck failed: *\[[^]]*\](\(https:\/\/github\.com\/[^) ]*\)).*/\1/p' | head -1)
    comment_check=$(printf '%s' "$rec" | sed -n \
      's/.*[Cc]heck failed: *\[\([^]]*\)\].*/\1/p' | head -1)
  fi
fi

# Fall back to the failing mirrored check's own details URL, which is the
# merge-branch job the app mirrored; the queue's status check links only its
# dashboard entry.
if [ -z "$run_url" ]; then
  run_url=$(printf '%s\n' "$failing" | awk -F '\t' '
    $2 ~ /^https:\/\/github\.com\/[^\/]+\/[^\/]+\/actions\/runs\/[0-9]+(\/job\/[0-9]+)?$/ {
      if (index($1, "/") > 0 && first == "") first = $2
      else if (fallback == "") fallback = $2
    }
    END { if (first != "") print first; else if (fallback != "") print fallback }')
fi
[ -n "$run_url" ] || exit 0

# Read the failing run's own log for the failing test ids. A run URL without a
# job id is read whole; the job id keeps a large workflow's log small.
log=''
run_id=''
job_id=''
case "$run_url" in
  "https://github.com/$owner/$repo/actions/runs/"*)
    rest=${run_url#https://github.com/}
    rest=${rest#*/}                 # <repo>/actions/runs/<id>[/job/<id>]
    rest=${rest#*/}                 # actions/runs/<id>[/job/<id>]
    rest=${rest#actions/runs/}
    run_id=${rest%%/*}
    rest=${rest#"$run_id"}
    rest=${rest#/job/}
    job_id=${rest%%/*}
    case "$run_id" in ''|*[!0-9]*) run_id='' ;; esac
    case "$job_id" in ''|*[!0-9]*) job_id='' ;; esac
    ;;
esac
if [ -n "$run_id" ]; then
  if [ -n "$job_id" ]; then
    log=$(fm_run_timed "$log_timeout" gh run view "$run_id" -R "$owner/$repo" \
      --job "$job_id" --log-failed 2>/dev/null) || log=''
  else
    log=$(fm_run_timed "$log_timeout" gh run view "$run_id" -R "$owner/$repo" \
      --log-failed 2>/dev/null) || log=''
  fi
fi

failure=''
if [ -n "$log" ]; then
  failure=$(printf '%s\n' "$log" | awk '
    {
      # gh prefixes each line with its job and step, so take the failure
      # itself from the FAILED or ERROR marker onward.
      if (!match($0, /(FAILED|ERROR)[ \t]+/)) next
      line = substr($0, RSTART + RLENGTH)
      # A pytest failure line is "<test id> - <error>"; the id is what a
      # reader needs and the error text is what bloats a steer, so keep the id
      # whole and drop the trailing explanation.
      if (sub(/[ \t]+- .*$/, "", line)) {}
      sub(/[ \t\r]+$/, "", line)
      if (length(line) > 200) line = substr(line, 1, 197) "..."
      if (line != "" && !(line in seen)) {
        seen[line] = 1
        out = (out == "" ? line : out "; " line)
        if (++n >= 6) exit
      }
    }
    END { if (out != "") print out }')
fi
if [ -z "$failure" ]; then
  failure="check ${comment_check:-$first_name}"
fi
[ -n "$failure" ] || exit 0

printf 'ejection %s %s %s\n' "$head" "$run_url" "$failure"
