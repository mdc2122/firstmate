#!/usr/bin/env bash
# Live driver: runs the real fm-brief/fm-spawn/fm-promote/fm-teardown CLIs
# against a disposable FM home, project, and git remotes.
set -u
ROOT=${ROOT:?}
export FM_GATE_REFUSE_BYPASS=1  # documented sandbox-fleet bypass; everything below is disposable
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-verify-live.XXXXXX")
trap 'rm -rf "$T"' EXIT
H=$T/home; P=$T/proj; FB=$T/bin
mkdir -p "$H/data" "$H/state" "$H/config" "$P" "$FB"
git -C "$P" init -q
printf '#!/bin/sh\nexit 1\n' > "$FB/tmux"; chmod +x "$FB/tmux"   # backend refuses: proves gate passed before launch
hdr(){ printf '\n===== %s =====\n' "$*"; }
spawn(){ FM_ROOT_OVERRIDE='' FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" \
  FM_PROJECTS_OVERRIDE="$T/none" FM_CONFIG_OVERRIDE="$H/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
  PATH="$FB:$PATH" "$ROOT/bin/fm-spawn.sh" "$@" 2>&1; echo "[exit=$?]"; }
scaffold(){ FM_HOME="$H" "$ROOT/bin/fm-brief.sh" "$1" proj --mode direct-PR 2>&1
  local f=$H/data/$1/brief.md c; c=$(cat "$f"); c=${c//'{TASK}'/Ship the widget.}; c=${c//'{FIRSTMATE_SPEC}'/Build the widget.}
  [ -z "${2+x}" ] || c=${c//'{VERIFY}'/$2}; printf '%s\n' "$c" > "$f"; }

hdr "S1 scaffold: fm-brief.sh ship brief tail"
scaffold s1
awk '/^# Completion observation$/{e=1} e' "$H/data/s1/brief.md"

hdr "S2 spawn with {VERIFY} unfilled"
spawn s1 "$P" claude --mode direct-PR --yolo off
[ -e "$H/state/s1.meta" ] && echo "meta written (BAD)" || echo "no task meta written"

hdr "S3 spawn with brief lacking Completion observation section"
mkdir -p "$H/data/s3"; printf '# Task\n## Captain'"'"'s intent\nShip it.\n\n## Firstmate spec\nBuild it.\n\n# Definition of done\nDelivery contract: mode=direct-PR\n' > "$H/data/s3/brief.md"
spawn s3 "$P" claude --mode direct-PR --yolo off
[ -e "$H/state/s3.meta" ] && echo "meta written (BAD)" || echo "no task meta written"

n=0
while IFS='|' read -r obs; do
  n=$((n+1)); id=s4-$n
  hdr "S4 spawn with verify: $obs"
  scaffold "$id" "$obs" >/dev/null
  spawn "$id" "$P" claude --mode direct-PR --yolo off | grep -vE '^●' | tail -4; [ -e "$H/state/$id.meta" ] && echo "(task meta written: passed verify gate)" || echo "(no task meta)"
done <<'ROWS'
PR merged
Merged and checks green
ready for review
CI passing on main, PR approved
pushed to origin and tests pass
verify:
v2 deployed to staging and /health returns 200
no keychain popups on screen after a fresh login
ROWS

hdr "S6 promote scout without --verify / resting / live"
mkdir -p "$H/data/sc"; printf 'window=fm-sc\nkind=scout\nworktree=/tmp/wt\n' > "$H/state/sc.meta"
printf '# Task\n## Captain'"'"'s intent\nInvestigate the widget.\n\n## Firstmate spec\nShip the widget fix.\n' > "$H/data/sc/brief.md"
pro(){ FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" "$ROOT/bin/fm-promote.sh" sc "$@" 2>&1; echo "[exit=$?]"; grep '^kind=' "$H/state/sc.meta"; }
echo "-- no --verify"; pro --mode direct-PR --yolo off
echo "-- --verify 'PR merged and checks green'"; pro --mode direct-PR --yolo off --verify "PR merged and checks green"
echo "-- --verify '{VERIFY}'"; pro --mode direct-PR --yolo off --verify "{VERIFY}"
echo "-- --verify ''"; pro --mode direct-PR --yolo off --verify ""
echo "-- --verify live"; pro --mode direct-PR --yolo off --verify "widget renders on prod homepage"
echo "-- delivered ship-instructions tail:"; awk '/^# Completion observation$/{e=1} e' "$H/data/sc/ship-instructions.md"

hdr "S7 teardown of a landed ship task"
C=$T/td; mkdir -p "$C/state" "$C/config" "$C/data/task-x1" "$C/fb"
for b in treehouse tmux gh gh-axi no-mistakes; do printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in "pr list") printf "%%s\\n" "count: 0 (showing first 0)" "pull_requests[]: []";; "pr view") exit 1;; esac\nexit 0\n' > "$C/fb/$b"; chmod +x "$C/fb/$b"; done
git init -q --bare "$C/origin.git"; git -C "$C/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$C/origin.git" "$C/seed" 2>/dev/null; git -C "$C/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base; git -C "$C/seed" push -q origin main; rm -rf "$C/seed"
git clone -q "$C/origin.git" "$C/project"; git -C "$C/project" remote set-head origin main 2>/dev/null
git -C "$C/project" worktree add -q -b fm/task-x1 "$C/wt" main
git -C "$C/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
git -C "$C/wt" push -q origin fm/task-x1; git -C "$C/project" fetch -q origin
touch "$C/state/.last-watcher-beat"
printf 'window=firstmate:fm-task-x1\nendpoint_task_id=task-x1\nworktree=%s\nproject=%s\nkind=ship\nmode=direct-PR\nspawn_gen=live-x1\n' "$C/wt" "$C/project" > "$C/state/task-x1.meta"
printf '# Task\nShip it.\n\n# Completion observation\nverify: v2 deployed to staging and /health returns 200\n' > "$C/data/task-x1/brief.md"
td(){ FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$C/state" FM_DATA_OVERRIDE="$C/data" FM_CONFIG_OVERRIDE="$C/config" PATH="$C/fb:$PATH" "$ROOT/bin/fm-teardown.sh" task-x1 "$@" 2>&1; echo "[exit=$?]"; }
echo "-- status: PR ready + merged/green line only, plus empty verified, plus report.md verified: line"
printf '%s\n' 'done: PR https://github.com/example/repo/pull/7 checks green' 'done: verified:' 'done: merged and checks green' > "$C/state/task-x1.status"
printf '# Findings\nverified: reproduced on main\n' > "$C/data/task-x1/report.md"
td | tail -5; [ -d "$C/wt" ] && echo "worktree still present" ; [ -e "$C/state/task-x1.meta" ] && echo "task meta still present"
echo "-- status gains a non-done 'working: verified: ...' line"
printf '%s\n' 'working: verified: staging up' >> "$C/state/task-x1.status"
td | tail -3
echo "-- worker records done: verified:"
printf '%s\n' 'done: verified: staging /health returned 200 for v2 at 14:02Z' >> "$C/state/task-x1.status"
td | tail -4; [ -d "$C/wt" ] && echo "worktree still present" || echo "worktree removed"; [ -e "$C/state/task-x1.meta" ] && echo "task meta still present" || echo "task meta removed"

hdr "S8 classify: done: verified: citing PR is not a ready-signal"
( . "$ROOT/bin/fm-classify-lib.sh"
  for l in 'done: PR https://github.com/o/r/pull/7 checks green' 'done: verified: PR https://github.com/o/r/pull/7 deployed, /health 200'; do
    printf '%s -> ' "$l"; status_line_ready_pr_url "$l" && echo || echo "(not a ready signal, rc=1)"; done )
