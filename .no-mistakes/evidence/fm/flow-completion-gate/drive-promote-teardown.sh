#!/usr/bin/env bash
# Manual live driver for the promote --verify gate and the teardown
# recorded-observation gate, against a disposable FM home and git fixture.
set -u
export FM_GATE_REFUSE_BYPASS=1   # sandbox fleet; see bin/fm-gate-refuse-lib.sh
ROOT=${ROOT:?}
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-dod-drive2.XXXXXX")
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

echo "############ PROMOTE ############"
H=$T/phome; mkdir -p "$H/state" "$H/data/sc1"
printf '# Task\n## Captain'\''s intent\nScout it.\n\n## Firstmate spec\nInvestigate.\n' > "$H/data/sc1/brief.md"; touch "$H/state/.last-watcher-beat"
printf 'window=fm-sc1\nkind=scout\nworktree=/tmp/wt\n' > "$H/state/sc1.meta"
prom() { FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" "$ROOT/bin/fm-promote.sh" sc1 "$@" 2>&1; echo "rc=$? meta: $(tr '\n' ' ' < "$H/state/sc1.meta")"; }
echo "--- no --verify"; prom --mode direct-PR --yolo off
echo "--- --verify 'PR merged and checks green'"; prom --mode direct-PR --yolo off --verify "PR merged and checks green"
echo "--- --verify ''"; prom --mode direct-PR --yolo off --verify ""
echo "--- --verify '{VERIFY}'"; prom --mode direct-PR --yolo off --verify "{VERIFY}"
echo "--- --verify 'staging /health returns 200 after deploy'"; prom --mode direct-PR --yolo off --verify "staging /health returns 200 after deploy"
echo "--- delivered ship instructions tail:"; awk '/^# Completion observation$/{e=1} e' "$H/data/sc1/ship-instructions.md" | head -3

echo; echo "############ TEARDOWN ############"
C=$T/case; FB=$C/fakebin; mkdir -p "$C/state" "$C/config" "$C/data/task-x1" "$FB"
for t in treehouse tmux gh; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/$t"; done
printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in "pr list") printf "%%s\\n" "count: 0 (showing first 0)" "pull_requests[]: []";; "pr view") exit 1;; esac\nexit 0\n' > "$FB/gh-axi"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/no-mistakes"
chmod +x "$FB"/*
git init -q --bare "$C/origin.git"; git -C "$C/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$C/origin.git" "$C/seed" 2>/dev/null; git -C "$C/seed" commit -q --allow-empty -m base; git -C "$C/seed" push -q origin main
git clone -q "$C/origin.git" "$C/project"; git -C "$C/project" remote set-head origin main >/dev/null 2>&1
git -C "$C/project" worktree add -q -b fm/task-x1 "$C/wt" main
touch "$C/state/.last-watcher-beat"
printf '%s\n' window=firstmate:fm-task-x1 endpoint_task_id=task-x1 "worktree=$C/wt" "project=$C/project" kind=ship mode=no-mistakes spawn_gen=drive > "$C/state/task-x1.meta"
git -C "$C/wt" commit -q --allow-empty -m "shippable work"; git -C "$C/wt" push -q origin fm/task-x1
# land it: merge into origin main so the work is "merged"
git -C "$C/seed" fetch -q origin; git -C "$C/seed" merge -q --ff-only origin/fm/task-x1; git -C "$C/seed" push -q origin main
git -C "$C/project" fetch -q origin
printf '# Task\nShip it.\n\n# Completion observation\nverify: v2 deployed to staging and /health returns 200\n' > "$C/data/task-x1/brief.md"
td() { FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$C/state" FM_DATA_OVERRIDE="$C/data" FM_CONFIG_OVERRIDE="$C/config" PATH="$FB:$PATH" "$ROOT/bin/fm-teardown.sh" task-x1 "$@" 2>&1; echo "rc=$? meta_still_present=$([ -e "$C/state/task-x1.meta" ] && echo yes || echo no)"; }
echo "--- work merged, status only has ready line + empty 'done: verified:', report.md has a verified: line"
printf '%s\n' 'working: committed; starting validation' 'done: PR https://github.com/example/repo/pull/7 checks green' 'done: verified:' > "$C/state/task-x1.status"
printf '# Findings\nverified: reproduced on main at abc1234\n' > "$C/data/task-x1/report.md"
td
echo "--- 'note: verified: ...' (wrong verb) appended"
echo 'note: verified: looked fine' >> "$C/state/task-x1.status"; td
echo "--- worker appends 'done: verified: <observation>'"
echo 'done: verified: staging /health returned 200 for v2 at 12:03Z' >> "$C/state/task-x1.status"; td
