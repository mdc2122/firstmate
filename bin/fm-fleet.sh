#!/usr/bin/env bash
# fm-fleet.sh - place bounded omp ship workers on donor hosts with headroom.
#
# Usage:
#   fm-fleet.sh hosts                      sample every configured host and print
#                                          one eligibility verdict per host
#   fm-fleet.sh place <task-id>            pick a host and hold a reservation;
#                                          prints the host name, exit 4 when no
#                                          host has headroom (the task stays
#                                          queued - never overloads a host)
#   fm-fleet.sh launch <task-id> <project-dir> [--model M] [--effort E]
#                                          place, then start the worker on the
#                                          chosen host and record the task
#   fm-fleet.sh sync <task-id>             mirror the worker's status, turn-end
#                                          and busy state home; deliver pending
#                                          steering records to the host
#   fm-fleet.sh peek <task-id> [lines]     print the worker's pane
#   fm-fleet.sh attach <task-id>           print the ssh command that attaches
#                                          the worker's tmux session
#   fm-fleet.sh state <task-id>            alive|dead|missing|unreadable
#   fm-fleet.sh fetch <task-id>            commit-safe copy of the worker's
#                                          branch and uncommitted diff into
#                                          the local project clone and data/
#   fm-fleet.sh resume <task-id>           relaunch omp on the same host and
#                                          worktree with its saved session
#   fm-fleet.sh release <task-id>          fetch, then stop the worker and free
#                                          its slot; refuses while unfetched
#                                          work exists on the host
#
# Opt-in: nothing here runs unless config/fleet-hosts exists; the config
# grammar and placement rule are owned by bin/fm-fleet-lib.sh, and the
# operator contract (setup, launch, monitoring, recovery, removal) by
# docs/fleet-placement.md.
#
# What runs where:
# - The worker runs on the host inside a detached tmux session named
#   fm-<task-id> on that host's own tmux server, so it survives every SSH
#   disconnect, and `fm-fleet.sh attach` is the human view of it.
# - The worktree is a git worktree of a host-local clone under <root>/repos,
#   fetched from this machine over SSH (`git push` from the local project to
#   the host), so hosts need no GitHub credential. Results come back the same
#   way (`fetch`), from this machine, never pushed by the host.
# - omp runs from <root>/bin/omp with PI_CODING_AGENT_DIR=<root>/agent, an
#   isolated agent dir holding only a models.yml whose providers point at the
#   studio1 gateway, so the host's own omp/pi/claude configs are untouched and
#   no OAuth session is copied. The gateway key is the host's existing
#   cliproxy key, written once at setup with mode 0600.
# - omp sessions live in <root>/sessions/<task-id>, outside the worktree, so
#   `resume` continues the same conversation with `--resume <file>`.
# - The worker appends status lines and acknowledges steering records inside
#   <root>/tasks/<task-id>/, mirrored home by `sync` into this home's ordinary
#   state/<id>.status and state/<id>.inbox, so the watcher, fm-crew-state,
#   and fm-send see a remote worker exactly like a local one.
#
# Reservations: `place` takes this home's fleet lock, counts live
# reservations under state/fleet/, samples every host, and writes the
# winner's reservation before releasing the lock, so two concurrent launches
# can never both take a host's last slot. `release` removes the reservation.
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
fleet_ssh() {
  local alias=$1 script=$2
  printf '%s\n' "$script" | ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
    -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o ForwardAgent=no \
    -o ClearAllForwardings=yes "$alias" sh -s
}

meta_of() { printf '%s/%s.meta' "$STATE" "$1"; }

task_field() {  # <id> <key>
  fm_meta_get "$(meta_of "$1")" "$2"
}

task_host_record() {  # <id>
  local host
  host=$(task_field "$1" fleet_host)
  [ -n "$host" ] || die "task $1 is not a fleet task (no fleet_host= in its record)"
  fm_fleet_host_record "$HOSTS_FILE" "$host"
}

# --- reservations -----------------------------------------------------------

reservations_on() {  # <host> -> count of live reservations held by this home
  local host=$1 n=0 f
  [ -d "$FLEET_STATE" ] || { printf 0; return 0; }
  for f in "$FLEET_STATE"/*.reservation; do
    [ -f "$f" ] || continue
    [ "$(cat "$f")" = "$host" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

sample_host() {  # <record> -> sample line or empty
  local rec=$1 alias root tz procs
  alias=$(fm_fleet_host_field "$rec" ssh)
  root=$(fm_fleet_host_field "$rec" root)
  tz=$(fm_fleet_host_field "$rec" tz)
  procs=$(fm_fleet_host_field "$rec" busy_procs)
  fleet_ssh "$alias" "$(fm_fleet_probe_script "$root" "$tz" "$procs")" 2>/dev/null | tail -n 1 || true
}

# verdicts [<exclude-task-id>]: one fm_fleet_evaluate line per host. The
# reservation count passed in subtracts the host's own live workers already
# visible in its sample, so a placement still mid-launch is counted once.
verdicts() {
  local exclude=${1:-} records rec name sample held seen pending
  records=$(fm_fleet_hosts "$HOSTS_FILE") || exit 1
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    name=${rec%% *}
    sample=$(sample_host "$rec")
    held=$(reservations_on "$name")
    if [ -n "$exclude" ] && [ "$(cat "$FLEET_STATE/$exclude.reservation" 2>/dev/null)" = "$name" ]; then
      held=$((held - 1))
    fi
    seen=$(fm_fleet_sample_field "$sample" workers)
    case "$seen" in ''|*[!0-9]*) seen=0 ;; esac
    pending=$((held - seen))
    [ "$pending" -ge 0 ] || pending=0
    fm_fleet_evaluate "$rec" "$sample" "$pending"
  done <<EOF
$records
EOF
}

cmd_hosts() {
  require_fleet
  verdicts
}

cmd_place() {
  local id=$1 lock out host
  require_fleet
  valid_id "$id" || die "invalid task id '$id'"
  mkdir -p "$FLEET_STATE"
  if [ -f "$FLEET_STATE/$id.reservation" ]; then
    cat "$FLEET_STATE/$id.reservation"
    return 0
  fi
  lock="$FLEET_STATE/.place.lock"
  fm_lock_acquire_wait "$lock"
  out=$(verdicts "$id")
  if ! host=$(fm_fleet_pick "$out"); then
    fm_lock_release "$lock"
    printf '%s\n' "$out" >&2
    echo "fm-fleet: no host has headroom for $id; leave it queued and retry later" >&2
    return 4
  fi
  printf '%s\n' "$host" >"$FLEET_STATE/$id.reservation"
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

cmd_launch() {
  local id=$1 proj=$2
  shift 2
  local model='' effort='' host rec alias root os brief branch base launch_sh meta tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --model) model=${2:?--model needs a value}; shift 2 ;;
      --effort) effort=${2:?--effort needs a value}; shift 2 ;;
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

  # 1. Host-side bare mirror + worktree on a fresh branch at the local HEAD.
  fleet_ssh "$alias" "set -e
mkdir -p $(sq "$root/repos") $(sq "$root/worktrees") $(sq "$root/run") $(sq "$R_TASK/inbox/handled") $(sq "$R_SESS")
[ -d $(sq "$r_repo") ] || git init -q --bare $(sq "$r_repo")
" || { rm -f "$FLEET_STATE/$id.reservation"; die "could not prepare $host"; }
  git -C "$proj" push -q "$alias:$r_repo" "+$base:refs/heads/$branch" \
    || { rm -f "$FLEET_STATE/$id.reservation"; die "could not push $proj to $host"; }
  fleet_ssh "$alias" "set -e
cd $(sq "$r_repo")
[ -e $(sq "$R_WT") ] && { echo 'worktree path already exists' >&2; exit 1; }
git worktree add -q $(sq "$R_WT") $(sq "$branch")
git -C $(sq "$R_WT") config user.name \"\$(git -C $(sq "$r_repo") config user.name || echo firstmate-fleet)\" || true
" || { rm -f "$FLEET_STATE/$id.reservation"; die "could not create the worktree on $host"; }

  # 2. Brief and extension into the host's task dir.
  remote_brief "$id" "$R_TASK" | fleet_ssh_put "$alias" "$R_TASK/brief.md"
  remote_extension "$R_TASK" | fleet_ssh_put "$alias" "$R_TASK/omp-ext.ts"
  cat "$FM_ROOT/.omp/fm-worker-overlay.yml" | fleet_ssh_put "$alias" "$R_TASK/overlay.yml"

  # 3. Start the worker in a detached tmux session on the host.
  launch_sh=$(remote_launch_script "$id" "$model" "$effort" "")
  printf '%s\n' "$launch_sh" | fleet_ssh_put "$alias" "$R_TASK/launch.sh"
  fleet_ssh "$alias" "set -e
chmod 700 $(sq "$R_TASK/launch.sh")
tmux has-session -t $(sq "=fm-$id") 2>/dev/null && { echo 'tmux session already exists' >&2; exit 1; }
tmux new-session -d -s $(sq "fm-$id") -c $(sq "$R_WT") $(sq "$R_TASK/launch.sh")
tmux set-option -t $(sq "fm-$id") remain-on-exit on >/dev/null
" || { rm -f "$FLEET_STATE/$id.reservation"; die "could not start the worker on $host"; }

  # 4. Record the task in this home: a meta that ordinary tools read, plus an
  # empty status log and inbox the mirror keeps current.
  mkdir -p "$STATE"
  meta=$(meta_of "$id")
  tmp="$STATE/.$id.meta.fleet.$$"
  {
    echo "window=fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$R_WT"
    echo "project=$proj"
    echo "harness=omp"
    echo "kind=ship"
    echo "fleet_host=$host"
    echo "fleet_os=$os"
    echo "fleet_branch=$branch"
    echo "fleet_base=$base"
    [ -z "$model" ] || echo "model=$model"
    [ -z "$effort" ] || echo "effort=$effort"
  } >"$tmp"
  mv "$tmp" "$meta"
  touch "$STATE/$id.status"
  mkdir -p "$STATE/$id.inbox/handled"
  echo "launched $id on $host worktree=$R_WT session=fm-$id"
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
    printf 'exec %s --config %s --auto-approve --session-dir %s%s -e %s "$(cat %s)"\n' \
      "$(sq "$R_ROOT/bin/omp")" "$(sq "$R_TASK/overlay.yml")" "$(sq "$R_SESS")" "$flags" \
      "$(sq "$R_TASK/omp-ext.ts")" "$(sq "$R_TASK/brief.md")"
  fi
}

# --- sync (status, turn-end, busy, inbox) -----------------------------------

cmd_sync() {
  local id=$1 rec alias root out local_len remote_len section line
  require_fleet
  rec=$(task_host_record "$id")
  alias=$(fm_fleet_host_field "$rec" ssh)
  root=$(fm_fleet_host_field "$rec" root)
  remote_paths "$root" "$id"
  local_len=$(wc -c <"$STATE/$id.status" 2>/dev/null | tr -d ' ') || local_len=0
  # Deliver home-side steering records that the host has not seen yet.
  local f base
  for f in "$STATE/$id.inbox"/*.msg; do
    [ -f "$f" ] || continue
    base=${f##*/}
    fleet_ssh "$alias" "[ -e $(sq "$R_TASK/inbox/$base") ] || [ -e $(sq "$R_TASK/inbox/handled/$base") ] || cat > $(sq "$R_TASK/inbox/.$base.tmp") && mv $(sq "$R_TASK/inbox/.$base.tmp") $(sq "$R_TASK/inbox/$base") 2>/dev/null; true" <"$f" >/dev/null 2>&1 || true
  done
  out=$(fleet_ssh "$alias" "
s=$(sq "$R_TASK/status"); [ -f \"\$s\" ] || : > \"\$s\"
echo \"len=\$(wc -c < \"\$s\" | tr -d ' ')\"
echo \"turn=\$(cat $(sq "$R_TASK/turn-ended") 2>/dev/null)\"
echo \"busy=\$(cat $(sq "$R_TASK/busy") 2>/dev/null)\"
echo \"handled=\$(ls $(sq "$R_TASK/inbox/handled") 2>/dev/null | tr '\n' ' ')\"
echo '--status'
tail -c +$((local_len + 1)) \"\$s\"
") || { echo "unreachable"; return 3; }
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
  printf '%s\n' "$out" | sed -n 's/^busy=//p' | head -n 1 >"$FLEET_STATE/$id.busy"
  # Acknowledgements made on the host move the home-side record too.
  for base in $(printf '%s\n' "$out" | sed -n 's/^handled=//p'); do
    [ -f "$STATE/$id.inbox/$base" ] && mv "$STATE/$id.inbox/$base" "$STATE/$id.inbox/handled/$base"
  done
  echo "synced $id: status=${remote_len:-0}B busy=$(cut -d' ' -f1 <"$FLEET_STATE/$id.busy")"
}

cmd_peek() {
  local id=$1 n=${2:-40} rec alias
  require_fleet
  rec=$(task_host_record "$id")
  alias=$(fm_fleet_host_field "$rec" ssh)
  fleet_ssh "$alias" "tmux capture-pane -p -t $(sq "=fm-$id:") -S -$n"
}

cmd_attach() {
  local id=$1 rec alias
  require_fleet
  rec=$(task_host_record "$id")
  alias=$(fm_fleet_host_field "$rec" ssh)
  printf 'ssh -t %s tmux attach -t %s\n' "$alias" "$(sq "=fm-$id")"
}

# state: the recovery-grade verdict, read on the host from the tmux session
# and the recorded omp pid. An SSH failure is unreadable, never dead.
cmd_state() {
  local id=$1 rec alias root out
  require_fleet
  rec=$(task_host_record "$id")
  alias=$(fm_fleet_host_field "$rec" ssh)
  root=$(fm_fleet_host_field "$rec" root)
  remote_paths "$root" "$id"
  out=$(fleet_ssh "$alias" "
if ! tmux has-session -t $(sq "=fm-$id") 2>/dev/null; then echo missing; exit 0; fi
pid=\$(cat $(sq "$R_PID") 2>/dev/null)
case \"\$pid\" in ''|*[!0-9]*) echo dead; exit 0 ;; esac
if kill -0 \"\$pid\" 2>/dev/null; then echo alive; else echo dead; fi
" 2>/dev/null) || { echo unreadable; return 0; }
  case "$out" in alive|dead|missing) echo "$out" ;; *) echo unreadable ;; esac
}

# --- fetch / resume / release -----------------------------------------------

# fetch: bring the worker's branch home as refs/fleet/<id> in the local
# project, and save its uncommitted diff (tracked and untracked) plus a
# session archive under data/<id>/fleet/. Never touches the host worktree.
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
  fleet_ssh "$alias" "cd $(sq "$R_WT") && git add -A -N . && git diff --binary HEAD" >"$out/uncommitted.patch" \
    || die "could not read the uncommitted diff from the host"
  fleet_ssh "$alias" "cd $(sq "$R_ROOT") && tar -cf - $(sq "sessions/$id") $(sq "tasks/$id/status")" >"$out/session.tar" \
    || die "could not archive the omp session from the host"
  git -C "$proj" rev-parse "refs/fleet/$id" >"$out/head"
  echo "fetched $id: branch refs/fleet/$id at $(cut -c1-12 <"$out/head") ($(wc -c <"$out/uncommitted.patch" | tr -d ' ') bytes uncommitted) into $out"
}

cmd_resume() {
  local id=$1 rec alias root model effort sess
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
  fleet_ssh "$alias" "set -e
chmod 700 $(sq "$R_TASK/launch.sh")
tmux kill-session -t $(sq "=fm-$id") 2>/dev/null || true
tmux new-session -d -s $(sq "fm-$id") -c $(sq "$R_WT") $(sq "$R_TASK/launch.sh")
tmux set-option -t $(sq "fm-$id") remain-on-exit on >/dev/null
"
  echo "resumed $id on $(task_field "$id" fleet_host) from $sess"
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
  cmd_fetch "$id"
  patch="$DATA/$id/fleet/uncommitted.patch"
  if [ -s "$patch" ] && [ "${FM_FLEET_RELEASE_DISCARD:-0}" != 1 ]; then
    die "task $id has uncommitted work on its host (saved to $patch); have the worker commit it, or set FM_FLEET_RELEASE_DISCARD=1 once the saved patch is enough"
  fi
  fleet_ssh "$alias" "
tmux kill-session -t $(sq "=fm-$id") 2>/dev/null || true
rm -f $(sq "$R_PID")
cd $(sq "$r_repo") && git worktree remove --force $(sq "$R_WT") 2>/dev/null || true
" || die "could not reach the host to release $id; its slot is still held"
  rm -f "$FLEET_STATE/$id.reservation" "$FLEET_STATE/$id.turn" "$FLEET_STATE/$id.busy"
  echo "released $id; branch kept as refs/fleet/$id in $proj and fm/$id on the host mirror"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
cmd=$1
shift
case "$cmd" in
  -h|--help|help) usage ;;
  hosts) cmd_hosts ;;
  place) [ "$#" -eq 1 ] || die "usage: place <task-id>"; cmd_place "$1" ;;
  launch) [ "$#" -ge 2 ] || die "usage: launch <task-id> <project-dir> [--model M] [--effort E]"; cmd_launch "$@" ;;
  sync|peek|attach|state|fetch|resume|release)
    [ "$#" -ge 1 ] || die "usage: $cmd <task-id>"
    valid_id "$1" || die "invalid task id '$1'"
    "cmd_$cmd" "$@"
    ;;
  *) usage >&2; exit 2 ;;
esac
