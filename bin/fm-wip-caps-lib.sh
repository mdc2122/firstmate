# shellcheck shell=bash disable=SC2034 # FM_WIP_* outputs are read by the sourcing caller.
# fm-wip-caps-lib.sh - single owner of per-lane work-in-progress caps.
# Usage: . bin/fm-wip-caps-lib.sh (sourced by bin/fm-spawn.sh,
# bin/fm-promote.sh, and bin/fm-queue-zero.sh;
# it has no command of its own).
#
# WHY. Throughput comes from completion rate, not start rate. The baseline week
# (2026-10-09..16, the flow-wait-accounting report in the primary home's
# data/flow-wait-accounting/report.md, run run-2026-10-09_16) ran a median 11
# tasks in flight (p90 19, max 42) and accumulated 773 attributed wait-hours:
# merge_queue 293, release 213, ci 124. So each lane holds at most its cap, the
# next item is pulled only when one finishes, and idle capacity at a lane that
# is not the constraint is healthy: it is never backfilled to look busy.
#
# LANES. Every live task record in this home's state/*.meta holds exactly one
# lane slot, or none:
#   validations     a ship task with no recorded pull request yet (pr= unset):
#                   implementing and validating, up to the green PR; this lane
#                   also counts every host suite (HOST SUITES below)
#   merges          a ship task whose pull request is recorded (pr= set by
#                   bin/fm-pr-check.sh at its ready line) and whose merge outcome
#                   has not been delivered for that canonical PR identity
#                   (bin/fm-pr-lib.sh's merge-notified marker helpers)
#   reviews         a scout recorded with wip_lane=reviews, which bin/fm-spawn.sh
#                   writes for a scout dispatched from a backlog item of kind
#                   review
#   investigations  every other scout
# A secondmate holds no slot. A ship whose merge outcome was delivered holds
# none; every other task holds its slot until cleanup removes its record. A
# blocked, paused, parked, or decision-waiting task therefore still holds its
# slot, so a cap cannot be gamed by parking work. A local-only ship has no pull
# request and holds a validations slot until cleanup.
#
# HOST SUITES. Validation load is a machine resource, not a home one: full test
# suites started by secondmate homes, other agents on the host (for example
# pytest run by a board engineer), and no-mistakes pipelines under
# ~/.no-mistakes/worktrees are invisible to this home's records yet compete for
# the same CPU. So every scan also reads the host process table once
# (ps -Ao pid,ppid,args) and adds each live full-suite pytest run to the
# validations count, listed as pytest-<pid> [full test suite in <cwd>: <args>].
# A process is a pytest run when its command is pytest or py.test (directly or
# as the script a python interpreter runs) or python -m pytest. It is a full
# suite unless it targets a subset: a -k expression or any path argument other
# than a tests or test directory or "." (option values are not paths). A run
# is counted once: a match with a full-suite ancestor (an xdist worker, or a
# wrapper's re-invocation) folds into that ancestor. A suite whose working
# directory is inside the worktree of one of this home's validations tasks is
# that task's own and adds nothing more. Linux reads the working directory
# from /proc and macOS from lsof; an unknown one counts the suite as foreign.
# An unreadable process table adds nothing. FM_WIP_HOST_SUITES=off skips the
# host read; tests/lib.sh sets it so the suite's own runs never fill a lane.
#
# CAPS. The defaults below are the measured ones; the optional local, gitignored
# config/wip-caps overrides any of them, one `<lane>=<positive integer>` per
# line, with blank lines and # comments ignored. An unknown lane, a value that
# is not a positive integer, or an unreadable file is an error, never a silent
# default. The file is home-local and not inherited by secondmate homes.
# Lane occupancy below was sampled every 5 minutes from that run's tasks.csv
# and waits.csv (ship spawn -> first green for validations, scout spawn -> end).
#   validations     3  measured mean occupancy 2.5 (median 2, p90 5, max 20):
#                      123 ships at 0.72/h, mean spawn -> green 3.5 h. The
#                      smallest whole cap at or above the mean keeps the measured
#                      completion rate (Little's law) while cutting the surges
#                      that fed ci's 124 h.
#   merges          5  the report's merge-queue concurrency p90 (median 1, max
#                      14). merge_queue is the constraint (293 h, 38% of all
#                      wait, ten worst PRs 145 h); 5 green PRs keep the merge
#                      line fed without the 14-deep pile behind it.
#   reviews         1  measured occupancy median 0, p90 1, max 2 (10 review and
#                      audit scouts).
#   investigations  5  measured mean occupancy 4.9 (median 3, p90 9, max 13;
#                      58 scouts at 0.34/h); the same smallest-whole-cap-at-
#                      or-above-the-mean rule.
# Together the dispatch-fed lanes (validations, reviews, investigations) admit
# 9 tasks, below the baseline median of 11 in flight.
#
# ADMISSION (bin/fm-spawn.sh). A fresh scout needs a free slot in its lane. A
# fresh ship needs a free validations slot AND a merges lane below its cap,
# because a new ship only adds inventory ahead of a full merge line. A refused
# dispatch creates nothing - its backlog item stays Queued - and the refusal
# names each full lane, its cap, and every task occupying it with its newest
# status event. Admission runs under the home's task-set lock, so two spawns
# cannot both take the last slot.
# Promotion also runs under that lock: bin/fm-promote.sh checks before
# changing a scout to ship. A transition into a different lane uses the same
# admission checks, excluding the task's own record; an unchanged lane or
# no-slot outcome needs no admission. Refusal exits 5 without changing task
# metadata or the scout's brief, so finish existing work and retry.
#
# REGISTRATION (bin/fm-pr-check.sh). A ship entering merges by registering its
# PR is admitted only while the merges lane has a slot that no earlier queued
# registration claims. A same-lane registration (re-recording the PR of a task
# already in merges) needs no admission and takes no lock, and neither does
# the registration bin/fm-pr-merge.sh makes before every merge (--merge-order),
# so an ordered merge is never refused by the cap; it still holds its slot and
# leaves the queue. A merge refused before its forge merge call restores the
# task's prior registration (fm-pr-check.sh --merge-order-restore), putting it
# back in the queue at its original order, then retries the queue, since the
# slot it hands back may be the one a merge freed meanwhile. Admission waits at
# most FM_WIP_LOCK_WAIT seconds (default 20) for the task-set lock, as spawn and
# promotion also do, and holds it through the pr= publication.
# A refused or lock-busy registration exits 5, records nothing in the task,
# arms no poll, and is queued durably in state/.wip-pr-queue, one tab-separated
# line per task: <order> <task-id> <pr-url> merges. A task has at most one
# entry; re-queuing keeps its order and updates its URL. The task keeps its
# validations slot, and lane listings mark it "PR registration queued".
# `bin/fm-pr-check.sh --retry-queued` re-runs queued registrations in order and
# stops at the first one still refused, so the head of the queue always arms
# first; an entry whose task record is gone is dropped. It runs whenever a
# merges slot can free: when bin/fm-watch.sh retires a merged poll, at the end
# of every bin/fm-teardown.sh, and on every bin/fm-pr-sweep.sh check. Each
# registration it arms prints one "check: wip-queue: ..." line its caller turns
# into a wake, so enqueue and dequeue are both reported.
# Exempt, never checked: a secondmate spawn and any relaunch, so recovery is
# never queued behind a cap.
# Bypass: a captain's direct dispatch order (class captain) and outage or
# security work (classes outage, security) pass --cap-bypass <class>
# --cap-bypass-reason <why>. A bypassed task still holds its slot. Before
# anything is created, the spawn proves the bypass log is writable and refuses
# otherwise; the task record then carries wip_cap_bypass=<class>, and only once
# the spawn has succeeded is one tab-separated line appended to
# data/wip-cap-bypasses.log (<utc> <id> <lane> <class> <occupancy>/<cap>
# <reason>), so a failed spawn leaves no line and a retry leaves exactly one.
#
# PULL (bin/fm-queue-zero.sh). Each ready backlog row enters the lane its kind
# names (review -> reviews, scout -> investigations, anything else is dispatched
# as a ship -> validations, which also needs a merges lane below its cap), in
# tasks-axi ready order. Only as many rows as the lane has free slots are listed
# as ready to dispatch; the rest wait in their lane unlisted, so the queue-zero
# wake names the next row only when a finish frees a slot. A cap that cannot be
# read lists every ready row plus one error row naming config/wip-caps.

if ! declare -F fm_pr_url_parse >/dev/null; then
  # shellcheck source=bin/fm-pr-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-pr-lib.sh"
fi

FM_WIP_PR_QUEUE_NAME=.wip-pr-queue

FM_WIP_LANES='validations merges reviews investigations'
FM_WIP_ERROR=
FM_WIP_REFUSAL=
FM_WIP_BINDING=

fm_wip_cap_default() {  # <lane>
  case "$1" in
    validations) printf '3\n' ;;
    merges) printf '5\n' ;;
    reviews) printf '1\n' ;;
    investigations) printf '5\n' ;;
    *) return 1 ;;
  esac
}

fm_wip_lane_valid() {  # <lane>
  [ -n "$1" ] || return 1
  case " $FM_WIP_LANES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Load the caps into FM_WIP_CAP_<lane>: the measured default, overridden by
# <config-dir>/wip-caps. Returns 1 with FM_WIP_ERROR on any invalid input.
fm_wip_caps_load() {  # <config-dir>
  local file=$1/wip-caps lane line key value n=0
  FM_WIP_ERROR=
  for lane in $FM_WIP_LANES; do
    printf -v "FM_WIP_CAP_$lane" '%s' "$(fm_wip_cap_default "$lane")"
  done
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_WIP_ERROR="config/wip-caps must be a readable regular file of <lane>=<positive integer> lines"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] || continue
    key=${line%%=*}
    value=${line#*=}
    if [ "$key" = "$line" ] || ! fm_wip_lane_valid "$key"; then
      FM_WIP_ERROR="config/wip-caps line $n: expected <lane>=<positive integer> with lane one of: $FM_WIP_LANES"
      return 1
    fi
    case "$value" in
      '' | *[!0-9]* | 0*)
        FM_WIP_ERROR="config/wip-caps line $n: the $key cap must be a positive integer, got '$value'"
        return 1
        ;;
    esac
    printf -v "FM_WIP_CAP_$key" '%s' "$value"
  done <"$file"
}

fm_wip_cap() {  # <lane>; after fm_wip_caps_load
  local var="FM_WIP_CAP_$1"
  printf '%s' "${!var:-}"
}

# The lane a fresh dispatch enters: a scout from a backlog item of kind review
# is a review, every other scout an investigation, and every ship a validation.
# A secondmate enters none.
fm_wip_dispatch_lane() {  # <spawn-kind> <backlog-kind>
  case "$1" in
    scout) if [ "$2" = review ]; then printf 'reviews\n'; else printf 'investigations\n'; fi ;;
    secondmate) return 0 ;;
    *) printf 'validations\n' ;;
  esac
}

# kind|pr|wip_lane|wip_cap_bypass from one task record, last value winning.
fm_wip_meta_fields() {  # <meta>
  awk '
    index($0, "kind=") == 1 { k = substr($0, 6) }
    index($0, "pr=") == 1 { p = substr($0, 4) }
    index($0, "wip_lane=") == 1 { w = substr($0, 10) }
    index($0, "wip_cap_bypass=") == 1 { b = substr($0, 16) }
    END { printf "%s|%s|%s|%s\n", k, p, w, b }
  ' "$1" 2>/dev/null
}

# The lane one live task record holds, or empty (LANES above), in
# FM_WIP_TASK_LANE, and its recorded bypass class, if any, in FM_WIP_TASK_BYPASS.
fm_wip_task_lane() {  # <state-dir> <id>
  local state=$1 id=$2 kind pr wlane
  IFS='|' read -r kind pr wlane FM_WIP_TASK_BYPASS <<EOF
$(fm_wip_meta_fields "$state/$id.meta")
EOF
  fm_wip_record_lane "$state" "$id" "$kind" "$pr" "$wlane"
}

fm_wip_record_lane() {
  local state=$1 id=$2 kind=$3 pr=$4 wlane=$5
  FM_WIP_TASK_LANE=
  case "$kind" in
    secondmate) ;;
    scout)
      if [ "$wlane" = reviews ]; then FM_WIP_TASK_LANE=reviews; else FM_WIP_TASK_LANE=investigations; fi
      ;;
    *)
      if (fm_pr_url_parse "$pr" && fm_pr_poll_merge_already_notified "$state" "$id" \
        "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"); then
        :
      elif [ -n "$pr" ]; then
        FM_WIP_TASK_LANE=merges
      else
        FM_WIP_TASK_LANE=validations
      fi
      ;;
  esac
}

# One pass over this home's task records: FM_WIP_COUNT_<lane> and
# FM_WIP_OCCUPANTS_<lane> ("id [detail], ..."). <exclude-id> is the task being
# dispatched, which never occupies a slot against itself.
fm_wip_scan() {  # <state-dir> [exclude-id]
  local state=$1 exclude=${2:-} lane meta id last detail var wt worktrees=
  for lane in $FM_WIP_LANES; do
    printf -v "FM_WIP_COUNT_$lane" '%s' 0
    printf -v "FM_WIP_OCCUPANTS_$lane" '%s' ''
  done
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ "$id" != "$exclude" ] || continue
    fm_wip_task_lane "$state" "$id"
    lane=$FM_WIP_TASK_LANE
    [ -n "$lane" ] || continue
    if [ "$lane" = validations ]; then
      wt=$(sed -n 's/^worktree=//p' "$meta" 2>/dev/null | tail -n 1)
      [ -z "$wt" ] || worktrees="$worktrees$wt"$'\n'
    fi
    detail=
    if [ -s "$state/$id.status" ]; then
      last=$(tail -n 1 "$state/$id.status" 2>/dev/null | sed 's/[]:[ ].*//')
      [ -z "$last" ] || detail="last event: $last"
    fi
    [ -z "$FM_WIP_TASK_BYPASS" ] || detail="${detail:+$detail; }bypass: $FM_WIP_TASK_BYPASS"
    if [ "$lane" = validations ] && fm_wip_queue_has "$state" "$id"; then
      detail="${detail:+$detail; }PR registration queued"
    fi
    var="FM_WIP_COUNT_$lane"
    printf -v "$var" '%s' $((${!var} + 1))
    var="FM_WIP_OCCUPANTS_$lane"
    printf -v "$var" '%s' "${!var:+${!var}, }$id${detail:+ [$detail]}"
  done
  fm_wip_host_suites_add "$worktrees"
}

# The full-suite pytest runs live on this host (HOST SUITES above), one
# "<pid>\t<args>" line each, xdist workers and wrapped re-invocations folded
# into the outermost run. Prints nothing when the process table is unreadable.
fm_wip_host_suites() {
  LC_ALL=C ps -Ao pid=,ppid=,args= 2>/dev/null | awk '
    function base(s) { sub(/\/+$/, "", s); sub(/.*\//, "", s); return s }
    function python(s) { return base(s) ~ /^python[0-9.]*$/ }
    # 1 when the tokens from <start> select the whole suite, 0 when they target
    # a subset (a -k expression or any path other than a tests dir or .).
    function whole(start,   j, t, letter) {
      for (j = start; j <= n; j++) {
        t = tok[j]
        if (t == "&&" || t == "||" || t == ";" || t == "|") break
        if (t ~ /^--/) {
          if (t !~ /=/ && t ~ /^--(rootdir|ignore|ignore-glob|deselect|maxfail|tb|durations|junitxml|junit-xml|cov|cov-report|dist|basetemp|confcutdir|import-mode|log-level|override-ini|pyargs|numprocesses|tx|max-worker-restart)$/) j++
          continue
        }
        if (t ~ /^-./) {
          letter = substr(t, 2, 1)
          if (letter == "k") return 0
          if (length(t) == 2 && index("mpcoWrn", letter)) j++
          continue
        }
        sub(/;$/, "", t)
        if (t != "." && base(t) != "tests" && base(t) != "test") return 0
      }
      return 1
    }
    {
      pid = $1; parent[pid] = $2
      n = NF - 2
      for (i = 1; i <= n; i++) tok[i] = $(i + 2)
      for (i = 1; i <= n; i++) {
        b = base(tok[i])
        if ((b == "pytest" || b == "py.test") && (i == 1 || python(tok[i - 1]))) {
          if (whole(i + 1)) { suite[pid] = 1; line[pid] = $0 }
          break
        }
        if (tok[i] == "-m" && (tok[i + 1] == "pytest" || tok[i + 1] == "py.test") && python(tok[1])) {
          if (whole(i + 2)) { suite[pid] = 1; line[pid] = $0 }
          break
        }
      }
    }
    END {
      for (pid in suite) {
        p = parent[pid]
        for (depth = 0; depth < 64 && p != "" && p > 1; depth++) {
          if (p in suite) break
          p = parent[p]
        }
        if (p in suite) continue
        args = line[pid]
        sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", args)
        printf "%s\t%s\n", pid, substr(args, 1, 120)
      }
    }
  '
}

fm_wip_process_cwd() {  # <pid>
  local cwd
  cwd=$(readlink "/proc/$1/cwd" 2>/dev/null) && [ -n "$cwd" ] && { printf '%s\n' "$cwd"; return 0; }
  command -v lsof >/dev/null 2>&1 || return 1
  lsof -a -d cwd -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1
}

# Add every host suite not running inside one of <worktrees> (newline-separated
# validations worktrees of this home, whose own record already holds the slot)
# to the validations lane.
fm_wip_host_suites_add() {  # <worktrees>
  local worktrees=$1 pid args cwd wt own detail count=FM_WIP_COUNT_validations occupants=FM_WIP_OCCUPANTS_validations
  [ "${FM_WIP_HOST_SUITES:-on}" != off ] || return 0
  while IFS="$(printf '\t')" read -r pid args; do
    [ -n "$pid" ] || continue
    cwd=$(fm_wip_process_cwd "$pid") || cwd=
    own=
    if [ -n "$cwd" ]; then
      while IFS= read -r wt; do
        [ -n "$wt" ] || continue
        case "$cwd/" in "${wt%/}/"*) own=1; break ;; esac
      done <<EOF
$worktrees
EOF
    fi
    [ -z "$own" ] || continue
    detail="full test suite${cwd:+ in $cwd}: $args"
    printf -v "$count" '%s' $((${!count} + 1))
    printf -v "$occupants" '%s' "${!occupants:+${!occupants}, }pytest-$pid [$detail]"
  done <<EOF
$(fm_wip_host_suites)
EOF
}

# A full merges lane also counts every queued PR registration, since each one
# already claims the next free merges slot (REGISTRATION above).
fm_wip_lane_full() {  # <lane>; after fm_wip_caps_load and fm_wip_scan
  local count="FM_WIP_COUNT_$1" queued=0
  [ "$1" != merges ] || queued=${FM_WIP_QUEUED:-0}
  [ $((${!count} + queued)) -ge "$(fm_wip_cap "$1")" ]
}

# Admission for one fresh dispatch (ADMISSION above). Returns 0 when it may
# start. Returns 1 when a lane it needs is full, with FM_WIP_BINDING naming
# the first full lane as "<lane> <count>/<cap>" and FM_WIP_REFUSAL naming
# every full lane, its cap, and its occupants. Returns 2 with FM_WIP_ERROR
# when the caps cannot be read.
fm_wip_admit() {  # <config-dir> <state-dir> <id> <lane>
  local config=$1 state=$2 id=$3 lane=$4 need l count occupants text=
  FM_WIP_REFUSAL=
  FM_WIP_BINDING=
  fm_wip_caps_load "$config" || return 2
  fm_wip_scan "$state" "$id"
  fm_wip_queue_claims "$state"
  need=$lane
  [ "$lane" != validations ] || need='validations merges'
  for l in $need; do
    fm_wip_lane_full "$l" || continue
    count="FM_WIP_COUNT_$l"
    occupants="FM_WIP_OCCUPANTS_$l"
    [ -n "$FM_WIP_BINDING" ] || FM_WIP_BINDING="$l ${!count}/$(fm_wip_cap "$l")"
    text="${text:+$text; }lane $l is at its cap of $(fm_wip_cap "$l") with ${!count} in flight: ${!occupants}"
    if [ "$l" = merges ] && [ "${FM_WIP_QUEUED:-0}" -gt 0 ]; then
      text="$text; PR registrations queued for it: $FM_WIP_QUEUED_IDS"
    fi
  done
  [ -n "$FM_WIP_BINDING" ] || return 0
  FM_WIP_REFUSAL="work-in-progress cap: $text"
  return 1
}

# Admit a proposed kind/PR/lane change only when it enters a different lane
# (ADMISSION above); return codes match fm_wip_admit.
fm_wip_transition_admit() {
  local config=$1 state=$2 id=$3 kind=$4 pr=$5 wlane=$6 current target
  fm_wip_task_lane "$state" "$id"
  current=$FM_WIP_TASK_LANE
  fm_wip_record_lane "$state" "$id" "$kind" "$pr" "$wlane"
  target=$FM_WIP_TASK_LANE
  [ -n "$target" ] && [ "$target" != "$current" ] || return 0
  fm_wip_admit "$config" "$state" "$id" "$target"
}

# Free slots per lane as one JSON object for bin/fm-queue-zero.sh, or 1 with
# FM_WIP_ERROR when the caps cannot be read.
fm_wip_free_json() {  # <config-dir> <state-dir>
  local lane count free sep='' out='{'
  fm_wip_caps_load "$1" || return 1
  fm_wip_scan "$2"
  fm_wip_queue_claims "$2"
  for lane in $FM_WIP_LANES; do
    count="FM_WIP_COUNT_$lane"
    free=$(($(fm_wip_cap "$lane") - ${!count}))
    [ "$lane" != merges ] || free=$((free - ${FM_WIP_QUEUED:-0}))
    [ "$free" -ge 0 ] || free=0
    out="$out$sep\"$lane\":$free"
    sep=,
  done
  printf '%s}\n' "$out"
}

# Take the home's task-set lock, waiting at most FM_WIP_LOCK_WAIT seconds
# (default 20; the wait used is left in FM_WIP_LOCK_WAITED). A fresh spawn,
# a promotion and a PR registration all take it this way, so none fails
# outright because another briefly holds it.
fm_wip_task_set_lock_acquire() {  # <lock-path>
  FM_WIP_LOCK_WAITED=${FM_WIP_LOCK_WAIT:-20}
  case "$FM_WIP_LOCK_WAITED" in ''|*[!0-9]*|0) FM_WIP_LOCK_WAITED=20 ;; esac
  fm_lock_acquire_wait_bounded "$1" "$FM_WIP_LOCK_WAITED"
}

# --- queued PR registrations (REGISTRATION above) -------------------------

fm_wip_queue_path() {  # <state-dir>
  printf '%s/%s\n' "$1" "$FM_WIP_PR_QUEUE_NAME"
}

# Print the queue's entries in order as "<order>\t<id>\t<url>\t<lane>", dropping
# none; a missing queue prints nothing.
fm_wip_queue_list() {  # <state-dir>
  local queue
  queue=$(fm_wip_queue_path "$1")
  [ -f "$queue" ] && [ ! -L "$queue" ] || return 0
  awk -F'\t' 'NF == 4 && $1 ~ /^[0-9]+$/' "$queue" | sort -t"$(printf '\t')" -k1,1n
}

fm_wip_queue_has() {  # <state-dir> <id>
  fm_wip_queue_list "$1" | awk -F'\t' -v id="$2" '$2 == id { found = 1 } END { exit !found }'
}

# Rewrite the queue through <awk-program> under its own lock. The program
# reads the current entries (already in order) and prints the new ones.
fm_wip_queue_rewrite() {  # <state-dir> <awk-program> [awk -v assignments...]
  local state=$1 program=$2 queue lock tmp status=0
  shift 2
  queue=$(fm_wip_queue_path "$state")
  [ ! -L "$queue" ] || return 1
  lock="$queue.lock"
  fm_lock_acquire_wait "$lock" || return 1
  tmp=$(mktemp "$queue.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  if fm_wip_queue_list "$state" | awk -F'\t' -v OFS='\t' "$@" "$program" >"$tmp"; then
    if [ -s "$tmp" ]; then
      mv -f -- "$tmp" "$queue" || status=1
    else
      rm -f -- "$tmp" "$queue" || status=1
    fi
  else
    rm -f -- "$tmp"
    status=1
  fi
  fm_lock_release "$lock" || status=1
  return "$status"
}

# Queue <id>'s registration at the tail, or keep its place and update its URL
# when it is already queued.
fm_wip_queue_add() {  # <state-dir> <id> <url>
  # shellcheck disable=SC2016 # awk program text, not shell expansion.
  fm_wip_queue_rewrite "$1" '
    { if ($1 + 0 > max) max = $1 + 0 }
    $2 == id { $3 = url; found = 1 }
    { print }
    END { if (!found) print max + 1, id, url, "merges" }
  ' -v id="$2" -v url="$3"
}

# Put <id>'s registration back at its original <order>, shifting any entry
# queued at or after that order one place back so every earlier entry stays
# ahead of it and every later one behind it.
fm_wip_queue_restore() {  # <state-dir> <order> <id> <url>
  # shellcheck disable=SC2016 # awk program text, not shell expansion.
  fm_wip_queue_rewrite "$1" '
    $2 == id { next }
    $1 + 0 >= order + 0 { $1 = $1 + 1 }
    { print }
    END { print order, id, url, "merges" }
  ' -v order="$2" -v id="$3" -v url="$4"
}

fm_wip_queue_remove() {  # <state-dir> <id>
  fm_wip_queue_has "$1" "$2" || return 0
  # shellcheck disable=SC2016 # awk program text, not shell expansion.
  fm_wip_queue_rewrite "$1" '$2 != id' -v id="$2"
}

# Count, into FM_WIP_QUEUED and FM_WIP_QUEUED_IDS, the queued registrations
# that claim a merges slot ahead of <id>: every live entry when <id> is not
# queued, otherwise only those before it. An entry whose task record is gone
# claims nothing. <id> empty counts every live entry.
fm_wip_queue_claims() {  # <state-dir> [id]
  local state=$1 id=${2:-} order qid url lane
  FM_WIP_QUEUED=0
  FM_WIP_QUEUED_IDS=
  while IFS="$(printf '\t')" read -r order qid url lane; do
    [ -n "$qid" ] || continue
    [ "$qid" != "$id" ] || break
    [ -f "$state/$qid.meta" ] || continue
    FM_WIP_QUEUED=$((FM_WIP_QUEUED + 1))
    FM_WIP_QUEUED_IDS="${FM_WIP_QUEUED_IDS:+$FM_WIP_QUEUED_IDS, }$qid"
  done <<EOF
$(fm_wip_queue_list "$state")
EOF
}

# Admission for <id> registering its PR into merges (REGISTRATION above):
# 0 when the merges lane has a slot no earlier queued registration claims, 1
# with FM_WIP_REFUSAL when it does not, 2 with FM_WIP_ERROR when the caps
# cannot be read. Call under the task-set lock.
fm_wip_registration_admit() {  # <config-dir> <state-dir> <id>
  local config=$1 state=$2 id=$3 count=FM_WIP_COUNT_merges occupants=FM_WIP_OCCUPANTS_merges
  FM_WIP_REFUSAL=
  FM_WIP_BINDING=
  fm_wip_caps_load "$config" || return 2
  fm_wip_scan "$state" "$id"
  fm_wip_queue_claims "$state" "$id"
  fm_wip_lane_full merges || return 0
  FM_WIP_BINDING="merges ${!count}/$(fm_wip_cap merges)"
  FM_WIP_REFUSAL="work-in-progress cap: lane merges is at its cap of $(fm_wip_cap merges) with ${!count} in flight: ${!occupants}"
  [ "$FM_WIP_QUEUED" -eq 0 ] || FM_WIP_REFUSAL="$FM_WIP_REFUSAL; queued ahead of $id: $FM_WIP_QUEUED_IDS"
  return 1
}

fm_wip_bypass_class_valid() {  # <class>
  case "$1" in
    captain | outage | security) return 0 ;;
    *) return 1 ;;
  esac
}

# True when the bypass log can be appended: <data-dir> is a writable directory
# and the log is absent or a writable regular file (not a symlink).
fm_wip_bypass_log_writable() {  # <data-dir>
  local data=$1 log=$1/wip-cap-bypasses.log
  [ -d "$data" ] && [ -w "$data" ] && [ ! -L "$log" ] || return 1
  [ ! -e "$log" ] || { [ -f "$log" ] && [ -w "$log" ]; }
}

# Append the durable bypass record (BYPASS above), after a successful spawn.
# Returns 1 when it could not be written.
fm_wip_bypass_record() {  # <data-dir> <id> <lane> <class> <occupancy/cap> <reason>
  local log=$1/wip-cap-bypasses.log
  fm_wip_bypass_log_writable "$1" || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$4" "$5" "$6" >>"$log"
}
