#!/usr/bin/env bash
# Behavior tests for fleet task records through the ordinary backend dispatch
# (bin/fm-backend.sh -> bin/backends/fleet.sh -> bin/fm-fleet.sh): the
# recovery-grade agent state a donor host reports (alive, dead, missing, and
# unreadable when the host does not answer - never dead), capture absence only
# on the host's own positive verdict, endpoint metadata validation, and the
# status mirror that appends only the host log's new bytes even when syncs
# overlap, release stopping the worker before it snapshots the worktree, and a
# failed launch keeping a record that release can clean up. ssh, herdr and
# tmux are PATH fakes driven by files under the fixture, so no host is
# contacted.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-backend-tests)
HOME_DIR="$TMP_ROOT/home"
HOST_ROOT="$TMP_ROOT/host"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOST_ROOT/run" \
  "$HOST_ROOT/tasks/t1/inbox/handled"

printf 'h1 ssh=h1 os=linux root=%s session=herdr\n' "$HOST_ROOT" > "$HOME_DIR/config/fleet-hosts"
fm_write_meta "$HOME_DIR/state/t1.meta" \
  "window=fleet:t1" "endpoint_task_id=t1" "worktree=/srv/wt/t1" "project=$TMP_ROOT/proj" \
  "harness=omp" "kind=ship" "mode=local-only" "yolo=off" "backend=fleet" "spawn_gen=f1" \
  "fleet_host=h1" "fleet_endpoint=herdr:w2/w2:p1"
touch "$HOME_DIR/state/t1.status"
mkdir -p "$HOME_DIR/state/t1.inbox/handled"

# Fake ssh: `ssh [opts] <alias> sh -s` runs stdin locally (the host is this
# fixture); `ssh [opts] <alias> <cmd>` runs <cmd>. FM_FAKE_SSH_DOWN makes every
# connection fail like an unreachable host; FM_FAKE_SSH_FAIL_ON fails like a
# dropped connection any `sh -s` script containing that text.
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_SSH_DOWN:-}" ] || exit 255
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; -t|-T) shift ;; *) break ;; esac
done
shift
if [ "$*" = "sh -s" ]; then
  script=$(cat)
  case "$script" in *"${FM_FAKE_SSH_FAIL_ON:-}"*) [ -z "${FM_FAKE_SSH_FAIL_ON:-}" ] || exit 255 ;; esac
  printf '%s\n' "$script" | sh -s
  exit $?
fi
exec sh -c "$*"
SH
# Fake herdr: answers `pane get` from FM_FAKE_PANE (present|gone|error) and
# `pane read` with a fixed screen.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in --machine) shift 2 ;; *) break ;; esac; done
case "$1 $2" in
  "pane get")
    case "${FM_FAKE_PANE:-present}" in
      present) printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3" ;;
      gone) echo 'error: pane_not_found' >&2; exit 1 ;;
      *) echo 'error: connection reset' >&2; exit 1 ;;
    esac
    ;;
  "pane read") [ -z "${FM_FAKE_SSH_DOWN:-}" ] || { echo 'error: machine unreachable' >&2; exit 1; }; printf 'worker screen line\n' ;;
  *) exit 0 ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/tmux"
chmod +x "$FAKEBIN/ssh" "$FAKEBIN/herdr" "$FAKEBIN/tmux"

dispatch() {  # <function> <args...>: one fm-backend dispatch call for the home
  FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" bash -c '
    . "$1/bin/fm-backend.sh"
    shift
    "$@"' _ "$ROOT" "$@"
}

# --- endpoint metadata validation -------------------------------------------
out=$(dispatch fm_backend_validate_task_endpoint "$HOME_DIR/state/t1.meta" t1 2>&1)
expect_code 0 $? "a complete fleet record validates: $out"
cp "$HOME_DIR/state/t1.meta" "$TMP_ROOT/bad.meta"
sed -i.bak 's/^window=fleet:t1$/window=fleet:t2/' "$TMP_ROOT/bad.meta"
out=$(dispatch fm_backend_validate_task_endpoint "$TMP_ROOT/bad.meta" t1 2>&1)
expect_code 1 $? "a fleet window naming another task is refused"
assert_contains "$out" "fleet endpoint metadata for task t1 is malformed" "the refusal names the task"

# --- recovery-grade agent state ---------------------------------------------
sleep 60 &
LIVE_PID=$!
printf '%s\n' "$LIVE_PID" > "$HOST_ROOT/run/t1.pid"
assert_equals alive "$(dispatch fm_backend_agent_state fleet fleet:t1)" "a live omp pid on the host reads alive"
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
assert_equals dead "$(FM_FAKE_PANE=present dispatch fm_backend_agent_state fleet fleet:t1)" \
  "omp gone with its Herdr pane present reads dead"
assert_equals missing "$(FM_FAKE_PANE=gone dispatch fm_backend_agent_state fleet fleet:t1)" \
  "omp gone and the pane positively not found reads missing"
assert_equals unreadable "$(FM_FAKE_PANE=error dispatch fm_backend_agent_state fleet fleet:t1)" \
  "a Herdr transport error is unreadable, not missing"
assert_equals unreadable "$(FM_FAKE_SSH_DOWN=1 dispatch fm_backend_agent_state fleet fleet:t1)" \
  "an unreachable host is unreadable, never dead"

# --- capture: absence only on the host's positive verdict -------------------
assert_contains "$(dispatch fm_backend_capture fleet fleet:t1 5)" "worker screen line" "capture reads the remote pane"
FM_FAKE_SSH_DOWN=1 FM_FAKE_PANE=error dispatch fm_backend_capture fleet fleet:t1 5 >/dev/null 2>&1
expect_code 1 $? "an unreachable host is an ordinary read failure, not absence"

# --- status mirror appends only new bytes -----------------------------------
printf 'working: first\n' > "$HOST_ROOT/tasks/t1/status"
FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-fleet.sh" sync t1 >/dev/null
printf 'done: second\n' >> "$HOST_ROOT/tasks/t1/status"
FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-fleet.sh" sync t1 >/dev/null
assert_equals "$(printf 'working: first\ndone: second')" "$(cat "$HOME_DIR/state/t1.status")" \
  "two syncs mirror the host log once, in order"

# --- overlapping syncs mirror each status byte once -------------------------
printf 'working: third\n' >> "$HOST_ROOT/tasks/t1/status"
for _ in 1 2 3 4 5 6; do
  FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-fleet.sh" sync t1 >/dev/null 2>&1 &
done
wait
assert_equals "$(cat "$HOST_ROOT/tasks/t1/status")" "$(cat "$HOME_DIR/state/t1.status")" \
  "concurrent syncs neither duplicate nor skip status lines"

# --- steering record delivery and acknowledgement ---------------------------
printf 'schema=fm-task-inbox.v1\n--\nhello\n' > "$HOME_DIR/state/t1.inbox/001.msg"
FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-fleet.sh" sync t1 >/dev/null
assert_equals "$(cat "$HOME_DIR/state/t1.inbox/001.msg")" "$(cat "$HOST_ROOT/tasks/t1/inbox/001.msg")" \
  "a home steering record reaches the host inbox byte for byte"
mv "$HOST_ROOT/tasks/t1/inbox/001.msg" "$HOST_ROOT/tasks/t1/inbox/handled/"
FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-fleet.sh" sync t1 >/dev/null
assert_present "$HOME_DIR/state/t1.inbox/handled/001.msg" "the host acknowledgement moves the home record to handled/"
assert_absent "$HOST_ROOT/tasks/t1/inbox/001.msg" "a handled record is not delivered again"

# --- teardown never removes an unreleased fleet task ------------------------
out=$(FM_HOME="$HOME_DIR" FM_TEARDOWN_GUARD_DONE=1 PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-teardown.sh" t1 2>&1)
expect_code 1 $? "teardown refuses a fleet task that was not released"
assert_contains "$out" "run bin/fm-fleet.sh release t1 first" "the refusal names the release command"
assert_present "$HOME_DIR/state/t1.meta" "the refused teardown keeps the task record"

# --- a failed launch keeps a record that release cleans up ------------------
PROJ="$TMP_ROOT/proj"
git init -q "$PROJ"
git -C "$PROJ" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
fleet_cmd() {
  FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" FM_FLEET_SAMPLE_CMD="$TMP_ROOT/sample" "$ROOT/bin/fm-fleet.sh" "$@"
}
printf '#!/usr/bin/env bash\necho "os=linux cpus=32 cpu_pct=1 load1=0 load5=0 mem_avail_mb=100000 mem_pressure=normal hour=12 busy=- workers=0"\n' \
  > "$TMP_ROOT/sample"
chmod +x "$TMP_ROOT/sample"
mkdir -p "$HOME_DIR/data/t2"
printf 'do the thing\n' > "$HOME_DIR/data/t2/brief.md"
out=$(fleet_cmd launch t2 "$PROJ" 2>&1)
expect_code 1 $? "a launch whose Herdr workspace does not start fails"
assert_contains "$out" "could not start the worker on h1" "the failure names the host"
assert_equals h1 "$(sed -n 's/^fleet_host=//p' "$HOME_DIR/state/t2.meta")" "the failed launch still records its host"
assert_present "$HOST_ROOT/worktrees/t2" "the host worktree the failed launch made is still there"
assert_absent "$HOME_DIR/state/fleet/t2.reservation" "the failed launch frees its slot"
out=$(fleet_cmd release t2 2>&1)
expect_code 0 $? "release cleans up after the failed launch: $out"
assert_absent "$HOST_ROOT/worktrees/t2" "release removes the orphan worktree"

# --- a launch that fails before its worktree exists is still releasable -----
mkdir -p "$HOME_DIR/data/t4"
printf 'do the thing\n' > "$HOME_DIR/data/t4/brief.md"
out=$(FM_FAKE_SSH_FAIL_ON="git worktree add" fleet_cmd launch t4 "$PROJ" 2>&1)
expect_code 1 $? "a launch whose worktree step drops fails"
assert_contains "$out" "release t4 to clear its record" "the failure points at release"
assert_present "$HOME_DIR/state/t4.meta" "the failed launch keeps its record"
assert_absent "$HOST_ROOT/worktrees/t4" "no worktree was created"
out=$(fleet_cmd release t4 2>&1)
expect_code 0 $? "release succeeds with no host worktree: $out"
assert_equals 0 "$(wc -c < "$HOME_DIR/data/t4/fleet/uncommitted.patch" | tr -d ' ')" "the missing worktree saves an empty patch"
assert_contains "$(cat "$HOME_DIR/state/t4.meta")" "fleet_released=" "the record is marked released for teardown"

# --- release stops the worker before it snapshots the worktree --------------
fm_write_meta "$HOME_DIR/state/t3.meta" \
  "window=fleet:t3" "endpoint_task_id=t3" "worktree=$HOST_ROOT/worktrees/t3" "project=$PROJ" \
  "harness=omp" "kind=ship" "mode=local-only" "yolo=off" "backend=fleet" "spawn_gen=f3" \
  "fleet_host=h1" "fleet_endpoint=herdr:w3/w3:p1"
git -C "$HOST_ROOT/repos/proj.git" branch fm/t3 fm/t2
git -C "$HOST_ROOT/repos/proj.git" worktree add -q "$HOST_ROOT/worktrees/t3" fm/t3
mkdir -p "$HOST_ROOT/tasks/t3" "$HOST_ROOT/sessions/t3"
touch "$HOST_ROOT/tasks/t3/status"
# Workers are detached from this shell so an exited one is reaped, as on a host.
( sh -c 'trap "echo late > \"$1/late.txt\"; exit 0" TERM; while :; do sleep 0.1; done' _ "$HOST_ROOT/worktrees/t3" &
  echo $! > "$HOST_ROOT/run/t3.pid" )
WORKER_PID=$(cat "$HOST_ROOT/run/t3.pid")
out=$(fleet_cmd release t3 2>&1)
expect_code 1 $? "release refuses when the stopping worker leaves uncommitted work"
assert_contains "$out" "has uncommitted work" "the refusal names the uncommitted work"
assert_contains "$(cat "$HOME_DIR/data/t3/fleet/uncommitted.patch")" "late.txt" \
  "the saved patch holds what the worker wrote while stopping"
assert_present "$HOST_ROOT/worktrees/t3/late.txt" "the host worktree keeps the unsaved work"
kill -9 "$WORKER_PID" 2>/dev/null

# --- a worker that ignores SIGTERM is killed before release snapshots -------
( sh -c 'trap "" TERM; while :; do sleep 0.1; done' &
  echo $! > "$HOST_ROOT/run/t3.pid" )
WORKER_PID=$(cat "$HOST_ROOT/run/t3.pid")
fleet_cmd stop t3 >/dev/null 2>&1
expect_code 0 $? "stop succeeds once a SIGTERM-ignoring worker is killed"
kill -0 "$WORKER_PID" 2>/dev/null
expect_code 1 $? "the worker that ignored SIGTERM is gone after stop"
assert_absent "$HOST_ROOT/run/t3.pid" "the pid file goes only with the worker"

# --- a released task is never synced again ----------------------------------
printf '%s' "$(date +%s)" > "$HOST_ROOT/tasks/t2/turn-ended"
rm -f "$HOME_DIR/state/t2.turn-ended"
FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-fleet.sh" sync >/dev/null 2>&1
expect_code 0 $? "the every-task sync skips a released task"
out=$(fleet_cmd sync t2 2>&1)
expect_code 5 $? "syncing one released task refuses"
assert_contains "$out" "t2 was released" "the refusal names the release"
assert_absent "$HOME_DIR/state/t2.turn-ended" "a released task's host turn marker raises no wake"

# --- a released task's saved work is never overwritten ----------------------
printf 'diff --git a/saved b/saved\nsaved work\n' > "$HOME_DIR/data/t2/fleet/uncommitted.patch"
cp "$HOME_DIR/data/t2/fleet/uncommitted.patch" "$TMP_ROOT/t2.patch.before"
for c in fetch release resume stop; do
  fleet_cmd "$c" t2 >/dev/null 2>&1
  expect_code 5 $? "$c refuses a released task"
done
dispatch fm_backend_kill fleet fleet:t2 >/dev/null 2>&1
expect_code 0 $? "closing a released task's endpoint for teardown succeeds"
cmp -s "$TMP_ROOT/t2.patch.before" "$HOME_DIR/data/t2/fleet/uncommitted.patch"
expect_code 0 $? "the released task's saved patch is byte-identical"

# --- a failed fetch keeps the earlier saved copies --------------------------
printf 'older saved patch\n' > "$HOME_DIR/data/t3/fleet/uncommitted.patch"
FM_FAKE_SSH_FAIL_ON="tar -cf" fleet_cmd fetch t3 >/dev/null 2>&1
expect_code 1 $? "a fetch whose session archive drops fails"
assert_equals "older saved patch" "$(cat "$HOME_DIR/data/t3/fleet/uncommitted.patch")" \
  "a failed fetch leaves the earlier saved patch in place"

# --- a gone host worktree never clobbers the saved patch --------------------
printf 'diff --git a/only b/only\nonly copy of the work\n' > "$HOME_DIR/data/t3/fleet/uncommitted.patch"
cp "$HOME_DIR/data/t3/fleet/uncommitted.patch" "$TMP_ROOT/t3.patch.before"
git -C "$HOST_ROOT/repos/proj.git" worktree remove --force "$HOST_ROOT/worktrees/t3"
fleet_cmd fetch t3 >/dev/null 2>&1
expect_code 0 $? "fetch with the host worktree gone still fetches the branch"
cmp -s "$TMP_ROOT/t3.patch.before" "$HOME_DIR/data/t3/fleet/uncommitted.patch"
expect_code 0 $? "fetch keeps the saved patch byte-identical when the worktree is gone"
out=$(fleet_cmd release t3 2>&1)
expect_code 0 $? "release of a task whose worktree is gone records the release: $out"
cmp -s "$TMP_ROOT/t3.patch.before" "$HOME_DIR/data/t3/fleet/uncommitted.patch"
expect_code 0 $? "release keeps the saved patch byte-identical when the worktree is gone"
assert_contains "$(cat "$HOME_DIR/state/t3.meta")" "fleet_released=" "the task is marked released"

pass "fleet backend: validation, agent state, capture, status mirror, steering, teardown gate, launch record, release order, stop escalation, released task refusal, atomic fetch"
