#!/usr/bin/env bash
# Behavior tests for bin/fm-durable-job.sh.
#
# The regression is the desktop-hash-lost replica: an agent tool call launched a
# long check as `nohup /bin/bash -c 'h=$(job); printf ... > verdict' &`, the
# tool host killed the call's shell after it returned, and the verdict was never
# written. Here a tool-call-shaped parent runs in its own process group, launches
# the job, exits, and then has its whole process group SIGKILLed (kill-on-drop).
# The vulnerable shape is put through the same kill first and must lose its
# verdict, so the helper case cannot pass vacuously.
#
# Uses a real tmux server isolated through a private TMUX_TMPDIR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

HELPER="$ROOT/bin/fm-durable-job.sh"
TMP_ROOT=$(fm_test_tmproot fm-durable-job)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
export TMUX_TMPDIR="$TMP_ROOT/tmux"
mkdir -p "$TMUX_TMPDIR"
unset TMUX
cleanup_tmux() { tmux kill-server >/dev/null 2>&1 || true; }
trap cleanup_tmux EXIT

# wait_for <file> <tenths>: succeed once <file> exists.
wait_for() {
  local file=$1 left=$2
  while [ ! -e "$file" ]; do
    [ "$left" -gt 0 ] || return 1
    sleep 0.1
    left=$((left - 1))
  done
}

# Run <launch-script> as a tool-call-shaped parent in its own process group,
# let it return, then SIGKILL that whole group the way a tool host drops it.
run_as_dropped_tool_call() {
  local launch=$1 pgid
  set -m
  /bin/bash -c "$launch" &
  pgid=$!
  set +m
  wait "$pgid" 2>/dev/null
  sleep 0.3
  kill -KILL -- "-$pgid" 2>/dev/null || true
}

test_vulnerable_shape_loses_verdict() {
  local dir="$TMP_ROOT/vulnerable" verdict
  mkdir -p "$dir"
  verdict="$dir/verdict.txt"
  # shellcheck disable=SC2016 # The inner script must expand in the job shell.
  run_as_dropped_tool_call "cd '$dir' && nohup /bin/bash -c 'h=\$(sleep 1; echo fakehash); printf \"h=%s\\n\" \"\$h\" > verdict.txt' >/dev/null 2>&1 </dev/null &"
  sleep 2
  [ ! -e "$verdict" ] \
    || fail "control: the nohup bash -c shape survived the dropped tool call, so the replica proves nothing"
  pass "control: nohup bash -c shape loses its verdict when the tool-call group is killed"
}

test_helper_verdict_survives_dropped_tool_call() {
  local dir="$TMP_ROOT/durable" verdict out
  mkdir -p "$dir"
  verdict="$dir/verdict.txt"
  out="$dir/launch.out"
  run_as_dropped_tool_call "cd '$dir' && '$HELPER' replica verdict.txt -- /bin/sh -c 'sleep 1; echo fakehash' > '$out' 2>&1"
  grep -q "^due-check: replica verdict=$verdict " "$out" \
    || fail "launcher did not print the due-check line naming the absolute verdict path: $(cat "$out")"
  wait_for "$verdict" 200 || fail "verdict file never appeared after the tool-call group was killed"
  grep -q '^result=ok exit=0 ' "$verdict" || fail "verdict is not a clean success: $(cat "$verdict")"
  grep -qx 'fakehash' "$verdict.stdout" || fail "job stdout was not captured beside the verdict"
  [ ! -e "$verdict.partial" ] || fail "partial file was left behind after the verdict landed"
  pass "helper verdict survives the dropped tool call that kills the nohup shape"
}

test_failure_records_exit_and_stderr_tail() {
  local dir="$TMP_ROOT/failing" verdict
  mkdir -p "$dir"
  verdict="$dir/verdict.txt"
  (cd "$dir" && "$HELPER" failing verdict.txt -- /bin/sh -c 'echo read-error-here >&2; exit 7' >/dev/null) \
    || fail "launcher failed for a job that starts and then fails"
  wait_for "$verdict" 100 || fail "no verdict written for a failing job"
  grep -q '^result=error exit=7 ' "$verdict" || fail "failing job verdict lacks its exit code: $(cat "$verdict")"
  grep -qx 'read-error-here' "$verdict" || fail "failing job verdict lacks the stderr tail: $(cat "$verdict")"
  pass "failing job verdict records exit code and stderr tail"
}

test_killed_session_still_writes_verdict() {
  local dir="$TMP_ROOT/killed" verdict session
  mkdir -p "$dir"
  verdict="$dir/verdict.txt"
  session=$(cd "$dir" && "$HELPER" killed verdict.txt -- sleep 60 | sed -n 's/.* session=\([^;]*\);.*/\1/p')
  [ -n "$session" ] || fail "could not read the session from the due-check line"
  grep -q '^start=.* pid=[0-9]' "$verdict.partial" || fail "partial lacks start and pid: $(cat "$verdict.partial")"
  grep -qx 'command=sleep 60' "$verdict.partial" || fail "partial lacks the command: $(cat "$verdict.partial")"
  tmux kill-session -t "=$session"
  wait_for "$verdict" 100 || fail "no verdict after the job's session was killed"
  grep -q '^result=error exit=129 ' "$verdict" || fail "killed job verdict lacks the signal exit: $(cat "$verdict")"
  pass "killing the job's tmux session still writes an error verdict"
}

test_refuses_existing_result() {
  local dir="$TMP_ROOT/existing" rc
  mkdir -p "$dir"
  : > "$dir/verdict.txt"
  (cd "$dir" && "$HELPER" again verdict.txt -- true >/dev/null 2>&1); rc=$?
  expect_code 2 "$rc" "an existing verdict file must be refused"
  pass "refuses to reuse an existing verdict file"
}

test_quoted_args_reach_job_verbatim() {
  local dir="$TMP_ROOT/Captain's dir" verdict
  mkdir -p "$dir"
  verdict="$dir/verdict.txt"
  # shellcheck disable=SC2016 # The arguments must reach the job unexpanded.
  (cd "$dir" && "$HELPER" quoted verdict.txt -- printf '%s\n' "it's" 'a $b; c' >/dev/null) \
    || fail "launcher failed for arguments and a cwd containing a single quote"
  wait_for "$verdict" 100 || fail "no verdict written for the quoted-argument job"
  grep -q '^result=ok exit=0 ' "$verdict" || fail "quoted-argument job did not succeed: $(cat "$verdict")"
  # shellcheck disable=SC2016 # Literal fixture must stay unexpanded.
  printf '%s\n' "it's" 'a $b; c' | cmp -s - "$verdict.stdout" \
    || fail "job did not receive its arguments verbatim: $(cat "$verdict.stdout")"
  pass "arguments and paths with quotes, \$ and ; reach the job verbatim"
}

test_vulnerable_shape_loses_verdict
test_helper_verdict_survives_dropped_tool_call
test_failure_records_exit_and_stderr_tail
test_killed_session_still_writes_verdict
test_refuses_existing_result
test_quoted_args_reach_job_verbatim
