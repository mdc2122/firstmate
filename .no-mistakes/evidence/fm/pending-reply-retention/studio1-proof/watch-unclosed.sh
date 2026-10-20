#!/usr/bin/env bash
# Real fm-watch.sh on a fresh 444-record home that also holds an unclosed
# escalation: settled history must archive while the open requests and the
# unclosed record stay scanned and beats keep advancing.
# Usage: watch-unclosed.sh <product-root> <work-dir>
set -u
ROOT=$1; W=$2
D0=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$W"
bash "$D0/seed-home.sh" "$ROOT" "$W" > "$W/seed.out" || exit 1
H="$W/h"; S="$H/state"
. "$ROOT/bin/fm-marker-lib.sh"; . "$ROOT/bin/fm-pending-reply-lib.sh"
corr=$(fm_pending_reply_create "$H" "$S" hibit "unclosed escalation proof") || exit 1
fm_pending_reply_mark_delivered "$S" "$corr"
rec=$(fm_pending_reply_path "$S" "$corr")
fm_pending_reply_set "$rec" parent_status "$S/ro/adv.status"
fm_pending_reply_set "$rec" phase recovery_failed
fm_pending_reply_set "$rec" recovery_attempted_epoch 1100
fm_pending_reply_set "$rec" recovery_delivery_outcome failed
mkdir -p "$S/ro"; printf 'note: unrelated\n' > "$S/ro/adv.status"
FM_PENDING_REPLY_NOW=1200 fm_pending_reply_maybe_escalate "$S" "$corr" || { echo "FAIL: could not seed escalation"; exit 1; }
fm_pending_reply_set "$rec" phase resolved
fm_pending_reply_set "$rec" resolved_epoch 1000
chmod 400 "$S/ro/adv.status"; chmod 500 "$S/ro"
bash "$D0/quiet-home.sh" "$ROOT" "$H"
taskpolicy -c utility nice -n 15 bash "$D0/drive-watcher.sh" "$ROOT" "$S" > "$W/watcher.out" 2>&1
# drive-watcher kills itself after 4 beats or an early exit; either way inspect.
cat "$W/watcher.out"
chmod 700 "$S/ro"
rc=0
fail() { echo "FAIL: $*"; rc=1; }
grep -q "^  $corr phase=resolved escalated_epoch=" "$W/watcher.out" || fail "unclosed escalation was not retained in the scan"
[ -f "$rec" ] || fail "unclosed escalation record was removed"
[ -z "$(fm_pending_reply_get "$rec" escalation_closed_epoch)" ] || fail "unclosed escalation was closed"
[ ! -e "$S/pending-replies/archive/$corr" ] || fail "unclosed escalation was archived"
opens=$(find "$S/pending-replies" -maxdepth 1 -type f -exec grep -l '^phase=awaiting_report' {} + | wc -l | tr -d ' ')
[ "$opens" = 2 ] || fail "expected 2 open requests still scanned, found $opens"
archived=$(find "$S/pending-replies/archive" -maxdepth 1 -type f | wc -l | tr -d ' ')
[ "$archived" = 442 ] || fail "expected 442 archived records, found $archived"
beats=$(grep -c ' beat #' "$W/watcher.out")
[ "$beats" -ge 2 ] || fail "watcher beacon did not advance across passes (beats=$beats)"
if [ "$rc" = 0 ]; then echo "WATCHER PASS"; else echo "WATCHER FAIL"; fi
exit "$rc"