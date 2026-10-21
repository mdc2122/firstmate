#!/usr/bin/env bash
# Behavior tests for fleet task records through the ordinary backend dispatch
# (bin/fm-backend.sh -> bin/backends/fleet.sh -> bin/fm-fleet.sh): the
# recovery-grade agent state a donor host reports (alive, dead, missing, and
# unreadable when the host does not answer - never dead), capture absence only
# on the host's own positive verdict, endpoint metadata validation, and the
# status mirror that appends only the host log's new bytes. ssh and herdr are
# PATH fakes driven by files under the fixture, so no host is contacted.
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
# connection fail like an unreachable host.
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_SSH_DOWN:-}" ] || exit 255
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; -t|-T) shift ;; *) break ;; esac
done
shift
if [ "$*" = "sh -s" ]; then exec sh -s; fi
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
chmod +x "$FAKEBIN/ssh" "$FAKEBIN/herdr"

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

# --- steering record delivery and acknowledgement ---------------------------
printf 'schema=fm-task-inbox.v1\n--\nhello\n' > "$HOME_DIR/state/t1.inbox/001.msg"
FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-fleet.sh" sync t1 >/dev/null
assert_equals "$(cat "$HOME_DIR/state/t1.inbox/001.msg")" "$(cat "$HOST_ROOT/tasks/t1/inbox/001.msg")" \
  "a home steering record reaches the host inbox byte for byte"
mv "$HOST_ROOT/tasks/t1/inbox/001.msg" "$HOST_ROOT/tasks/t1/inbox/handled/"
FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-fleet.sh" sync t1 >/dev/null
assert_present "$HOME_DIR/state/t1.inbox/handled/001.msg" "the host acknowledgement moves the home record to handled/"
assert_absent "$HOST_ROOT/tasks/t1/inbox/001.msg" "a handled record is not delivered again"

pass "fleet backend: validation, agent state, capture, status mirror, steering"
