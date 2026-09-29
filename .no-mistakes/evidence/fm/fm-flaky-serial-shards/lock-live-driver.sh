#!/usr/bin/env bash
# Live driver for bin/fm-wake-lib.sh lock semantics. Usage: lock-live-driver.sh <repo-root>
set -u
ROOT=$1
LIB="$ROOT/bin/fm-wake-lib.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-lock-live.XXXXXX")
trap 'pkill -P $$ 2>/dev/null; rm -rf "$W"' EXIT
export FM_STATE_OVERRIDE="$W/state"
mkdir -p "$FM_STATE_OVERRIDE"
rc_all=0
say() { printf '%s\n' "$*"; }

# A: holder acquires, then execs a different program (cmdline changes, pid + start time kept).
LOCK="$FM_STATE_OVERRIDE/.exec.lock"
( . "$LIB"; fm_lock_acquire_wait "$LOCK"; exec sleep 30 ) &
holder=$!
for _ in $(seq 1 100); do [ "$(ps -p $holder -o comm= 2>/dev/null)" = sleep ] && break; sleep 0.05; done
say "A: holder pid=$holder now running: $(ps -p $holder -o command=)"
say "A: recorded identity: $(cat "$LOCK/pid-identity" 2>/dev/null || echo '<none>')"
out=$(bash -c '. "$1"; if fm_lock_try_acquire "$2"; then echo STOLEN; else echo "BLOCKED held_pid=$FM_LOCK_HELD_PID"; fi' _ "$LIB" "$LOCK")
say "A: contender -> $out"
[ "$out" = "BLOCKED held_pid=$holder" ] && say "A: PASS live exec'd holder kept its lock" || { say "A: FAIL"; rc_all=1; }

# C: holder dies -> contender reclaims.
kill $holder; wait $holder 2>/dev/null
out=$(bash -c '. "$1"; if fm_lock_try_acquire "$2"; then echo "ACQUIRED pid=$(cat "$2/pid")"; fm_lock_release "$2"; else echo BLOCKED; fi' _ "$LIB" "$LOCK")
say "C: after holder death contender -> $out"
case "$out" in ACQUIRED*) say "C: PASS dead holder reclaimed";; *) say "C: FAIL"; rc_all=1;; esac

# B: recycled pid - lock names a live unrelated pid whose recorded identity has another start time.
LOCK2="$FM_STATE_OVERRIDE/.recycled.lock"
sleep 30 & other=$!
( . "$LIB"; fm_lock_acquire_wait "$LOCK2"; exec sleep 30 ) & h2=$!
for _ in $(seq 1 100); do [ -s "$LOCK2/pid-identity" ] && [ "$(ps -p $h2 -o comm= 2>/dev/null)" = sleep ] && break; sleep 0.05; done
kill $h2; wait $h2 2>/dev/null
# rewrite owner record to claim the live unrelated pid, with a start time from 1999
ownerpid_file=$(ls "$LOCK2"/pid 2>/dev/null || true)
printf '%s\n' "$other" > "$LOCK2/pid"
printf 'Fri Jan  1 00:00:00 1999 sleep 30\n' > "$LOCK2/pid-identity"
out=$(bash -c '. "$1"; if fm_lock_try_acquire "$2"; then echo "ACQUIRED pid=$(cat "$2/pid")"; fm_lock_release "$2"; else echo "BLOCKED held=$FM_LOCK_HELD_PID"; fi' _ "$LIB" "$LOCK2")
say "B: recycled-pid ($other, mismatched start time) contender -> $out"
case "$out" in ACQUIRED*) say "B: PASS recycled pid reclaimed";; *) say "B: FAIL"; rc_all=1;; esac
kill $other 2>/dev/null; wait $other 2>/dev/null

# D: churn - 20 short holders cycle the lock; a bounded contender must acquire (0) or report contention (124), never 1.
LOCK3="$FM_STATE_OVERRIDE/.churn.lock"
for i in $(seq 1 20); do
  ( . "$LIB"; for _ in $(seq 1 15); do fm_lock_acquire_wait "$LOCK3"; sleep 0.02; fm_lock_release "$LOCK3"; done ) &
done
bad=0; codes=""
for i in $(seq 1 8); do
  rc=$(bash -c '. "$1"; fm_lock_acquire_wait_bounded "$2" 1; r=$?; [ $r -eq 0 ] && fm_lock_release "$2"; echo $r' _ "$LIB" "$LOCK3")
  codes="$codes $rc"; case "$rc" in 0|124) ;; *) bad=1;; esac
done
wait
say "D: bounded contender return codes under churn:$codes"
[ $bad -eq 0 ] && say "D: PASS churned contention never reported unsafe (1)" || { say "D: FAIL"; rc_all=1; }
exit $rc_all
