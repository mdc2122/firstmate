#!/usr/bin/env bash
# Build a disposable parent home shaped like 2026-10-20 (441 resolved + 2 open
# pending-reply records), then time fm_pending_reply_tick passes with the given
# product root. Usage: drive-tick-load.sh <product-root> <work-dir>
set -u
ROOT=$1; W=$2
rm -rf "$W"; mkdir -p "$W/h/state"
H="$W/h"; S="$H/state"
. "$ROOT/bin/fm-marker-lib.sh"; . "$ROOT/bin/fm-pending-reply-lib.sh"
export FM_PENDING_REPLY_NOW=1000
# One real resolved record via the product API, cloned as history.
seed=$(fm_pending_reply_create "$H" "$S" hibit "seed")
fm_pending_reply_mark_delivered "$S" "$seed"
printf 'done [corr=%s]: ok\n' "$seed" > "$S/hibit.status"
fm_pending_reply_try_resolve "$S" "$seed"
D="$S/pending-replies"
for i in $(seq 1 440); do
  c=$(printf '%016x' $((0xa000000000000000 + i)))
  sed "s/^corr_id=.*/corr_id=$c/" "$D/$seed" > "$D/$c"
  # every 10th record had an escalation that was later closed
  if [ $((i % 10)) = 0 ]; then
    sed -i '' "s/^escalated_epoch=.*/escalated_epoch=900/" "$D/$c"; printf 'escalation_closed_epoch=950\n' >> "$D/$c"
  fi
done
# One resolved record whose escalation is still OPEN (must not be archived).
oe=ffffffffffff0001
sed -e "s/^corr_id=.*/corr_id=$oe/" -e "s/^escalated_epoch=.*/escalated_epoch=900/" "$D/$seed" > "$D/$oe"
# Two open (unresolved) requests.
o1=$(fm_pending_reply_create "$H" "$S" hibit "open one"); fm_pending_reply_mark_delivered "$S" "$o1"
o2=$(fm_pending_reply_create "$H" "$S" hibit "open two")
echo "open1=$o1 open2=$o2 open_escalation=$oe"
echo "records before: $(find "$D" -maxdepth 1 -type f | wc -l | tr -d ' ') (resolved: $(grep -l '^phase=resolved' "$D"/* | wc -l | tr -d ' '))"
export FM_PENDING_REPLY_NOW=$((1000 + 7200))
for pass in 1 2 3; do
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  fm_pending_reply_tick "$S"
  t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  echo "pass $pass: $(perl -e "printf '%.2f', $t1-$t0")s; scanned=$(find "$D" -maxdepth 1 -type f | wc -l | tr -d ' ') archived=$(find "$D/archive" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
done
for c in "$o1" "$o2" "$oe"; do
  [ -f "$D/$c" ] && echo "still scanned: $c phase=$(fm_pending_reply_get "$D/$c" phase)" || echo "MISSING from scan: $c"
done
[ -d "$D/archive" ] && echo "archived total=$(ls "$D/archive" | wc -l | tr -d ' ') seed_archived=$([ -f "$D/archive/$seed" ] && echo yes || echo no) seed_phase=$(fm_pending_reply_get "$D/archive/$seed" phase 2>/dev/null) seed_resolved_epoch=$(fm_pending_reply_get "$D/archive/$seed" resolved_epoch 2>/dev/null)"
echo "total records preserved (scanned+archive): $(find "$D" -type f | wc -l | tr -d ' ')"
