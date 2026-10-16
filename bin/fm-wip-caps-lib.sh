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
#                   implementing and validating, up to the green PR
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
# already in merges, as bin/fm-pr-merge.sh does before every merge) needs no
# admission and takes no lock. Admission waits at most FM_WIP_LOCK_WAIT seconds
# (default 20) for the task-set lock and holds it through the pr= publication.
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
  local state=$1 exclude=${2:-} lane meta id last detail var
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
