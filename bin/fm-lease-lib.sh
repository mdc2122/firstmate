#!/usr/bin/env bash
# fm-lease-lib.sh - the per-task supervision lease contract (one owner).
#
# WHY. On the Pi supervision branch (docs/pi-supervision-branch.md), two LLM
# actors share one firstmate home inside one pi process: MAIN (the captain's
# chat) and BRANCH (the persistent supervision conversation). Most records have
# exactly one natural owner, but the overlap set - steering or stopping a
# worker, post-landing cleanup, backlog status for a task, stuck-worker
# recovery - could otherwise be mutated by both actors at once. The lease is
# the merge-conflict analog: a small per-task file saying which actor is
# changing that task right now, and the mutating entrypoints refuse the other
# actor while it exists.
#
# CONTRACT.
#   - Lease file: $STATE/.lease-<task>, one line "<actor>\t<pid>\t<epoch>".
#     Written atomically (temp + ln for claim, temp + mv for a same-actor
#     refresh), with inspection and mutation serialized by the home-local
#     lease-command lock; leases never coordinate across firstmate homes.
#   - Actors: exactly "main" and "branch". The current actor is
#     $FM_SUPERVISION_ACTOR when set, else "main". The branch's shell gets
#     FM_SUPERVISION_ACTOR=branch injected deterministically by the Pi branch
#     extension's bash tool, not by agent memory. Any other value is refused
#     loudly - an unknown actor is a wiring bug, not a third role.
#   - Staleness: the recorded pid is the long-lived supervising process (the
#     session-lock holder, or FM_LEASE_HOLDER_PID - see bin/fm-lease.sh), and
#     both actors live inside that one harness process, so a dead recorded pid
#     means the process died; the lease is cleared at the next claim, guard,
#     or sweep. Liveness requires a supervision-branch calling context (see
#     fm_lease_context_active) plus state/.lock, and the recorded pid must BE
#     its current holder, so a lease left by an exited session goes stale even
#     if its pid was recycled by an unrelated process, and a home without a
#     branch never honors a leftover lease. A lease held by the
#     live current session but an abandoned branch conversation is recovered
#     by the branch extension's generation-activation cleanup.
#   - Calling context: Pi marks every tool shell PI_CODING_AGENT=true. omp marks
#     its tool shells OMPCODE=1 but runs the branch only when this home's
#     config/omp-supervision-branch says `on`, so an omp shell is a supervision
#     context only then. Without this, main's omp shell (no actor variable)
#     would read the branch's live lease as stale and delete it.
#
# THREAT MODEL (deliberate, captain-decided): these guards are
# CONFUSED-AGENT-GRADE, the same grade bin/fm-gate-refuse-lib.sh documents
# for the gate refusal. They stop non-deliberate misuse - the injected actor
# identity, the loud refusals, and the session-bound staleness make every
# accidental cross-actor mutation fail loudly. A deliberately forging shell
# running as the same uid inside the same pi process can evade any in-process
# discriminator (it can rewrite env, spawn fresh shells, and edit state
# files), so adversarial-grade separation is explicitly out of scope here and
# tracked as separate follow-up design work. The branch's shell prelude makes
# the actor variables readonly (see the Pi branch extension), so an
# ACCIDENTAL override fails loudly inside the branch's own shell as well.
#   - Guard semantics (fm_lease_guard): no lease, a same-actor lease, or a
#     provably stale lease passes; a live lease held by the OTHER actor
#     refuses with exit FM_LEASE_REFUSE_EXIT. In a Pi supervision context the
#     guard retains the lease-command lock until fm_lease_guard_release, so the
#     other actor cannot claim between the check and the guarded mutation. A
#     home without a branch-capable session lock cannot have a live lease, so
#     the guard is a no-op there - non-branch behavior is unchanged by construction.
#   - Role partition (fm_lease_forbid_branch): actions MAIN alone owns -
#     merging a PR, landing local-only work, spawning workers - refuse the
#     branch actor outright, lease or no lease.
#   - "backlog" is a reserved claimable resource name used by the branch
#     prompt around its own data/backlog.md writes. This is deliberately
#     branch-side containment only; main's tasks-axi path has no executable
#     backlog lease guard in this scope.
#
# Sourced by bin/fm-send.sh, bin/fm-control.sh, bin/fm-teardown.sh,
# bin/fm-pr-merge.sh, bin/fm-merge-local.sh, bin/fm-spawn.sh, and
# bin/fm-lease.sh. Callers must have $STATE resolved before calling. No side
# effects on source. set -u / set -e safe.

# Distinct from usage errors (2), the gate refusal (3), and fm-send's
# unconfirmed submit (3): recognizable as "the other supervision actor holds
# this task right now - retry after the lease clears".
FM_LEASE_REFUSE_EXIT=6
FM_LEASE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_LEASE_GUARD_LOCK=

fm_lease_lock_helpers() {
  command -v fm_lock_acquire_wait >/dev/null 2>&1 && return 0
  # fm-wake-lib.sh is a canonical lint root in its own right and is already
  # sourced directly by every caller of this lazy fallback; keep this an
  # analysis boundary so ShellCheck's external-source traversal does not
  # recursively duplicate that large graph for every lease-lib consumer.
  # shellcheck source=/dev/null
  . "$FM_LEASE_LIB_DIR/fm-wake-lib.sh"
}

# fm_lease_actor: print the current actor after validating it. Returns 1 (with
# stderr) for an unknown FM_SUPERVISION_ACTOR value.
fm_lease_actor() {
  local actor=${FM_SUPERVISION_ACTOR:-main}
  case "$actor" in
    main|branch) printf '%s\n' "$actor" ;;
    *)
      echo "error: unknown FM_SUPERVISION_ACTOR '$actor' (expected main or branch)" >&2
      return 1
      ;;
  esac
}

# fm_lease_valid_id <id>: 0 iff the task/resource id is safe to embed in a
# state filename.
fm_lease_valid_id() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_lease_path() {
  printf '%s/.lease-%s\n' "$STATE" "$1"
}

# fm_omp_branch_mode [<config-dir>]: print the omp supervision branch mode this
# home's config selects - `on`, `report-only`, or `off`. The first word of
# config/omp-supervision-branch decides; an absent, unreadable, symlinked, or
# unknown value is `off`. docs/configuration.md "omp supervision branch" owns
# the file format; .omp/extensions/lib/fm-omp-branch-mode.ts is its TypeScript
# reader.
fm_omp_branch_mode() {
  local dir=${1:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-${STATE%/*}}/config}} mode=''
  if [ -f "$dir/omp-supervision-branch" ] && [ ! -L "$dir/omp-supervision-branch" ]; then
    read -r mode _ < "$dir/omp-supervision-branch" 2>/dev/null || true
  fi
  case "$mode" in
    on|report-only) printf '%s\n' "$mode" ;;
    *) printf 'off\n' ;;
  esac
}

# fm_lease_context_active: 0 when this shell is a supervision-branch calling
# context in which leases bind (see "Calling context" above).
fm_lease_context_active() {
  case "${PI_CODING_AGENT:-}:${FM_SUPERVISION_ACTOR:-}" in
    true:*|*:main|*:branch) return 0 ;;
  esac
  [ "${OMPCODE:-}" = 1 ] && [ "$(fm_omp_branch_mode)" = on ]
}

# fm_lease_read <task>: read the lease into FM_LEASE_ACTOR/FM_LEASE_PID/
# FM_LEASE_EPOCH. Returns 1 when no lease file exists. A malformed lease
# (unreadable actor or pid) reads as actor "" so callers treat it as stale
# rather than blocking forever on a torn record.
fm_lease_read() {
  local file line
  file=$(fm_lease_path "$1")
  FM_LEASE_ACTOR=
  FM_LEASE_PID=
  FM_LEASE_EPOCH=
  [ -e "$file" ] || return 1
  IFS= read -r line < "$file" 2>/dev/null || line=
  FM_LEASE_ACTOR=$(printf '%s' "$line" | cut -f1)
  FM_LEASE_PID=$(printf '%s' "$line" | cut -f2)
  # shellcheck disable=SC2034 # Consumed by sourcing callers (bin/fm-lease.sh check).
  FM_LEASE_EPOCH=$(printf '%s' "$line" | cut -f3)
  case "$FM_LEASE_ACTOR" in
    main|branch) ;;
    *) FM_LEASE_ACTOR= ;;
  esac
  case "$FM_LEASE_PID" in
    '' | *[!0-9]*) FM_LEASE_PID= ;;
  esac
  return 0
}

# fm_lease_live <task>: 0 iff a well-formed lease exists in a supervision
# context, its recorded pid is alive, and that pid IS the current session-lock
# holder (see the staleness contract above).
fm_lease_live() {
  local lock_pid
  fm_lease_context_active || return 1
  fm_lease_read "$1" || return 1
  [ -n "$FM_LEASE_ACTOR" ] || return 1
  [ -n "$FM_LEASE_PID" ] || return 1
  kill -0 "$FM_LEASE_PID" 2>/dev/null || return 1
  lock_pid=$(head -n 1 "$STATE/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|0|1|*[!0-9]*) return 1 ;; esac
  [ "$FM_LEASE_PID" = "$lock_pid" ]
}

# fm_lease_clear_stale <task>: remove the lease file when it exists but is not
# live. Silent; never touches a live lease.
fm_lease_clear_stale() {
  local file
  file=$(fm_lease_path "$1")
  [ -e "$file" ] || return 0
  fm_lease_live "$1" && return 0
  rm -f -- "$file"
}

# fm_lease_guard <task> <action-label>: refuse (exit FM_LEASE_REFUSE_EXIT) when
# a live lease held by the OTHER actor exists for <task>. In a Pi supervision
# context, a successful guard retains the command lock across the caller's
# mutation; the caller must invoke fm_lease_guard_release from its EXIT cleanup.
# This closes the check/use race with a concurrent claim. Outside Pi, stale
# records are still cleaned but the lock is released before returning.
fm_lease_guard() {
  local task=$1 action=$2 actor lock lease_actor active=0
  fm_lease_valid_id "$task" || return 0
  actor=$(fm_lease_actor) || exit "$FM_LEASE_REFUSE_EXIT"
  if fm_lease_context_active; then active=1; fi
  [ "$active" = 1 ] || [ -e "$(fm_lease_path "$task")" ] || return 0
  fm_lease_lock_helpers
  lock="$STATE/.fm-lease-command.lock"
  # A caller with more than one guarded phase already excludes claims until
  # its shared cleanup; do not recursively acquire the non-reentrant lock.
  if [ "$FM_LEASE_GUARD_LOCK" != "$lock" ]; then
    fm_lock_acquire_wait "$lock"
    FM_LEASE_GUARD_LOCK=$lock
  fi
  if ! fm_lease_live "$task"; then
    fm_lease_clear_stale "$task" || { fm_lease_guard_release; return 1; }
    if [ "$active" != 1 ]; then
      fm_lease_guard_release
    fi
    return 0
  fi
  lease_actor=$FM_LEASE_ACTOR
  if [ "$lease_actor" != "$actor" ]; then
    fm_lease_guard_release
    echo "error: $action refused - task '$task' is leased to the $lease_actor supervision actor (state/.lease-$task); retry after that actor releases it" >&2
    exit "$FM_LEASE_REFUSE_EXIT"
  fi
}

# Release the claim/guard serialization lock retained by fm_lease_guard.
# Idempotent so callers can use it unconditionally from existing EXIT cleanup.
fm_lease_guard_release() {
  local lock=$FM_LEASE_GUARD_LOCK
  [ -n "$lock" ] || return 0
  FM_LEASE_GUARD_LOCK=
  fm_lock_release "$lock"
}

# fm_lease_forbid_branch <action-label>: refuse (exit FM_LEASE_REFUSE_EXIT)
# when the current actor is the supervision branch. Guards the main-owned role
# partition; a home with no branch never sets the actor and always passes.
fm_lease_forbid_branch() {
  local action=$1 actor
  actor=$(fm_lease_actor) || exit "$FM_LEASE_REFUSE_EXIT"
  [ "$actor" = branch ] || return 0
  echo "error: $action refused - the supervision branch never performs this action; report the outcome and leave it to main (role partition: docs/pi-supervision-branch.md)" >&2
  exit "$FM_LEASE_REFUSE_EXIT"
}
