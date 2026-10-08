#!/usr/bin/env bash
# fm-stow-trigger.sh - context-volume /stow trigger for a firstmate primary.
#
# A busy session fills its context window and compacts long before a
# time-based stow reminder comes due, so knowledge held only in conversation can
# be condensed away before a /stow captures it. The omp and Pi primary turn-end
# guard extensions (.omp/extensions/fm-primary-turnend-guard.ts,
# .pi/extensions/fm-primary-turnend-guard.ts) get the threshold trigger plus the
# pre-compaction trigger; a Claude Code primary gets only the pre-compaction
# trigger, through its PreCompact hook (bin/fm-stow-trigger-claude.sh); other
# primary harnesses get only the time-based floor. Reports come only from the
# fleet-lock holder, and this script queues ordinary durable `check` wakes
# (key stow-due): one per context cycle, plus one per further growth step
# after each completed stow (below), so the stow runs as a normal firstmate
# turn. It never runs the stow and never touches compaction.
#
# Usage:
#   fm-stow-trigger.sh context <percent>       agent loop ended at <percent> usage
#   fm-stow-trigger.sh compacting [<percent>]  the harness is about to compact
#   fm-stow-trigger.sh cycle                   a new context cycle began
#                                              (compaction finished, or a session started)
#   fm-stow-trigger.sh threshold               print the effective threshold
#   fm-stow-trigger.sh --help
#
# Threshold: config/stow-context-threshold holds one whole number 1-100 (local,
# gitignored); absent or invalid means 70. docs/configuration.md documents it.
#
# Latch, one wake per context cycle plus step re-arms. A cycle starts at the
# first report after install, at every `cycle`, at the first report from a new
# fleet-lock holder, and never otherwise. state/.stow-trigger records
#   cycle=<epoch>  when the current cycle started
#   above=<epoch>  when usage was first seen at or above the threshold this cycle (0: not yet)
#   fired=<epoch>  when this cycle's latest wake was queued (0: not yet)
#   holder=<pid>   the state/.lock holder that reported this cycle
#   stowed=<epoch> the state/.last-stow mtime that base belongs to (0: none yet)
#   base=<percent> usage at the first context report after that stow
# and the stow marker is state/.last-stow, which the /stow skill touches after
# every completed pass.
# A report naming a different holder (or a record with none) is a new session
# whose startup `cycle` report can be dropped: a harness may run its session
# start hook before the session takes state/.lock, while the lock still names
# the previous session. That report then starts a new cycle itself, dated from
# when the holder took state/.lock (its mtime; now if unreadable), so the
# previous session's latch and stow never suppress the new session's wake while
# a stow this session completed before its first report still counts.
#   context:    wakes when <percent> >= threshold, nothing fired this cycle, and
#               no stow completed since usage first reached the threshold. A
#               stow below the threshold (the daily floor on a quiet morning)
#               does not cover the later busy part of the cycle; a stow at or
#               above it does, until usage grows. Step re-arm: once a stow
#               completed since usage first reached the threshold and after
#               this cycle's latest wake, the first context report after it
#               records its usage as base, and a report at base+STEP or more
#               (STEP 5 points) queues one more wake. That wake re-latches
#               until the next completed stow, so there is at most one wake
#               per step and none without both a stow and further growth.
#   compacting: wakes when nothing fired this cycle and no stow covers the busy
#               part of it, whatever the usage. When usage reached the
#               threshold this cycle, only a stow since it first did covers it
#               (the context rule). Otherwise (no usage signal, as on Claude
#               Code, or usage never reached the threshold) only a stow this
#               cycle within the last FM_STOW_TRIGGER_RECENT_SECS seconds
#               (whole seconds, default 1800; invalid means 1800) does, so an
#               early light stow never covers a long cycle.
# The wake row is appended before the record is written, so a failed append is
# retried at the next report rather than suppressed; an identical stow-due row
# still queued is not appended twice. Prints the wake reason when it wakes,
# nothing otherwise.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RECORD="$STATE/.stow-trigger"
RECORD_SCHEMA=fm-stow-trigger-v1
STOW_MARKER="$STATE/.last-stow"
DEFAULT_THRESHOLD=70
DEFAULT_RECENT_SECS=1800
REARM_STEP=5

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'fm-stow-trigger: %s\n' "$1" >&2; exit "${2:-1}"; }

threshold() {
  local v=''
  [ -f "$CONFIG/stow-context-threshold" ] && read -r v < "$CONFIG/stow-context-threshold" 2>/dev/null
  v=${v//[[:space:]]/}
  case "$v" in ''|*[!0-9]*) printf '%s\n' "$DEFAULT_THRESHOLD"; return ;; esac
  v=$((10#$v))
  if [ "$v" -ge 1 ] && [ "$v" -le 100 ]; then printf '%s\n' "$v"; else printf '%s\n' "$DEFAULT_THRESHOLD"; fi
}

recent_secs() {
  local v=${FM_STOW_TRIGGER_RECENT_SECS:-}
  case "$v" in ''|*[!0-9]*) printf '%s\n' "$DEFAULT_RECENT_SECS"; return ;; esac
  v=$((10#$v))
  if [ "$v" -gt 0 ]; then printf '%s\n' "$v"; else printf '%s\n' "$DEFAULT_RECENT_SECS"; fi
}

whole_percent() {  # <raw> -> whole number, or fail
  local p=${1%%.*}
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((10#$p))"
}

REC_CYCLE=0 REC_ABOVE=0 REC_FIRED=0 REC_HOLDER='' REC_STOWED=0 REC_BASE=0
record_read() {
  local line key value
  REC_CYCLE=0 REC_ABOVE=0 REC_FIRED=0 REC_HOLDER='' REC_STOWED=0 REC_BASE=0
  [ -f "$RECORD" ] || return 1
  { read -r line && [ "$line" = "$RECORD_SCHEMA" ]; } < "$RECORD" || return 1
  while IFS='=' read -r key value; do
    case "$value" in ''|*[!0-9]*) continue ;; esac
    case "$key" in
      cycle) REC_CYCLE=$value ;;
      above) REC_ABOVE=$value ;;
      fired) REC_FIRED=$value ;;
      holder) REC_HOLDER=$value ;;
      stowed) REC_STOWED=$value ;;
      base) REC_BASE=$value ;;
    esac
  done < "$RECORD"
  [ "$REC_CYCLE" -gt 0 ]
}

# Writes the decide() locals cycle, above, fired, stowed, base.
record_write() {
  local tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\ncycle=%s\nabove=%s\nfired=%s\nholder=%s\nstowed=%s\nbase=%s\n' \
      "$RECORD_SCHEMA" "$cycle" "$above" "$fired" "$HOLDER" "$stowed" "$base" > "$tmp" \
    || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

lock_holder() {  # the state/.lock pid, or nothing
  local pid=''
  [ -f "$STATE/.lock" ] && read -r pid < "$STATE/.lock" 2>/dev/null
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$pid"
}

stow_mtime() {  # the state/.last-stow mtime, or 0
  [ -f "$STOW_MARKER" ] && fm_path_mtime "$STOW_MARKER" 2>/dev/null || printf '0\n'
}

stowed_since() {  # <epoch>: 0 when state/.last-stow is at or after <epoch>
  local m
  m=$(stow_mtime)
  [ "$m" -gt 0 ] && [ "$m" -ge "$1" ]
}

queue_wake() {  # <reason>
  local status=0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  if ! fm_wake_queued_keys_locked check | grep -Fx stow-due >/dev/null; then
    fm_wake_append_locked check stow-due "$1" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

# Runs under the trigger lock.
decide() {  # <action> [<percent>]
  local action=$1 raw=${2:-} percent='' limit now cycle above fired stowed base fresh=0 since reason stow_m
  limit=$(threshold)
  now=$(date +%s)
  if [ -n "$raw" ]; then
    percent=$(whole_percent "$raw") || die "invalid percent: $raw" 2
  fi
  HOLDER=$(lock_holder)
  cycle=$now above=0 fired=0 stowed=0 base=0
  if record_read && [ "$REC_HOLDER" = "$HOLDER" ]; then
    cycle=$REC_CYCLE above=$REC_ABOVE fired=$REC_FIRED stowed=$REC_STOWED base=$REC_BASE
  else
    fresh=1
    cycle=$(fm_path_mtime "$STATE/.lock" 2>/dev/null) || cycle=$now
  fi

  case "$action" in
    cycle)
      cycle=$now above=0 fired=0 stowed=0 base=0
      record_write || die "could not write $RECORD"
      return 0
      ;;
    context)
      [ -n "$percent" ] || die "context needs a percent" 2
      if [ "$percent" -lt "$limit" ]; then
        [ "$fresh" -eq 0 ] || record_write || true
        return 0
      fi
      [ "$above" -gt 0 ] || above=$now
      stow_m=$(stow_mtime)
      if [ "$stow_m" -gt 0 ] && [ "$stow_m" -ge "$above" ] && [ "$stow_m" -gt "$fired" ]; then
        # A stow covers the busy part of the cycle and every wake so far.
        if [ "$stow_m" -ne "$stowed" ]; then
          stowed=$stow_m base=$percent
          record_write || true
          return 0
        fi
        if [ "$percent" -lt $((base + REARM_STEP)) ]; then
          [ "$fresh" -eq 0 ] || record_write || true
          return 0
        fi
        reason="check: stow-due: context ${percent}% (${REARM_STEP}+ points since the last /stow at ${base}%) - run the /stow pass again before compaction condenses this session"
      elif [ "$fired" -gt 0 ]; then
        record_write || true
        return 0
      else
        reason="check: stow-due: context ${percent}% (threshold ${limit}%) - run the /stow pass before compaction condenses this session"
      fi
      ;;
    compacting)
      if [ "$above" -gt 0 ]; then
        since=$above
      else
        since=$((now - $(recent_secs)))
        [ "$since" -ge "$cycle" ] || since=$cycle
      fi
      if [ "$fired" -gt 0 ] || stowed_since "$since"; then
        [ "$fresh" -eq 0 ] || record_write || true
        return 0
      fi
      reason="check: stow-due: context ${percent:-?}% at compaction - run the /stow pass; knowledge this session held only in conversation may already be condensed"
      ;;
  esac
  queue_wake "$reason" || die "could not queue the stow-due wake; it is retried at the next report"
  fired=$now
  record_write || true
  printf '%s\n' "$reason"
}

case "${1:-}" in
  context|compacting|cycle) ;;
  threshold) threshold; exit 0 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
TRIGGER_LOCK="$STATE/.stow-trigger.lock"
fm_lock_acquire_wait "$TRIGGER_LOCK"
rc=0
( decide "$@" ) || rc=$?
fm_lock_release "$TRIGGER_LOCK"
exit "$rc"
