#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# Usage: fm-pr-check.sh [--merge-order <snapshot>] <task-id> <pr-url>
#        fm-pr-check.sh --merge-order-restore <snapshot> <task-id>
#        fm-pr-check.sh --retry-queued
# Work-in-progress cap (bin/fm-wip-caps-lib.sh REGISTRATION owns the rule): a
# ship whose PR would enter the merges lane is admitted only under the home's
# task-set lock while that lane has a slot no earlier queued registration
# claims. Otherwise this exits 5, records nothing in the task and arms no poll,
# and queues the registration in state/.wip-pr-queue. --retry-queued re-runs
# queued registrations in order, stopping at the first still refused, and
# queues one `check: wip-queue:` wake for each it arms. A same-lane
# re-registration needs no admission and takes no lock, and neither does
# --merge-order, which bin/fm-pr-merge.sh passes so an ordered merge completes
# work instead of being queued behind the cap; it still takes its merges slot.
# When that skips admission, the task's prior registration state (queue order,
# pr=, pr_head=, armed poll, merge-line entry) is written to <snapshot>, a
# private file the caller created; otherwise <snapshot> is left empty. When the
# merge is then refused before any forge merge call, the caller runs
# --merge-order-restore with the same snapshot, which puts every one of those
# back, so a refused merge leaves the cap and the queue order as they were.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-wip-caps-lib.sh
. "$SCRIPT_DIR/fm-wip-caps-lib.sh"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# --retry-queued: re-run each queued registration through this same script, in
# order, and stop at the first one still refused so the queue head arms first.
if [ "${1:-}" = --retry-queued ]; then
  [ "$#" -eq 1 ] || { echo "error: invalid PR check request" >&2; exit 2; }
  while IFS="$(printf '\t')" read -r _order qid qurl _lane; do
    [ -n "$qid" ] || continue
    if [ ! -f "$STATE/$qid.meta" ]; then
      fm_wip_queue_remove "$STATE" "$qid" || true
      continue
    fi
    rc=0
    "$0" "$qid" "$qurl" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || break
    reason="check: wip-queue: $qid's queued PR registration $qurl armed now that a merges slot freed"
    fm_wake_append check "wip-queue-$qid" "$reason" || true
    printf '%s\n' "$reason"
  done <<EOF
$(fm_wip_queue_list "$STATE")
EOF
  exit 0
fi

merge_order_snapshot_valid() {  # <snapshot>
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(fm_pr_file_link_count "$1")" = 1 ]
}

if [ "${1:-}" = --merge-order-restore ]; then
  [ "$#" -eq 3 ] && merge_order_snapshot_valid "$2" && fm_pr_task_id_valid "$3" \
    || { echo "error: invalid PR check request" >&2; exit 2; }
  SNAPSHOT=$2
  ID=$3
  [ -s "$SNAPSHOT" ] || exit 0
  snapshot_field() { grep "^$1=" "$SNAPSHOT" | tail -1 | cut -d= -f2- || true; }
  SNAP_URL=$(snapshot_field url)
  PRIOR_PR=$(snapshot_field pr)
  PRIOR_HEAD=$(snapshot_field pr_head)
  QUEUE_ORDER=$(snapshot_field queue_order)
  QUEUE_URL=$(snapshot_field queue_url)
  PRIOR_POLL=$(snapshot_field poll)
  PRIOR_LISTED=$(snapshot_field merge_line)
  if [ "$(snapshot_field id)" != "$ID" ] || ! fm_pr_url_parse "$SNAP_URL" \
    || { [ -n "$PRIOR_PR" ] && ! fm_pr_url_parse "$PRIOR_PR"; } \
    || { [ -n "$PRIOR_HEAD" ] && ! fm_pr_head_valid "$PRIOR_HEAD"; } \
    || { [ -n "$QUEUE_ORDER" ] && { case "$QUEUE_ORDER" in *[!0-9]*) true ;; *) false ;; esac \
      || ! fm_pr_url_parse "$QUEUE_URL"; }; } \
    || { [ "$PRIOR_POLL" != 0 ] && [ "$PRIOR_POLL" != 1 ]; } \
    || { [ "$PRIOR_LISTED" != 0 ] && [ "$PRIOR_LISTED" != 1 ]; }; then
    echo "error: $ID's merge-order snapshot is unreadable; its registration was not restored" >&2
    exit 1
  fi
  RESTORE_FAILED=0
  META="$STATE/$ID.meta"
  if [ -f "$META" ] && [ ! -L "$META" ]; then
    META_LOCK=$(fm_meta_lock_path "$META") || exit 1
    fm_lock_acquire_wait "$META_LOCK"
    META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || { fm_lock_release "$META_LOCK"; exit 1; }
    if grep -v -e '^pr=' -e '^pr_head=' "$META" > "$META_TMP" || [ "$?" -eq 1 ]; then
      { [ -z "$PRIOR_PR" ] || printf 'pr=%s\n' "$PRIOR_PR"; } >> "$META_TMP" \
        && { [ -z "$PRIOR_HEAD" ] || printf 'pr_head=%s\n' "$PRIOR_HEAD"; } >> "$META_TMP" \
        && chmod 0600 "$META_TMP" && mv -f -- "$META_TMP" "$META" || RESTORE_FAILED=1
    else
      RESTORE_FAILED=1
    fi
    rm -f -- "$META_TMP"
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$PRIOR_POLL" = 0 ]; then
    # shellcheck disable=SC2034 # Read by fm_pr_poll_revoke_final.
    FM_PR_POLL_CHECK_DEST="$STATE/$ID.check.sh"
    # shellcheck disable=SC2034 # Read by fm_pr_poll_revoke_final.
    FM_PR_POLL_REG_DEST="$STATE/$ID.pr-poll-registration"
    # shellcheck disable=SC2034 # Read by fm_pr_poll_revoke_final.
    FM_PR_POLL_DATA_DEST="$STATE/$ID.pr-poll"
    fm_pr_poll_revoke_final || RESTORE_FAILED=1
  fi
  if [ "$PRIOR_LISTED" = 0 ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-merge-line.sh" remove "$SNAP_URL" \
      || RESTORE_FAILED=1
  fi
  if [ -n "$QUEUE_ORDER" ]; then
    fm_wip_queue_restore "$STATE" "$QUEUE_ORDER" "$ID" "$QUEUE_URL" || RESTORE_FAILED=1
  fi
  if [ "$RESTORE_FAILED" = 1 ]; then
    echo "actionable: $ID's refused merge could not fully restore its prior PR registration; check its pr=, merge poll, merge line and $STATE/$FM_WIP_PR_QUEUE_NAME entry" >&2
    exit 1
  fi
  echo "restored: $ID's refused merge left its PR registration as it was before the merge order" >&2
  "$0" --retry-queued || true
  exit 0
fi

MERGE_ORDER_SNAPSHOT=
if [ "${1:-}" = --merge-order ]; then
  [ "$#" -ge 2 ] && merge_order_snapshot_valid "$2" \
    || { echo "error: invalid PR check request" >&2; exit 2; }
  MERGE_ORDER_SNAPSHOT=$2
  shift 2
  : > "$MERGE_ORDER_SNAPSHOT"
fi
if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
# One supervisor action ledger row per arm (bin/fm-action-ledger-lib.sh owns
# the format); best-effort, never blocking.
# shellcheck source=bin/fm-action-ledger-lib.sh
. "$SCRIPT_DIR/fm-action-ledger-lib.sh"
fm_action_ledger_record pr-check arm "$ID" "$URL"

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time for the same reason,
# and treats a recorded value that disagrees as stale rather than authoritative.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
TASK_SET_LOCK=
TASK_SET_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
  if [ "$TASK_SET_LOCK_HELD" = 1 ]; then
    fm_lock_release "$TASK_SET_LOCK" || true
    TASK_SET_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

# Work-in-progress registration admission (header; bin/fm-wip-caps-lib.sh
# REGISTRATION). Only a ship entering merges from another lane is admitted;
# re-recording a PR for a task already in merges, or any --merge-order
# registration, takes no lock and waits on nothing, so a merge never stalls
# behind a spawn or the cap.
wip_queue_refusal() {  # <why>
  if ! fm_wip_queue_add "$STATE" "$ID" "$URL"; then
    echo "error: $ID's PR registration was refused ($1) and could not be queued in $STATE/$FM_WIP_PR_QUEUE_NAME" >&2
    exit 1
  fi
  fm_wip_queue_claims "$STATE" "$ID"
  echo "refused: $ID's PR registration $URL is queued, not armed: $1. It is queued behind ${FM_WIP_QUEUED:-0} earlier registration(s) and arms in order once a merges slot frees." >&2
  exit 5
}
IFS='|' read -r WIP_KIND _WIP_PR WIP_LANE _WIP_BYPASS <<EOF
$(fm_wip_meta_fields "$META")
EOF
fm_wip_task_lane "$STATE" "$ID"
WIP_CURRENT=$FM_WIP_TASK_LANE
fm_wip_record_lane "$STATE" "$ID" "$WIP_KIND" "$URL" "$WIP_LANE"
if [ "$FM_WIP_TASK_LANE" = merges ] && [ "$WIP_CURRENT" != merges ] && [ -n "$MERGE_ORDER_SNAPSHOT" ]; then
  SNAP_QUEUED=$(fm_wip_queue_list "$STATE" | awk -F'\t' -v id="$ID" '$2 == id { print $1 "\t" $3; exit }')
  SNAP_LISTED=0
  if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-merge-line.sh" show "$URL" 2>/dev/null \
    | awk -v u="$URL" '$2 == u { f = 1 } END { exit !f }'; then
    SNAP_LISTED=1
  fi
  SNAP_POLL=0
  [ ! -e "$STATE/$ID.check.sh" ] || SNAP_POLL=1
  printf 'id=%s\nurl=%s\nqueue_order=%s\nqueue_url=%s\npr=%s\npr_head=%s\npoll=%s\nmerge_line=%s\n' \
    "$ID" "$URL" "${SNAP_QUEUED%%$'\t'*}" "${SNAP_QUEUED#*$'\t'}" "$_WIP_PR" \
    "$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)" "$SNAP_POLL" "$SNAP_LISTED" \
    > "$MERGE_ORDER_SNAPSHOT" || exit 1
elif [ "$FM_WIP_TASK_LANE" = merges ] && [ "$WIP_CURRENT" != merges ]; then
  TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") || exit 1
  if ! fm_wip_task_set_lock_acquire "$TASK_SET_LOCK"; then
    wip_queue_refusal "the task-set lock stayed busy for ${FM_WIP_LOCK_WAITED}s, so merges capacity could not be checked"
  fi
  TASK_SET_LOCK_HELD=1
  WIP_STATUS=0
  fm_wip_registration_admit "$CONFIG" "$STATE" "$ID" || WIP_STATUS=$?
  case "$WIP_STATUS" in
    0) ;;
    1) wip_queue_refusal "$FM_WIP_REFUSAL" ;;
    *) echo "error: $ID's PR registration was not checked because its work-in-progress caps could not be read: $FM_WIP_ERROR" >&2; exit 1 ;;
  esac
fi

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0
# The task now holds its merges slot through pr=, so it leaves the queue and
# the task-set lock that guarded its admission is released.
fm_wip_queue_remove "$STATE" "$ID" \
  || printf 'actionable: %s registered but its queued entry could not be removed from %s\n' "$ID" "$STATE/$FM_WIP_PR_QUEUE_NAME" >&2
if [ "$TASK_SET_LOCK_HELD" = 1 ]; then
  fm_lock_release "$TASK_SET_LOCK"
  TASK_SET_LOCK_HELD=0
fi

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
# Arming order is merge-line order: when the PR's repository has a declared
# merge line, bin/fm-merge-line.sh appends it at the tail (a no-op without a
# line or for a PR already listed). A failed append leaves the PR held rather
# than merged out of order, so it is reported, not fatal.
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-merge-line.sh" enqueue "$URL" \
  || printf 'actionable: PR %s is armed but could not join its merge line; it stays held until it is added\n' "$URL" >&2
# The contribution observer uses the same authenticated check mechanism and
# owns verdict freshness, required actors and external feedback separately from
# the exact merged-state poll. Registration is local and performs no forge read.
if command -v jq >/dev/null 2>&1; then
  "$SCRIPT_DIR/fm-contributions.sh" arm >/dev/null \
    || printf 'contributions: observation not armed; coverage is unconfirmed\n' >&2
else
  printf 'contributions: jq unavailable; coverage is unconfirmed\n' >&2
fi
# In a secondmate home the registration itself is a captain-facing fact:
# publish the child's PR-ready line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/fm-parent-channel-lib.sh). A main home has no channel and this is a
# silent no-op there. The poll is armed either way; a channel that cannot be
# written is reported as actionable, and bin/fm-inactive-reconcile.sh still
# delivers the child's own ready line on the next supervision poll.
READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
PR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PR_YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$PR_MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$PR_MODE")"
[ -z "$PR_YOLO" ] || READY_LINE="$READY_LINE yolo=$(fm_parent_channel_clean_note "$PR_YOLO")"
READY_RC=0
fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
printf 'armed: state/%s.check.sh\n' "$ID"
