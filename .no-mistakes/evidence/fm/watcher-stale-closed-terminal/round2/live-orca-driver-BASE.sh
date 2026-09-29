#!/usr/bin/env bash
# Same live drive as live-orca-driver.sh scenarios A and B, but running the
# BASE commit's bin/fm-watch.sh (9b11db8, before the fix) against the same real
# closed Orca terminal, to reproduce the reported false "stopped responding"
# wakes before the fix.
set -u
W=$1; OUT=$2
cd "$W" || exit 1
tmp=$(mktemp "${TMPDIR:-/tmp}/nm-live.XXXXXX")
sed '/^test_[a-z_0-9]*$/d' tests/fm-watch-triage.test.sh > "$tmp"
sed -i '' "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$W/tests#g" "$tmp"
# shellcheck disable=SC1090
. "$tmp"; rm -f "$tmp"
exec > >(tee "$OUT") 2>&1
echo "# BASE (9b11db8, before the fix) watcher drive against the REAL Orca runtime ($(date '+%Y-%m-%d %H:%M:%S')) bin=$WATCH"
seed_task() {
  local state=$1 id=$2 terminal=$3 line=$4 key
  fm_write_meta "$state/$id.meta" "window=fm-$id" "endpoint_task_id=$id" "terminal=$terminal" "kind=ship" "backend=orca"
  printf '%s\n' "$line" > "$state/$id.status"
  printf '%s' "$(seen_sig "$state/$id.status")" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$terminal" | tr ':/.' '___')
  printf '%s' "$(hash_text '')" > "$state/.hash-$key"; printf '480\n' > "$state/.count-$key"
  printf '%s' "$(hash_text '')" > "$state/.stale-$key"; echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
}
report() {
  local state=$1 key=$2 out=$3
  echo "stdout: $(tr '\n' '|' < "$out")"
  echo "stale rows in wake-queue: $(awk -F '\t' '$3 == "stale" { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null)"
  echo "markers now: $(cd "$state" && ls -a | grep -- "-$key$" | tr '\n' ' ')  count=$(cat "$state/.count-$key" 2>/dev/null)"
  [ ! -s "$state/.watch-triage.log" ] || echo "triage log: $(grep -c . "$state/.watch-triage.log") lines; last: $(tail -1 "$state/.watch-triage.log")"
}
run_round() {
  local state=$1 fakebin=$2 key=$3 label=$4 max=$5 out pid start last now adv=0 rc beat
  out="$state/../$label.stdout"; beat="$state/.last-watcher-beat"; rm -f "$beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2> "$state/../$label.stderr" &
  pid=$!; start=$(date +%s); last=
  while :; do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; rc=$?
      echo "--- $label: EXITED rc=$rc after $(( $(date +%s) - start ))s ($adv beacon advances)"; report "$state" "$key" "$out"; return 0; fi
    now=$(file_mtime "$beat"); if [ -n "$now" ] && [ "$now" != "$last" ]; then last=$now; adv=$((adv+1)); fi
    if [ $(( $(date +%s) - start )) -ge "$max" ] && [ "$adv" -ge 6 ]; then break; fi
    sleep 0.2
  done
  reap "$pid"
  echo "--- $label: STILL RUNNING and silent after $(( $(date +%s) - start ))s ($adv beacon advances); killed by driver"
  report "$state" "$key" "$out"
}
CLOSED=term_9cd9e1f8-da6b-4f1f-926b-045a5e5e7e6e
for st in 'done: PR https://github.com/paperclipai/paperclip/pull/14479' 'working: implementing the fallback'; do
  echo; echo "== BASE: closed terminal $CLOSED, status '$st'"
  dir=$(make_case "BASE-${st%%:*}"); state="$dir/state"
  seed_task "$state" task-base "$CLOSED" "$st"
  for i in 1 2 3; do
    run_round "$state" "$dir/fakebin" "$CLOSED" "BASE-${st%%:*}-$i" 15
    if [ -s "$dir/BASE-${st%%:*}-$i.stdout" ]; then ack_stopped_cycle "$state" && echo "acked wake" || echo "ack failed"; fi
  done
done
echo "# done $(date '+%H:%M:%S')"
