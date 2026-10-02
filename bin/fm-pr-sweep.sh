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
# asked once for its open pull requests. A non-draft, same-repository PR whose
# head branch carries a swept task's branch name is a candidate, but a name
# match alone never arms anything; ownership is proven by commit:
#   - same repository (the task worktree's origin): the PR's head commit must
#     be the task worktree's HEAD;
#   - another registered repository: the PR's head commit must exist in the
#     task's recorded worktree= or project= clone.
# Candidates are keyed by (repository, branch), so tasks sharing a branch name
# in different repositories never collide. Two tasks owning one (repository,
# branch), two tasks proving one cross-repository PR, or a candidate whose
# head commit proves no task is reported by wake and never armed.
#
# For each owned PR whose checks are all green by bin/fm-pr-lib.sh's
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
# stderr and retried next sweep. The repository listing asks only for
# lightweight fields; the check rollup is read per candidate PR afterwards,
# because listing every open PR's rollup at once makes GitHub's GraphQL
# gateway answer 504 on a busy upstream repository. FM_PR_SWEEP_GH_TIMEOUT
# (default 20) bounds each GitHub read and FM_PR_SWEEP_ARM_TIMEOUT (default
# 60) each arm; a read that times out ends the run's reads, so a degraded
# network costs one read.
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

# "<owner>/<repo>" (lowercase) for a GitHub origin URL; fails otherwise.
github_repo() {  # <url>
  local url=$1
  case "$url" in
    https://github.com/*) url=${url#https://github.com/} ;;
    git@github.com:*) url=${url#git@github.com:} ;;
    ssh://git@github.com/*) url=${url#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  url=${url%/}
  url=${url%.git}
  case "$url" in */*/*|*[!A-Za-z0-9._/-]*|/*|*/|'') return 1 ;; esac
  case "$url" in */*) ;; *) return 1 ;; esac
  printf '%s\n' "$url" | tr '[:upper:]' '[:lower:]'
}

# "<repo>\t<branch>\t<task>\t<head>\t<worktree>\t<project>" for every swept
# task, one per line; <repo> is empty when the worktree has no GitHub origin.
task_rows() {
  local meta task kind wt branch head repo
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
    head=$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null) || continue
    repo=$(github_repo "$(git -C "$wt" remote get-url origin 2>/dev/null)") || repo=
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$branch" "$task" "$head" "$wt" "$(fm_meta_get "$meta" project)"
  done
}

# "<owner>/<repo>" for every registered GitHub clone, deduplicated.
registered_repos() {
  local dir
  for dir in "$PROJECTS"/*/; do
    [ -d "$dir" ] || continue
    github_repo "$(git -C "$dir" remote get-url origin 2>/dev/null)" || continue
  done | sort -u
}

# 0 when commit <sha> exists in any of the given git directories.
commit_in() {  # <sha> <dir>...
  local sha=$1 dir
  shift
  for dir in "$@"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null && return 0
  done
  return 1
}

# Resolve the task owning PR <repo> <branch> <sha> from $TASKS. Sets
# OWNER_TASK (the owning task, or a comma-joined label when none is proven)
# and OWNER_NOTE (empty when ownership is proven, else why it is not).
pr_owner() {  # <repo> <branch> <sha>
  local t_repo t_branch t_task t_head t_wt t_project names=""
  local own="" own_n=0 own_head="" proven="" proven_n=0
  while IFS=$'\t' read -r t_repo t_branch t_task t_head t_wt t_project; do
    [ "$t_branch" = "$2" ] || continue
    names="$names${names:+,}$t_task"
    if [ "$t_repo" = "$1" ]; then
      own=$t_task; own_head=$t_head; own_n=$((own_n + 1))
    elif commit_in "$3" "$t_wt" "$t_project"; then
      proven=$t_task; proven_n=$((proven_n + 1))
    fi
  done <<EOF
$TASKS
EOF
  OWNER_TASK=$names
  OWNER_NOTE=
  if [ "$own_n" -gt 1 ]; then
    OWNER_NOTE="several tasks ($names) are on that branch of $1"
  elif [ "$own_n" -eq 1 ]; then
    OWNER_TASK=$own
    [ "$own_head" = "$3" ] || OWNER_NOTE="its head commit is not $own's worktree HEAD"
  elif [ "$proven_n" -eq 1 ]; then
    OWNER_TASK=$proven
  elif [ "$proven_n" -gt 1 ]; then
    OWNER_NOTE="its head commit is in several tasks' clones ($names)"
  else
    OWNER_NOTE="its head commit is in no clone recorded for $names"
  fi
}

# 0 when <task>'s armed poll names exactly <url>; sets nothing else.
armed_for() {  # <task> <provider> <host> <path> <number>
  fm_pr_poll_artifacts_valid "$STATE" "$1" "$SCRIPT_DIR/fm-pr-poll.sh" || return 1
  [ "$FM_PR_DATA_PROVIDER" = "$2" ] && [ "$FM_PR_DATA_HOST" = "$3" ] \
    && [ "$FM_PR_DATA_PATH" = "$4" ] && [ "$FM_PR_DATA_NUMBER" = "$5" ]
}

action_check() {
  local branches repos repo json prs pr url branch sha task meta red armed_any handled
  local provider host path number out rc reason entry read_failed=0
  local -a wakes=() keys=() keep=()
  TASKS=$(task_rows)
  [ -n "$TASKS" ] || { record_write; return 0; }
  branches=$(printf '%s\n' "$TASKS" | cut -f2 | sort -u)
  repos=$(registered_repos)
  [ -n "$repos" ] || { record_write; return 0; }
  command -v gh >/dev/null 2>&1 || { log "gh not found; sweep skipped"; return 0; }
  command -v jq >/dev/null 2>&1 || { log "jq not found; sweep skipped"; return 0; }
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    rc=0
    json=$(fm_run_timed "$GH_TIMEOUT" gh pr list --repo "$repo" --state open --limit 100 \
      --json url,headRefName,headRefOid,isDraft,isCrossRepository 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ] || ! printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then
      read_failed=1
      if [ "$rc" -eq 124 ]; then
        log "reading open pull requests for $repo timed out; remaining repositories retried next sweep"
        break
      fi
      log "could not read open pull requests for $repo; retried next sweep"
      continue
    fi
    prs=$(printf '%s' "$json" | jq -c --arg branches "$branches" '
      ($branches | split("\n") | map(select(. != ""))) as $names
      | .[] | select((.isDraft | not) and (.isCrossRepository | not) and (.headRefName as $b | $names | index($b)))
      | {url, branch: .headRefName, sha: (.headRefOid // "")}') || continue
    while IFS= read -r pr; do
      [ -n "$pr" ] || continue
      url=$(printf '%s' "$pr" | jq -r .url)
      branch=$(printf '%s' "$pr" | jq -r .branch)
      sha=$(printf '%s' "$pr" | jq -r .sha)
      fm_pr_url_parse "$url" || continue
      provider=$FM_PR_PROVIDER; host=$FM_PR_HOST; path=$FM_PR_PATH; number=$FM_PR_NUMBER
      case "$sha" in ''|*[!0-9a-f]*) continue ;; esac
      pr_owner "$repo" "$branch" "$sha"
      task=$OWNER_TASK
      handled=0
      for entry in ${task//,/ }; do
        if armed_for "$entry" "$provider" "$host" "$path" "$number" \
          || fm_pr_poll_merge_already_notified "$STATE" "$entry" "$provider" "$host" "$path" "$number"; then
          handled=1
        fi
      done
      [ "$handled" -eq 0 ] || continue
      # Green only by the shared rule, and never on an empty rollup. The
      # rollup is read for this candidate alone, together with its head; an
      # unreadable rollup, or one for a head other than the listed one, is
      # treated as not green and reconsidered next sweep.
      rc=0
      pr=$(fm_run_timed "$GH_TIMEOUT" gh pr view "$url" --json headRefOid,statusCheckRollup 2>/dev/null) || rc=$?
      if [ "$rc" -ne 0 ]; then
        read_failed=1
        if [ "$rc" -eq 124 ]; then
          log "reading checks for $url timed out; remaining reads retried next sweep"
          break 2
        fi
        log "could not read checks for $url; retried next sweep"
        continue
      fi
      printf '%s' "$pr" | jq -e --arg sha "$sha" '.headRefOid == $sha' >/dev/null || continue
      printf '%s' "$pr" | jq -e '(.statusCheckRollup | type) == "array" and (.statusCheckRollup | length) > 0' >/dev/null || continue
      red=$(fm_pr_github_checks_not_green "$pr") || continue
      [ -z "$red" ] || continue
      if [ -n "$OWNER_NOTE" ]; then
        keep+=("$task $url")
        seen "$task $url" && continue
        wakes+=("check: pr-sweep: green PR $url on branch $branch was not armed: $OWNER_NOTE; arm it with bin/fm-pr-check.sh <task> $url only if it is that task's PR and its merge is authorized")
        keys+=("pr-sweep-$repo-$branch")
        continue
      fi
      meta="$STATE/$task.meta"
      armed_any=0
      fm_pr_poll_artifacts_valid "$STATE" "$task" "$SCRIPT_DIR/fm-pr-poll.sh" && armed_any=1
      if [ "$(fm_meta_get "$meta" yolo)" = on ] && [ "$armed_any" -eq 0 ]; then
        rc=0
        out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$FM_ROOT" \
          fm_run_timed "$ARM_TIMEOUT" "$SCRIPT_DIR/fm-pr-check.sh" "$task" "$url" 2>&1) || rc=$?
        if [ "$rc" -eq 0 ]; then
          log "armed merge poll for $task from its green PR at its own commit: $url"
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
