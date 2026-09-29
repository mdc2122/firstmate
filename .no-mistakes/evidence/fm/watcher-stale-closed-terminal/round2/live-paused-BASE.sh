#!/usr/bin/env bash
# Scenario E on the BASE commit: a LIVE open worker terminal with a declared
# paused: status, to show the first-sight stale wake predates this change.
set -u
W=$1; OUT=$2; cd "$W" || exit 1
tmp=$(mktemp "${TMPDIR:-/tmp}/nm-live.XXXXXX")
sed '/^test_[a-z_0-9]*$/d' tests/fm-watch-triage.test.sh > "$tmp"
sed -i '' "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$W/tests#g" "$tmp"
. "$tmp"; rm -f "$tmp"
exec > >(tee "$OUT") 2>&1
echo "# BASE (9b11db8) watcher, live paused terminal ($(date '+%H:%M:%S')) bin=$WATCH"
LIVE=$(orca terminal list --json | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));const t=d.result.terminals||d.result;const x=t.find(x=>/93e67bf9/.test(x.handle))||t[0];process.stdout.write(x.handle)')
dir=$(make_case E-paused-live-BASE); state="$dir/state"; key=$LIVE
fm_write_meta "$state/worker-e.meta" "window=fm-worker-e" "endpoint_task_id=worker-e" "terminal=$LIVE" "kind=ship" "backend=orca"
printf 'paused: waiting on upstream PR\n' > "$state/worker-e.status"
printf '%s' "$(seen_sig "$state/worker-e.status")" > "$state/.seen-worker-e_status"
printf '%s' "$(hash_text '')" > "$state/.hash-$key"; printf '480\n' > "$state/.count-$key"
printf '%s' "$(hash_text '')" > "$state/.stale-$key"; echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
out="$dir/E.stdout"
PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
  FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
pid=$!; wait_for_exit "$pid" 200; rc=$?
echo "rc=$rc stdout: $(tr '\n' '|' < "$out")"
echo "markers now: $(cd "$state" && ls -a | grep -- "-$key$" | tr '\n' ' ')"
