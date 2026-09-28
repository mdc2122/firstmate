#!/usr/bin/env bash
# Adversarial live pass on the episode record, real bin/fm-watch.sh + real gh
# against mdc2122/viral-moment#302 (green, conflicting), throwaway lab FM_HOME:
#   1. an unreadable forge (gh missing from PATH) leaves an armed, backdated
#      episode untouched and raises nothing (an unknown reading changes nothing);
#   2. a symlinked record is not trusted: the sweep starts a fresh episode in
#      a regular file instead of alerting from the planted 31-minute-old epoch;
#   3. a corrupted record (non-numeric first-seen) is replaced by a fresh
#      episode rather than alerting or crashing;
#   4. FM_PR_GREEN_BLOCKED_SECS=abc falls back to the 30-minute default.
set -u
ROOT=$(pwd)
URL=https://github.com/mdc2122/viral-moment/pull/302
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
STATE="$LAB/state"
mkdir -p "$LAB/wt" "$LAB/bin" "$LAB/bin-nogh"
git -C "$LAB/wt" init -q && git -C "$LAB/wt" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
ln -s "$(command -v gh)" "$LAB/bin/gh"
ln -s "$(command -v jq)" "$LAB/bin/jq"
ln -s "$(command -v jq)" "$LAB/bin-nogh/jq"
. "$ROOT/bin/fm-pr-lib.sh"
printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$STATE/z-stop.check.sh"
chmod 0700 "$STATE/z-stop.check.sh"
FM_HOME="$LAB" "$ROOT/bin/fm-check-register.sh" z-stop >/dev/null || { echo "register failed"; exit 1; }
printf 'window=fm-task-a\nworktree=%s\npr=%s\n' "$LAB/wt" "$URL" > "$STATE/task-a.meta"
fm_pr_url_parse "$URL" || exit 1
fm_pr_poll_prepare "$STATE" task-a "$FM_PR_PROVIDER" "$URL" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$ROOT/bin/fm-pr-poll.sh" || exit 1
fm_pr_poll_publish_prepared || exit 1
HEAD=$(gh pr view "$URL" --json headRefOid --jq .headRefOid)
echo "lab home: $LAB"; echo "PR under watch: $URL head=$HEAD"

record() { if [ -L "$STATE/task-a.pr-green-blocked" ]; then echo "record: SYMLINK -> $(readlink "$STATE/task-a.pr-green-blocked")"; elif [ -f "$STATE/task-a.pr-green-blocked" ]; then echo "record: $(cat "$STATE/task-a.pr-green-blocked")"; else echo "record: (absent)"; fi; }
cycle() {  # <label> <bindir> [env...]
  local label=$1 bindir=$2 out rc err seq gen; shift 2
  rm -f "$STATE/.last-check"
  echo "--- watcher cycle: $label"
  out=$(perl -MPOSIX=WNOHANG -MTime::HiRes=time,sleep -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } my $left=90; my $last=time; while (waitpid($pid, WNOHANG) == 0) { my $now=time; $left -= $now-$last; $last=$now; if ($left<=0) { kill "TERM",$pid; waitpid $pid,0; exit 124 } sleep 0.02 } exit($?>>8)' \
    env -u NO_MISTAKES_GATE -u FM_CHECK_TIMEOUT "$@" FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 PATH="$bindir:/usr/bin:/bin:/usr/sbin:/sbin" "$ROOT/bin/fm-watch.sh" 2>"$LAB/watch.err")
  rc=$?
  echo "watcher stdout: ${out:-<none>}"; echo "watcher exit: $rc"
  [ ! -s "$LAB/watch.err" ] || { echo "watcher stderr:"; sed 's/^/  /' "$LAB/watch.err"; }
  record
  err="$STATE/.drain.err"
  FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -z "$seq" ] || [ -z "$gen" ] || FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 || echo "ack failed"
}
old=$(( $(date +%s) - 1860 ))

echo; echo "===== 1. unreadable forge: gh absent from PATH, episode already 31 minutes old"
printf '%s %s %s 0\n' "$URL" "$HEAD" "$old" > "$STATE/task-a.pr-green-blocked"; echo "planted:"; record
cycle "1: no gh on PATH (expect no alert, record byte-identical)" "$LAB/bin-nogh"
echo; echo "===== 2. symlinked record planted 31 minutes old"
rm -f "$STATE/task-a.pr-green-blocked"
printf '%s %s %s 0\n' "$URL" "$HEAD" "$old" > "$LAB/planted-record"
ln -s "$LAB/planted-record" "$STATE/task-a.pr-green-blocked"; echo "planted:"; record
cycle "2: symlinked record (expect no alert, fresh regular-file record with a new first-seen and alerted=0)" "$LAB/bin"
[ -L "$STATE/task-a.pr-green-blocked" ] && echo "symlink still in place" || echo "record is now a regular file: $( [ -f "$STATE/task-a.pr-green-blocked" ] && echo yes || echo no )"
echo; echo "===== 3. corrupted record: non-numeric first-seen epoch"
rm -f "$STATE/task-a.pr-green-blocked"
printf '%s %s notanumber 0\n' "$URL" "$HEAD" > "$STATE/task-a.pr-green-blocked"; echo "planted:"; record
cycle "3: corrupted record (expect no alert, replaced by a fresh episode)" "$LAB/bin"
echo; echo "===== 4. FM_PR_GREEN_BLOCKED_SECS=abc with a record that is 31 minutes old (default 1800 applies: alert)"
printf '%s %s %s 0\n' "$URL" "$HEAD" "$old" > "$STATE/task-a.pr-green-blocked"; echo "planted:"; record
cycle "4: invalid threshold falls back to 1800s (expect ONE alert at 31m)" "$LAB/bin" FM_PR_GREEN_BLOCKED_SECS=abc
echo; echo "===== 5. FM_PR_GREEN_BLOCKED_SECS=0 with a fresh record already alerted: still no second alert"
cycle "5: threshold 0, same head already alerted (expect no alert)" "$LAB/bin" FM_PR_GREEN_BLOCKED_SECS=0
echo; echo "lab removed: $LAB"
