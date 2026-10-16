#!/usr/bin/env bash
# fm-resume-watch.sh - the one owner of a task's resume watch: a deterministic
# condition->action watch (bin/fm-procevent-when.sh) that resumes a worker
# waiting on its own PR once that PR merges, or once its merge is live, with no
# firstmate turn.
#
# Usage:
#   fm-resume-watch.sh arm    <task-id> <pr-url> [merged|live]
#   fm-resume-watch.sh retire <task-id>
#   fm-resume-watch.sh form   <task-id> <pr-url>
#   fm-resume-watch.sh name   <task-id>
#
# arm     Bind watch `resume-<home>-<task-id>`, where <home> is the first 8 hex
#         of a SHA-256 of this home's physical state directory: process-event
#         ownership is keyed by source id across every home sharing one claim
#         root, so two homes with the same task id must not share a source. A
#         task id longer than 43 characters keeps its first 26 and gains a
#         16-hex hash of the whole id, because a source id is capped at 64.
#         Condition: `bin/fm-resume-cond.sh pr-merged <pr-url>`, or for `live`
#         `bin/fm-resume-cond.sh pr-live <pr-url> <repo-dir> <pointer-file>`.
#         Action: `bin/fm-resume-action.sh <home> <state> <task-id> <pr-url>
#         <form>`, which re-checks that the task is still waiting on that PR
#         and sends one fixed-template `Resume fact (watch): ...` steer through
#         bin/fm-send.sh. The home and state directory travel in the action's
#         argv because the `when` runner injects neither.
#         Without a form argument the selection rule below picks one. Arming
#         the same task again for the same PR and form is a no-op, whether the
#         watch is still polling or has already ended, so a re-run of
#         bin/fm-pr-check.sh can never resume a worker twice; arming it for a
#         different PR or form retires the old watch first. bin/fm-pr-check.sh
#         arms one for every PR it registers.
# retire  Retire the task's watch through bin/fm-procevent-when.sh retire and
#         remove this script's own record. Idempotent, and a task that never had
#         a watch is a no-op that touches nothing. bin/fm-teardown.sh retires it.
#         A watch also stops by itself: it fires at most once, and every `when`
#         outcome is terminal, so the runner retires its registration as soon
#         as it captures the outcome; retire then only clears the private
#         records left behind.
# form    Print the form the selection rule picks for this task and PR.
# name    Print the watch name (the `when` name, without the `when-` prefix).
#
# Selection rule. `live` applies only to a PR whose repository has a configured
# release pointer AND whose task brief's `verify:` line (bin/fm-dod-lib.sh
# fm_brief_verify_observation, read from data/<task-id>/brief.md) names a live
# surface: one of the whole words production, prod, deployed, or live, in any
# case. Every other PR uses `merged`. An explicit `live` for a repository with
# no configured pointer is refused.
#
# Release pointers come from config/resume-live-pointers, whose schema
# docs/configuration.md "Resume watch release pointers" owns.
#
# Cadence, overridable per run for tests and tuning: FM_RESUME_WATCH_INTERVAL
# (60 seconds between condition polls), FM_RESUME_WATCH_STABLE (2 consecutive
# true polls), FM_RESUME_WATCH_DEADLINE (172800 seconds before the watch gives up
# as never-true), and FM_RESUME_WATCH_ERROR_BUDGET (5 consecutive condition
# errors). A PR closed unmerged is a condition error on every poll, so it ends
# the watch in condition-error after that budget with nothing sent.
#
# Outcomes. A `fired` outcome whose action is bin/fm-resume-action.sh is a
# routine success: bin/fm-procevent-when.sh's `silent` command makes the runner
# record it handled without a wake, while the captured result, the worker's
# inbox record, and the supervisor action ledger row (origin
# fm-resume-action.sh) remain as the record. Every other outcome - the task no
# longer waiting (action-failed), a closed-unmerged PR (condition-error), a
# deadline (never-true), ambiguous, or rejected - still wakes firstmate.
#
# Private record: state/<task-id>.resume-watch names the watch, PR, and form the
# task's watch was armed for; this script alone writes and removes it, writes it
# before arming, and retires exactly the watch it names.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,69p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

RECORD_VERSION=fm-resume-watch-v1

sha256_hex() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

watch_name() {  # <task-id>
  local id=$1 state_real home_digest id_digest
  state_real=$(cd "$STATE" 2>/dev/null && pwd -P) || return 1
  home_digest=$(sha256_hex "$state_real")
  [[ "$home_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  if [ "${#id}" -le 43 ]; then
    printf 'resume-%s-%s\n' "${home_digest:0:8}" "$id"
    return 0
  fi
  id_digest=$(sha256_hex "$id")
  [[ "$id_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'resume-%s-%s-%s\n' "${home_digest:0:8}" "${id:0:26}" "${id_digest:0:16}"
}

record_file() { printf '%s/%s.resume-watch\n' "$STATE" "$1"; }

# record_read <task-id>: set RECORD_NAME, RECORD_URL, and RECORD_FORM; return 1
# when absent or malformed.
record_read() {
  local file version name url form extra
  RECORD_NAME='' RECORD_URL='' RECORD_FORM=''
  file=$(record_file "$1")
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  {
    IFS= read -r version && IFS= read -r name && IFS= read -r url && IFS= read -r form \
      && ! IFS= read -r extra
  } < "$file" || return 1
  [ "$version" = "$RECORD_VERSION" ] || return 1
  case "$name" in name=resume-*) RECORD_NAME=${name#name=} ;; *) return 1 ;; esac
  fm_task_id_path_safe "when-$RECORD_NAME" && [ "${#RECORD_NAME}" -le 59 ] || return 1
  case "$url" in url=*) RECORD_URL=${url#url=} ;; *) return 1 ;; esac
  case "$form" in form=merged|form=live) RECORD_FORM=${form#form=} ;; *) return 1 ;; esac
}

record_write() {  # <task-id> <name> <url> <form>
  local file tmp
  file=$(record_file "$1")
  tmp=$(umask 077; mktemp "$STATE/.resume-watch.XXXXXX") || return 1
  printf '%s\nname=%s\nurl=%s\nform=%s\n' "$RECORD_VERSION" "$2" "$3" "$4" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$file" && return 0
  rm -f -- "$tmp"
  return 1
}

# repo_url: the repository URL of the PR fm_pr_url_parse just parsed.
repo_url() {
  case "$FM_PR_PROVIDER" in
    github) printf 'https://github.com/%s\n' "$FM_PR_PATH" ;;
    gitlab) printf 'https://%s/%s\n' "$FM_PR_HOST" "$FM_PR_PATH" ;;
  esac
}

# pointer_for <repository-url>: set POINTER_REPO and POINTER_FILE from the first
# matching config/resume-live-pointers line; return 1 when none matches.
pointer_for() {
  local want=$1 file="$CONFIG/resume-live-pointers" line repo dir pointer extra
  POINTER_REPO='' POINTER_FILE=''
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    read -r repo dir pointer extra <<< "$line"
    [ -n "$repo" ] || continue
    [ "$repo" = "$want" ] || continue
    [ -z "$extra" ] || return 1
    case "$dir" in /*) ;; *) return 1 ;; esac
    case "$pointer" in /*) ;; *) return 1 ;; esac
    POINTER_REPO=$dir
    POINTER_FILE=$pointer
    return 0
  done < "$file"
  return 1
}

# verify_names_live <task-id>: 0 when the brief's verify observation names a
# live surface (see the selection rule in the header).
verify_names_live() {
  local brief="$DATA/$1/brief.md" observation
  [ -f "$brief" ] || return 1
  # shellcheck source=bin/fm-dod-lib.sh
  . "$SCRIPT_DIR/fm-dod-lib.sh"
  observation=$(fm_brief_verify_observation "$brief") || return 1
  printf '%s\n' "$observation" | LC_ALL=C grep -qiE '(^|[^[:alnum:]_])(production|prod|deployed|live)([^[:alnum:]_]|$)'
}

parse_task_and_url() {  # <task-id> <pr-url>
  fm_pr_task_id_valid "${1-}" || die "invalid task id: ${1-}" 2
  fm_pr_url_parse "${2-}" && [ "$FM_PR_URL" = "${2-}" ] || die "not a canonical PR URL: ${2-}" 2
}

select_form() {  # <task-id>  (after parse_task_and_url)
  if pointer_for "$(repo_url)" && verify_names_live "$1"; then
    printf 'live\n'
  else
    printf 'merged\n'
  fi
}

LOCK=''
lock_task() {  # <task-id>
  LOCK="$STATE/.resume-watch-$1.lock"
  fm_lock_acquire_wait "$LOCK" || die "cannot lock the resume watch for $1"
  trap 'fm_lock_release "$LOCK" 2>/dev/null || true' EXIT
}

when_cmd() { FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-procevent-when.sh" "$@"; }

# retire_locked <task-id>: retire the watch the task's record names, then drop
# the record; 1 on failure. A task with no record never had a watch armed
# through this script (arm writes the record before it arms), so it is a no-op
# that reads nothing else and needs no tool beyond the shell.
retire_locked() {
  local id=$1 file
  file=$(record_file "$id")
  [ -e "$file" ] || [ -L "$file" ] || return 0
  record_read "$id" || return 1
  when_cmd retire "$RECORD_NAME" >/dev/null || return 1
  rm -f -- "$file"
}

cmd_arm() {
  local id url form='' name home state
  [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || usage
  parse_task_and_url "$1" "$2"
  id=$1 url=$2
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  [ -f "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || die "task $id has no record in this home"
  if [ "$#" -eq 3 ]; then
    form=$3
    case "$form" in merged|live) ;; *) usage ;; esac
  else
    form=$(select_form "$id")
  fi
  if [ "$form" = live ]; then
    pointer_for "$(repo_url)" \
      || die "no release pointer is configured for $(repo_url) in $CONFIG/resume-live-pointers; a live watch needs one"
  fi
  name=$(watch_name "$id") || die "cannot derive the watch name for $id"
  home=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || die "home is unavailable: $FM_HOME"
  state=$(cd "$STATE" 2>/dev/null && pwd -P) || die "state directory is unavailable"

  lock_task "$id"
  # The watch's spec survives its own terminal outcome until retire, so a
  # matching record with a spec present is a watch still polling or already
  # ended; either way it must not be armed again.
  if record_read "$id" && [ "$RECORD_NAME" = "$name" ] && [ "$RECORD_URL" = "$url" ] \
    && [ "$RECORD_FORM" = "$form" ] && [ -f "$STATE/when/when-$name.spec" ]; then
    printf 'already armed: resume watch when-%s for %s on %s (%s)\n' "$name" "$id" "$url" "$form"
    return 0
  fi
  retire_locked "$id" || die "cannot retire the previous resume watch for $id"
  # A leftover spec under this name without a record (an interrupted arm) is
  # retired too, so the arm below never meets stale state.
  if [ -e "$STATE/when/when-$name.spec" ] || [ -e "$STATE/procevent/when-$name.source" ]; then
    when_cmd retire "$name" >/dev/null || die "cannot retire the leftover resume watch for $id"
  fi
  record_write "$id" "$name" "$url" "$form" || die "cannot record the resume watch for $id"

  local -a cond=("$SCRIPT_DIR/fm-resume-cond.sh" pr-merged "$url")
  if [ "$form" = live ]; then
    cond=("$SCRIPT_DIR/fm-resume-cond.sh" pr-live "$url" "$POINTER_REPO" "$POINTER_FILE")
  fi
  if ! when_cmd arm "$name" \
    --interval "${FM_RESUME_WATCH_INTERVAL:-60}" \
    --stable "${FM_RESUME_WATCH_STABLE:-2}" \
    --deadline "${FM_RESUME_WATCH_DEADLINE:-172800}" \
    --error-budget "${FM_RESUME_WATCH_ERROR_BUDGET:-5}" \
    --condition "${cond[@]}" \
    --action "$SCRIPT_DIR/fm-resume-action.sh" "$home" "$state" "$id" "$url" "$form" >/dev/null; then
    retire_locked "$id" || true
    die "cannot arm the resume watch for $id"
  fi
  printf 'armed: resume watch when-%s for %s on %s (%s)\n' "$name" "$id" "$url" "$form"
}

cmd_retire() {
  local id=${1-}
  [ "$#" -eq 1 ] || usage
  fm_pr_task_id_valid "$id" || die "invalid task id: $id" 2
  [ -d "$STATE" ] || { printf 'retired: no resume watch for %s\n' "$id"; return 0; }
  if [ ! -e "$(record_file "$id")" ] && [ ! -L "$(record_file "$id")" ]; then
    printf 'retired: no resume watch for %s\n' "$id"
    return 0
  fi
  lock_task "$id"
  retire_locked "$id" || die "cannot retire the resume watch for $id"
  printf 'retired: resume watch for %s\n' "$id"
}

cmd_form() {
  [ "$#" -eq 2 ] || usage
  parse_task_and_url "$1" "$2"
  select_form "$1"
}

cmd_name() {
  [ "$#" -eq 1 ] || usage
  fm_pr_task_id_valid "$1" || die "invalid task id: $1" 2
  watch_name "$1"
}

case "${1-}" in
  arm)    shift; cmd_arm "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  form)   shift; cmd_form "$@" ;;
  name)   shift; cmd_name "$@" ;;
  *) usage ;;
esac
