#!/usr/bin/env bash
# Live drive of the incident shape: a finished PR worker whose REAL Orca
# terminal (term_9cd9e1f8, closed on purpose by firstmate) keeps its record so
# the armed merge poll stays alive. Real `orca` CLI on PATH; the PR host is the
# pr-check harness's fake `gh` (OPEN then MERGED) so the merge is deterministic.
set -u
W=$1; EV=$2; OUT=$3
cd "$W" || exit 1
export FM_TEST_BASE_PATH="/opt/homebrew/bin:$(dirname "$(command -v node)"):/usr/bin:/bin:/usr/sbin:/sbin"
tmp=$(mktemp "${TMPDIR:-/tmp}/nm-live.XXXXXX")
sed '/^test_[a-z_0-9]*$/d' tests/fm-pr-check-security.test.sh > "$tmp"
sed -i '' "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$W/tests#g" "$tmp"
# shellcheck disable=SC1090
. "$tmp"; rm -f "$tmp"
exec > >(tee "$OUT") 2>&1
CLOSED=term_9cd9e1f8-da6b-4f1f-926b-045a5e5e7e6e
url=https://github.com/paperclipai/paperclip/pull/14479
echo "# live PR-poll drive ($(date '+%Y-%m-%d %H:%M:%S')): real Orca terminal $CLOSED, orca=$(command -v orca), fake gh"
echo "orca says: $(orca terminal read --terminal $CLOSED --limit 3 --json | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(JSON.stringify({ok:d.ok,status:d.result.terminal.status,tail:d.result.terminal.tail}))')"
dir=$(make_case live-closed-terminal-pr-poll); state="$dir/home/state"
write_poll_meta "$state" paperclip-pi-local-fallback-pr "$url" "endpoint_task_id=paperclip-pi-local-fallback-pr" "terminal=$CLOSED" "kind=ship" "backend=orca" "yolo=off"
seed_canonical_poll "$dir" paperclip-pi-local-fallback-pr "$url"
printf 'done: PR %s\n' "$url" > "$state/paperclip-pi-local-fallback-pr.status"
FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$state/paperclip-pi-local-fallback-pr.status"
printf 'd41d8cd98f00b204e9800998ecf8427e' > "$state/.hash-$CLOSED"; printf '486\n' > "$state/.count-$CLOSED"
printf 'd41d8cd98f00b204e9800998ecf8427e' > "$state/.stale-$CLOSED"; echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$CLOSED"
echo "seeded: meta+armed poll, status done:, stale markers count=486: $(cd "$state" && ls -a | grep -- "-$CLOSED$" | tr '\n' ' ')"
echo "-- run 1: PR still OPEN, watcher bounded to 10s"
FM_TEST_GH_STATE=OPEN FM_TEST_GH_LOG="$dir/gh.log" FM_STALE_ESCALATE_SECS=240 run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/w1.out" 2> "$dir/w1.err"; rc=$?
echo "rc=$rc (124 = still running silently when the 10s bound expired)"
echo "stdout: $(tr '\n' '|' < "$dir/w1.out")"
echo "stale rows in wake-queue: $(awk -F '\t' '$3 == "stale" { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null)"
echo "markers now: $(cd "$state" && ls -a | grep -- "-$CLOSED$" | tr '\n' ' ')"
echo "endpoint-gone marker: $(cat "$state/.endpoint-gone-$CLOSED" 2>/dev/null || echo none)"
echo "gh calls while the terminal was closed: $(grep -c "pr view $url" "$dir/gh.log") x 'pr view $url'; first: $(grep -m1 "pr view" "$dir/gh.log")"
echo "triage log: $(cat "$state/.watch-triage.log" 2>/dev/null | tail -2)"
echo "-- run 2+: PR now MERGED"
for attempt in 1 2; do
  rm -f "$state/.last-check"
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/w2.out" 2> "$dir/w2.err"; rc=$?
  echo "attempt $attempt rc=$rc stdout: $(tr '\n' '|' < "$dir/w2.out")"
  case "$(cat "$dir/w2.out")" in
    check:*merged) echo "RESULT: merge reported as a check wake while the terminal stayed closed"; break ;;
    'check: rearm-resurface') ack_watcher_cycle "$state" && echo "acked rearm-resurface" ;;
  esac
done
echo "stale rows in wake-queue at end: $(awk -F '\t' '$3 == "stale" { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null)"
echo "markers at end: $(cd "$state" && ls -a | grep -- "-$CLOSED$" | tr '\n' ' ')"
cp "$state/.wake-queue" "$EV/round2/live-pr-poll-wake-queue.tsv" 2>/dev/null || true
echo "# done $(date '+%H:%M:%S')"
