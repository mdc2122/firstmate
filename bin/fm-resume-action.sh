#!/usr/bin/env bash
# fm-resume-action.sh - the action half of a resume watch (bin/fm-resume-watch.sh):
# send one fixed-template resume steer to a task still waiting on its own PR.
#
# Usage: fm-resume-action.sh <fm-home> <state-dir> <task-id> <pr-url> merged|live
#
# The `when` runner injects no FM_HOME and no state override into an action, so
# both travel in argv and are exported to bin/fm-send.sh, which refuses to
# resolve a target without an explicit home.
#
# Immediately before sending, it re-runs `bin/fm-resume-cond.sh task-waiting`:
# a task whose record is gone, that recorded `done: verified:`, or whose newest
# status line is not its ready line or a `paused:` line naming exactly
# <pr-url> is not resumed - nothing is sent and the exit is 3 ("not sent: ..."),
# so the watch's outcome reads action-failed and firstmate decides.
#
# Otherwise it sends exactly one steer through bin/fm-send.sh, called by its
# path in this directory so the supervisor action ledger records the send with
# origin fm-resume-action.sh rather than as a direct touch
# (bin/fm-action-ledger-lib.sh). The body is a fixed template that carries only
# the observed fact and no instruction of its own:
#   Resume fact (watch): PR <pr-url> merged. The wait you declared has
#   cleared; continue with the next step your brief or your own last status
#   line already names, and append working: when you resume.
# (`live` reads "PR <pr-url> live in production".) bin/fm-flow-wait.py counts a
# steer opening `Resume fact (watch): ` as a script action, not a firstmate
# touch. Neither a ready line nor a `paused:` line opens a decision record, so
# no --resolve-key is involved.
#
# Exit: 0 the steer is durably recorded in the task's steering inbox; 3 the task
# is not waiting (nothing sent); 2 usage or read error (nothing sent); anything
# else is fm-send's own failure (nothing confirmed delivered).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: fm-resume-action.sh <fm-home> <state-dir> <task-id> <pr-url> merged|live" >&2; exit 2; }

[ "$#" -eq 5 ] || usage
home=$1 state=$2 task=$3 url=$4 form=$5
[ -n "$home" ] && [ -d "$home" ] || usage
[ -n "$state" ] && [ -d "$state" ] || usage
case "$form" in
  merged) fact="PR $url merged" ;;
  live) fact="PR $url live in production" ;;
  *) usage ;;
esac

waiting_rc=0
"$SCRIPT_DIR/fm-resume-cond.sh" task-waiting "$state" "$task" "$url" || waiting_rc=$?
case "$waiting_rc" in
  0) ;;
  3)
    echo "not sent: $task is no longer waiting on $url (its newest status line is not its ready line or a paused: line naming that PR, or it already recorded done: verified:)"
    exit 3
    ;;
  *) echo "not sent: could not read whether $task is waiting on $url (rc=$waiting_rc)"; exit 2 ;;
esac

msg="Resume fact (watch): $fact. The wait you declared has cleared; continue with the next step your brief or your own last status line already names, and append working: when you resume."
FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$SCRIPT_DIR/fm-send.sh" "$task" "$msg"
