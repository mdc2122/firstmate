# shellcheck shell=bash disable=SC2034 # FM_WIP_* outputs are read by the sourcing caller.
# fm-wip-caps-lib.sh - single owner of per-lane work-in-progress caps.
# Usage: . bin/fm-wip-caps-lib.sh (sourced by bin/fm-spawn.sh and
# bin/fm-queue-zero.sh; it has no command of its own).
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
#                   has not been delivered (no state/<id>.pr-poll-merge-notified)
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
# Exempt, never checked: a secondmate spawn and any relaunch, so recovery is
# never queued behind a cap.
#
# PULL (bin/fm-queue-zero.sh). Each ready backlog row enters the lane its kind
# names (review -> reviews, scout -> investigations, anything else is dispatched
# as a ship -> validations, which also needs a merges lane below its cap), in
# tasks-axi ready order. Only as many rows as the lane has free slots are listed
# as ready to dispatch; the rest wait in their lane unlisted, so the queue-zero
# wake names the next row only when a finish frees a slot. A cap that cannot be
# read lists every ready row plus one error row naming config/wip-caps.
# Promotion (bin/fm-promote.sh) is not a dispatch: the promoted task moves from
# its scout lane to validations without an admission check.

FM_WIP_LANES='validations merges reviews investigations'
FM_WIP_ERROR=
FM_WIP_REFUSAL=

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

# kind|pr|wip_lane from one task record, last value winning.
fm_wip_meta_fields() {  # <meta>
  awk '
    index($0, "kind=") == 1 { k = substr($0, 6) }
    index($0, "pr=") == 1 { p = substr($0, 4) }
    index($0, "wip_lane=") == 1 { w = substr($0, 10) }
    END { printf "%s|%s|%s\n", k, p, w }
  ' "$1" 2>/dev/null
}

# The lane one live task record holds, or empty (LANES above), in
# FM_WIP_TASK_LANE.
fm_wip_task_lane() {  # <state-dir> <id>
  local state=$1 id=$2 kind pr wlane
  IFS='|' read -r kind pr wlane <<EOF
$(fm_wip_meta_fields "$state/$id.meta")
EOF
  FM_WIP_TASK_LANE=
  case "$kind" in
    secondmate) ;;
    scout)
      if [ "$wlane" = reviews ]; then FM_WIP_TASK_LANE=reviews; else FM_WIP_TASK_LANE=investigations; fi
      ;;
    *)
      if [ -e "$state/$id.pr-poll-merge-notified" ]; then
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
    var="FM_WIP_COUNT_$lane"
    printf -v "$var" '%s' $((${!var} + 1))
    var="FM_WIP_OCCUPANTS_$lane"
    printf -v "$var" '%s' "${!var:+${!var}, }$id${detail:+ [$detail]}"
  done
}

fm_wip_lane_full() {  # <lane>; after fm_wip_caps_load and fm_wip_scan
  local count="FM_WIP_COUNT_$1"
  [ "${!count}" -ge "$(fm_wip_cap "$1")" ]
}

# Admission for one fresh dispatch (ADMISSION above). Returns 0 when it may
# start. Returns 1 when a lane it needs is full, with FM_WIP_REFUSAL naming
# every full lane, its cap, and its occupants. Returns 2 with FM_WIP_ERROR
# when the caps cannot be read.
fm_wip_admit() {  # <config-dir> <state-dir> <id> <lane>
  local config=$1 state=$2 id=$3 lane=$4 need l count occupants text=
  FM_WIP_REFUSAL=
  fm_wip_caps_load "$config" || return 2
  fm_wip_scan "$state" "$id"
  need=$lane
  [ "$lane" != validations ] || need='validations merges'
  for l in $need; do
    fm_wip_lane_full "$l" || continue
    count="FM_WIP_COUNT_$l"
    occupants="FM_WIP_OCCUPANTS_$l"
    text="${text:+$text; }lane $l is at its cap of $(fm_wip_cap "$l") with ${!count} in flight: ${!occupants}"
  done
  [ -n "$text" ] || return 0
  FM_WIP_REFUSAL="work-in-progress cap: $text"
  return 1
}

# Free slots per lane as one JSON object for bin/fm-queue-zero.sh, or 1 with
# FM_WIP_ERROR when the caps cannot be read.
fm_wip_free_json() {  # <config-dir> <state-dir>
  local lane count free sep='' out='{'
  fm_wip_caps_load "$1" || return 1
  fm_wip_scan "$2"
  for lane in $FM_WIP_LANES; do
    count="FM_WIP_COUNT_$lane"
    free=$(($(fm_wip_cap "$lane") - ${!count}))
    [ "$free" -ge 0 ] || free=0
    out="$out$sep\"$lane\":$free"
    sep=,
  done
  printf '%s}\n' "$out"
}
