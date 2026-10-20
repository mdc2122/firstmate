#!/usr/bin/env bash
# Prove that an unresolved request and a resolved record whose escalation
# genuinely cannot close both stay in the scanned directory, that settled
# history archives with its contents intact, and that nothing is deleted.
# Usage: adversarial.sh <product-root> <work-dir>
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
[ "$(fm_pending_reply_get "$rec" phase)" = escalated ] || { echo "FAIL: escalation did not open"; exit 1; }
fm_pending_reply_set "$rec" phase resolved
fm_pending_reply_set "$rec" resolved_epoch 1000
chmod 400 "$S/ro/adv.status"; chmod 500 "$S/ro"

FM_PENDING_REPLY_NOW=8200 fm_pending_reply_tick "$S"
rc=0
fail() { echo "FAIL: $*"; rc=1; }
[ -f "$rec" ] || fail "resolved record with an unclosed escalation was archived or removed"
[ -z "$(fm_pending_reply_get "$rec" escalation_closed_epoch)" ] || fail "close unexpectedly succeeded"
[ ! -e "$S/pending-replies/archive/$corr" ] || fail "unclosed escalation has an archive copy"
chmod 700 "$S/ro"
opens=$(grep -l '^phase=awaiting_report' "$S/pending-replies"/* 2>/dev/null | wc -l | tr -d ' ')
[ "$opens" = 2 ] || fail "expected 2 open requests still scanned, found $opens"
scanned=$(find "$S/pending-replies" -maxdepth 1 -type f | wc -l | tr -d ' ')
archived=$(find "$S/pending-replies/archive" -maxdepth 1 -type f | wc -l | tr -d ' ')
total=$(find "$S/pending-replies" -type f | wc -l | tr -d ' ')
echo "scanned=$scanned archived=$archived total=$total"
# 445 records seeded in this home: 2 open + 1 unclosed stay scanned, 442 settle.
[ "$scanned" = 3 ] || fail "expected 3 scanned survivors, found $scanned"
[ "$archived" = 442 ] || fail "expected 442 archived records, found $archived"
[ "$total" = 445 ] || fail "expected 445 preserved records, found $total"
seed=$(grep -o '^[a-f0-9]\{16\}$' "$S/pending-replies/archive"/* 2>/dev/null | head -1 | cut -d: -f2)
arch_ok=$(grep -l '^phase=resolved' "$S/pending-replies/archive"/* 2>/dev/null | wc -l | tr -d ' ')
[ "$arch_ok" = 442 ] || fail "archived records lost phase=resolved"
empty=$(find "$S/pending-replies/archive" -maxdepth 1 -type f -size 0 | wc -l | tr -d ' ')
[ "$empty" = 0 ] || fail "archived records include empty files"
for f in "$S/pending-replies/archive"/*; do
  [ "$(fm_pending_reply_get "$f" resolved_epoch)" = 1000 ] || { fail "archived record lost resolved_epoch: $f"; break; }
done
if [ "$rc" = 0 ]; then echo "ADVERSARIAL PASS"; else echo "ADVERSARIAL FAIL"; fi
exit "$rc"