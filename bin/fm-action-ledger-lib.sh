# shellcheck shell=bash
# fm-action-ledger-lib.sh - the supervisor action ledger. This header is the
# one owner of its file, row format, and write rule; every supervisor verb
# records through fm_action_ledger_record and nothing else writes the file.
#
# Why it exists: status lines are wake events and steering inboxes are runtime
# state, so who acted on which task, and when, used to be recoverable only by
# replaying agent transcripts. The ledger makes each supervisor action a fact
# with a timestamp, so wait accounting (bin/fm-flow-wait.py) reads it instead
# of reconstructing it.
#
# File: $STATE/supervisor-actions.jsonl, strictly APPEND-ONLY, one JSON object
# per line. Existing lines are never rewritten, reordered, or deleted; teardown
# keeps it, and truncation, if ever needed, is a captain-approved manual act.
#   {"at":"2026-10-16T05:12:00Z","epoch":1791702720,"task":"<id>",
#    "verb":"<verb>","action":"<action>","target":"<target>","origin":"<origin>"}
#   at/epoch  UTC time of the invocation, taken once the verb has parsed its
#             arguments and before it acts, so a refused or failed action is
#             still recorded as an action someone took.
#   task      the task id the action concerns; empty when it names none (an
#             explicit backend-target steer, a repository-wide merge-line
#             change, or a PR no task has armed).
#   verb      send | control | pr-check | pr-merge | merge-line | captain-hold
#   action    send: steer | key; control: interrupt | exit | relaunch;
#             pr-check: arm; pr-merge: merge; merge-line: declare | undeclare |
#             front | enqueue | remove | prune (one row per entry a sweep
#             drops); captain-hold: hold | answer | answers |
#             bind | unbind | complete | reconcile-requests | reconcile-close |
#             reconcile-note.
#   target    what the action names: the PR or repository URL for the PR verbs
#             and merge lines, the target exactly as given for a steer, the
#             task id for control, the task, origin, or source id for single
#             captain-hold actions, and the arguments as given for its batch
#             intakes (answers, reconcile-requests).
#   origin    "direct" when the verb was run by an agent or person, otherwise
#             the basename of the firstmate script that ran it (fm-watch.sh
#             arming a PR, fm-pr-check.sh enqueueing it on a merge line), so a
#             reader can count supervisor touches without counting automation.
#             The nearest ancestor process running a script from this
#             checkout's bin/ decides it; timeout, perl, and env wrappers are
#             looked through, and any other process means "direct".
# Read-only queries (merge-line show/gate/head/probe, captain-hold
# open/verify/binding/diverged/reconcile list) and usage errors change nothing
# and are not actions, so they write no row.
#
# Write rule: one row per invocation, appended with a single write. A ledger
# failure never blocks, fails, or prints into the verb that recorded it: every
# step is best-effort and the function always returns 0.
#
# Usage (after STATE is set):
#   . "$SCRIPT_DIR/fm-action-ledger-lib.sh"
#   fm_action_ledger_record <verb> <action> <task> <target>

FM_ACTION_LEDGER_FILE_NAME=supervisor-actions.jsonl

_fm_action_ledger_json() {  # <text> -> JSON string body
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s" | LC_ALL=C tr -d '\000-\037\177'
}

_FM_ACTION_LEDGER_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 0 when <path> names a script in this firstmate checkout's own bin/ (a test or
# any other fm-*.sh elsewhere is not firstmate automation).
_fm_action_ledger_is_bin_script() {  # <path>
  case "$1" in */*) ;; *) return 1 ;; esac
  case "${1##*/}" in fm-*.sh) ;; *) return 1 ;; esac
  [ -f "$1" ] || return 1
  [ "$(cd "$(dirname "$1")" 2>/dev/null && pwd)" = "$_FM_ACTION_LEDGER_BIN" ]
}

# Print the basename of the nearest firstmate bin script among this process's
# ancestors, or "direct" when the chain reaches anything else first.
_fm_action_ledger_origin() {
  local pid=${PPID:-} depth=0 row ppid args argv0 argv1 name
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 8 ]; do
    row=$(ps -o ppid= -o args= -p "$pid" 2>/dev/null) || break
    row=${row#"${row%%[![:space:]]*}"}
    [ -n "$row" ] || break
    ppid=${row%%[[:space:]]*}
    args=${row#"$ppid"}
    args=${args#"${args%%[![:space:]]*}"}
    argv0=${args%%[[:space:]]*}
    argv1=${args#"$argv0"}
    argv1=${argv1#"${argv1%%[![:space:]]*}"}
    argv1=${argv1%%[[:space:]]*}
    name=${argv0##*/}
    name=${name#-}
    if _fm_action_ledger_is_bin_script "$argv0"; then
      printf '%s' "$name"
      return 0
    fi
    case "$name" in
      bash|sh|dash|zsh|ksh)
        if _fm_action_ledger_is_bin_script "$argv1"; then
          printf '%s' "${argv1##*/}"
        else
          printf 'direct'
        fi
        return 0
        ;;
      timeout|gtimeout|perl|env|nice|nohup) ;;
      *) printf 'direct'; return 0 ;;
    esac
    pid=$ppid
    depth=$((depth + 1))
  done
  printf 'direct'
}

fm_action_ledger_record() {  # <verb> <action> <task> <target>
  local state=${STATE:-} file epoch at origin row
  {
    [ -n "$state" ] && [ -d "$state" ] || return 0
    file="$state/$FM_ACTION_LEDGER_FILE_NAME"
    [ ! -L "$file" ] || return 0
    epoch=$(date -u +%s) || return 0
    at=$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ) || return 0
    origin=$(_fm_action_ledger_origin) || origin=direct
    row=$(printf '{"at":"%s","epoch":%s,"task":"%s","verb":"%s","action":"%s","target":"%s","origin":"%s"}' \
      "$at" "$epoch" "$(_fm_action_ledger_json "${3-}")" "$(_fm_action_ledger_json "${1-}")" \
      "$(_fm_action_ledger_json "${2-}")" "$(_fm_action_ledger_json "${4-}")" \
      "$(_fm_action_ledger_json "$origin")")
    printf '%s\n' "$row" >> "$file"
  } 2>/dev/null || true
  return 0
}
