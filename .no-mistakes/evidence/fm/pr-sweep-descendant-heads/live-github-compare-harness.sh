#!/usr/bin/env bash
# Drives the real bin/fm-pr-sweep.sh `check` against the REAL GitHub compare API
# (read-only, public repo cli/cli). PR listing/view and the task registry are a
# disposable fixture home (from tests/fm-pr-sweep.test.sh helpers); every
# `gh api repos/.../compare/...` call is forwarded to the real gh.
set -u
WT=$1
cd "$WT"
. tests/lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
SWEEP="$ROOT/bin/fm-pr-sweep.sh"; POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(mktemp -d /tmp/fm-live-sweep.XXXXXX)
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
REAL_JQ=$(command -v jq); REAL_GIT=$(command -v git); REAL_GH=$(command -v gh)
eval "$(sed -n '/^make_home() {/,/^test_green_unarmed_branch_pr_is_armed_with_no_done_line() {/p' tests/fm-pr-sweep.test.sh | sed '$d')"
GREEN='[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-01T00:00:00Z"}]'

B0=0706fa4d513426c0961720732198d6e0f7b54cdd   # merge commit on trunk
L1=3bc352e06367cdae0dc8e708b1f7ddf0aa24c7eb   # single-parent child of B0
L2=b6289046c5b1db0220ffdd472e480387534d01c3   # single-parent child of L1
M3=1863cb7c0f1d27e9479a95edb30ba97fcc6c01b1   # merge commit whose first parent is L2

live_home() {  # <name> <worktree-head> [local-commit]
  local home; home=$(make_home "$1")
  mv "$home/fakebin/gh" "$home/fakebin/gh-fixture"
  cat > "$home/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "api repos/"*) printf 'REAL-GH %s\n' "\$*" >> "$home/forge/real-gh.log"; exec "$REAL_GH" "\$@" ;;
  *) exec "$home/fakebin/gh-fixture" "\$@" ;;
esac
SH
  chmod +x "$home/fakebin/gh"
  local dir="$home/projects/cli"
  git init -q -b main "$dir"; git -C "$dir" remote add origin https://github.com/cli/cli.git
  git -C "$dir" fetch -q --depth=1 origin "$2"
  git -C "$dir" worktree add -q -b fm/t1 "$home/wt-t1" "$2"
  [ -z "${3:-}" ] || commit "$home/wt-t1" "local-only work never pushed"
  fm_write_meta "$home/state/t1.meta" "window=fm-t1" "endpoint_task_id=t1" "worktree=$home/wt-t1" \
    "project=$dir" "kind=ship" "mode=no-mistakes" "yolo=on"
  printf '%s\n' "$home"
}
report() {  # <home> <label>
  local home=$1
  echo "=== $2"
  echo "worktree HEAD: $(git -C "$home/wt-t1" rev-parse HEAD)"
  echo "real gh calls:"; sed 's/^/  /' "$home/forge/real-gh.log" 2>/dev/null || echo "  (none)"
  echo "armed url: $(armed_url "$home" t1 || echo '(not armed)')"
  echo "pr-sweep wakes queued: $(sweep_rows "$home")"
  echo "sweep stdout:"; sed 's/^/  /' "$home/sweep.out"
  echo "sweep stderr:"; sed 's/^/  /' "$home/sweep.err"
  echo
}

h=$(live_home linear "$B0"); forge_prs "$h" cli/cli "101|fm/t1|$GREEN|$L2"; sweep "$h"; report "$h" "A: PR head = worktree HEAD + 2 linear commits (real GitHub compare status=ahead)"
h=$(live_home merge "$L2"); forge_prs "$h" cli/cli "102|fm/t1|$GREEN|$M3"; sweep "$h"; report "$h" "B: PR head descends via a MERGE commit"
h=$(live_home behind "$L2"); forge_prs "$h" cli/cli "103|fm/t1|$GREEN|$L1"; sweep "$h"; report "$h" "C: PR head is BEHIND the worktree HEAD"
h=$(live_home unpushed "$L1" local); forge_prs "$h" cli/cli "104|fm/t1|$GREEN|$L2"; sweep "$h"; report "$h" "D: worktree HEAD is a local commit GitHub never saw (real HTTP 404)"
h=$(live_home badtoken "$B0"); forge_prs "$h" cli/cli "105|fm/t1|$GREEN|$L2"
GH_TOKEN=invalid-token-for-test sweep "$h"; report "$h" "E1: compare fails with a non-404 error (real HTTP 401 via invalid GH_TOKEN)"
sweep "$h"; report "$h" "E2: same home, next sweep with valid auth"
h=$(live_home exact "$L2"); forge_prs "$h" cli/cli "106|fm/t1|$GREEN|$L2"; sweep "$h"; report "$h" "F: PR head == worktree HEAD (no compare needed)"
rm -rf "$TMP_ROOT"
