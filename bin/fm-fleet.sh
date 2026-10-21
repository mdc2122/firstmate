#!/usr/bin/env bash
# fm-fleet.sh - place bounded omp ship workers on donor hosts with headroom.
#
# Usage:
#   fm-fleet.sh setup <host> [--omp-version V]
#                       install omp and the gateway-only model config under
#                       the host's root
#   fm-fleet.sh hosts   sample every configured host; one verdict per host
#   fm-fleet.sh place <task-id>
#                       pick a host and hold a deadline-bound reservation;
#                       prints the host, exit 4 when no host has headroom (the
#                       task stays queued - a host is never overloaded)
#   fm-fleet.sh launch <task-id> <project-dir> [--model M] [--effort E] [--yolo on|off]
#                       place, then start the worker on the chosen host and
#                       record the task (backend=fleet, mode=local-only)
#   fm-fleet.sh sync [<task-id>]
#                       mirror status, turn-end and busy home and deliver
#                       pending steering records; no id = every fleet task
#   fm-fleet.sh ring|key|type <task-id> ...
#                       steering doorbell, one named key, or literal text
#   fm-fleet.sh peek <task-id> [lines]   print the worker's pane
#   fm-fleet.sh attach <task-id>         how to open the worker
#   fm-fleet.sh state <task-id>          alive|dead|missing|unreadable
#   fm-fleet.sh stop <task-id>           end omp, close the endpoint, keep work
#   fm-fleet.sh fetch <task-id>          branch, uncommitted diff and omp
#                                        session home (read-only on the host)
#   fm-fleet.sh resume <task-id>         relaunch omp on the same host and
#                                        worktree from its saved session
#   fm-fleet.sh release <task-id>        stop the worker, fetch, then free
#                                        the slot; refuses while unfetched
#                                        uncommitted work remains
#
# sync <id>, ring, key, type, stop, fetch, resume, and release exit 5 for a
# released task (fleet_released= in its record) and change nothing.
#
# Opt-in: nothing here runs unless config/fleet-hosts exists; the config
# grammar and placement rule are owned by bin/fm-fleet-lib.sh, and the
# operator contract (setup, launch, monitoring, recovery, removal) by
# docs/fleet-placement.md.
#
# What runs where:
# - The worker runs on the host in the endpoint its host record names
#   (session=herdr, the default: a workspace fm-<id> on the host's own
#   `fm-fleet` Herdr server, which this machine's Herdr shows under the saved
#   machine fleet-<host>; session=tmux, only for a host whose record gives a
#   tmux_reason=: a detached tmux session fm-<id>). Either way it outlives
#   every SSH disconnect. Running work never moves between hosts.
# - The worktree is a git worktree of a host-local bare mirror under
#   <root>/repos, filled from this machine over SSH, so hosts need no GitHub
#   credential. Results come back the same way (`fetch`); hosts never push.
# - omp runs from <root>/bin/omp with PI_CODING_AGENT_DIR=<root>/agent, an
#   isolated agent dir holding only a models.yml whose providers point at the
#   studio1 gateway, so the host's own omp/pi/claude configs are untouched and
#   no OAuth session is copied. The gateway key is written once by setup with
#   mode 0600.
# - omp sessions live in <root>/sessions/<task-id>, outside the worktree, so
#   `resume` continues the same conversation with `--resume <file>`.
# - The worker appends status lines and acknowledges steering records inside
#   <root>/tasks/<task-id>/, mirrored home by `sync` into this home's ordinary
#   state/<id>.status, state/<id>.inbox, and state/<id>.turn-ended. The task
#   record's backend=fleet routes fm-send, fm-peek, fm-crew-state, fm-control
#   and fm-teardown to bin/backends/fleet.sh, which calls back into this file.
#
# Reservations: `place` takes this home's fleet lock, samples every host,
# counts this home's unexpired reservations, and writes the winner's
# reservation (host plus deadline) before releasing the lock, so two
# concurrent launches can never both take a host's last slot. `launch` drops
# the reservation once the worker's pid appears in the host's own sample; a
# launch that dies first frees the slot at the deadline. `launch` writes the
# task record before it creates anything task-specific on the host, so a
# launch that fails part way still leaves a record that stop and release use.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
HOSTS_FILE="$CONFIG/fleet-hosts"
FLEET_STATE="$STATE/fleet"
SSH_TIMEOUT=${FM_FLEET_SSH_TIMEOUT:-10}

# shellcheck source=bin/fm-fleet-lib.sh
. "$SCRIPT_DIR/fm-fleet-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

die() {
  echo "fm-fleet: $*" >&2
  exit 1
}

usage() {
  sed -n '2,/^set -euo pipefail$/{/^set -euo pipefail$/d;s/^# \{0,1\}//;p;}' "$0"
}

sq() {
  local q="'\\''" s=$1
  printf "'%s'" "${s//\'/$q}"
}

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

require_fleet() {
  [ -f "$HOSTS_FILE" ] || die "fleet placement is off: $HOSTS_FILE does not exist (docs/fleet-placement.md)"
}

# fleet_ssh <alias> <remote-sh-source>: run POSIX sh source on the host with
# stdin as the script. No agent forwarding, bounded connect and dead-peer
# detection; exit 255 means the transport failed and completion is unknown.
# The remote PATH is fixed rather than read from shell startup files, which a
# non-interactive SSH command never sources: Homebrew and the account's own
# ~/.local/bin and ~/bin come first so tmux, git, and herdr resolve on macOS.
# shellcheck disable=SC2016 # expands on the host, not here
FLEET_REMOTE_PATH='PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"; export PATH'
fleet_ssh() {
  local alias=$1 script=$2
  printf '%s\n%s\n' "$FLEET_REMOTE_PATH" "$script" | ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
    -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o ForwardAgent=no \
    -o ClearAllForwardings=yes "$alias" sh -s
}

meta_of() { printf '%s/%s.meta' "$STATE" "$1"; }

task_field() {  # <id> <key>
  fm_meta_get "$(meta_of "$1")" "$2"
}

set_task_field() {  # <id> <key> <value>: replace one meta field atomically
  local meta tmp
  meta=$(meta_of "$1")
  tmp="$STATE/.$1.meta.fleet.$$"
  { grep -v "^$2=" "$meta" || true; printf '%s=%s\n' "$2" "$3"; } >"$tmp" && mv "$tmp" "$meta"
}

# require_unreleased <id>: refuse, with exit 5, any command that acts on a
# released task's host state; its worktree is gone and data/<id>/fleet holds
# the only copy of what it saved.
require_unreleased() {
  local at
  at=$(task_field "$1" fleet_released)
  [ -n "$at" ] || return 0
  echo "fm-fleet: task $1 was released at $at; its saved work is in $DATA/$1/fleet and nothing was changed" >&2
  exit 5
}

task_host_record() {  # <id>
  local host
  host=$(task_field "$1" fleet_host)
  [ -n "$host" ] || die "task $1 is not a fleet task (no fleet_host= in its record)"
  fm_fleet_host_record "$HOSTS_FILE" "$host"
}

# --- reservations -----------------------------------------------------------
#
# A reservation is state/fleet/<id>.reservation holding one line
# "host=<name> deadline=<epoch>". It holds a slot only until the worker
# starts (its pid file then counts in the host's sample) or the deadline
# passes, so a launch that dies before starting frees its slot on its own.
# FM_FLEET_RESERVATION_TTL (seconds, default 600) sets the deadline.

RESERVATION_TTL=${FM_FLEET_RESERVATION_TTL:-600}

reservation_host() {  # <id> -> host name of an unexpired reservation
  local f="$FLEET_STATE/$1.reservation" line deadline
  [ -f "$f" ] || return 1
  line=$(cat "$f")
  deadline=$(fm_fleet_host_field "$line" deadline 0)
  case "$deadline" in ''|*[!0-9]*) return 1 ;; esac
  [ "$deadline" -gt "$(date +%s)" ] || return 1
  fm_fleet_host_field "$line" host
}

pending_on() {  # <host> [<exclude-id>] -> unexpired, not-yet-started reservations
  local host=$1 exclude=${2:-} n=0 f id
  [ -d "$FLEET_STATE" ] || { printf 0; return 0; }
  for f in "$FLEET_STATE"/*.reservation; do
    [ -f "$f" ] || continue
    id=${f##*/}
    id=${id%.reservation}
    [ "$id" != "$exclude" ] || continue
    [ "$(reservation_host "$id" 2>/dev/null)" = "$host" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# sample_host <record>: one sample line, or empty when the host did not
# answer. FM_FLEET_SAMPLE_CMD, when set, is run as `<cmd> <host-name>` in place
# of the SSH probe (the portable test seam); its stdout is the sample.
sample_host() {
  local rec=$1 alias root tz procs
  if [ -n "${FM_FLEET_SAMPLE_CMD:-}" ]; then
    "$FM_FLEET_SAMPLE_CMD" "${rec%% *}" 2>/dev/null | tail -n 1 || true
    return 0
  fi
  alias=$(fm_fleet_host_field "$rec" ssh)
  root=$(fm_fleet_host_field "$rec" root)
  tz=$(fm_fleet_host_field "$rec" tz)
  procs=$(fm_fleet_host_field "$rec" busy_procs)
  fleet_ssh "$alias" "$(fm_fleet_probe_script "$root" "$tz" "$procs")" 2>/dev/null | tail -n 1 || true
}

# verdicts [<exclude-task-id>]: sample every host in parallel, advance each
# host's availability state (state/fleet/<host>.availability), and print one
# fm_fleet_evaluate line per host.
verdicts() {
  local exclude=${1:-} records rec name tmp now sample avail
  records=$(fm_fleet_hosts "$HOSTS_FILE") || exit 1
  mkdir -p "$FLEET_STATE"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet.XXXXXX")
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    sample_host "$rec" >"$tmp/${rec%% *}" &
  done <<EOF
$records
EOF
  wait
  now=$(date +%s)
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    name=${rec%% *}
    sample=$(cat "$tmp/$name")
    avail=$(fm_fleet_availability "$FLEET_STATE/$name.availability" "$rec" "$sample" "$now")
    printf '%s%s\n' "$(fm_fleet_evaluate "$rec" "$sample" "$avail" "$(pending_on "$name" "$exclude")")" "$(tmux_note "$rec")"
  done <<EOF
$records
EOF
  rm -rf "$tmp"
}

cmd_hosts() {
  require_fleet
  verdicts
}

# place: exit 0 printing the host, exit 4 when no host has headroom (the task
# stays queued; nothing ever overloads a host).
cmd_place() {
  local id=$1 lock out host
  require_fleet
  valid_id "$id" || die "invalid task id '$id'"
  mkdir -p "$FLEET_STATE"
  if host=$(reservation_host "$id"); then
    printf '%s\n' "$host"
    return 0
  fi
  lock="$FLEET_STATE/.place.lock"
  fm_lock_acquire_wait "$lock"
  out=$(verdicts "$id")
  if ! host=$(fm_fleet_pick "$out"); then
    rm -f "$FLEET_STATE/$id.reservation"
    fm_lock_release "$lock"
    printf '%s\n' "$out" >&2
    echo "fm-fleet: no host has headroom for $id; it stays queued - retry later" >&2
    return 4
  fi
  printf 'host=%s deadline=%s\n' "$host" "$(( $(date +%s) + RESERVATION_TTL ))" >"$FLEET_STATE/$id.reservation"
  fm_lock_release "$lock"
  printf '%s\n' "$out" >&2
  printf '%s\n' "$host"
}

# --- remote layout ----------------------------------------------------------

remote_paths() {  # <root> <id> -> sets R_* globals
  R_ROOT=$1
  R_TASK="$1/tasks/$2"
  R_WT="$1/worktrees/$2"
  R_SESS="$1/sessions/$2"
  R_PID="$1/run/$2.pid"
}

# The worker-side extension: busy state and turn-end markers written inside
# the host's task dir, mirrored home by `sync`. Same event contract as the
# local omp extension in bin/fm-spawn.sh (agent_end without willContinue is
# idle; subagent events are ignored).
remote_extension() {  # <task-dir>
  cat <<EOF
import { appendFileSync, writeFileSync } from "node:fs";
const dir = "$1";
const isSubagent = (ctx: any) => ctx?.agent?.kind === "sub";
const mark = (state: string, event: string) => {
  try {
    writeFileSync(dir + "/busy", state + " " + event + " " + Math.floor(Date.now() / 1000) + "\\n");
  } catch {}
};
export default function (pi: any) {
  pi.on("agent_start", (_e: any, ctx: any) => { if (!isSubagent(ctx)) mark("busy", "agent-start"); });
  pi.on("agent_end", (e: any, ctx: any) => {
    if (isSubagent(ctx) || (e && e.willContinue === true)) return;
    mark("idle", "agent-end");
  });
  pi.on("turn_end", (_e: any, ctx: any) => {
    if (isSubagent(ctx)) return;
    try { appendFileSync(dir + "/turn-ended", ""); writeFileSync(dir + "/turn-ended", String(Date.now())); } catch {}
  });
}
EOF
}

# --- launch -----------------------------------------------------------------

# --- worker endpoint: Herdr (visible in studio2's Herdr view) or tmux -------
#
# session=herdr (the default) hosts the worker in a workspace of the host's
# own `fm-fleet` Herdr server, driven from this machine through the
# saved-machine profile fleet-<host> (`herdr --machine fleet-<host> ...`), so
# the worker shows in this machine's Herdr sidebar under that machine with no
# SSH command. session=tmux is only the fallback for a host that cannot run
# Herdr; its record carries tmux_reason=, which every verdict and launch
# prints. It hosts the worker in a detached tmux session fm-<id> on the host.
# The endpoint string recorded as fleet_endpoint= is
# `herdr:<workspace-id>/<pane-id>` or `tmux:fm-<id>`.

host_session() {  # <record>
  fm_fleet_host_field "$1" session herdr
}

# tmux_note <record>: " (session=tmux: <reason>)" for a tmux-fallback host,
# nothing for a Herdr host.
tmux_note() {
  [ "$(host_session "$1")" = tmux ] || return 0
  printf ' (session=tmux, not in the Herdr view: %s)' "$(fm_fleet_host_field "$1" tmux_reason)"
}

herdr_machine() {  # <record> -> saved-machine label
  printf 'fleet-%s' "${1%% *}"
}

# fleet_herdr <record> <herdr args...>: one API command on the host's fm-fleet
# Herdr server through this machine's saved-machine profile.
fleet_herdr() {
  local rec=$1
  shift
  herdr --machine "$(herdr_machine "$rec")" "$@"
}

# endpoint_start <record> <id>: start the staged launcher; prints the endpoint.
endpoint_start() {
  local rec=$1 id=$2 alias out ws pane
  alias=$(fm_fleet_host_field "$rec" ssh)
  case "$(host_session "$rec")" in
    herdr)
      out=$(fleet_herdr "$rec" workspace create --cwd "$R_WT" --label "fm-$id" --no-focus) || return 1
      ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
      pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
      [ -n "$ws" ] && [ -n "$pane" ] || { echo "fm-fleet: herdr returned no workspace or pane for fm-$id" >&2; return 1; }
      fleet_herdr "$rec" pane run "$pane" "$R_TASK/launch.sh" >/dev/null || {
        fleet_herdr "$rec" workspace close "$ws" >/dev/null 2>&1 || true
        return 1
      }
      printf 'herdr:%s/%s\n' "$ws" "$pane"
      ;;
    *)
      fleet_ssh "$alias" "set -e
tmux has-session -t $(sq "=fm-$id") 2>/dev/null && { echo 'tmux session already exists' >&2; exit 1; }
tmux new-session -d -s $(sq "fm-$id") -c $(sq "$R_WT") $(sq "$R_TASK/launch.sh")
tmux set-option -t $(sq "fm-$id") remain-on-exit on >/dev/null
" || return 1
      printf 'tmux:fm-%s\n' "$id"
      ;;
  esac
}

# endpoint_of <id>: the recorded endpoint (older records have none: tmux).
endpoint_of() {
  local e
  e=$(task_field "$1" fleet_endpoint)
  printf '%s' "${e:-tmux:fm-$1}"
}

# endpoint_exists <record> <endpoint>: 0 present, 1 absent, 2 unreadable.
endpoint_exists() {
  local rec=$1 ep=$2 alias out
  alias=$(fm_fleet_host_field "$rec" ssh)
  case "$ep" in
    herdr:*)
      out=$(fleet_herdr "$rec" pane get "${ep##*/}" 2>&1) && return 0
      case "$out" in *pane_not_found*|*"not found"*) return 1 ;; esac
      return 2
      ;;
    tmux:*)
      out=$(fleet_ssh "$alias" "tmux has-session -t $(sq "=${ep#tmux:}") 2>/dev/null && echo yes || echo no") || return 2
      [ "$out" = yes ] && return 0
      return 1
      ;;
  esac
  return 2
}

endpoint_capture() {  # <record> <endpoint> <lines>
  local rec=$1 ep=$2 n=$3
  case "$ep" in
    herdr:*) fleet_herdr "$rec" pane read "${ep##*/}" --source recent --lines "$n" ;;
    tmux:*) fleet_ssh "$(fm_fleet_host_field "$rec" ssh)" "tmux capture-pane -p -t $(sq "=${ep#tmux:}:") -S -$n" ;;
  esac
}

endpoint_type_line() {  # <record> <endpoint> <text>: literal text, then Enter
  local rec=$1 ep=$2 text=$3
  case "$ep" in
    herdr:*)
      fleet_herdr "$rec" pane send-text "${ep##*/}" "$text" >/dev/null && sleep 0.4 &&
        fleet_herdr "$rec" pane send-keys "${ep##*/}" enter >/dev/null
      ;;
    tmux:*)
      fleet_ssh "$(fm_fleet_host_field "$rec" ssh)" \
        "tmux send-keys -t $(sq "=${ep#tmux:}:") -l $(sq "$text") && sleep 0.4 && tmux send-keys -t $(sq "=${ep#tmux:}:") Enter"
      ;;
  esac
}

endpoint_send_key() {  # <record> <endpoint> <Escape|Enter|C-c>
  local rec=$1 ep=$2 key=$3 hk tk
  case "$key" in
    Escape|escape|esc) hk=esc tk=Escape ;;
    Enter|enter) hk=enter tk=Enter ;;
    C-c|ctrl+c) hk=ctrl+c tk=C-c ;;
    *) echo "fm-fleet: unsupported key '$key'" >&2; return 1 ;;
  esac
  case "$ep" in
    herdr:*) fleet_herdr "$rec" pane send-keys "${ep##*/}" "$hk" >/dev/null ;;
    tmux:*) fleet_ssh "$(fm_fleet_host_field "$rec" ssh)" "tmux send-keys -t $(sq "=${ep#tmux:}:") $tk" ;;
  esac
}

endpoint_close() {  # <record> <endpoint>
  local rec=$1 ep=$2
  case "$ep" in
    herdr:*)
      local ws=${ep#herdr:}
      fleet_herdr "$rec" workspace close "${ws%%/*}" >/dev/null 2>&1 || true
      ;;
    tmux:*) fleet_ssh "$(fm_fleet_host_field "$rec" ssh)" "tmux kill-session -t $(sq "=${ep#tmux:}") 2>/dev/null || true" ;;
  esac
}

# endpoint_relaunch <record> <id> <endpoint>: run the staged launcher again in
# the task's own endpoint when it still exists (its shell is back at a prompt
# after the agent exited), or start a fresh endpoint. Prints the endpoint.
endpoint_relaunch() {
  local rec=$1 id=$2 ep=$3 rc=0
  endpoint_exists "$rec" "$ep" || rc=$?
  case "$ep:$rc" in
    herdr:*:0)
      fleet_herdr "$rec" pane run "${ep##*/}" "$R_TASK/launch.sh" >/dev/null || return 1
      printf '%s\n' "$ep"
      return 0
      ;;
    *:2) echo "fm-fleet: the endpoint $ep did not answer; refusing to start a second copy" >&2; return 1 ;;
  esac
  endpoint_close "$rec" "$ep"
  endpoint_start "$rec" "$id"
}

cmd_launch() {
  local id=$1 proj=$2
  shift 2
  local model='' effort='' yolo=off mode=local-only host rec alias root os brief branch base launch_sh meta tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --model) model=${2:?--model needs a value}; shift 2 ;;
      --effort) effort=${2:?--effort needs a value}; shift 2 ;;
      --yolo) yolo=${2:?--yolo needs on or off}; shift 2 ;;
      *) die "unknown launch option '$1'" ;;
    esac
  done
  require_fleet
  valid_id "$id" || die "invalid task id '$id'"
  proj=$(cd "$proj" && pwd -P) || die "project directory not found"
  git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || die "$proj is not a git repository"
  brief="$DATA/$id/brief.md"
  [ -f "$brief" ] || die "no brief at $brief; scaffold it with bin/fm-brief.sh first"
  [ ! -e "$(meta_of "$id")" ] || die "task $id already has a record; use resume or release"
  case "$effort" in ''|low|medium|high|xhigh|max) ;; *) die "--effort must be low, medium, high, xhigh, or max" ;; esac
  case "$yolo" in on|off) ;; *) die "--yolo must be on or off" ;; esac

  host=$(cmd_place "$id") || return $?
  rec=$(fm_fleet_host_record "$HOSTS_FILE" "$host")
  alias=$(fm_fleet_host_field "$rec" ssh)
  root=$(fm_fleet_host_field "$rec" root)
  os=$(fm_fleet_host_field "$rec" os)
  remote_paths "$root" "$id"
  branch="fm/$id"
  base=$(git -C "$proj" rev-parse HEAD)
  local repo_name; repo_name=$(basename "$proj")
  local r_repo="$root/repos/$repo_name.git"

  # 1. Host-side bare mirror holding a fresh branch at the local HEAD.
  fleet_ssh "$alias" "set -e
mkdir -p $(sq "$root/repos") $(sq "$root/worktrees") $(sq "$root/run") $(sq "$R_TASK/inbox/handled") $(sq "$R_SESS")
touch $(sq "$R_TASK/status")
[ -d $(sq "$r_repo") ] || git init -q --bare $(sq "$r_repo")
" || { rm -f "$FLEET_STATE/$id.reservation"; die "could not prepare $host"; }
  git -C "$proj" push -q "$alias:$r_repo" "+$base:refs/heads/$branch" \
    || { rm -f "$FLEET_STATE/$id.reservation"; die "could not push $proj to $host"; }

  # 2. Record the task in this home before anything task-specific exists on
  # the host: a meta that ordinary tools read, plus an empty status log and
  # inbox the mirror keeps current. From here on a failed launch keeps this
  # record, so stop and release can clean up the host.
  mkdir -p "$STATE"
  meta=$(meta_of "$id")
  tmp="$STATE/.$id.meta.fleet.$$"
  {
    echo "window=fleet:$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$R_WT"
    echo "project=$proj"
    echo "harness=omp"
    echo "kind=ship"
    echo "mode=$mode"
    echo "yolo=$yolo"
    echo "backend=fleet"
    echo "spawn_gen=f$(date +%s).$$.$RANDOM"
    echo "fleet_host=$host"
    echo "fleet_os=$os"
    echo "fleet_session=$(host_session "$rec")"
    echo "fleet_branch=$branch"
    echo "fleet_base=$base"
    echo "model=${model:-default}"
    echo "effort=${effort:-default}"
  } >"$tmp"
  mv "$tmp" "$meta"
  touch "$STATE/$id.status"
  mkdir -p "$STATE/$id.inbox/handled"

  # 3. Host-side worktree on the fresh branch.
  fleet_ssh "$alias" "set -e
cd $(sq "$r_repo")
[ -e $(sq "$R_WT") ] && { echo 'worktree path already exists' >&2; exit 1; }
git worktree add -q $(sq "$R_WT") $(sq "$branch")
git -C $(sq "$R_WT") config user.name \"\$(git -C $(sq "$r_repo") config user.name || echo firstmate-fleet)\" || true
" || { rm -f "$FLEET_STATE/$id.reservation"; die "could not create the worktree on $host; release $id to clear its record (inspect $R_WT there first if it exists)"; }

  # 4. Brief, extension, overlay and launcher into the host's task dir.
  launch_sh=$(remote_launch_script "$id" "$model" "$effort" "")
  { remote_brief "$id" "$R_TASK" | fleet_ssh_put "$alias" "$R_TASK/brief.md" &&
    remote_extension "$R_TASK" | fleet_ssh_put "$alias" "$R_TASK/omp-ext.ts" &&
    fleet_ssh_put "$alias" "$R_TASK/overlay.yml" <"$FM_ROOT/.omp/fm-worker-overlay.yml" &&
    printf '%s\n' "$launch_sh" | fleet_ssh_put "$alias" "$R_TASK/launch.sh" &&
    fleet_ssh "$alias" "chmod 700 $(sq "$R_TASK/launch.sh")"; } \
    || { rm -f "$FLEET_STATE/$id.reservation"; die "could not stage the worker launcher on $host; release $id to remove its worktree"; }

  # 5. Start the worker in the host's session (Herdr, or the tmux fallback).
  [ -z "$(tmux_note "$rec")" ] || echo "fm-fleet: $host$(tmux_note "$rec")" >&2
  local endpoint
  endpoint=$(endpoint_start "$rec" "$id") \
    || { rm -f "$FLEET_STATE/$id.reservation"; die "could not start the worker on $host; release $id to remove its worktree"; }
  set_task_field "$id" fleet_endpoint "$endpoint"
  # Arm the busy-state contract the mirror in `sync` feeds; the launch brief is
  # a submitted turn, so the seed record reads busy.
  "$SCRIPT_DIR/fm-busy-event.sh" arm "$STATE" "$id" --source omp-ext --event launch-brief >/dev/null \
    || echo "fm-fleet: warning: busy-state record for $id could not be armed; its busy state reads unknown" >&2
  # The worker counts in the host's own sample once its pid file exists, so
  # the reservation is released then; a worker that never starts leaves the
  # reservation to expire at its deadline instead.
  local started=0 _
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if fleet_ssh "$alias" "pid=\$(cat $(sq "$R_PID") 2>/dev/null) && kill -0 \"\$pid\" 2>/dev/null" 2>/dev/null; then
      started=1
      break
    fi
    sleep 1
  done
  [ "$started" = 1 ] || die "the worker on $host did not start ($endpoint); its reservation expires on its own and its record stays for state, stop and release"
  rm -f "$FLEET_STATE/$id.reservation"
  echo "launched $id on $host worktree=$R_WT endpoint=$endpoint"
}

# fleet_ssh_put <alias> <remote-path>: write stdin to a host file (0600).
fleet_ssh_put() {
  local alias=$1 path=$2
  ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" -o ForwardAgent=no \
    -o ClearAllForwardings=yes "$alias" "umask 077; cat > $(sq "$path")"
}

# remote_brief <id> <task-dir>: the brief the host worker reads. It keeps the
# task's own brief and replaces the home-local status and inbox paths with the
# host-local ones `sync` mirrors.
remote_brief() {
  local id=$1 tdir=$2
  cat <<EOF
# Current worker role contract
You are a crewmate: an autonomous worker agent managed by firstmate, running on a fleet host.
Do the assigned work yourself and report only to firstmate; do not adopt a supervisor identity or address the captain.

# Fleet worker paths (these replace every status-file and inbox path below)
- Report status by appending one line to \`$tdir/status\`: \`echo "<state>: <one short line>" >> '$tdir/status'\`.
- Your steering inbox is \`$tdir/inbox\`: list \`$tdir/inbox/*.msg\` in numeric order, act on each, then \`mv\` it into \`$tdir/inbox/handled/\`.
- Your branch is \`fm/$id\`. Commit your work on it. Never push; firstmate fetches your branch from this host.
- Commit early and often: firstmate recovers committed work and the uncommitted diff, but a commit is the durable result.
- When the work is committed, append \`done: ready in branch fm/$id\` to the status file and stop.

EOF
  cat "$DATA/$id/brief.md"
}

# remote_launch_script <id> <model> <effort> <resume-file>: the host-side
# launcher. It records its pid for slot accounting, exports the isolated
# agent dir and gateway key, and runs omp in the worktree.
remote_launch_script() {
  local id=$1 model=$2 effort=$3 resume=$4 flags=''
  [ -z "$model" ] || flags="$flags --model $(sq "$model")"
  [ -z "$effort" ] || flags="$flags --thinking $(sq "$effort")"
  cat <<EOF
#!/bin/sh
$FLEET_REMOTE_PATH
echo \$\$ > $(sq "$R_PID")
export PI_CODING_AGENT_DIR=$(sq "$R_ROOT/agent")
export OMP_SKIP_SETUP=1 FM_OMP_HARNESS=omp FM_TASK_ID=$(sq "$id")
[ -f $(sq "$R_ROOT/agent/gateway.env") ] && . $(sq "$R_ROOT/agent/gateway.env")
cd $(sq "$R_WT") || exit 1
EOF
  if [ -n "$resume" ]; then
    printf 'exec %s --config %s --auto-approve --session-dir %s --resume %s%s -e %s %s\n' \
      "$(sq "$R_ROOT/bin/omp")" "$(sq "$R_TASK/overlay.yml")" "$(sq "$R_SESS")" "$(sq "$resume")" "$flags" \
      "$(sq "$R_TASK/omp-ext.ts")" "$(sq "Firstmate restarted you on the same host and worktree after an interruption. Re-read $R_TASK/brief.md, check git status and your inbox, and continue the task.")"
  else
    # The $(cat ...) is literal launcher text: the host shell reads the brief.
    # shellcheck disable=SC2016
    printf 'exec %s --config %s --auto-approve --session-dir %s%s -e %s "$(cat %s)"\n' \
      "$(sq "$R_ROOT/bin/omp")" "$(sq "$R_TASK/overlay.yml")" "$(sq "$R_SESS")" "$flags" \
      "$(sq "$R_TASK/omp-ext.ts")" "$(sq "$R_TASK/brief.md")"
  fi
}

# --- sync (status, turn-end, busy, inbox) -----------------------------------

# One sync per task at a time (the watcher's cycle and every fm-send ring both
# sync): the mirror reads the local length, fetches the tail past it, and
# appends, so overlapping syncs would duplicate or skip status bytes. A sync
# that dies holding the lock frees it through the lock's dead-owner recovery.
# A released task is never synced again: release marks it under this lock.
cmd_sync() {
  local id=$1 rec alias root out local_len remote_len section line lock
  require_fleet
  mkdir -p "$FLEET_STATE"
  lock="$FLEET_STATE/.$id.sync.lock"
  fm_lock_acquire_wait "$lock"
  if [ -n "$(task_field "$id" fleet_released)" ]; then
    fm_lock_release "$lock"
    return 0
  fi
  rec=$(task_host_record "$id")
  alias=$(fm_fleet_host_field "$rec" ssh)
  root=$(fm_fleet_host_field "$rec" root)
  remote_paths "$root" "$id"
  local_len=$(wc -c <"$STATE/$id.status" 2>/dev/null | tr -d ' ') || local_len=0
  # Deliver home-side steering records the host has not seen yet: stage the
  # body under a dot name (fleet_ssh_put reads it from stdin), then rename it
  # into place only when neither the inbox nor handled/ already holds it.
  local f base
  for f in "$STATE/$id.inbox"/*.msg; do
    [ -f "$f" ] || continue
    base=${f##*/}
    fleet_ssh_put "$alias" "$R_TASK/inbox/.$base.tmp" <"$f" || continue
    fleet_ssh "$alias" "if [ -e $(sq "$R_TASK/inbox/$base") ] || [ -e $(sq "$R_TASK/inbox/handled/$base") ]; then rm -f $(sq "$R_TASK/inbox/.$base.tmp"); else mv $(sq "$R_TASK/inbox/.$base.tmp") $(sq "$R_TASK/inbox/$base"); fi" >/dev/null 2>&1 || true
  done
  out=$(fleet_ssh "$alias" "
s=$(sq "$R_TASK/status"); [ -f \"\$s\" ] || : > \"\$s\"
echo \"len=\$(wc -c < \"\$s\" | tr -d ' ')\"
echo \"turn=\$(cat $(sq "$R_TASK/turn-ended") 2>/dev/null)\"
echo \"busy=\$(cat $(sq "$R_TASK/busy") 2>/dev/null)\"
echo \"handled=\$(ls $(sq "$R_TASK/inbox/handled") 2>/dev/null | tr '\n' ' ')\"
echo '--status'
tail -c +$((local_len + 1)) \"\$s\"
") || { fm_lock_release "$lock"; echo "unreachable"; return 3; }
  remote_len=$(printf '%s\n' "$out" | sed -n 's/^len=//p' | head -n 1)
  section=$(printf '%s\n' "$out" | sed '1,/^--status$/d')
  if [ "${remote_len:-0}" -lt "$local_len" ]; then
    echo "fm-fleet: host status log for $id is shorter than the local mirror; not appending (inspect $R_TASK/status)" >&2
  elif [ -n "$section" ]; then
    printf '%s\n' "$section" >>"$STATE/$id.status"
  fi
  # Turn-end and busy: a changed remote marker touches the local file the
  # watcher already reads.
  line=$(printf '%s\n' "$out" | sed -n 's/^turn=//p' | head -n 1)
  if [ -n "$line" ] && [ "$line" != "$(cat "$FLEET_STATE/$id.turn" 2>/dev/null)" ]; then
    printf '%s' "$line" >"$FLEET_STATE/$id.turn"
    touch "$STATE/$id.turn-ended"
  fi
  # Busy: the host marker is "<busy|idle> <event> <epoch>". A changed marker
  # becomes one ordinary omp-ext event in this home's busy-state record
  # (bin/fm-busy-lib.sh owns the contract; launch armed its gen), so the
  # watcher and fm-crew-state classify a fleet worker like a local omp one.
  line=$(printf '%s\n' "$out" | sed -n 's/^busy=//p' | head -n 1)
  if [ -n "$line" ] && [ "$line" != "$(cat "$FLEET_STATE/$id.busy" 2>/dev/null)" ]; then
    printf '%s\n' "$line" >"$FLEET_STATE/$id.busy"
    case "${line%% *}" in
      busy|idle)
        "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$id" "${line%% *}" --current-gen \
          --source omp-ext --event "$(printf '%s' "$line" | awk '{print $2}')" >/dev/null 2>&1 || true
        ;;
    esac
  fi
  # Acknowledgements made on the host move the home-side record too.
  for base in $(printf '%s\n' "$out" | sed -n 's/^handled=//p'); do
    [ -f "$STATE/$id.inbox/$base" ] && mv "$STATE/$id.inbox/$base" "$STATE/$id.inbox/handled/$base"
  done
  fm_lock_release "$lock"
  echo "synced $id: status=${remote_len:-0}B busy=$(cut -d' ' -f1 "$FLEET_STATE/$id.busy" 2>/dev/null || echo unknown)"
}

# ring <id>: type the constant steering doorbell (bin/fm-task-inbox-lib.sh's
# fm_task_inbox_doorbell_line, naming the host-side inbox) into the worker's
# pane, then Enter. Best-effort, like the local doorbell: the inbox record is
# the delivery and its move into handled/ is the acknowledgement.
cmd_ring() {
  local id=$1 rec root line
  require_fleet
  rec=$(task_host_record "$id")
  root=$(fm_fleet_host_field "$rec" root)
  remote_paths "$root" "$id"
  line=$(fm_task_inbox_doorbell_line "$R_TASK/inbox/x.msg") || die "could not build the doorbell line"
  endpoint_type_line "$rec" "$(endpoint_of "$id")" "$line"
}

# key <id> <Escape|Enter|C-c>: one named key into the worker's pane.
cmd_key() {
  local id=$1 rec
  [ "$#" -eq 2 ] || die "usage: key <task-id> <Escape|Enter|C-c>"
  require_fleet
  rec=$(task_host_record "$id")
  endpoint_send_key "$rec" "$(endpoint_of "$id")" "$2"
}

# type <id> <text>: literal text into the worker's pane, then Enter. Lifecycle
# words never ride this path; use key, stop, or resume.
cmd_type() {
  local id=$1 rec
  [ "$#" -eq 2 ] || die "usage: type <task-id> <text>"
  require_fleet
  rec=$(task_host_record "$id")
  endpoint_type_line "$rec" "$(endpoint_of "$id")" "$2"
}

# stop <id>: end the worker's omp and close its endpoint. The host worktree,
# branch, and omp session stay, so `fetch` and `resume` still work; `release`
# is what removes them after fetching.
cmd_stop() {
  local id=$1 rec alias root
  require_fleet
  rec=$(task_host_record "$id")
  alias=$(fm_fleet_host_field "$rec" ssh)
  root=$(fm_fleet_host_field "$rec" root)
  remote_paths "$root" "$id"
  stop_worker "$alias" || die "could not stop $id on $(task_field "$id" fleet_host): the host did not answer or its omp survived SIGKILL"
  endpoint_close "$rec" "$(endpoint_of "$id")"
}

# stop_worker <alias>: end the omp recorded in $R_PID and wait (up to 10 s)
# for it to exit, then SIGKILL it, so nothing writes to the worktree
# afterwards. A pid that survives keeps its pid file and fails the call.
stop_worker() {
  fleet_ssh "$1" "
pid=\$(cat $(sq "$R_PID") 2>/dev/null)
case \"\$pid\" in
  ''|*[!0-9]*) ;;
  *)
    kill \"\$pid\" 2>/dev/null || true
    n=0
    while kill -0 \"\$pid\" 2>/dev/null && [ \$n -lt 50 ]; do sleep 0.2; n=\$((n + 1)); done
    if kill -0 \"\$pid\" 2>/dev/null; then
      kill -9 \"\$pid\" 2>/dev/null || true
      sleep 1
      kill -0 \"\$pid\" 2>/dev/null && { echo \"omp pid \$pid survived SIGKILL\" >&2; exit 1; }
    fi
    ;;
esac
rm -f $(sq "$R_PID")
"
}

cmd_peek() {
  local id=$1 n=${2:-40} rec
  require_fleet
  rec=$(task_host_record "$id")
  endpoint_capture "$rec" "$(endpoint_of "$id")" "$n"
}

# attach: how a human opens the worker. A Herdr worker is already in this
# machine's Herdr view under fleet-<host>, workspace fm-<id>.
cmd_attach() {
  local id=$1 rec ep
  require_fleet
  rec=$(task_host_record "$id")
  ep=$(endpoint_of "$id")
  case "$ep" in
    herdr:*) printf 'open Herdr on this machine; select %s, workspace fm-%s (or: herdr --remote %s --session fm-fleet)\n' \
      "$(herdr_machine "$rec")" "$id" "$(fm_fleet_host_field "$rec" ssh)" ;;
    *) printf 'ssh -t %s tmux attach -t %s\n' "$(fm_fleet_host_field "$rec" ssh)" "$(sq "=${ep#tmux:}")" ;;
  esac
}

# state: the recovery-grade verdict from the endpoint and the recorded omp
# pid. alive = omp runs; dead = endpoint present, omp gone; missing = endpoint
# gone; unreadable = the host or its Herdr did not answer (never death).
cmd_state() {
  local id=$1 rec alias root out rc=0
  require_fleet
  rec=$(task_host_record "$id")
  alias=$(fm_fleet_host_field "$rec" ssh)
  root=$(fm_fleet_host_field "$rec" root)
  remote_paths "$root" "$id"
  out=$(fleet_ssh "$alias" "
pid=\$(cat $(sq "$R_PID") 2>/dev/null)
case \"\$pid\" in ''|*[!0-9]*) echo dead; exit 0 ;; esac
if kill -0 \"\$pid\" 2>/dev/null; then echo alive; else echo dead; fi
" 2>/dev/null) || { echo unreadable; return 0; }
  [ "$out" = alive ] && { echo alive; return 0; }
  endpoint_exists "$rec" "$(endpoint_of "$id")" || rc=$?
  case "$rc" in
    0) echo dead ;;
    1) echo missing ;;
    *) echo unreadable ;;
  esac
}

# --- fetch / resume / release -----------------------------------------------

# fetch: bring the worker's branch home as refs/fleet/<id> in the local
# project, and save its uncommitted diff (tracked and untracked) plus a
# session archive under data/<id>/fleet/, replacing the saved copies only when
# every read succeeded. Never touches the host worktree. A
# worktree the host reports absent (a launch that failed before creating it)
# has nothing uncommitted, so its patch is empty.
cmd_fetch() {
  local id=$1 rec alias root proj r_repo out
  require_fleet
  rec=$(task_host_record "$id")
  alias=$(fm_fleet_host_field "$rec" ssh)
  root=$(fm_fleet_host_field "$rec" root)
  proj=$(task_field "$id" project)
  remote_paths "$root" "$id"
  r_repo="$root/repos/$(basename "$proj").git"
  out="$DATA/$id/fleet"
  mkdir -p "$out"
  git -C "$proj" fetch -q "$alias:$r_repo" "+refs/heads/fm/$id:refs/fleet/$id" \
    || die "could not fetch fm/$id from $(task_field "$id" fleet_host)"
  fleet_ssh "$alias" "[ -e $(sq "$R_WT") ] || exit 0; cd $(sq "$R_WT") && i=\$(mktemp) && cp \"\$(git rev-parse --git-path index)\" \"\$i\" && GIT_INDEX_FILE=\$i git add -A -N . && GIT_INDEX_FILE=\$i git diff --binary HEAD; r=\$?; rm -f \"\$i\"; exit \$r" >"$out/.uncommitted.patch.$$" \
    || { rm -f "$out/.uncommitted.patch.$$"; die "could not read the uncommitted diff from the host"; }
  fleet_ssh "$alias" "cd $(sq "$R_ROOT") && tar -cf - $(sq "sessions/$id") $(sq "tasks/$id/status")" >"$out/.session.tar.$$" \
    || { rm -f "$out/.uncommitted.patch.$$" "$out/.session.tar.$$"; die "could not archive the omp session from the host"; }
  git -C "$proj" rev-parse "refs/fleet/$id" >"$out/.head.$$"
  mv "$out/.uncommitted.patch.$$" "$out/uncommitted.patch"
  mv "$out/.session.tar.$$" "$out/session.tar"
  mv "$out/.head.$$" "$out/head"
  echo "fetched $id: branch refs/fleet/$id at $(cut -c1-12 <"$out/head") ($(wc -c <"$out/uncommitted.patch" | tr -d ' ') bytes uncommitted) into $out"
}

cmd_resume() {
  local id=$1 rec alias root model effort sess ep
  require_fleet
  rec=$(task_host_record "$id")
  alias=$(fm_fleet_host_field "$rec" ssh)
  root=$(fm_fleet_host_field "$rec" root)
  remote_paths "$root" "$id"
  case "$(cmd_state "$id")" in
    alive) die "task $id still has a live omp on its host; nothing to resume" ;;
    unreadable) die "task $id's host did not answer; resume needs a positive dead or missing verdict" ;;
  esac
  sess=$(fleet_ssh "$alias" "ls -t $(sq "$R_SESS")/*.jsonl 2>/dev/null | head -n 1")
  [ -n "$sess" ] || die "no saved omp session for $id under $R_SESS"
  model=$(task_field "$id" model)
  effort=$(task_field "$id" effort)
  remote_launch_script "$id" "$model" "$effort" "$sess" | fleet_ssh_put "$alias" "$R_TASK/launch.sh"
  fleet_ssh "$alias" "chmod 700 $(sq "$R_TASK/launch.sh")" || die "could not stage the resume launcher"
  ep=$(endpoint_relaunch "$rec" "$id" "$(endpoint_of "$id")") || die "could not restart the worker on $(task_field "$id" fleet_host)"
  set_task_field "$id" fleet_endpoint "$ep"
  echo "resumed $id on $(task_field "$id" fleet_host) in $ep from $sess"
}

cmd_release() {
  local id=$1 rec alias root proj r_repo patch
  require_fleet
  rec=$(task_host_record "$id")
  alias=$(fm_fleet_host_field "$rec" ssh)
  root=$(fm_fleet_host_field "$rec" root)
  proj=$(task_field "$id" project)
  remote_paths "$root" "$id"
  r_repo="$root/repos/$(basename "$proj").git"
  stop_worker "$alias" || die "could not stop $id on its host (unreachable, or its omp survived SIGKILL); nothing was released"
  cmd_fetch "$id"
  patch="$DATA/$id/fleet/uncommitted.patch"
  if [ -s "$patch" ] && [ "${FM_FLEET_RELEASE_DISCARD:-0}" != 1 ]; then
    die "task $id has uncommitted work on its host (saved to $patch); the worker is stopped: resume it to commit the work, or set FM_FLEET_RELEASE_DISCARD=1 once the saved patch is enough"
  fi
  endpoint_close "$rec" "$(endpoint_of "$id")"
  fleet_ssh "$alias" "[ -e $(sq "$R_WT") ] || exit 0; cd $(sq "$r_repo") && git worktree remove --force $(sq "$R_WT")" \
    || die "could not remove the worktree on $(task_field "$id" fleet_host); the work stays there and $id is not released"
  # bin/fm-teardown.sh refuses a fleet task until this marker exists.
  fm_lock_acquire_wait "$FLEET_STATE/.$id.sync.lock"
  rm -f "$FLEET_STATE/$id.reservation" "$FLEET_STATE/$id.turn" "$FLEET_STATE/$id.busy"
  set_task_field "$id" fleet_released "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fm_lock_release "$FLEET_STATE/.$id.sync.lock"
  echo "released $id; branch kept as refs/fleet/$id in $proj and fm/$id on the host mirror; saved work in $DATA/$id/fleet"
}

# --- host setup -------------------------------------------------------------
#
# setup <host> [--omp-version V]: prepare <root> on one host. Installs the omp
# release binary for the host's platform into <root>/bin/omp (checked against
# the release's SHA256SUMS), writes <root>/agent/models.yml with only this
# home's studio1-gateway providers (base URLs pointing at the gateway, keys by
# environment-variable reference), and writes <root>/agent/gateway.env (0600)
# carrying CLIPROXY_KEY taken from this home's environment. Nothing outside
# <root> is touched: no shell profile, no ~/.omp, no Claude, Codex, or pi
# credentials. Idempotent; rerunning updates omp and the gateway config.
cmd_setup() {
  local host=$1 rec alias root os version arch asset tmp models
  shift
  version=${FM_FLEET_OMP_VERSION:-}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --omp-version) version=${2:?--omp-version needs a value}; shift 2 ;;
      *) die "unknown setup option '$1'" ;;
    esac
  done
  require_fleet
  rec=$(fm_fleet_host_record "$HOSTS_FILE" "$host")
  alias=$(fm_fleet_host_field "$rec" ssh)
  root=$(fm_fleet_host_field "$rec" root)
  os=$(fm_fleet_host_field "$rec" os)
  [ -n "${CLIPROXY_KEY:-}" ] || die "CLIPROXY_KEY is not set in this environment; setup copies the gateway key from it"
  if [ -z "$version" ]; then
    version=$(omp --version 2>/dev/null | sed -n 's#^omp/##p')
    [ -n "$version" ] || die "could not read the local omp version; pass --omp-version"
  fi
  arch=$(fleet_ssh "$alias" 'uname -m') || die "could not reach $host"
  case "$os:$arch" in
    darwin:arm64) asset=omp-darwin-arm64 ;;
    darwin:x86_64) asset=omp-darwin-x64 ;;
    linux:x86_64) asset=omp-linux-x64 ;;
    linux:aarch64|linux:arm64) asset=omp-linux-arm64 ;;
    *) die "no omp release asset for $os $arch" ;;
  esac
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-setup.XXXXXX")
  gh release download "v$version" -R can1357/oh-my-pi -D "$tmp" -p "$asset" -p SHA256SUMS.txt --clobber \
    || { rm -rf "$tmp"; die "could not download omp v$version $asset"; }
  (cd "$tmp" && grep " $asset\$" SHA256SUMS.txt | shasum -a 256 -c - >/dev/null) \
    || { rm -rf "$tmp"; die "omp $asset failed its SHA256SUMS check"; }
  models=$(gateway_models_yml) || { rm -rf "$tmp"; die "could not derive the gateway model config"; }
  fleet_ssh "$alias" "mkdir -p $(sq "$root/bin") $(sq "$root/agent") $(sq "$root/run") $(sq "$root/tasks") $(sq "$root/sessions") $(sq "$root/worktrees") $(sq "$root/repos")" \
    || { rm -rf "$tmp"; die "could not create $root on $host"; }
  if ! fleet_ssh_put "$alias" "$root/bin/.omp.tmp" <"$tmp/$asset" ||
    ! fleet_ssh "$alias" "chmod 755 $(sq "$root/bin/.omp.tmp") && mv $(sq "$root/bin/.omp.tmp") $(sq "$root/bin/omp")"; then
    rm -rf "$tmp"
    die "could not install omp on $host"
  fi
  rm -rf "$tmp"
  printf '%s\n' "$models" | fleet_ssh_put "$alias" "$root/agent/models.yml"
  printf 'export CLIPROXY_KEY=%s\n' "$(sq "$CLIPROXY_KEY")" | fleet_ssh_put "$alias" "$root/agent/gateway.env"
  fleet_ssh "$alias" "$(sq "$root/bin/omp") --version"
  echo "setup $host: omp v$version ($asset), gateway config at $root/agent"
}

# gateway_models_yml: this home's omp providers that point at the studio1
# gateway (FM_FLEET_GATEWAY, default 100.69.240.64), with every API key
# rewritten to the CLIPROXY_KEY environment reference. Providers that do not
# go through the gateway, and every literal credential, are left out.
gateway_models_yml() {
  local src=${FM_FLEET_MODELS_YML:-$HOME/.omp/agent/models.yml}
  python3 - "$src" "${FM_FLEET_GATEWAY:-100.69.240.64}" <<'PY'
import sys, yaml
src, gateway = sys.argv[1], sys.argv[2]
data = yaml.safe_load(open(src)) or {}
out = {}
for name, prov in (data.get("providers") or {}).items():
    if not isinstance(prov, dict) or gateway not in str(prov.get("baseUrl", "")):
        continue
    prov = dict(prov)
    prov["apiKey"] = "CLIPROXY_KEY"
    out[name] = prov
if not out:
    sys.exit("no gateway providers found")
yaml.safe_dump({"providers": out}, sys.stdout, sort_keys=False)
PY
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
cmd=$1
shift
case "$cmd" in
  -h|--help|help) usage ;;
  hosts) cmd_hosts ;;
  setup) [ "$#" -ge 1 ] || die "usage: setup <host> [--omp-version V]"; cmd_setup "$@" ;;
  place) [ "$#" -eq 1 ] || die "usage: place <task-id>"; cmd_place "$1" ;;
  launch) [ "$#" -ge 2 ] || die "usage: launch <task-id> <project-dir> [--model M] [--effort E]"; cmd_launch "$@" ;;
  sync)
    if [ "$#" -eq 0 ]; then
      # Every fleet task in this home; a host that does not answer is
      # reported and skipped so one dead host never stalls the others.
      [ -f "$HOSTS_FILE" ] || exit 0
      for meta in "$STATE"/*.meta; do
        [ -f "$meta" ] || continue
        [ "$(fm_meta_get "$meta" backend)" = fleet ] || continue
        [ -z "$(fm_meta_get "$meta" fleet_released)" ] || continue
        sid=${meta##*/}
        ( cmd_sync "${sid%.meta}" ) || echo "fm-fleet: sync ${sid%.meta}: host unreachable" >&2
      done
      exit 0
    fi
    valid_id "$1" || die "invalid task id '$1'"
    require_unreleased "$1"
    cmd_sync "$1"
    ;;
  ring|key|type|stop|fetch|resume|release)
    [ "$#" -ge 1 ] || die "usage: $cmd <task-id>"
    valid_id "$1" || die "invalid task id '$1'"
    require_unreleased "$1"
    "cmd_$cmd" "$@"
    ;;
  peek|attach|state)
    [ "$#" -ge 1 ] || die "usage: $cmd <task-id>"
    valid_id "$1" || die "invalid task id '$1'"
    "cmd_$cmd" "$@"
    ;;
  *) usage >&2; exit 2 ;;
esac
