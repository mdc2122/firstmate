#!/usr/bin/env bash
# Run a long check detached from the calling agent's tool session so its verdict
# always lands in a file.
#
# Usage: fm-durable-job.sh <name> <result-file> -- <cmd> [args...]
#
# Why: an agent tool call (omp's bash tool, for one) may kill the shell it ran
# shortly after the call returns. A `nohup /bin/bash -c 'h=$(job); printf ... >
# file' &` launched from such a call loses its verdict: the top shell that would
# write the result dies while its `$( ... )` children keep running as orphans.
# This helper owns the whole job instead:
#
# - It starts <cmd> in a new detached tmux session named
#   fm-job-<name>-<epoch>-<pid>, so the job's lifetime belongs to the tmux
#   server, never to the caller's shell or process group.
# - Inside that session a wrapper writes <result-file>.partial first: start time
#   (UTC), wrapper pid, job pid once launched, session, and the command.
# - <cmd> runs with the caller's working directory and PATH, stdin from
#   /dev/null, stdout to <result-file>.stdout and stderr to <result-file>.stderr.
# - When <cmd> ends, or the session is killed (HUP/TERM/INT), the wrapper writes
#   <result-file> atomically: a `result=ok|error exit=<code>` line with start,
#   end, name and command, the stdout/stderr paths, and the stderr tail; it then
#   removes the .partial. Exit code 128+N means the job was stopped by signal N.
#   Only SIGKILL of the wrapper itself can skip the verdict, which the due-check
#   below still catches.
# - The launcher waits up to 10 seconds for the .partial or the verdict to
#   appear, then prints exactly one stdout line for the supervisor:
#     due-check: <name> verdict=<result-file> session=<session> ...
#   Watch the verdict file, not a pid: the job is done when <result-file>
#   exists, and failed when the tmux session is gone and <result-file> is absent.
#
# <name> is [A-Za-z0-9_-]+, so the session name is always a valid tmux target.
# <result-file> may be relative to the current directory, is reported as an
# absolute path, and its directory must exist.
# Refuses (exit 2) when <result-file> or its .partial already exists, so a stale
# verdict is never mistaken for this run's. Exit 1 means the job did not start.
# Requires tmux 3.0 or newer (new-session -e).
#
# macOS privacy (TCC) caveat: the job inherits the removable-volume access of
# the tmux server's launch context and of the binary doing the reading.
# Binaries without a removable-volume grant cannot read FLEET-8TB or other
# /Volumes/* media and are denied without a prompt - launchd jobs (`launchctl
# submit`), /bin/bash as the responsible process, and Homebrew openssl among
# them. Prefer /usr/bin tools or a granted python3 started from a herdr-launched
# session, and probe with a 1 MiB read of the target before a multi-hour run.
set -u

die() {
  printf 'fm-durable-job: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$0"
}

# Single-quote one word for a POSIX shell command string.
sq() {
  local q="'\\''" s=$1
  printf "'%s'" "${s//\'/$q}"
}

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Wrapper mode, run inside the tmux session:
#   --run <name> <session> <result-file> -- <cmd...>
run_job() {
  local name=$1 session=$2 result=$3
  shift 4
  local partial="$result.partial" out="$result.stdout" err="$result.stderr"
  local start cmd_text child='' rc
  start=$(utc_now)
  cmd_text=$(printf '%q ' "$@")
  cmd_text=${cmd_text% }

  write_partial() {
    printf 'start=%s wrapper_pid=%s pid=%s session=%s name=%s\ncommand=%s\n' \
      "$start" "$$" "${child:-pending}" "$session" "$name" "$cmd_text" \
      > "$partial.tmp.$$" && mv -f "$partial.tmp.$$" "$partial"
  }

  write_verdict() {
    local code=$1 note=${2:-} verdict=error tmp="$result.tmp.$$"
    [ "$code" -eq 0 ] && verdict=ok
    {
      printf 'result=%s exit=%s start=%s end=%s name=%s session=%s\n' \
        "$verdict" "$code" "$start" "$(utc_now)" "$name" "$session"
      [ -z "$note" ] || printf 'note=%s\n' "$note"
      printf 'command=%s\n' "$cmd_text"
      printf 'stdout=%s\nstderr=%s\n' "$out" "$err"
      printf -- '--- stderr tail ---\n'
      tail -n 20 "$err" 2>/dev/null
    } > "$tmp"
    mv -f "$tmp" "$result"
    rm -f "$partial"
  }

  # shellcheck disable=SC2329 # Invoked by the traps below.
  on_signal() {
    local sig=$1 num=$2
    trap '' HUP TERM INT
    [ -z "$child" ] || kill -TERM "$child" 2>/dev/null
    write_verdict $((128 + num)) "stopped by SIG$sig before the command finished"
    exit $((128 + num))
  }
  trap 'on_signal HUP 1' HUP
  trap 'on_signal INT 2' INT
  trap 'on_signal TERM 15' TERM

  write_partial
  "$@" </dev/null >"$out" 2>"$err" &
  child=$!
  write_partial
  wait "$child"
  rc=$?
  trap '' HUP TERM INT
  write_verdict "$rc"
  exit "$rc"
}

if [ "${1:-}" = --run ]; then
  shift
  [ "$#" -ge 5 ] && [ "$4" = -- ] || die "internal: malformed --run invocation" 2
  run_job "$@"
fi

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -ge 4 ] && [ "$3" = -- ] || { usage >&2; exit 2; }
NAME=$1
RESULT_ARG=$2
shift 3

case "$NAME" in
  ''|*[!A-Za-z0-9_-]*) die "invalid name '$NAME' (allowed: A-Z a-z 0-9 _ -)" 2 ;;
esac
case "$RESULT_ARG" in
  ''|*/) die "invalid result file '$RESULT_ARG'" 2 ;;
esac
RESULT_DIR=$(cd "$(dirname "$RESULT_ARG")" 2>/dev/null && pwd -P) \
  || die "result directory does not exist: $(dirname "$RESULT_ARG")" 2
RESULT="$RESULT_DIR/$(basename "$RESULT_ARG")"
[ ! -e "$RESULT" ] || die "result file already exists: $RESULT" 2
[ ! -e "$RESULT.partial" ] || die "partial file already exists: $RESULT.partial" 2

command -v tmux >/dev/null 2>&1 || die "tmux not found"

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
SESSION="fm-job-$NAME-$(date +%s)-$$"
! tmux has-session -t "=$SESSION" 2>/dev/null || die "tmux session already exists: $SESSION"

JOB_CMD="exec /bin/bash $(sq "$SELF") --run $(sq "$NAME") $(sq "$SESSION") $(sq "$RESULT") --"
for word in "$@"; do
  JOB_CMD="$JOB_CMD $(sq "$word")"
done

tmux new-session -d -s "$SESSION" -c "$PWD" -e "PATH=$PATH" "$JOB_CMD" \
  || die "tmux new-session failed for $SESSION"

waited=0
while [ ! -e "$RESULT.partial" ] && [ ! -e "$RESULT" ]; do
  [ "$waited" -lt 100 ] \
    || die "job did not record a start within 10s (session $SESSION, expected $RESULT.partial)"
  sleep 0.1
  waited=$((waited + 1))
done

printf 'due-check: %s verdict=%s partial=%s session=%s; done when the verdict file exists, failed when tmux session %s is gone and the verdict file is absent\n' \
  "$NAME" "$RESULT" "$RESULT.partial" "$SESSION" "$SESSION"
