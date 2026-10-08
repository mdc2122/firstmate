#!/usr/bin/env bash
# Drives bin/fm-stow-trigger.sh (the real CLI the omp guard extension calls) against
# disposable FM_HOMEs. Usage: drive-stow-trigger.sh <path-to-fm-stow-trigger.sh>
set -u
TRIGGER=$1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stowdrive.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
touch_epoch() { TZ=UTC0 touch -t "$(TZ=UTC0 date -r "$1" +%Y%m%d%H%M.%S)" "$2"; }
mk() { local h="$TMP/$1"; mkdir -p "$h/state" "$h/config"; echo $$ > "$h/state/.lock"; echo "$h"; }
t() { local h=$1; shift; local out; out=$(FM_HOME="$h" "$TRIGGER" "$@" 2>&1); printf '  $ fm-stow-trigger.sh %-14s -> %s\n' "$*" "${out:-(silent)}"; }
rows() { awk -F '\t' '$3=="check" && $4=="stow-due"' "$1/state/.wake-queue" 2>/dev/null | wc -l | tr -d ' '; }
drain() { : > "$1/state/.wake-queue"; }
rec() { echo "  record: $(tr '\n' ' ' < "$1/state/.stow-trigger")"; }
now=$(date +%s)

echo "== S1 regression: threshold wake -> /stow at 72% -> long session grows to 86% -> compaction"
h=$(mk s1); t "$h" cycle; t "$h" context 71; echo "  queued stow-due rows: $(rows "$h")"; drain "$h"
sleep 1; touch_epoch $(( $(date +%s) + 1 )) "$h/state/.last-stow"; sleep 2
t "$h" context 72; rec "$h"
t "$h" context 76; t "$h" context 79; echo "  queued stow-due rows after growth: $(rows "$h")"
drain "$h"; t "$h" context 86; t "$h" compacting 88; echo "  queued after re-latch: $(rows "$h")"

echo "== S2 boundary: growth of 4 points stays silent, exactly 5 wakes"
h=$(mk s2); t "$h" cycle; t "$h" context 75; drain "$h"
sleep 1; touch_epoch $(( $(date +%s) + 1 )) "$h/state/.last-stow"; sleep 2
t "$h" context 78; t "$h" context 82; echo "  rows at +4: $(rows "$h")"; t "$h" context 83; echo "  rows at +5: $(rows "$h")"

echo "== S3 incident variant: no wake ever fired, a manual /stow at high usage, then growth"
h=$(mk s3); t "$h" cycle; t "$h" context 65
# usage crosses; simulate a wake that never reached the queue by writing the stow first then crossing:
sleep 1; t "$h" context 70 >/dev/null; drain "$h"; rec "$h"
# rewrite fired=0 to model 'no stow-due wake in deliveries log' with a stow after above
sed -i '' 's/^fired=.*/fired=0/' "$h/state/.stow-trigger"; sleep 1
touch_epoch $(( $(date +%s) + 1 )) "$h/state/.last-stow"; sleep 2
t "$h" context 74; rec "$h"; t "$h" context 79; echo "  rows: $(rows "$h")"

echo "== S4 guard: stow before the threshold (daily floor) does not cover; crossing still wakes once, no step wake w/o stow"
h=$(mk s4); touch_epoch $((now - 7200)) "$h/state/.last-stow"; t "$h" cycle; t "$h" context 71; echo "  rows: $(rows "$h")"; drain "$h"
t "$h" context 80; t "$h" context 95; echo "  rows after growth with no new stow: $(rows "$h")"

echo "== S5 guard: high usage held flat after a stow never re-wakes"
h=$(mk s5); t "$h" cycle; t "$h" context 71; drain "$h"
sleep 1; touch_epoch $(( $(date +%s) + 1 )) "$h/state/.last-stow"; sleep 2
for p in 80 80 81 82 84; do t "$h" context $p; done; echo "  rows: $(rows "$h")"

echo "== S6 new fleet-lock holder resets: stale stowed/base not carried"
h=$(mk s6); t "$h" cycle; t "$h" context 71; drain "$h"
sleep 1; touch_epoch $(( $(date +%s) + 1 )) "$h/state/.last-stow"; sleep 2; t "$h" context 72; rec "$h"
echo 999999 > "$h/state/.lock"; t "$h" context 50; rec "$h"; t "$h" context 71; echo "  rows: $(rows "$h")"

echo "== S7 compaction rule unchanged (declined review-1): stow covers cycle, compacting at base+8 stays silent"
h=$(mk s7); t "$h" cycle; t "$h" context 71; drain "$h"
sleep 1; touch_epoch $(( $(date +%s) + 1 )) "$h/state/.last-stow"; sleep 2; t "$h" context 78; t "$h" compacting 86; echo "  rows: $(rows "$h")"
h=$(mk s7b); t "$h" cycle; t "$h" context 40; t "$h" compacting 90; echo "  compaction with no stow and no wake -> rows: $(rows "$h")"
