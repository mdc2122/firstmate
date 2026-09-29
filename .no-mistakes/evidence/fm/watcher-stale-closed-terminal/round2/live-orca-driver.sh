#!/usr/bin/env bash
# Live driver: bin/fm-watch.sh from the worktree under test, polling REAL Orca
# terminals (the real `orca` CLI on PATH, no fake adapter) from a synthetic
# home. Only the crew-state probe is a canned "unknown" verdict, the harness
# default, so a quiet live pane is NOT provably working and surfaces at once.
set -u
W=$1; EV=$2; OUT=$3
cd "$W" || exit 1
tmp=$(mktemp "${TMPDIR:-/tmp}/nm-live.XXXXXX")
sed '/^test_[a-z_0-9]*$/d' tests/fm-watch-triage.test.sh > "$tmp"
sed -i '' "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$W/tests#g" "$tmp"
# shellcheck disable=SC1090
. "$tmp"; rm -f "$tmp"
exec > >(tee "$OUT") 2>&1
echo "# live watcher drive against the REAL Orca runtime ($(date '+%Y-%m-%d %H:%M:%S')) bin=$W/bin/fm-watch.sh orca=$(command -v orca) $(orca --version 2>/dev/null)"

seed_task() {  # <state> <id> <terminal> <status-line>
  local state=$1 id=$2 terminal=$3 line=$4 key
  fm_write_meta "$state/$id.meta" "window=fm-$id" "endpoint_task_id=$id" \
    "terminal=$terminal" "kind=ship" "backend=orca"
  printf '%s\n' "$line" > "$state/$id.status"
  printf '%s' "$(seen_sig "$state/$id.status")" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$terminal" | tr ':/.' '___')
  printf '%s' "$(hash_text '')" > "$state/.hash-$key"
  printf '480\n' > "$state/.count-$key"
  printf '%s' "$(hash_text '')" > "$state/.stale-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  echo "seeded $id terminal=$terminal status='$line' markers: $(cd "$state" && ls -a | grep -- "-$key$" | tr '\n' ' ')"
}

report() {  # <state> <key> <label> <out>
  local state=$1 key=$2 label=$3 out=$4
  echo "stdout: $(tr '\n' '|' < "$out")"
  echo "stale rows in wake-queue: $(awk -F '\t' -v k="$key" '$3 == "stale" { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null)"
  echo "markers now: $(cd "$state" && ls -a | grep -- "-$key$" | tr '\n' ' ')"
  [ ! -e "$state/.endpoint-gone-$key" ] || echo "endpoint-gone marker: $(cat "$state/.endpoint-gone-$key")"
  [ ! -s "$state/.watch-triage.log" ] || echo "triage log: $(grep -c . "$state/.watch-triage.log") lines; last: $(tail -1 "$state/.watch-triage.log")"
}

# run_round <state> <fakebin> <key> <label> <max-secs>: run the watcher until
# it exits (an actionable wake) or has advanced its poll beacon >= 6 times and
# max-secs elapsed while staying silent.
run_round() {
  local state=$1 fakebin=$2 key=$3 label=$4 max=$5 out pid start last now adv=0 rc beat
  out="$state/../$label.stdout"; beat="$state/.last-watcher-beat"; rm -f "$beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2> "$state/../$label.stderr" &
  pid=$!; start=$(date +%s); last=
  while :; do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; rc=$?
      echo "--- $label: EXITED rc=$rc after $(( $(date +%s) - start ))s ($adv beacon advances)"; report "$state" "$key" "$label" "$out"; return 0; fi
    now=$(file_mtime "$beat"); if [ -n "$now" ] && [ "$now" != "$last" ]; then last=$now; adv=$((adv+1)); fi
    if [ $(( $(date +%s) - start )) -ge "$max" ] && [ "$adv" -ge 6 ]; then break; fi
    sleep 0.2
  done
  reap "$pid"
  echo "--- $label: STILL RUNNING and silent after $(( $(date +%s) - start ))s ($adv beacon advances); killed by driver"
  report "$state" "$key" "$label" "$out"
}

CLOSED=term_9cd9e1f8-da6b-4f1f-926b-045a5e5e7e6e   # the incident terminal: firstmate closed it on purpose
echo; echo "== A. incident replay: real closed terminal $CLOSED, finished task (done:), watcher must stay silent and retire pane markers"
echo "orca says: $(orca terminal read --terminal $CLOSED --limit 3 --json | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(JSON.stringify({ok:d.ok,status:d.result.terminal.status,tail:d.result.terminal.tail}))')"
dir=$(make_case A-done-closed); state="$dir/state"
seed_task "$state" paperclip-pi-local-fallback-pr "$CLOSED" 'done: PR https://github.com/paperclipai/paperclip/pull/14479'
run_round "$state" "$dir/fakebin" "$CLOSED" A-done-1 20
run_round "$state" "$dir/fakebin" "$CLOSED" A-done-2 12

echo; echo "== B. real closed terminal $CLOSED, UNFINISHED task (working:): exactly one notice, then silence"
dir=$(make_case B-working-closed); state="$dir/state"
seed_task "$state" worker-b "$CLOSED" 'working: implementing the fallback'
run_round "$state" "$dir/fakebin" "$CLOSED" B-working-1 20
ack_stopped_cycle "$state" && echo "acked wake" || echo "ack failed"
run_round "$state" "$dir/fakebin" "$CLOSED" B-working-2 20
run_round "$state" "$dir/fakebin" "$CLOSED" B-working-3 12

echo; echo "== C. live transition: a REAL scratch terminal opened in Orca, watched while open, then closed under the watcher"
WT='708e814e-bb60-4e51-80a8-ee3640d24f3c::/Users/studio2/orca/workspaces/fm-primary/fm-watcher-stale-closed-terminal'
create=$(orca terminal create --worktree "id:$WT" --title "no-mistakes scratch (safe to close)" --json)
printf '%s\n' "$create" > "$EV/round2/scratch-terminal-create.json"
H=$(printf '%s' "$create" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(d.result.terminal.handle)')
echo "created scratch terminal handle=$H"
trap 'orca terminal close --terminal "$H" --json >/dev/null 2>&1 || true' EXIT
sleep 2
echo "orca says: $(orca terminal read --terminal $H --limit 3 --json | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(JSON.stringify({ok:d.ok,status:d.result.terminal.status,tail:d.result.terminal.tail}))')"
dir=$(make_case C-transition); state="$dir/state"
seed_task "$state" task-scratch "$H" 'working: implementing'
run_round "$state" "$dir/fakebin" "$H" C-open-1 25
ack_stopped_cycle "$state" && echo "acked wake" || echo "ack failed"
run_round "$state" "$dir/fakebin" "$H" C-open-2 15
echo "-- closing the scratch terminal in Orca"
orca terminal close --terminal "$H" --json > "$EV/round2/scratch-terminal-close.json"
echo "close: $(node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify({ok:d.ok,close:d.result&&d.result.close}))' "$EV/round2/scratch-terminal-close.json")"
sleep 2
echo "orca says: $(orca terminal read --terminal $H --limit 3 --json | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(JSON.stringify({ok:d.ok,status:d.result.terminal.status,tail:d.result.terminal.tail}))')"
for i in 1 2 3; do
  run_round "$state" "$dir/fakebin" "$H" C-closed-$i 15
  if [ -s "$dir/C-closed-$i.stdout" ]; then ack_stopped_cycle "$state" && echo "acked wake" || echo "ack failed"; fi
done

echo; echo "== D. adversarial: reads that FAIL must not be taken as absence (markers kept, no endpoint-gone marker, no absence notice)"
for bogus in term_93e67bf9 term_00000000-0000-0000-0000-000000000000; do
  echo "orca raw for $bogus: $(orca terminal read --terminal $bogus --limit 3 --json 2>&1 | tr -d '\n ' | head -c 160) (cli rc=$(orca terminal read --terminal $bogus --limit 3 --json >/dev/null 2>&1; echo $?))"
  dir=$(make_case "D-$bogus"); state="$dir/state"
  seed_task "$state" worker-d "$bogus" 'working: implementing'
  before=$(cat "$state/.hash-$bogus" "$state/.count-$bogus" "$state/.stale-since-$bogus")
  run_round "$state" "$dir/fakebin" "$bogus" "D-$bogus" 12
  after=$(cat "$state/.hash-$bogus" "$state/.count-$bogus" "$state/.stale-since-$bogus" 2>/dev/null)
  [ "$before" = "$after" ] && echo "pane markers unchanged: yes" || echo "pane markers unchanged: NO"
done

echo; echo "== E. regression: a LIVE open worker terminal with a declared paused: status keeps ordinary handling (no absence marker)"
LIVE=$(orca terminal list --json | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));const t=d.result.terminals||d.result;const x=t.find(x=>/93e67bf9/.test(x.handle))||t[0];process.stdout.write(x.handle)')
echo "orca says: $(orca terminal read --terminal $LIVE --limit 2 --json | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(JSON.stringify({ok:d.ok,status:d.result.terminal.status,tail_lines:d.result.terminal.tail.length}))')"
dir=$(make_case E-paused-live); state="$dir/state"
seed_task "$state" worker-e "$LIVE" 'paused: waiting on upstream PR'
run_round "$state" "$dir/fakebin" "$LIVE" E-paused-1 20
echo; echo "# done $(date '+%H:%M:%S')"
