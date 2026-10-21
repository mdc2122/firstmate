#!/usr/bin/env bash
# Live driver: runs the real bin/fm-watch.sh from <product-root> in a disposable
# home (fake tmux from tests/wake-helpers.sh, private claim root) that has one
# registered process-event source plus a foreign home's leftover claim, while
# other live processes hold BOTH sources' machine-wide locks. Samples the age of
# state/.last-watcher-beat once a second and reports the largest gap.
# Usage: drive-watcher.sh <test-helpers-root> <product-root> <label> [seconds]
set -u
HELPERS=$1; PRODUCT=$2; LABEL=$3; DURATION=${4:-45}
. "$HELPERS/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-watch)
dir=$(make_case watcher-held-lock); dir=$(cd "$dir" && pwd -P)
export FM_PROCEVENT_CLAIM_ROOT="$dir/claims"; mkdir -p "$FM_PROCEVENT_CLAIM_ROOT"; chmod 700 "$FM_PROCEVENT_CLAIM_ROOT"
state="$dir/state"
cat > "$dir/blocker.sh" <<'SH'
#!/usr/bin/env bash
while [ ! -e "$1" ]; do [ "$SECONDS" -lt 120 ] || exit 75; sleep 0.2; done
SH
chmod +x "$dir/blocker.sh"
(unset FM_ROOT_OVERRIDE; FM_HOME="$dir" "$PRODUCT/bin/fm-procevent.sh" register lavish own-src -- "$dir/blocker.sh" "$dir/never" >/dev/null)
printf '%s\n%s\nforeign-token\nforeign-identity\n' "$dir/home-gone" 999999 > "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim"
chmod 600 "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim"

holders=()
for id in ${HOLD_IDS-foreign-src own-src}; do
  bash -c '
    . "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_source_lock_acquire "$2" || exit 1
    trap "fm_procevent_source_lock_release \"$2\"" EXIT
    : > "$3/ready-$2"
    while [ ! -e "$3/release" ]; do sleep 0.05; done
  ' _ "$PRODUCT" "$id" "$dir" &
  holders+=($!)
  while [ ! -e "$dir/ready-$id" ]; do sleep 0.05; done
done

echo "=== [$LABEL] fm-watch.sh with source locks held (${HOLD_IDS-foreign-src own-src}); FM_POLL=1, default lock timeout ==="
PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$PRODUCT/bin/fm-watch.sh" > "$dir/watch.out" 2>"$dir/watch.err" &
wpid=$!
max_age=0; i=0; line=
while [ "$i" -lt "$DURATION" ]; do
  sleep 1; i=$((i + 1))
  if [ -e "$state/.last-watcher-beat" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$state/.last-watcher-beat") ))
  else age=-1; fi
  [ "$age" -gt "$max_age" ] && max_age=$age
  line="$line $age"
  kill -0 "$wpid" 2>/dev/null || { echo "  watcher exited at t=${i}s: $(cat "$dir/watch.out")"; break; }
done
echo "  beacon age (s) sampled each second:$line"
echo "  max beacon age over ${i}s: ${max_age}s"
echo "  foreign claim untouched: $([ -e "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim" ] && echo yes || echo no)"
kill "$wpid" 2>/dev/null; pkill -P "$wpid" 2>/dev/null
: > "$dir/release"; sleep 0.5
for p in ${holders[@]+"${holders[@]}"}; do kill "$p" 2>/dev/null; done
(unset FM_ROOT_OVERRIDE; FM_HOME="$dir" "$PRODUCT/bin/fm-procevent.sh" retire own-src >/dev/null 2>&1)
pkill -f "$dir/blocker.sh" 2>/dev/null
