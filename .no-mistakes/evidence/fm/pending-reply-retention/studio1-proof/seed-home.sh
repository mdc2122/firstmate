#!/usr/bin/env bash
# Seed a disposable parent home shaped like 2026-10-20 without running a tick:
# 441 resolved + 2 open pending-reply records, one resolved record with its
# escalation still open, and some closed-escalation history. Mirrors the
# evidence driver drive-tick-load.sh so drive-watcher.sh gets a fresh home.
# Usage: seed-home.sh <product-root> <work-dir>
set -u
ROOT=$1; W=$2
rm -rf "$W"; mkdir -p "$W/h/state"
H="$W/h"; S="$H/state"
. "$ROOT/bin/fm-marker-lib.sh"; . "$ROOT/bin/fm-pending-reply-lib.sh"
export FM_PENDING_REPLY_NOW=1000
seed=$(fm_pending_reply_create "$H" "$S" hibit "seed")
fm_pending_reply_mark_delivered "$S" "$seed"
printf 'done [corr=%s]: ok\n' "$seed" > "$S/hibit.status"
fm_pending_reply_try_resolve "$S" "$seed"
D="$S/pending-replies"
for i in $(seq 1 440); do
  c=$(printf '%016x' $((0xa000000000000000 + i)))
  sed "s/^corr_id=.*/corr_id=$c/" "$D/$seed" > "$D/$c"
  if [ $((i % 10)) = 0 ]; then
    sed -i '' "s/^escalated_epoch=.*/escalated_epoch=900/" "$D/$c"; printf 'escalation_closed_epoch=950\n' >> "$D/$c"
  fi
done
oe=ffffffffffff0001
sed -e "s/^corr_id=.*/corr_id=$oe/" -e "s/^escalated_epoch=.*/escalated_epoch=900/" "$D/$seed" > "$D/$oe"
o1=$(fm_pending_reply_create "$H" "$S" hibit "open one"); fm_pending_reply_mark_delivered "$S" "$o1"
o2=$(fm_pending_reply_create "$H" "$S" hibit "open two")
echo "open1=$o1 open2=$o2 open_escalation=$oe"
echo "records before: $(find "$D" -maxdepth 1 -type f | wc -l | tr -d ' ') (resolved: $(grep -l '^phase=resolved' "$D"/* | wc -l | tr -d ' '))"
echo "scanned before: $(find "$D" -maxdepth 1 -type f | wc -l | tr -d ' ') archived before: $(find "$D/archive" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"