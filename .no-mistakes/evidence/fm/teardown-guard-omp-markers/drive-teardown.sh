#!/usr/bin/env bash
# Live driver: stands up a disposable firstmate home whose project is a real
# snapshot of the firstmate repo (real .omp/extensions, real .gitignore), creates
# a scout worktree, and runs the real bin/fm-teardown.sh against it.
# Usage: drive-teardown.sh <fm-root> <scenario>
set -u
FMROOT=$1 SCEN=$2 SRC=${SRC_REPO:?}
T=$(mktemp -d "${TMPDIR:-/tmp}/fmtd.XXXXXX")
mkdir -p "$T/state" "$T/config" "$T/data" "$T/fakebin"
for b in treehouse tmux; do printf '#!/usr/bin/env bash\nexit 0\n' > "$T/fakebin/$b"; done
cat > "$T/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []";; "pr view") exit 1;; esac
SH
printf '#!/usr/bin/env bash\n[ "${1:-} ${2:-}" = "pr view" ] && exit 1; exit 0\n' > "$T/fakebin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/fakebin/no-mistakes"
chmod +x "$T/fakebin"/*
g() { git -c user.email=t@t -c user.name=t "$@"; }
git init -q --bare "$T/origin.git"; git -C "$T/origin.git" symbolic-ref HEAD refs/heads/main
mkdir "$T/project"
if [ "$SCEN" = project-state-extensions ]; then
  echo "# some other project" > "$T/project/README.md"
else
  (cd "$SRC" && git archive HEAD) | tar -x -C "$T/project"
fi
git -C "$T/project" init -q -b main; g -C "$T/project" add -A; g -C "$T/project" commit -q -m snapshot
git -C "$T/project" remote add origin "$T/origin.git"; git -C "$T/project" push -q origin main
git -C "$T/project" fetch -q origin; git -C "$T/project" remote set-head origin main
git -C "$T/project" worktree add -q -b fm/fm-loose-ends-0930-1002 "$T/wt" main
touch "$T/state/.last-watcher-beat"
WT=$T/wt
markers() {
  mkdir -p "$WT/state/extensions/omp-primary-watch"
  printf 'sha256:deadbeef\n4242\n' > "$WT/state/.omp-turnend-extension-loaded"
  printf 'sha256:deadbeef\n4242\n' > "$WT/state/.omp-watch-extension-loaded"
  printf 'gen owner=start\n' > "$WT/state/extensions/omp-primary-watch/session-generations.log"
  printf '{"version":2,"pending":[]}\n' > "$WT/state/extensions/omp-primary-watch/session-replacement-actionable.json"
}
REPORT="# Loose ends

Swept the open loose ends; nothing here is a deliverable."
CWD=$T
case $SCEN in
  markers-only) markers ;;
  cite-state-dir) markers; REPORT="# Loose ends

The worktree's state/ held only omp runtime markers; nothing in \`state/\` is a deliverable." ;;
  cite-marker-path) markers; REPORT="# Watch handoff

The pending handoff is in state/extensions/omp-primary-watch/session-replacement-actionable.json." ;;
  project-state-extensions) mkdir -p "$WT/state/extensions"; printf 'export const plugin = 1;\n' > "$WT/state/extensions/foo.ts"
    REPORT="# Plugin

Wrote the plugin to state/extensions/foo.ts." ;;
  firstmate-other-state-extensions) markers; printf 'export const plugin = 1;\n' > "$WT/state/extensions/foo.ts"
    REPORT="# Plugin

Wrote the plugin to state/extensions/foo.ts." ;;
  real-work-beside-markers) markers; mkdir -p "$WT/findings"; printf '{"task":1,"answer":"42"}\n' > "$WT/findings/answers.jsonl"
    REPORT="# Sweep

Kept graded answers in \`findings/answers.jsonl\`; the state/ markers are runtime noise." ;;
  cwd-markers) mkdir -p "$T/home/state" "$WT/state"; printf 'x\n' > "$T/home/state/.omp-watch-extension-loaded"
    printf 'x\n' > "$WT/state/.omp-turnend-extension-loaded"; CWD=$T/home
    REPORT="# Loose ends

Nothing in \`state/\` is a deliverable; it is runtime noise, not work." ;;
esac
. "$FMROOT/lib/fm-meta.sh" 2>/dev/null || true
cat > "$T/state/task-x1.meta" <<M
window=firstmate:fm-task-x1
endpoint_task_id=task-x1
worktree=$WT
project=$T/project
kind=scout
mode=no-mistakes
decisions_reviewed=1
decision_keys=
spawn_gen=teardown-test-task-x1
M
mkdir -p "$T/data/task-x1"; printf '%s\n' "$REPORT" > "$T/data/task-x1/report.md"
echo "## scenario=$SCEN fm-root=$FMROOT"
echo "## worktree untracked/ignored files:"; (cd "$WT" && find state findings -type f 2>/dev/null | sort | sed 's/^/   /')
echo "## report:"; sed 's/^/   /' "$T/data/task-x1/report.md"
cd "$CWD"
FM_ROOT_OVERRIDE="$FMROOT" FM_STATE_OVERRIDE="$T/state" FM_DATA_OVERRIDE="$T/data" FM_CONFIG_OVERRIDE="$T/config" \
  PATH="$T/fakebin:$PATH" "$FMROOT/bin/fm-teardown.sh" task-x1 > "$T/out" 2> "$T/err"
rc=$?
echo "## fm-teardown.sh exit=$rc"
echo "## stderr:"; sed 's/^/   /' "$T/err"
echo "## task meta after: $([ -e "$T/state/task-x1.meta" ] && echo present || echo removed)"
rm -rf "$T"
