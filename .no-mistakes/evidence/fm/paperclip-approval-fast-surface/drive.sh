#!/usr/bin/env bash
H=/tmp/pcfm.WQ0o; R=/Users/studio2/.no-mistakes/worktrees/662ae98237ac/01M3WPKJ11X822NW4B53XHMXS1
iso() { date -u -v-$1M +%Y-%m-%dT%H:%M:%S.000Z; }
run() { echo "$ $*"; "$@"; echo "[rc=$?]"; }
printf '[{"id":"aaaaaaaa-1","type":"request_board_approval","status":"pending","createdAt":"%s","payload":{"title":"old ask (10h)"}},{"id":"bbbbbbbb-2","type":"request_board_approval","status":"pending","createdAt":"%s","payload":{"title":"studio1 service autostart fix (filed 2 min ago)"}}]' "$(iso 600)" "$(iso 2)" > $H/pc/approvals.json
echo "=== Fake Paperclip at http://127.0.0.1:18765 (real HTTP, real curl). Pending approvals:"; jq -c '.[]|{id,createdAt,title:.payload.title}' $H/pc/approvals.json; echo "now: $(date -u +%FT%TZ)"
echo; echo "=== S1: default config, NEW code (target e62b90d)"
run env FM_HOME=$H $R/bin/fm-paperclip-sweep.sh scan
echo; echo "=== S1 baseline: default config, BASE code (45d2183)"
run env FM_HOME=$H $H/base/fm-paperclip-sweep.sh scan
echo; echo "=== S2: queue-zero check wakes firstmate with the fresh approval"
rm -f $H/state/.wake-queue
run env FM_HOME=$H $R/bin/fm-queue-zero.sh check
echo "--- durable wake queue:"; cat $H/state/.wake-queue 2>/dev/null
echo "--- repeat check (same set, expect silence):"
run env FM_HOME=$H $R/bin/fm-queue-zero.sh check
echo; echo "=== S3: home .env FM_PAPERCLIP_APPROVAL_AGE_MINUTES=240"
cp $H/.env $H/.env.bak; echo FM_PAPERCLIP_APPROVAL_AGE_MINUTES=240 >> $H/.env
run env FM_HOME=$H $R/bin/fm-paperclip-sweep.sh scan
echo "--- environment 0 overrides the .env 240:"
run env FM_HOME=$H FM_PAPERCLIP_APPROVAL_AGE_MINUTES=0 $R/bin/fm-paperclip-sweep.sh scan
cp $H/.env.bak $H/.env
echo; echo "=== S4 adversarial: leading-zero values (were octal crashes)"
for v in 08 09 010; do
  run env FM_HOME=$H FM_PAPERCLIP_APPROVAL_AGE_MINUTES=$v $R/bin/fm-paperclip-sweep.sh configured
  run env FM_HOME=$H FM_PAPERCLIP_APPROVAL_AGE_MINUTES=$v $R/bin/fm-paperclip-sweep.sh scan
done
echo "--- leading zero in .env (0090 = 90 min, fresh 2-min approval hidden, 10h shown):"
echo FM_PAPERCLIP_APPROVAL_AGE_MINUTES=0090 >> $H/.env
run env FM_HOME=$H $R/bin/fm-paperclip-sweep.sh scan
echo "--- queue-zero scan with .env 0090 still includes the Paperclip board:"
run env FM_HOME=$H $R/bin/fm-queue-zero.sh scan
cp $H/.env.bak $H/.env
echo "--- leading-zero FM_PAPERCLIP_STALE_HOURS=08 also no longer crashes:"
run env FM_HOME=$H FM_PAPERCLIP_STALE_HOURS=08 $R/bin/fm-paperclip-sweep.sh scan
echo; echo "=== S5 adversarial: malformed values fall back to 0 (list everything)"
for v in soon -5 1.5 ' 30'; do run env FM_HOME=$H "FM_PAPERCLIP_APPROVAL_AGE_MINUTES=$v" $R/bin/fm-paperclip-sweep.sh scan; done
echo; echo "=== S6: legacy FM_PAPERCLIP_APPROVAL_AGE_HOURS=4 no longer imposes a wait"
run env FM_HOME=$H FM_PAPERCLIP_APPROVAL_AGE_HOURS=4 $R/bin/fm-paperclip-sweep.sh scan
echo; echo "=== S7: --help documents the new knob"
$R/bin/fm-paperclip-sweep.sh --help | grep -A3 APPROVAL
