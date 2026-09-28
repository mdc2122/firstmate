#!/usr/bin/env bash
# Live proof: the real bin/fm-watch.sh, with the real gh/jq and the machine's
# normal GitHub login, watching an armed merge poll for a real open pull request
# that is green but conflicting (mdc2122/viral-moment#302), inside a throwaway
# lab FM_HOME. Nothing here writes to GitHub.
set -u
ROOT=$(pwd)
URL=${1:-https://github.com/mdc2122/viral-moment/pull/302}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
STATE="$LAB/state"
mkdir -p "$LAB/wt" "$LAB/bin"
git -C "$LAB/wt" init -q && git -C "$LAB/wt" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
# Real forge tools, no tmux: the lab never addresses the default tmux server.
ln -s "$(command -v gh)" "$LAB/bin/gh"
ln -s "$(command -v jq)" "$LAB/bin/jq"
LABPATH="$LAB/bin:/usr/bin:/bin:/usr/sbin:/sbin"

. "$ROOT/bin/fm-pr-lib.sh"
printf 'window=fm-task-a\nworktree=%s\npr=%s\n' "$LAB/wt" "$URL" > "$STATE/task-a.meta"
fm_pr_url_parse "$URL" || exit 1
fm_pr_poll_prepare "$STATE" task-a "$FM_PR_PROVIDER" "$URL" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$ROOT/bin/fm-pr-poll.sh" || { echo "poll prepare failed"; exit 1; }
fm_pr_poll_publish_prepared || { echo "poll publish failed"; exit 1; }
printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$STATE/z-stop.check.sh"
chmod 0700 "$STATE/z-stop.check.sh"
FM_HOME="$LAB" "$ROOT/bin/fm-check-register.sh" z-stop >/dev/null || { echo "register failed"; exit 1; }
echo "lab home: $LAB"
echo "armed poll artifacts:"; ls "$STATE" | sed 's/^/  /'
echo "PR under watch: $URL"
gh pr view "$URL" --json state,isDraft,mergeable,mergeStateStatus,headRefOid,statusCheckRollup \
  --jq '"  gh: state=\(.state) draft=\(.isDraft) mergeable=\(.mergeable) mergeState=\(.mergeStateStatus) head=\(.headRefOid) checks=\([.statusCheckRollup[] | (.conclusion // .state)] | join(","))"'

cycle() {  # <label> [env...]
  local label=$1 out rc; shift
  rm -f "$STATE/.last-check"
  echo
  echo "--- watcher cycle: $label"
  out=$(perl -MPOSIX=WNOHANG -MTime::HiRes=time,sleep -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } my $left=90; my $last=time; while (waitpid($pid, WNOHANG) == 0) { my $now=time; $left -= $now-$last; $last=$now; if ($left<=0) { kill "TERM",$pid; waitpid $pid,0; exit 124 } sleep 0.02 } exit($?>>8)' \
    env -u NO_MISTAKES_GATE -u FM_CHECK_TIMEOUT "$@" FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 PATH="$LABPATH" "$ROOT/bin/fm-watch.sh" 2>"$LAB/watch.err")
  rc=$?
  echo "watcher stdout (the wake firstmate receives): ${out:-<none>}"
  echo "watcher exit: $rc"
  [ ! -s "$LAB/watch.err" ] || { echo "watcher stderr:"; sed 's/^/  /' "$LAB/watch.err"; }
  if [ -f "$STATE/task-a.pr-green-blocked" ]; then
    echo "state/task-a.pr-green-blocked: $(cat "$STATE/task-a.pr-green-blocked")"
  else
    echo "state/task-a.pr-green-blocked: (absent)"
  fi
  # acknowledge the delivered wake so the next cycle is a fresh sweep
  local err="$STATE/.drain.err" seq gen
  FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  if [ -n "$seq" ] && [ -n "$gen" ]; then
    FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 || echo "ack failed"
  fi
}

cycle "1: default 30-minute threshold, first blocked reading opens the episode (no alert expected)"
cycle "2: default threshold again a moment later (still under 30 minutes, no alert expected)"
echo
echo "--- backdating the episode's first-seen epoch by 31 minutes to stand in for the wait"
read -r r_url r_head r_first r_alerted < "$STATE/task-a.pr-green-blocked"
printf '%s %s %s %s\n' "$r_url" "$r_head" "$((r_first - 1860))" "$r_alerted" > "$STATE/task-a.pr-green-blocked"
echo "state/task-a.pr-green-blocked: $(cat "$STATE/task-a.pr-green-blocked")"
cycle "3: default threshold, episode now 31 minutes old (ONE alert expected)"
cycle "4: default threshold, same episode and head (no repeat alert expected)"
echo
echo "--- wake rows persisted in the lab home (state/wake*):"
for f in "$STATE"/wake* "$STATE"/.wake*; do [ -f "$f" ] && { echo "  $f:"; sed 's/^/    /' "$f"; }; done
echo
echo "--- forge writes attempted by the lab: gh commands other than 'pr view' would show here"
echo "(the lab PATH only exposes the real gh; the probe and poll are read-only by contract)"
echo "PR after the run:"
gh pr view "$URL" --json state,mergeStateStatus,headRefOid --jq '"  gh: state=\(.state) mergeState=\(.mergeStateStatus) head=\(.headRefOid)"'
echo "lab removed: $LAB"
