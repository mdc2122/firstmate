#!/usr/bin/env bash
# fm-pr-sweep.sh - forge-side backstop for merge-poll arming.
#
# Usage:
#   fm-pr-sweep.sh check
#   fm-pr-sweep.sh --help
#
# The watcher arms a task's merge poll from the worker's `done: PR <url>`
# ready line (bin/fm-watch.sh ready_pr_polls_arm). This sweep covers every PR
# that path cannot see because it depends on worker prose: a PR the worker
# never announced, a second or third PR a task opened later, or a PR in a
# repository other than the task's own project clone.
#
# Each run reads GitHub, never a status log. A task is swept when it has a
# state/<id>.meta whose kind is neither scout nor secondmate and whose recorded
# worktree is on a named branch. Every registered GitHub repository - each
# clone under this home's projects directory with a github.com origin - is
# asked once for its open pull requests, and each non-draft, same-repository
# PR whose head branch is a swept task's branch is matched to that task. So a
# task opening several PRs, or a PR in another registered repository, is
# found by branch name alone.
#
# For each matched PR whose checks are all green by bin/fm-pr-lib.sh's
# fm_pr_github_checks_not_green (an empty or unreadable rollup is not green):
#   - already armed for that exact PR, or its merge already delivered: nothing;
#   - the task records yolo=on: arm it through bin/fm-pr-check.sh, the single
#     owner of validation, metadata, sidecar, and registration;
#   - otherwise: queue one `check` wake naming the task and PR, once per PR.
# A task polls one PR at a time (bin/fm-pr-check.sh's contract), so a yolo
# task with a different PR already armed is reported by wake instead of
# re-armed; the armed PR keeps its poll and firstmate decides the other.
# A red, pending, or draft PR is left alone and reconsidered next sweep.
# A refused arm is reported by wake too, so the sweep never fails silently.
#
# Durable record state/.pr-sweep holds one `seen=<task> <url>` line per PR
# already reported by wake; a PR is woken about once while that line stands,
# and a line whose PR is no longer a green candidate is dropped so a later
# return is a new report. The record is rewritten only after every wake for
# the run is durably queued.
#
# `check` prints each queued wake reason (nothing when nothing is due) and
# exits 0 even when a repository cannot be read; a read failure is logged to
# stderr and retried next sweep. FM_PR_SWEEP_GH_TIMEOUT (default 20) bounds
# each GitHub read and FM_PR_SWEEP_ARM_TIMEOUT (default 60) each arm.
# FM_PROJECTS_OVERRIDE points at a different projects directory (tests).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
RECORD="$STATE/.pr-sweep"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-pr-sweep.sh check    watcher hook: arm or report green unarmed PRs on task branches
  fm-pr-sweep.sh --help   print this help
EOF
}

whole_setting() {  # <name> <default>
  local v=${!1:-$2}
  case "$v" in ''|*[!0-9]*|0) v=$2 ;; esac
  printf '%s' "$v"
}
GH_TIMEOUT=$(whole_setting FM_PR_SWEEP_GH_TIMEOUT 20)
ARM_TIMEOUT=$(whole_setting FM_PR_SWEEP_ARM_TIMEOUT 60)

log() { printf 'fm-pr-sweep: %s\n' "$1" >&2; }

# "<branch>\t<task>" for every swept task, one per line.
task_branches() {
  local meta task kind wt branch
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=$(basename "$meta" .meta)
    fm_pr_task_id_valid "$task" || continue
    kind=$(fm_meta_get "$meta" kind)
    case "$kind" in scout|secondmate) continue ;; esac
    wt=$(fm_meta_get "$meta" worktree)
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || continue
    [ -n "$branch" ] || continue
    printf '%s\t%s\n' "$branch" "$task"
  done
}

# "<owner>/<repo>" for every registered GitHub clone, deduplicated.
registered_repos() {
  local dir url
  for dir in "$PROJECTS"/*/; do
    [ -d "$dir" ] || continue
    url=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
    case "$url" in
      https://github.com/*) url=${url#https://github.com/} ;;
      git@github.com:*) url=${url#git@github.com:} ;;
      ssh://git@github.com/*) url=${url#ssh://git@github.com/} ;;
      *) continue ;;
    esac
    url=${url%/}
    url=${url%.git}
    case "$url" in */*/*|*[!A-Za-z0-9._/-]*|/*|*/) continue ;; esac
    printf '%s\n' "$url"
  done | sort -u
}

# 0 when <task>'s armed poll names exactly <url>; sets nothing else.
armed_for() {  # <task> <provider> <host> <path> <number>
  fm_pr_poll_artifacts_valid "$STATE" "$1" "$SCRIPT_DIR/fm-pr-poll.sh" || return 1
  [ "$FM_PR_DATA_PROVIDER" = "$2" ] && [ "$FM_PR_DATA_HOST" = "$3" ] \
    && [ "$FM_PR_DATA_PATH" = "$4" ] && [ "$FM_PR_DATA_NUMBER" = "$5" ]
}

action_check() {
  local branches repos repo json prs pr url branch task meta red armed_any
  local provider host path number out rc reason entry read_failed=0
  local -a wakes=() keys=() keep=()
  branches=$(task_branches)
  [ -n "$branches" ] || { record_write; return 0; }
  repos=$(registered_repos)
  [ -n "$repos" ] || { record_write; return 0; }
  command -v gh >/dev/null 2>&1 || { log "gh not found; sweep skipped"; return 0; }
  command -v jq >/dev/null 2>&1 || { log "jq not found; sweep skipped"; return 0; }
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    if ! json=$(fm_run_timed "$GH_TIMEOUT" gh pr list --repo "$repo" --state open --limit 100 \
        --json url,headRefName,isDraft,isCrossRepository,statusCheckRollup 2>/dev/null) \
      || ! printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then
      log "could not read open pull requests for $repo; retried next sweep"
      read_failed=1
      continue
    fi
    prs=$(printf '%s' "$json" | jq -c --arg branches "$branches" '
      ($branches | split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: .[1]}) | from_entries) as $map
      | .[] | select((.isDraft | not) and (.isCrossRepository | not) and ($map[.headRefName] != null))
      | {url, branch: .headRefName, task: $map[.headRefName], pr: .}') || continue
    while IFS= read -r pr; do
      [ -n "$pr" ] || continue
      url=$(printf '%s' "$pr" | jq -r .url)
      task=$(printf '%s' "$pr" | jq -r .task)
      branch=$(printf '%s' "$pr" | jq -r .branch)
      fm_pr_url_parse "$url" || continue
      provider=$FM_PR_PROVIDER; host=$FM_PR_HOST; path=$FM_PR_PATH; number=$FM_PR_NUMBER
      # Green only by the shared rule, and never on an empty rollup.
      printf '%s' "$pr" | jq -e '(.pr.statusCheckRollup | type) == "array" and (.pr.statusCheckRollup | length) > 0' >/dev/null || continue
      red=$(fm_pr_github_checks_not_green "$(printf '%s' "$pr" | jq -c .pr)") || continue
      [ -z "$red" ] || continue
      armed_for "$task" "$provider" "$host" "$path" "$number" && continue
      fm_pr_poll_merge_already_notified "$STATE" "$task" "$provider" "$host" "$path" "$number" && continue
      meta="$STATE/$task.meta"
      armed_any=0
      fm_pr_poll_artifacts_valid "$STATE" "$task" "$SCRIPT_DIR/fm-pr-poll.sh" && armed_any=1
      if [ "$(fm_meta_get "$meta" yolo)" = on ] && [ "$armed_any" -eq 0 ]; then
        rc=0
        out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$FM_ROOT" \
          fm_run_timed "$ARM_TIMEOUT" "$SCRIPT_DIR/fm-pr-check.sh" "$task" "$url" 2>&1) || rc=$?
        if [ "$rc" -eq 0 ]; then
          log "armed merge poll for $task from its green branch PR: $url"
          continue
        fi
        reason="check: pr-sweep: green PR $url on $task's branch $branch could not be armed (rc=$rc): $(printf '%s' "$out" | tr '\r\n\t' '   ' | cut -c1-400)"
      elif [ "$armed_any" -eq 1 ]; then
        reason="check: pr-sweep: green PR $url on $task's branch $branch is not armed; the task already polls $FM_PR_DATA_URL"
      else
        reason="check: pr-sweep: green PR $url on $task's branch $branch has no merge poll; arm it with bin/fm-pr-check.sh $task $url when its merge is authorized"
      fi
      keep+=("$task $url")
      seen "$task $url" && continue
      wakes+=("$reason")
      keys+=("pr-sweep-$task")
    done <<EOF
$prs
EOF
  done <<EOF
$repos
EOF
  if [ "${#wakes[@]}" -gt 0 ]; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    for ((rc = 0; rc < ${#wakes[@]}; rc++)); do
      fm_wake_append check "${keys[$rc]}" "${wakes[$rc]}" \
        || { log "could not queue a sweep wake; retried next sweep"; return 0; }
    done
  fi
  # A repository that could not be read this run keeps its earlier reports, so
  # an unreadable sweep never turns into a repeat wake on the next one.
  if [ "$read_failed" -eq 1 ] && [ -f "$RECORD" ]; then
    while IFS= read -r entry; do
      case "$entry" in seen=*) keep+=("${entry#seen=}") ;; esac
    done < "$RECORD"
  fi
  record_write ${keep[@]+"${keep[@]}"}
  for reason in ${wakes[@]+"${wakes[@]}"}; do printf '%s\n' "$reason"; done
}

seen() {  # <task url>
  [ -f "$RECORD" ] && grep -qxF "seen=$1" "$RECORD"
}

# Replace the record with exactly the given "<task> <url>" entries.
record_write() {
  local tmp entry
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  if ! {
    for entry in "$@"; do printf 'seen=%s\n' "$entry"; done
  } > "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

case "${1:-}" in
  check) action_check ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
