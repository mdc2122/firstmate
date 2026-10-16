#!/usr/bin/env bash
# fm-merge-line.sh - the one owner of per-repository merge lines.
#
# A merge line is an ordered list of armed PRs for one repository that lands
# them one at a time, in order. While a repository has a declared line, only
# the head of that line may merge directly: bin/fm-watch.sh's yolo merge poll
# and its behind-base rerun steer act only on the head, and bin/fm-pr-merge.sh
# refuses any other PR of that repository (so an attended merge goes through
# the same order; move the PR to the head first with `front`). A PR behind the
# head stays armed and green but neither merges nor gets rerun-steered until it
# reaches the head; it keeps its own green-unmergeable episode. A repository
# with no declared line behaves exactly as if this script did not exist.
#
# QUEUE WINDOW. Because a base branch whose effective rules require a
# merge-queue app's own check cannot merge directly at all (bin/fm-pr-merge.sh
# hands such a PR to its queue through GitHub auto-merge), the queue, not the
# line, serializes there: once the line's head has been handed to that queue
# (its task's state/<id>.queue-merge records the request), the first
# FM_MERGE_LINE_QUEUE_WINDOW (default 3) listed armed entries starting at the
# head may each be handed to the queue as well, in line order, so the queue
# holds the order and starts each test the moment its predecessor lands.
# `gate --window` admits exactly those entries, and each only once every
# earlier entry of the window that reads green or still pending (the queue
# app's own check included), or cannot be read, is already queued, so the
# queue never receives an entry ahead of one before it that may yet go green,
# whatever order the watcher visits them in; only an earlier red, ejected,
# closed, or merged entry is skipped. The window opens only behind a
# queued head: with the head not queued, or a window size of 1, the single-head
# gate above is the whole contract. A fronted entry that no queue holds blocks
# the window behind it exactly as it blocks the head, so a constraint PR
# fronted during a freeze is never overtaken. A queue ejection, a red entry,
# or an entry no poll arms simply never lands from the window; the queue and
# the watcher's own episode wakes report it, and the next entry arms instead.
#
# Repository identity is bin/fm-pr-lib.sh's provider-tagged identity
# (provider, host, path), derived from a canonical PR URL or a repository URL
# (https://github.com/<owner>/<repo>, or https://<gitlab-host>/<group>/.../<project>).
#
# RECORD (state/merge-lines/<provider>@<host>@<path with / as %2F>; private,
# mode 0600, single-link, atomically replaced; written only by this script):
#   fm-merge-line-v1
#   <provider> <host> <path>
#   <canonical PR URL>[ front]  one per line, head first, no duplicates;
#                               " front" marks an entry placed by `front`
# A record that does not parse exactly, or whose entries do not belong to its
# repository, refuses every gate for that repository rather than opening it.
#
# ORDER. Arming order by default: bin/fm-pr-check.sh enqueues every PR it arms
# at the tail of its repository's line (a no-op without a line, and for a PR
# already listed, so a re-arm keeps its place). `declare` seeds a new line with
# the repository's already-armed PRs in arming order (each task's
# state/<id>.pr-poll-registration mtime). `front` moves a PR to the head in one
# command, adding it when it is not listed yet.
#
# HEAD. The effective head is the first listed PR that is either fronted or
# armed by some task's merge poll (state/<id>.pr-poll names it). A fronted
# entry is sticky: it holds the line even before any poll arms it, so a
# constraint PR fronted during a freeze is never overtaken by an armed green PR
# behind it. An ordinary arming-order entry no poll arms, such as a PR whose
# task was cleaned up unmerged, is skipped rather than blocking the line, and
# `show` marks it. A PR of a lined repository that is not listed is held, never
# merged out of order.
#
# LEAVING. A PR leaves its line, sticky or not, when it merges (the watcher
# removes it when its poll retires on a landed merge, or when `probe` reads the
# head merged), when it closes unmerged (the watcher drops a closed head and
# wakes firstmate at once), or by `remove`. The next listed entry becomes the
# head, and a merged head hands off at once: bin/fm-watch.sh's
# merge_line_handoff runs the new head's yolo merge attempt in the same sweep
# that saw the old head land, through the same gate, so the order and
# one-at-a-time landing are unchanged and only the idle wait for a later sweep
# goes. bin/fm-watch.sh's merge_line_stall_tick owns the stall wake: once per
# episode when a PR held behind the head is green and that head has not
# changed for FM_MERGE_LINE_STALL_SECS (default 30 minutes).
#
# LOCK. Every mutation holds the away-posture record's cross-subsystem
# authority lock (bin/fm-afk-contract.sh owns it). bin/fm-pr-merge.sh already
# holds that lock across its final authority read and the forge merge command,
# and re-runs `gate` inside that critical section, so a reorder can never land
# between the gate and the merge it allowed. Lock order is the per-task control
# lock, then this lock, matching the merge path. `gate` and `show` take no lock.
#
# Usage:
#   fm-merge-line.sh declare <repo-or-pr-url>   start a line (seeded with armed PRs)
#   fm-merge-line.sh undeclare <repo-or-pr-url> drop the line; the repository merges as before
#   fm-merge-line.sh show [<repo-or-pr-url>]    print line(s): position, URL, task, armed state
#   fm-merge-line.sh front <pr-url>             move (or add) the PR to the head
#   fm-merge-line.sh enqueue <pr-url>           append at the tail if lined and not listed
#   fm-merge-line.sh remove <pr-url>            drop the PR from its line
#   fm-merge-line.sh gate [--window] <pr-url> exit 0 when the PR may merge now
#                                               (no line, the head, or - with
#                                               --window on a merge-queue-app
#                                               base whose head is queued -
#                                               one of the first
#                                               FM_MERGE_LINE_QUEUE_WINDOW
#                                               armed entries); exit 3 and
#                                               print why when it is held;
#                                               exit 1 on an unreadable line
#   fm-merge-line.sh head [--window] <pr-or-repo-url>
#                                               print the effective head URL (empty when none),
#                                               or with --window the first window entry, which
#                                               skips an ejected head; exit 2 without a line,
#                                               1 on an unreadable line
#   fm-merge-line.sh probe <pr-url>             read-only forge read printing one word:
#                                               merged, closed, green (open, every check
#                                               green), or open; nothing when unknown
set -u

FM_MERGE_LINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_MERGE_LINE_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LINES="$STATE/merge-lines"
FM_MERGE_LINE_HELD=3

# shellcheck source=bin/fm-pr-lib.sh
. "$FM_MERGE_LINE_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_MERGE_LINE_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$FM_MERGE_LINE_DIR/fm-afk-contract.sh"

die() { printf 'fm-merge-line: %s\n' "$*" >&2; exit "${2:-1}"; }
usage() {
  sed -n '/^# Usage:/,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

REPO_PROVIDER=
REPO_HOST=
REPO_PATH=
LINE_FILE=

# Resolve a canonical PR URL or a repository URL to the repository identity
# and its line path. A repository URL is checked by rebuilding a PR URL from it
# and passing that through the one canonical parser.
resolve_repo() {  # <url>
  local raw=${1-} probe
  if ! fm_pr_url_parse "$raw"; then
    case "$raw" in
      https://github.com/*) probe="$raw/pull/1" ;;
      https://*/*) probe="$raw/-/merge_requests/1" ;;
      *) return 1 ;;
    esac
    fm_pr_url_parse "$probe" || return 1
  fi
  REPO_PROVIDER=$FM_PR_PROVIDER
  REPO_HOST=$FM_PR_HOST
  REPO_PATH=$FM_PR_PATH
  LINE_FILE="$LINES/$REPO_PROVIDER@$REPO_HOST@${REPO_PATH//\//%2F}"
}

# Parse a PR URL that must be a canonical PR of the resolved repository.
pr_in_repo() {  # <url>
  fm_pr_url_parse "${1-}" || return 1
  [ "$FM_PR_PROVIDER" = "$REPO_PROVIDER" ] && [ "$FM_PR_HOST" = "$REPO_HOST" ] \
    && [ "$FM_PR_PATH" = "$REPO_PATH" ]
}

ENTRIES=()
FRONTED=' '
# Read LINE_FILE into ENTRIES and the fronted (sticky) set into FRONTED. Returns 2 when the line is absent, 1 when it is
# present but unreadable or malformed.
read_line() {
  local version repo line url flag state_device seen=' '
  ENTRIES=()
  FRONTED=' '
  [ -e "$LINE_FILE" ] || [ -L "$LINE_FILE" ] || return 2
  state_device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_private_file_valid "$LINE_FILE" 600 "$state_device" || return 1
  exec 9< "$LINE_FILE" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r repo <&9 || { exec 9<&-; return 1; }
  [ "$version" = fm-merge-line-v1 ] \
    && [ "$repo" = "$REPO_PROVIDER $REPO_HOST $REPO_PATH" ] || { exec 9<&-; return 1; }
  while IFS= read -r line <&9; do
    url=${line%% *}
    flag=${line#"$url"}
    case "$flag" in
      '') ;;
      ' front') FRONTED="$FRONTED$url " ;;
      *) exec 9<&-; return 1 ;;
    esac
    pr_in_repo "$url" || { exec 9<&-; return 1; }
    case "$seen" in *" $url "*) exec 9<&-; return 1 ;; esac
    seen="$seen$url "
    ENTRIES+=("$url")
  done
  exec 9<&-
  return 0
}

write_line() {
  local tmp url state_device
  [ ! -L "$LINES" ] || return 1
  mkdir -p "$LINES" || return 1
  [ -d "$LINES" ] && [ ! -L "$LINES" ] || return 1
  state_device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$LINE_FILE" "$state_device" || return 1
  umask 077
  tmp=$(mktemp "$LINES/.line.XXXXXX") || return 1
  if ! {
      printf 'fm-merge-line-v1\n%s %s %s\n' "$REPO_PROVIDER" "$REPO_HOST" "$REPO_PATH"
      for url in ${ENTRIES[@]+"${ENTRIES[@]}"}; do
        if fronted "$url"; then printf '%s front\n' "$url"; else printf '%s\n' "$url"; fi
      done
    } > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! mv -f -- "$tmp" "$LINE_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Every task merge poll arming a PR of the resolved repository, one
# "<registration-mtime> <url> <task-id>" line each.
armed_polls() {
  local data id reg mtime
  for data in "$STATE"/*.pr-poll; do
    [ -f "$data" ] && [ ! -L "$data" ] || continue
    id=${data##*/}
    id=${id%.pr-poll}
    fm_pr_task_id_valid "$id" || continue
    fm_pr_poll_data_parse "$data" || continue
    [ "$FM_PR_DATA_PROVIDER" = "$REPO_PROVIDER" ] && [ "$FM_PR_DATA_HOST" = "$REPO_HOST" ] \
      && [ "$FM_PR_DATA_PATH" = "$REPO_PATH" ] || continue
    reg="$STATE/$id.pr-poll-registration"
    mtime=$(fm_path_mtime "$reg") || mtime=0
    printf '%s %s %s\n' "${mtime:-0}" "$FM_PR_DATA_URL" "$id"
  done
}

ARMED=
load_armed() { ARMED=$(armed_polls); }
armed_task() {  # <url>
  printf '%s\n' "$ARMED" | awk -v u="$1" '$2 == u { print $3; exit }'
}

lock_line() {
  fm_afk_contract_lock_hold "$STATE" || die "could not take the merge authority lock; nothing was changed"
  trap 'fm_afk_contract_lock_release || true' EXIT
}

# Mutations: resolve, lock, read (an absent line refuses unless declaring).
# With <skip-absent> 1, a repository with no line returns before taking the
# lock, so arming and retiring PRs of an unlined repository touch nothing.
begin_mutation() {  # <url> <require-pr: 0|1> [skip-absent: 0|1]
  local rc=0
  if [ "$2" = 1 ]; then
    fm_pr_url_parse "${1-}" || die "not a canonical PR URL: ${1-}" 2
  fi
  resolve_repo "${1-}" || die "not a canonical PR or repository URL: ${1-}" 2
  if [ "${3:-0}" = 1 ] && [ ! -e "$LINE_FILE" ] && [ ! -L "$LINE_FILE" ]; then
    return 2
  fi
  lock_line
  read_line || rc=$?
  case "$rc" in
    0) ;;
    2) return 2 ;;
    *) die "the merge line at $LINE_FILE is unreadable; nothing was changed" ;;
  esac
}

place() {  # <url> <1-based position>
  local url=$1 pos=$2 e out=() i=1 placed=0
  for e in ${ENTRIES[@]+"${ENTRIES[@]}"}; do
    [ "$e" != "$url" ] || continue
    if [ "$i" -eq "$pos" ]; then out+=("$url"); placed=1; i=$((i + 1)); fi
    out+=("$e")
    i=$((i + 1))
  done
  [ "$placed" -eq 1 ] || out+=("$url")
  ENTRIES=(${out[@]+"${out[@]}"})
}

fronted() {  # <url>
  case "$FRONTED" in *" $1 "*) return 0 ;; esac
  return 1
}

listed() {  # <url>
  local e
  for e in ${ENTRIES[@]+"${ENTRIES[@]}"}; do [ "$e" != "$1" ] || return 0; done
  return 1
}

repo_label() { printf '%s/%s' "$REPO_HOST" "$REPO_PATH"; }

cmd_declare() {
  local rc=0 mtime url id
  begin_mutation "${1-}" 0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'merge line for %s already declared\n' "$(repo_label)"
    return 0
  fi
  ENTRIES=()
  while read -r mtime url id; do
    [ -n "$url" ] || continue
    listed "$url" || ENTRIES+=("$url")
  done < <(armed_polls | LC_ALL=C sort -n -k1,1 -k3,3)
  write_line || die "could not write the merge line"
  printf 'declared merge line for %s with %s armed PR(s)\n' "$(repo_label)" "${#ENTRIES[@]}"
}

cmd_undeclare() {
  local rc=0
  begin_mutation "${1-}" 0 || rc=$?
  [ "$rc" -eq 0 ] || { printf 'no merge line for %s\n' "$(repo_label)"; return 0; }
  rm -f -- "$LINE_FILE" || die "could not remove the merge line"
  printf 'removed merge line for %s; its PRs merge as without a line\n' "$(repo_label)"
}

cmd_front() {  # <pr-url>
  local url=${1-} rc=0
  begin_mutation "$url" 1 || rc=$?
  [ "$rc" -eq 0 ] || die "no merge line is declared for $(repo_label); declare one first"
  place "$url" 1
  fronted "$url" || FRONTED="$FRONTED$url "
  write_line || die "could not write the merge line"
  cmd_show_one
}

cmd_enqueue() {
  local url=${1-} rc=0
  begin_mutation "$url" 1 1 || rc=$?
  [ "$rc" -eq 0 ] || return 0
  listed "$url" && return 0
  ENTRIES+=("$url")
  write_line || die "could not write the merge line"
}

cmd_remove() {
  local url=${1-} rc=0 e out=()
  begin_mutation "$url" 1 1 || rc=$?
  [ "$rc" -eq 0 ] || return 0
  listed "$url" || return 0
  for e in "${ENTRIES[@]}"; do [ "$e" = "$url" ] || out+=("$e"); done
  ENTRIES=(${out[@]+"${out[@]}"})
  FRONTED=${FRONTED/ $url / }
  write_line || die "could not write the merge line"
}

# First listed PR that is fronted (sticky) or that some task's poll arms.
effective_head() {
  local e
  for e in ${ENTRIES[@]+"${ENTRIES[@]}"}; do
    if fronted "$e" || [ -n "$(armed_task "$e")" ]; then
      printf '%s' "$e"
      return 0
    fi
  done
  return 1
}

# The window: the first FM_MERGE_LINE_QUEUE_WINDOW eligible entries starting
# at the effective head, one per line. An entry is eligible when a task's poll
# arms it or it is fronted; an entry whose task's queue record reads ejected
# is skipped, not re-armed. A fronted entry the queue does not hold is listed
# and ends the listing: the queue holds nothing behind a fronted entry it does
# not hold, so a constraint PR fronted during a freeze is never overtaken.
# Whether the window is open at all (the head is queued) is the caller's
# check, not this listing's.
FM_MERGE_LINE_QUEUE_WINDOW=${FM_MERGE_LINE_QUEUE_WINDOW:-3}
case "$FM_MERGE_LINE_QUEUE_WINDOW" in
  ''|*[!0-9]*|0|1) FM_MERGE_LINE_QUEUE_WINDOW=1 ;;
esac
queue_recorded() {  # <url> <status>
  local id
  id=$(armed_task "$1")
  [ -n "$id" ] || return 1
  fm_pr_queue_merge_record_read "$STATE" "$id" || return 1
  [ "$FM_PR_QUEUE_MERGE_URL" = "$1" ] && [ "$FM_PR_QUEUE_MERGE_STATUS" = "$2" ]
}
queued_head() {  # <url>
  queue_recorded "$1" requested
}
window_entries() {
  local e n=0
  for e in ${ENTRIES[@]+"${ENTRIES[@]}"}; do
    if [ -n "$(armed_task "$e")" ]; then
      queue_recorded "$e" ejected && continue
      printf '%s\n' "$e"
      n=$((n + 1))
      fronted "$e" && ! queued_head "$e" && return 0
    elif fronted "$e"; then
      printf '%s\n' "$e"
      n=$((n + 1))
      return 0
    else
      continue
    fi
    [ "$n" -lt "$FM_MERGE_LINE_QUEUE_WINDOW" ] || return 0
  done
}

# Whether a window entry ahead of another must reach the queue first: it reads
# open with every check green or still pending, or it cannot be read. A red,
# closed, or merged entry does not. A not-green check name is pending when its
# current run is: a status context still PENDING or EXPECTED with no failed
# context of that name, or a check run not yet completed that started after
# every completed red run of that name (one not yet started counts as newest),
# so a run cancelled before its re-run does not mark the re-run red.
window_waits_for() {  # <url>
  local json state red names pending
  fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ] || return 0
  json=$(gh pr view "$FM_PR_URL" --json state,statusCheckRollup 2>/dev/null </dev/null) || return 0
  state=$(printf '%s' "$json" | jq -r 'if type == "object" then (.state // "") else "" end' 2>/dev/null) || return 0
  case "$state" in
    OPEN) ;;
    MERGED|CLOSED) return 1 ;;
    *) return 0 ;;
  esac
  red=$(fm_pr_github_checks_not_green "$json") || return 0
  [ -n "$red" ] || return 0
  names=$(printf '%s\n' "$red" | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null) || return 0
  pending=$(printf '%s' "$json" | jq -r --argjson names "$names" '
    .statusCheckRollup as $reported
    | $names[]
    | . as $name
    | [$reported[] | select((if .__typename == "CheckRun" then .name else .context end) == $name)] as $runs
    | ([$runs[] | select(.__typename == "CheckRun" and .status == "COMPLETED"
          and ((.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED") | not))
        | (.startedAt // "")] | max // "") as $last_red
    | select(
        ([$runs[] | select(.__typename != "CheckRun"
            and .state != "SUCCESS" and .state != "PENDING" and .state != "EXPECTED")] | length) == 0
        and any($runs[];
          if .__typename == "CheckRun"
          then .status != "COMPLETED" and ((.startedAt // "~") > $last_red)
          else .state == "PENDING" or .state == "EXPECTED" end))
    | $name
  ' 2>/dev/null) || return 0
  red=$(printf '%s\n' "$red" | awk -v pending="$pending" '
    BEGIN { n = split(pending, p, "\n"); for (i = 1; i <= n; i++) skip[p[i]] = 1 }
    !($0 in skip)')
  [ -z "$red" ]
}

cmd_gate() {  # [--window] <url>
  local mode='' url rc=0 head e admitted=''
  if [ "${1-}" = --window ]; then
    mode=--window
    shift
  fi
  url=${1-}
  fm_pr_url_parse "$url" || die "not a canonical PR URL: $url" 2
  resolve_repo "$url" || die "not a canonical PR URL: $url" 2
  read_line || rc=$?
  case "$rc" in
    0) ;;
    2) return 0 ;;
    *) printf 'held: the merge line for %s is unreadable; nothing in it merges until it is fixed\n' "$(repo_label)"; return 1 ;;
  esac
  if ! listed "$url"; then
    printf 'held: %s is not in the merge line for %s; add it with fm-merge-line.sh front\n' "$url" "$(repo_label)"
    return "$FM_MERGE_LINE_HELD"
  fi
  load_armed
  head=$(effective_head) || head=
  [ "$head" = "$url" ] && return 0
  if [ "$mode" = --window ]; then
    if [ -z "$head" ] || ! queued_head "$head"; then
      printf 'held: %s waits behind %s in the merge line for %s; its head is not in a merge queue\n' \
        "$url" "${head:-<none armed>}" "$(repo_label)"
      return "$FM_MERGE_LINE_HELD"
    fi
    while IFS= read -r e; do
      [ "$e" = "$url" ] && admitted=1 && break
      queued_head "$e" && continue
      if ( window_waits_for "$e" ); then
        printf 'held: %s waits for %s ahead of it in the merge line for %s to reach the merge queue first\n' \
          "$url" "$e" "$(repo_label)"
        return "$FM_MERGE_LINE_HELD"
      fi
    done < <(window_entries)
    [ "$admitted" = 1 ] && return 0
    printf 'held: %s is outside the queue window (first %s) of the merge line for %s\n' \
      "$url" "$FM_MERGE_LINE_QUEUE_WINDOW" "$(repo_label)"
    return "$FM_MERGE_LINE_HELD"
  fi
  printf 'held: %s waits behind %s in the merge line for %s\n' "$url" "${head:-<none armed>}" "$(repo_label)"
  return "$FM_MERGE_LINE_HELD"
}

cmd_head() {  # [--window] <url>
  local rc=0 window=''
  if [ "${1-}" = --window ]; then
    window=1
    shift
  fi
  resolve_repo "${1-}" || die "not a canonical PR or repository URL: ${1-}" 2
  read_line || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  load_armed
  if [ -n "$window" ]; then
    window_entries | sed -n 1p | tr -d '\n'
  else
    effective_head || true
  fi
  printf '\n'
}

# Read-only: one forge read classifying a PR for the watcher's stall tick.
# Silent on any failed or unreadable read, so an unknown never drops a head or
# opens a stall episode.
cmd_probe() {
  local url=${1-} json fields state red pipeline
  fm_pr_url_parse "$url" || return 0
  command -v jq >/dev/null 2>&1 || return 0
  case "$FM_PR_PROVIDER" in
    github)
      command -v gh >/dev/null 2>&1 || return 0
      json=$(gh pr view "$FM_PR_URL" --json state,statusCheckRollup 2>/dev/null) || return 0
      state=$(printf '%s' "$json" | jq -r 'if type == "object" then (.state // "") else "" end' 2>/dev/null) || return 0
      case "$state" in
        MERGED) echo merged ;;
        CLOSED) echo closed ;;
        OPEN)
          red=$(fm_pr_github_checks_not_green "$json") || return 0
          if [ -z "$red" ]; then echo green; else echo open; fi
          ;;
      esac
      ;;
    gitlab)
      command -v glab >/dev/null 2>&1 || return 0
      json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$FM_PR_NUMBER" \
        -R "https://$FM_PR_HOST/$FM_PR_PATH" -F json 2>/dev/null) || return 0
      fields=$(printf '%s' "$json" | jq -r \
        'if type == "object" then ((.state // "") + " " + (.head_pipeline.status // "none")) else error("x") end' \
        2>/dev/null) || return 0
      state=${fields%% *}
      pipeline=${fields#* }
      case "$state" in
        merged) echo merged ;;
        closed) echo closed ;;
        opened) if [ "$pipeline" = success ]; then echo green; else echo open; fi ;;
      esac
      ;;
  esac
}

cmd_show_one() {
  local e i=1 task head
  load_armed
  head=$(effective_head) || head=
  printf 'merge line %s\n' "$(repo_label)"
  for e in ${ENTRIES[@]+"${ENTRIES[@]}"}; do
    task=$(armed_task "$e")
    if [ "$e" = "$head" ]; then
      printf '  %s. %s task=%s head%s\n' "$i" "$e" "${task:--}" "$(fronted "$e" && printf ' fronted')"
    elif [ -n "$task" ] || fronted "$e"; then
      printf '  %s. %s task=%s held\n' "$i" "$e" "${task:--}"
    else
      printf '  %s. %s not-armed (skipped)\n' "$i" "$e"
    fi
    i=$((i + 1))
  done
}

cmd_show() {
  local rc=0 f repo version
  if [ "$#" -gt 0 ]; then
    resolve_repo "$1" || die "not a canonical PR or repository URL: $1" 2
    read_line || rc=$?
    case "$rc" in
      0) cmd_show_one ;;
      2) printf 'no merge line for %s\n' "$(repo_label)" ;;
      *) die "the merge line at $LINE_FILE is unreadable" ;;
    esac
    return 0
  fi
  for f in "$LINES"/*@*@*; do
    [ -f "$f" ] || continue
    { IFS= read -r version; IFS= read -r repo; } < "$f" || continue
    [ "$version" = fm-merge-line-v1 ] || { printf 'unreadable merge line %s\n' "$f"; continue; }
    read -r REPO_PROVIDER REPO_HOST REPO_PATH <<< "$repo"
    LINE_FILE=$f
    if read_line; then cmd_show_one; else printf 'unreadable merge line %s\n' "$f"; fi
  done
}

main() {
  local cmd=${1-}
  [ -n "$cmd" ] || { usage >&2; exit 2; }
  shift
  case "$cmd" in
    gate|head)
      { [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "$1" = --window ]; }; } \
        || { usage >&2; exit 2; } ;;
    declare|undeclare|front|enqueue|remove|probe)
      [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
    show) [ "$#" -le 1 ] || { usage >&2; exit 2; } ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  case "$cmd" in
    declare) cmd_declare "$@" ;;
    undeclare) cmd_undeclare "$@" ;;
    front) cmd_front "$@" ;;
    enqueue) cmd_enqueue "$@" ;;
    remove) cmd_remove "$@" ;;
    gate) cmd_gate "$@" ;;
    head) cmd_head "$@" ;;
    probe) cmd_probe "$@" ;;
    show) cmd_show "$@" ;;
  esac
}

main "$@"
