#!/usr/bin/env bash
# Live proof of the episode's other edges with the real bin/fm-watch.sh, real
# gh/jq, and the machine's normal GitHub login, in a throwaway lab FM_HOME:
#   A. a stale, already-alerted episode record for the task is removed by a
#      clear reading (a real green, mergeable PR: kunchenguid/firstmate#6010)
#      and raises nothing;
#   B. a real PR that is behind its base but has a red check
#      (mdc2122/viral-moment#312) is not "green-unmergeable": no episode, no alert;
#   C. a real green draft PR (mdc2122/viral-moment#223) opens an episode and,
#      once 31 minutes old, alerts with the draft reason.
# Nothing here writes to GitHub.
set -u
ROOT=$(pwd)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
STATE="$LAB/state"
mkdir -p "$LAB/wt" "$LAB/bin"
git -C "$LAB/wt" init -q && git -C "$LAB/wt" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
ln -s "$(command -v gh)" "$LAB/bin/gh"
ln -s "$(command -v jq)" "$LAB/bin/jq"
LABPATH="$LAB/bin:/usr/bin:/bin:/usr/sbin:/sbin"
. "$ROOT/bin/fm-pr-lib.sh"
printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$STATE/z-stop.check.sh"
chmod 0700 "$STATE/z-stop.check.sh"
FM_HOME="$LAB" "$ROOT/bin/fm-check-register.sh" z-stop >/dev/null || { echo "register failed"; exit 1; }
echo "lab home: $LAB"

arm() {  # <id> <url>
  local id=$1 url=$2
  printf 'window=fm-%s\nworktree=%s\npr=%s\n' "$id" "$LAB/wt" "$url" > "$STATE/$id.meta"
  fm_pr_url_parse "$url" || exit 1
  fm_pr_poll_prepare "$STATE" "$id" "$FM_PR_PROVIDER" "$url" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$ROOT/bin/fm-pr-poll.sh" || { echo "poll prepare failed"; exit 1; }
  fm_pr_poll_publish_prepared || { echo "poll publish failed"; exit 1; }
  echo "armed poll $id -> $url"
  gh pr view "$url" --json state,isDraft,mergeable,mergeStateStatus,headRefOid,statusCheckRollup \
    --jq '"  gh: state=\(.state) draft=\(.isDraft) mergeable=\(.mergeable) mergeState=\(.mergeStateStatus) head=\(.headRefOid) checks=\([.statusCheckRollup[] | (.conclusion // .state)] | join(","))"'
}
disarm() {  # <id>
  rm -f "$STATE/$1.check.sh" "$STATE/$1.pr-poll" "$STATE/$1.pr-poll-registration" "$STATE/$1.meta" "$STATE/$1.pr-green-blocked"
}
record() {  # <id>
  if [ -f "$STATE/$1.pr-green-blocked" ]; then echo "state/$1.pr-green-blocked: $(cat "$STATE/$1.pr-green-blocked")"; else echo "state/$1.pr-green-blocked: (absent)"; fi
}
cycle() {  # <label>
  local out rc err seq gen
  rm -f "$STATE/.last-check"
  echo "--- watcher cycle: $1"
  out=$(perl -MPOSIX=WNOHANG -MTime::HiRes=time,sleep -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } my $left=90; my $last=time; while (waitpid($pid, WNOHANG) == 0) { my $now=time; $left -= $now-$last; $last=$now; if ($left<=0) { kill "TERM",$pid; waitpid $pid,0; exit 124 } sleep 0.02 } exit($?>>8)' \
    env -u NO_MISTAKES_GATE -u FM_CHECK_TIMEOUT FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 PATH="$LABPATH" "$ROOT/bin/fm-watch.sh" 2>"$LAB/watch.err")
  rc=$?
  echo "watcher stdout (the wake firstmate receives): ${out:-<none>}"
  echo "watcher exit: $rc"
  [ ! -s "$LAB/watch.err" ] || { echo "watcher stderr:"; sed 's/^/  /' "$LAB/watch.err"; }
  err="$STATE/.drain.err"
  FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -z "$seq" ] || [ -z "$gen" ] || FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 || echo "ack failed"
}

echo
echo "===== A. clear reading ends a stale already-alerted episode"
arm task-a https://github.com/kunchenguid/firstmate/pull/6010
printf 'https://github.com/kunchenguid/firstmate/pull/6010 7ab9ef576b3ee20118446b261e0150043046216c %s 1\n' "$(( $(date +%s) - 7200 ))" > "$STATE/task-a.pr-green-blocked"
echo "seeded stale record before the cycle:"; record task-a
cycle "A: green and CLEAN pull request (no alert; record removed)"
record task-a
disarm task-a

echo
echo "===== B. behind its base but with a red check is not green-unmergeable"
arm task-b https://github.com/mdc2122/viral-moment/pull/312
cycle "B1: red+BEHIND (no episode expected)"
record task-b
echo "backdating would need a record; there is none, so a second cycle must also stay silent"
cycle "B2: red+BEHIND again (no alert expected)"
record task-b
disarm task-b

echo
echo "===== C. green draft pull request alerts with the draft reason after 30 minutes"
arm task-c https://github.com/mdc2122/viral-moment/pull/223
cycle "C1: first blocked reading opens the episode (no alert expected)"
record task-c
read -r r_url r_head r_first r_alerted < "$STATE/task-c.pr-green-blocked"
printf '%s %s %s %s\n' "$r_url" "$r_head" "$((r_first - 1860))" "$r_alerted" > "$STATE/task-c.pr-green-blocked"
echo "backdated first-seen by 31 minutes:"; record task-c
cycle "C2: episode 31 minutes old (ONE alert with the draft reason expected)"
record task-c
cycle "C3: same head, already alerted (no repeat expected)"
record task-c
echo
echo "lab removed: $LAB"
