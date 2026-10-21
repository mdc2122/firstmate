#!/usr/bin/env bash
# fm-test-run.sh - single owner of Firstmate's behavior-test runner, lane
# composition for portable CI shards, local --jobs for proven-concurrent work,
# timing markers, and the complete-regression coverage guard.
#
# Selection modes (exactly one of: --all, --family, --changed, --lane,
# --proven-isolated, or script paths):
#   fm-test-run.sh --all
#   fm-test-run.sh --family <name>
#   fm-test-run.sh --changed [--base <git-ref>]
#   fm-test-run.sh --lane portable-parallel-1|portable-parallel-2|portable-serial
#   fm-test-run.sh --lane portable-serial-<k>of<n>   (one CI serial shard)
#   fm-test-run.sh --proven-isolated
#   fm-test-run.sh tests/<name>.test.sh [more scripts...]
#
# Inspection (no execution):
#   fm-test-run.sh --list --all
#   fm-test-run.sh --list --family <name>
#   fm-test-run.sh --list --lane portable-parallel-1
#   fm-test-run.sh --list-scheduled --family <name>
#   fm-test-run.sh --list-scheduled --lane portable-parallel-1
#   fm-test-run.sh --list-families
#   fm-test-run.sh --list-concurrent-safe-families
#   fm-test-run.sh --concurrent-safe-family-jobs-max <name>
#   fm-test-run.sh --list-lanes
#   fm-test-run.sh --check-coverage
#
# Aggregation (no suite execution):
#   fm-test-run.sh --aggregate-json <out.json> <lane.json> [more lane.json...]
#
# Options:
#   --json <path>   write a deterministic timing artifact after the run. Each
#                   script record carries its family, expected gate-skip class,
#                   exit, duration, whether it gate-skipped, and the reason it
#                   gave (empty when it ran), so a lane can say which harness or
#                   tool this host could not exercise.
#   --list          print selected script paths (one per line) and exit 0
#   --list-scheduled
#                   print selected paths longest-hint-first and exit 0.
#                   Only --lane portable-parallel-1 or portable-parallel-2 uses
#                   parallel hints, falling back to serial weights if missing.
#                   Every other selection uses serial weights alone.
#                   Equal weights are ordered by path under LC_ALL=C.
#   --base <ref>    with --changed, compare against this ref (default: origin/main)
#   --exclude-family <name>
#                   drop scripts whose primary family matches <name> after selection
#                   (repeatable; portable CI lanes exclude real-herdr-gated so the
#                   dedicated required Herdr lane owns that coverage)
#   --fail-on-gate-skip <token>
#                   after each script, fail the run if any output line contains
#                   "skip: <token>" (e.g. --fail-on-gate-skip 'herdr not found').
#                   The required Herdr CI lane uses this so a missing pin cannot
#                   silently pass as a gate skip.
#   --jobs N        run the selected scripts with up to N concurrent workers.
#                   Plain --changed and a plain list of script paths use
#                   min(4, cpus) workers when multiple selected scripts are
#                   admissible; --lane, --family, and --all stay serial unless
#                   asked for concurrency explicitly.
#                   N>1 is allowed only when every selected script is proven
#                   safe to run concurrently: individually in the proven-isolated
#                   set (bin/fm-test-isolation-proof.sh --list), or in a family
#                   carrying a recorded concurrent proof
#                   (list_concurrent_safe_families below). Overall cap is 8;
#                   family proofs may impose a lower cap. Individually proven
#                   scripts share one phase; scripts admitted only by a family
#                   proof run in a separate phase for each family. Concurrent
#                   phases use serial weights, longest-hint-first. Unproven stateful
#                   scripts run serially after all concurrent phases. Default is
#                   1 (serial) except for plain --changed and a plain list of
#                   script paths, which use the bounded automatic scheduler.
#   --per-script-timeout-secs N|auto
#                   terminate an attempt that runs longer than its bound, record
#                   it as exit 124 (preserving any recorded nonzero test exit),
#                   and append a "not ok - timed out: ..." line
#                   naming the script and its bound (0 disables, the default).
#                   N applies one bound to every script; auto applies the
#                   measured bound table in per_script_timeout_auto_secs below.
#                   --changed and every CI lane use auto: no healthy script
#                   approaches its bound, so it only converts a HUNG script
#                   into a prompt, named failure instead of a stall to the
#                   caller's or job's own timeout. --max-wall-ms is checked
#                   after the run and so cannot catch a hang on its own.
#                   FM_TEST_STEP_BUDGET_SECS caps all attempts to a shared
#                   invocation deadline; CI reserves reporting margin. It is
#                   consumed by this runner, not inherited by child scripts.
#                   A script it would cut short, or would never start, fails
#                   as budget exhausted (exit 125), never as a timed-out
#                   script and never retried.
#                   FM_TEST_SCRIPT_BASH selects the test interpreter.
#   --retry-infra-flakes
#                   retry once after an observed process signal, harness startup
#                   failure, or per-script timeout. Test-produced exit statuses
#                   never qualify, regardless of their output. Any recorded
#                   test exit vetoes retry even if a descendant holds stdout
#                   open until the stream-draining deadline; that timeout is
#                   still named and annotated. Retries share the invocation
#                   deadline, are skipped when it cannot cover the script's
#                   bound, and are labeled as infrastructure flakes.
#                   Off by default.
#   --max-wall-ms N fail the run when its measured invocation wall clock exceeds
#                   N milliseconds, including an empty selection. It is
#                   evaluated after selection and suite execution and cannot
#                   interrupt a running script; per-script hangs are
#                   bounded by --per-script-timeout-secs. Pathological output
#                   sinks that block finalization are explicitly out of scope.
#   -h, --help      print this header
#
# Per-script machine-parseable markers (stdout):
#   FM_TEST_BEGIN <iso8601> <script> family=<family> expected_gate_skip=<class>
#   FM_TEST_RETRY <iso8601> <script> signature=<id> first_exit=<code>
#                   (only under --retry-infra-flakes, before the single retry)
#   FM_TEST_END <iso8601> <script> exit=<code> duration_ms=<n> gate_skip=<true|false>
#
# After all scripts (stdout):
#   FM_TEST_SUMMARY total=<n> failed=<n> skipped_gate=<n> duration_ms=<n>
#   FM_TEST_SUMMARY_FAMILY family=<name> count=<n> duration_ms=<n> failed=<n>
#   FM_TEST_TIMED_OUT script=<path> bound_secs=<n>   (one per timed-out script)
#   FM_TEST_RETRIED_FLAKE script=<path> signature=<id> first_exit=<n> exit=<n>
#                   (one per retried script; exit is the retry's result)
#   FM_TEST_SLOWEST rank=<k> script=<path> duration_ms=<n>
#   FM_TEST_BUDGET max_wall_ms=<n> duration_ms=<n>   (only with --max-wall-ms)
#
# Under GitHub Actions (GITHUB_ACTIONS=true) each timeout also emits an error
# annotation and each retried flake a warning annotation, and when either
# occurred a table of them is appended to $GITHUB_STEP_SUMMARY.
#
# Placement refusal:
#   A task worker is assigned an isolated worktree, and that placement is
#   checked only when its task starts. When FM_TASK_ID marks such a worker and
#   this runner resolves to the repository's PRIMARY checkout, every executing
#   mode refuses before selecting a suite: the suite creates and switches
#   branches, and the primary is the checkout every linked worktree resolves
#   against. Inspection modes execute nothing and stay available, and a run with
#   no FM_TASK_ID set is unchanged.
#
# Exit status is non-zero if any selected script exits non-zero, a configured
# --fail-on-gate-skip token appears, the measured duration exceeds
# --max-wall-ms, timing-artifact finalization fails, or a concurrent worker
# violates its isolation check. Other gate skips (first meaningful line
# matching ^skip:) remain successful and are counted as skipped_gate; each one
# is logged with its reason and recorded in the timing artifact.
#
# expected_gate_skip classes name why a family is allowed to skip: herdr (the
# pinned real-Herdr lane), optional-binary (a backend whose binary is optional),
# live-capability (a live-harness guard governed by fm_live_gate, which records
# unavailable tools and explicit policy skips; see tests/lib.sh), or none.
#
# Every selected script runs isolated from the host's global and system Git
# configuration, including one that sources no test helper of its own;
# tests/git-config-helpers.sh owns that contract and its limits.
#
# Family labels, the changed-file map, and production portable-shard composition
# live in this script only (one owner). The proven-isolated candidate set remains
# owned by bin/fm-test-isolation-proof.sh; portable parallel shards are a
# duration-balanced partition of that exact set, packed from the measured hints
# in portable_parallel_weight_hints (see docs/fm-test-portable-shards.md).
# --check-coverage reports parallel_max_ms (the larger lane hint sum),
# parallel_imbalance_ms (the absolute difference between the sums), and
# parallel_unhinted (the number of members missing a parallel hint).
# These sums exclude unhinted members and are estimates, not measured job wall
# times. Missing parallel hints are reported without failing this guard.
#
# portable-serial stays strictly serial. Its CI shards (portable-serial-<k>of<n>)
# split it across separate runners, so two of its stateful scripts still never
# share a machine. This script owns <n>: a lane whose <n> disagrees with the
# configured shard count is refused, so a CI matrix cannot silently drop a shard.
# --changed is conservative: it over-selects related families rather than
# under-selecting, and never expands to the complete suite unless --all. The one
# place it is deliberately narrow is a bin/ path with no curated family: a test
# that names it is selected as that SCRIPT, because the reference is per-script
# evidence. Consumer bin/ scripts still resolve through the curated map, so
# recorded family-level coupling still expands to the whole family.
# tests/lib.sh, tests/fixtures.sh, tests/*-helpers.sh and tests/*-fixture.sh are
# shared files that map to the suites naming them; a fixture under
# tests/fixtures/<dir>/ is mapped by that directory instead. Curated family arms
# above those also name individual tests/ files explicitly.
set -eu

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    echo $(($(date +%s) * 1000))
  fi
}

RUN_STARTED_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_STARTED_MS=$(now_ms)
STEP_BUDGET_SECS=${FM_TEST_STEP_BUDGET_SECS:-}
unset FM_TEST_STEP_BUDGET_SECS

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

MODE=
LIST_ONLY=0
LIST_SCHEDULED=0
LIST_FAMILIES=0
LIST_CONCURRENT_SAFE_FAMILIES=0
LIST_LANES=0
CHECK_COVERAGE=0
AGGREGATE_OUT=
FAMILY=
LANE=
BASE_REF=origin/main
JSON_PATH=
SCRIPTS=()
EXCLUDE_FAMILIES=()
FAIL_ON_GATE_SKIP=
JOBS=1
JOBS_EXPLICIT=0
JOBS_MAX=8
MAX_WALL_MS=
PER_SCRIPT_TIMEOUT_SECS=0
RETRY_INFRA_FLAKES=0

# Default bound for --per-script-timeout-secs auto. Derived from measured
# healthy CI runtimes rather than picked: across 30 fork CI runs on 2026-09-30
# every script outside the explicit entries in per_script_timeout_auto_secs
# finished within 218s at its slowest, so 400s leaves more than 1.8x headroom
# while still firing well inside the 25-minute portable parallel job cap.
PER_SCRIPT_TIMEOUT_AUTO_DEFAULT_SECS=400

# How many separate-runner shards the portable serial remainder splits into.
# One owner: CI lane names carry this count and are refused when they disagree.
# 24 keeps every PR-gate shard under the five-minute target on self-hosted
# runners: the lane holds ~89 minutes of measured script time, so an even split
# packs ~3.7 minutes per shard and the longest shard stays below 5 minutes.
PORTABLE_SERIAL_SHARDS=24

# Packed-duration ceiling for one portable serial CI shard, in milliseconds.
# The program's PR-gate target is "each shard <= 5 min". The measured lane is
# 7454 s over 194 scripts, so 24 shards average 310.6 s and no partition can be
# strictly under 300 s: the last few seconds are the shard-count floor, not a
# balancing failure. 330 s is therefore the enforced ceiling, and the coverage
# guard prints the actual maximum so a change that erodes the margin fails
# loudly. This is a sum-of-hints bound, not a wall-clock bound: job setup,
# runner speed, and queueing live outside it. Wall time on N runners is at
# least ceil(24 / N) x the slowest shard.
PORTABLE_SERIAL_MAX_SHARD_MS=330000

# Balance hint for a portable-serial script with no measured duration, close to
# the measured per-script mean so a newly added test neither starves nor
# overloads the shard it lands in.
PORTABLE_SERIAL_DEFAULT_WEIGHT_MS=27000

# Largest share of the serial lane allowed to run on the default weight above.
# Hints are what keep the shards balanced, so once too much of the lane is
# unmeasured the balance is guesswork and one shard can reach its CI job cap
# while another sits idle. The coverage guard refuses past this share, which
# leaves room for newly added tests while making a stale hint table fail loudly
# instead of silently. docs/fm-test-portable-shards.md owns the refresh.
PORTABLE_SERIAL_MAX_UNHINTED_PERCENT=15

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-test-run: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-test-run: %s\n' "$*" >&2
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Bound in seconds for one script under --per-script-timeout-secs auto. Each
# explicit entry is a script whose slowest healthy CI run, across 30 fork CI
# runs on 2026-09-30, came too near the default; its bound keeps at least 1.6x
# headroom over that slowest run, so a hang fails here, named, rather than when
# the job or step cap kills the lane with no explanation.
per_script_timeout_auto_secs() {  # <script path or basename>
  case "${1##*/}" in
    fm-backend-herdr-presentation-e2e.test.sh) echo 1000 ;;  # slowest 473s; Herdr step cap 24m
    # The former fm-watch-triage.test.sh (2100s) and fm-pr-check-security.test.sh
    # (1000s) monoliths are now four case-group drivers each. Their measured
    # slices are ~236s and ~210s, so the default bound is already more than 1.5x
    # the slowest measured slice and no manual entry is needed.
    fm-captain-hold-lifecycle.test.sh) echo 650 ;;  # slowest 392s
    fm-session-start.test.sh | \
      fm-remote-secondmate-lifecycle-e2e.test.sh | fm-procevent.test.sh)
      echo 500 ;;  # slowest 278-309s
    *) echo "$PER_SCRIPT_TIMEOUT_AUTO_DEFAULT_SECS" ;;
  esac
}

# The bound this run applies to <script>, in seconds; 0 means unbounded.
script_timeout_secs() {  # <script>
  case "$PER_SCRIPT_TIMEOUT_SECS" in
    auto) per_script_timeout_auto_secs "$1" ;;
    *) echo "$PER_SCRIPT_TIMEOUT_SECS" ;;
  esac
}

# Emit a GitHub Actions workflow command when running under Actions; a no-op
# elsewhere so local logs stay plain.
gha_annotate() {  # <error|warning> <file> <title> <message>
  [ "${GITHUB_ACTIONS:-}" = true ] || return 0
  printf '::%s file=%s,title=%s::%s\n' "$1" "$2" "$3" "$4"
}

# Enforce the placement refusal described in this script's header.
#
# The primary checkout is the working tree whose own git dir IS the repository's
# common git dir; every linked worktree has a git dir under it instead. That is
# the same predicate bin/fm-spawn.sh uses to keep a launch out of the primary,
# and unlike comparing top-level paths it still holds when the primary is
# reached through a different path. When git resolves neither directory - a
# non-repository fixture, a detached copy - nothing proves this is the primary,
# so the run proceeds.
refuse_primary_checkout_for_task() {
  local task_id git_dir common_dir top
  task_id=${FM_TASK_ID:-}
  [ -n "$task_id" ] || return 0
  git_dir=$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null) \
    && git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || git_dir=
  common_dir=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    && common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P) || common_dir=
  [ -n "$git_dir" ] && [ -n "$common_dir" ] || return 0
  [ "$git_dir" = "$common_dir" ] || return 0
  top=$(cd "$ROOT" && pwd -P)
  die "refusing to run in the repository primary checkout $top while FM_TASK_ID=$task_id is set; run from the assigned task worktree instead"
}

cpu_count() {
  local n
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$n" in
    ''|*[!0-9]*) n=1 ;;
  esac
  [ "$n" -ge 1 ] || n=1
  printf '%s\n' "$n"
}

# Primary family for one tests/*.test.sh basename. Unmapped scripts are
# unclassified so new tests are still runnable and visible in summaries.
#
# `standalone` is the residual family: scripts that belong to no subsystem
# family above but each own their own surface. Its membership is enumerated
# rather than inherited from the `*)` catch-all precisely because the catch-all
# also swallows every test nobody has classified yet. Keeping the two separate
# is what lets `standalone` carry a concurrent proof while a brand-new test
# lands in `unclassified` and stays serial until someone proves it.
FM_FAMILY=
family_for_basename_into() {
  case "$1" in
    fm-arm-pretool-check.test.sh|fm-ask-user-authority.test.sh|\
    fm-bearings-board.test.sh|\
    fm-brief.test.sh|fm-vendor-auth-probe.test.sh|\
    fm-calm-pi-extension.test.sh|fm-cd-pretool-check.test.sh|\
    fm-classify-decision-key.test.sh|\
    fm-composer-ghost.test.sh|fm-composer-lib.test.sh|\
    fm-crew-state.test.sh|fm-captain-hold-lifecycle.test.sh|\
    fm-documentation-audiences.test.sh|fm-ensure-agents-md.test.sh|fm-grok-harness.test.sh|\
    fm-harness-precedence.test.sh|\
    fm-kimi-harness.test.sh|fm-muse-harness.test.sh|fm-rovo-harness.test.sh|fm-agy-harness.test.sh|fm-omp-harness.test.sh|fm-omp-branch.test.sh|fm-herdr-lab.test.sh|fm-lint.test.sh|\
    fm-lint-workflows.test.sh|\
    fm-operational-input.test.sh|fm-pi-primary-types.test.sh|\
    fm-calm-claude-mod.test.sh|\
    fm-harness-adapter-references.test.sh|\
    fm-send-popup-settle.test.sh|fm-send-settle.test.sh|\
    fm-subagent-pretool-check.test.sh|\
    fm-supervision-instructions.test.sh|fm-task-delivery.test.sh|\
    fm-tmux-submit-busy.test.sh|fm-trace-context-lib.test.sh|\
    fm-transition-lib.test.sh|\
    fm-test-run.test.sh|fm-test-isolation-proof.test.sh)
      FM_FAMILY=pure-contract-unit
      ;;
    fm-daemon.test.sh|fm-guard-stale-banner.test.sh|fm-pi-watch-extension.test.sh|\
    fm-session-lock-ancestry.test.sh|fm-cursor-primary.test.sh|\
    fm-supervision-events.test.sh|fm-turnend-guard.test.sh|fm-wake-daemon-lifecycle-e2e.test.sh|\
    fm-wake-drain-unread-status.test.sh|\
    fm-tool-update-check.test.sh|\
    fm-mail.test.sh|fm-mail-check.test.sh|fm-queue-zero.test.sh|fm-far-holds.test.sh|fm-attention-check.test.sh|fm-release-stopped.test.sh|\
    fm-wake-queue.test.sh|fm-watch-arm.test.sh|fm-watch-checkpoint.test.sh|fm-watch-recovery-loop.test.sh|\
    fm-watch-triage-*.test.sh|fm-task-inbox.test.sh|\
    fm-watcher-lock.test.sh|fm-inactive-reconcile.test.sh)
      FM_FAMILY=watcher-wake-lock
      ;;
    fm-afk-inject-herdr-e2e.test.sh|fm-afk-launch.test.sh|fm-backend-autodetect-smoke.test.sh|\
    fm-backend-herdr-eventwait-smoke.test.sh|fm-backend-herdr-presentation-e2e.test.sh|\
    fm-backend-herdr-launcher-workspace-e2e.test.sh|\
    fm-backend-herdr-prune-safety-e2e.test.sh|fm-backend-herdr-respawn-idem-e2e.test.sh|\
    fm-backend-herdr-focus-flash-e2e.test.sh|\
    fm-backend-herdr-stale-active-tab-e2e.test.sh|\
    fm-backend-herdr-agent-exit-shell-e2e.test.sh|\
    fm-herdr-attached-viewer-live-e2e.test.sh|fm-herdr-session-cleanup-e2e.test.sh|\
    fm-backend-herdr-smoke.test.sh|fm-backend-herdr-workspace-per-home-e2e.test.sh|\
    fm-control-herdr-smoke.test.sh)
      FM_FAMILY=real-herdr-gated
      ;;
    fm-backlog-handoff.test.sh|fm-on.test.sh|fm-remote-backlog-handoff.test.sh|\
    fm-remote-doctor.test.sh|fm-remote-herdr-guard.test.sh|fm-remote-job.test.sh|fm-remote-job-orphan-reap.test.sh|\
    fm-remote-transport-lanes.test.sh|\
    fm-remote-reply.test.sh|fm-remote-secondmate-lifecycle-e2e.test.sh|\
    fm-remote-secondmate-trace-context.test.sh|\
    fm-secondmate-harness.test.sh|fm-secondmate-lifecycle-e2e.test.sh|\
    fm-secondmate-liveness.test.sh|fm-secondmate-reconcile.test.sh|\
    fm-secondmate-restart.test.sh|\
    fm-secondmate-safety.test.sh|fm-secondmate-sync.test.sh|\
    fm-startup-memory-budget.test.sh|fm-stow-cascade.test.sh|\
    fm-send-secondmate-marker.test.sh|fm-shared-captain-inheritance.test.sh)
      FM_FAMILY=secondmate
      ;;
    fm-backlog-atomicity.test.sh|\
    fm-bootstrap.test.sh|fm-bootstrap-network-parallel.test.sh|fm-fleet-sync.test.sh|fm-gate-refuse.test.sh|fm-gotmp.test.sh|\
    fm-session-start.test.sh|fm-sessionstart-nudge.test.sh|fm-startup-network.test.sh|\
    fm-tangle-guard.test.sh|fm-update.test.sh)
      FM_FAMILY=session-bootstrap
      ;;
    fm-afk-pi-herdr-return-e2e.test.sh|\
    fm-bearings-board-lavish-live-e2e.test.sh|\
    fm-claude-stop-autoarm-live-e2e.test.sh|\
    fm-cmux-claude-composer-live-e2e.test.sh|\
    fm-composer-matrix-live-e2e.test.sh|\
    fm-composer-codex-idle-live-e2e.test.sh|\
    fm-codex-continuity-live-e2e.test.sh|fm-grok-continuity-live-e2e.test.sh|\
    fm-cursor-primary-live-e2e.test.sh|\
    fm-grok-stop-live-e2e.test.sh|fm-harness-adapter-instructions-live-e2e.test.sh|\
    fm-harness-liveness-drift-live-e2e.test.sh|\
    fm-muse-signals-live-e2e.test.sh|fm-rovo-signals-live-e2e.test.sh|fm-agy-signals-live-e2e.test.sh|\
    fm-herdr-version-floor-live-e2e.test.sh|\
    fm-herdr-pi-stale-registration-live-e2e.test.sh|\
    fm-opencode-primary-live-e2e.test.sh|fm-pi-branch-live-e2e.test.sh|fm-omp-branch-live-e2e.test.sh|\
    fm-pi-branch-responsiveness-live-e2e.test.sh|\
    fm-pi-primary-live-e2e.test.sh|fm-pi-codex-native.test.sh|fm-omp-primary-live-e2e.test.sh|\
    fm-pr-state-live-e2e.test.sh|\
    fm-sessionstart-hook-live-e2e.test.sh|fm-sessionstart-instruction-refresh-live-e2e.test.sh|\
    fm-quota-array-dispatch-live-e2e.test.sh|fm-send-secondmate-marker-herdr-e2e.test.sh|\
    fm-send-inbox-doorbell-live-e2e.test.sh|fm-control-switch-model-live-e2e.test.sh|\
    fm-calm-claude-mod-plugin.test.sh|fm-calm-claude-mod-live-e2e.test.sh|\
    fm-herdr-submit-confirm-live-e2e.test.sh)
      FM_FAMILY=live-harness-optin
      ;;
    fm-backend-herdr.test.sh|fm-backend-tmux-smoke.test.sh|fm-backend.test.sh|\
    fm-tmux-agent-liveness.test.sh|\
    fm-control.test.sh|fm-control-relaunch.test.sh|\
    fm-herdr-session-cleanup.test.sh|fm-send-resolve-key.test.sh|fm-send-strict.test.sh|\
    fm-send-inbox.test.sh|fm-spawn-batch.test.sh|\
    fm-spawn-dispatch-profile.test.sh|fm-wip-caps.test.sh|fm-claude-trust.test.sh|\
    fm-trace-context-spawn.test.sh|fm-spawn-worktree-settle.test.sh|\
    fm-teardown-endpoint-safety.test.sh)
      FM_FAMILY=backend-dispatch
      ;;
    fm-action-ledger.test.sh|fm-check-unregister.test.sh|fm-flow-wait-ledger.test.sh|fm-flow-wait-analyze.test.sh|\
    fm-pr-check-security-*.test.sh|fm-pr-merge.test.sh|fm-pr-sweep.test.sh|\
    fm-pr-reviewers.test.sh|fm-pr-state.test.sh|\
    fm-review-diff.test.sh|fm-teardown.test.sh|fm-followup-ledger.test.sh|fm-x-mode.test.sh)
      FM_FAMILY=pr-forge
      ;;
    fm-afk-contract.test.sh|fm-afk-inject-e2e.test.sh|fm-afk-return.test.sh)
      FM_FAMILY=afk
      ;;
    fm-bearings-board-render.test.sh|fm-bearings-snapshot.test.sh|fm-contributions.test.sh|\
    fm-fleet-snapshot-view.test.sh|fm-home-summary-refresh.test.sh)
      FM_FAMILY=snapshot-bearings
      ;;
    fm-backend-cmux.test.sh|fm-backend-cmux-smoke.test.sh)
      FM_FAMILY=cmux
      ;;
    fm-backend-zellij.test.sh|fm-backend-zellij-smoke.test.sh)
      FM_FAMILY=zellij
      ;;
    fm-backend-orca.test.sh)
      FM_FAMILY=orca
      ;;
    fm-branch-supervision.test.sh|fm-busy-adapter-wiring.test.sh|\
    fm-busy-state.test.sh|fm-classify-corr-token.test.sh|\
    fm-claude-stop-autoarm.test.sh|fm-cursor-harness.test.sh|\
    fm-extension-binding.test.sh|fm-gitignore-config.test.sh|\
    fm-no-mistakes-required.test.sh|fm-peek-remote.test.sh|\
    fm-pending-reply.test.sh|fm-pi-branch-extension.test.sh|\
    fm-procevent-quota.test.sh|fm-procevent-when.test.sh|fm-procevent.test.sh|\
    fm-resume-watch.test.sh|\
    fm-live-gate.test.sh|\
    fm-project-origin.test.sh|fm-public-followup.test.sh|fm-quota-choose.test.sh|\
    fm-remote-entrypoint.test.sh|fm-remote-secondmate-parent-binding.test.sh|\
    fm-send-remote-delivery.test.sh|fm-spawn-pool-base-freshen.test.sh|\
    fm-test-fixture-cleanup.test.sh|fm-test-fixtures.test.sh|\
    fm-voice-relay.test.sh|fm-wake-drain-open-decisions-cursor.test.sh|\
    fm-wake-drain-open-decisions.test.sh|fm-wake-drain-outcome-backstop.test.sh)
      FM_FAMILY=standalone
      ;;
    *)
      FM_FAMILY=unclassified
      ;;
  esac
}

# Command-substitution wrapper for callers that need the value in a pipeline;
# hot loops use family_for_basename_into and read $FM_FAMILY to avoid a fork
# per repository test.
family_for_basename() {
  family_for_basename_into "$1"
  printf '%s\n' "$FM_FAMILY"
}

expected_gate_skip_for_family() {
  case "$1" in
    real-herdr-gated) printf '%s\n' herdr ;;
    live-harness-optin) printf '%s\n' live-capability ;;
    cmux|zellij|orca) printf '%s\n' optional-binary ;;
    snapshot-bearings) printf '%s\n' optional-binary ;;
    *) printf '%s\n' none ;;
  esac
}

list_known_families() {
  cat <<'EOF'
pure-contract-unit
watcher-wake-lock
real-herdr-gated
secondmate
session-bootstrap
live-harness-optin
backend-dispatch
pr-forge
afk
snapshot-bearings
cmux
zellij
orca
standalone
unclassified
EOF
}

list_known_lanes() {
  local i
  printf '%s\n' portable-parallel-1
  printf '%s\n' portable-parallel-2
  printf '%s\n' portable-serial
  i=1
  while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    printf 'portable-serial-%sof%s\n' "$i" "$PORTABLE_SERIAL_SHARDS"
    i=$((i + 1))
  done
  printf '%s\n' real-herdr-gated
}

# Exact proven-isolated candidate set (same paths as
# bin/fm-test-isolation-proof.sh --list). Do not expand without a new concurrent
# isolation proof archive.
list_proven_isolated() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-brief.test.sh
tests/fm-captain-hold-lifecycle.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-composer-lib.test.sh
tests/fm-crew-state.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-grok-harness.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-lint.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-pr-merge.test.sh
tests/fm-review-diff.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-test-run.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-transition-lib.test.sh
tests/fm-x-mode.test.sh
EOF
}

# Per-script serial CI duration hints, one "<path> <ms>" per line, used to
# pack only the two portable parallel lanes. Measurement provenance and the
# refresh procedure are owned by docs/fm-test-portable-shards.md.
portable_parallel_weight_hints() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh 32376
tests/fm-backend-herdr.test.sh 31064
tests/fm-brief.test.sh 6259
tests/fm-captain-hold-lifecycle.test.sh 402790
tests/fm-cd-pretool-check.test.sh 17725
tests/fm-composer-ghost.test.sh 2536
tests/fm-composer-lib.test.sh 8052
tests/fm-crew-state.test.sh 19177
tests/fm-ensure-agents-md.test.sh 937
tests/fm-grok-harness.test.sh 7680
tests/fm-herdr-lab.test.sh 17363
tests/fm-lint.test.sh 214204
tests/fm-pi-primary-types.test.sh 3109
tests/fm-pr-merge.test.sh 307448
tests/fm-review-diff.test.sh 3376
tests/fm-send-popup-settle.test.sh 5997
tests/fm-send-settle.test.sh 2553
tests/fm-send-strict.test.sh 10618
tests/fm-spawn-batch.test.sh 2942
tests/fm-supervision-instructions.test.sh 395
tests/fm-test-run.test.sh 148422
tests/fm-tmux-submit-busy.test.sh 2765
tests/fm-transition-lib.test.sh 143
tests/fm-x-mode.test.sh 31910
EOF
}

# Sum the hints above for the scripts read on stdin, and report how many of
# them had no hint at all, as "<summed_ms> <unhinted_count>".
portable_parallel_lane_weight() {
  awk '
    NR == FNR { if (NF) { hint[$1] = $2 } ; next }
    NF {
      if ($1 in hint) { total += hint[$1] } else { unhinted++ }
    }
    END { printf "%d %d\n", total + 0, unhinted + 0 }
  ' <(portable_parallel_weight_hints) -
}

# Portable parallel shard 1: LPT balance of the proven-isolated set over the
# hints above. Stored order agrees with this lane's --list-scheduled output.
# tests/fm-pi-primary-types.test.sh belongs to this lane because
# this is the parallel job that installs the Pi package; moving it needs that
# workflow step moved with it.
list_portable_parallel_1() {
  cat <<'EOF'
tests/fm-captain-hold-lifecycle.test.sh
tests/fm-test-run.test.sh
tests/fm-x-mode.test.sh
tests/fm-crew-state.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-grok-harness.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-send-settle.test.sh
tests/fm-ensure-agents-md.test.sh
EOF
}

# Portable parallel shard 2: the complementary LPT half of the proven set.
list_portable_parallel_2() {
  cat <<'EOF'
tests/fm-pr-merge.test.sh
tests/fm-lint.test.sh
tests/fm-arm-pretool-check.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-send-strict.test.sh
tests/fm-composer-lib.test.sh
tests/fm-brief.test.sh
tests/fm-review-diff.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-transition-lib.test.sh
EOF
}

# Families whose scripts are proven safe to run concurrently WITH EACH OTHER
# under the bounded local scheduler. Deliberately separate from the
# proven-isolated set, which must stay exactly equal to the portable CI shard
# union (see the coverage guard); these families keep their serial CI lane and
# only gain concurrency for a local run.
#
# Membership is empirical, never assumed:
# `bin/fm-test-isolation-proof.sh --pool <family> --jobs 4` is the owner of the
# proof, and docs/fm-test-isolation-proof.md records the dated result.
list_concurrent_safe_families() {
  cat <<'EOF'
watcher-wake-lock
pure-contract-unit
pr-forge
secondmate
session-bootstrap
standalone
EOF
}

family_is_concurrent_safe() {
  local want=$1 line
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done < <(list_concurrent_safe_families)
  return 1
}

concurrent_safe_family_jobs_max() {
  case "$1" in
    watcher-wake-lock|pure-contract-unit|pr-forge) printf '4\n' ;;
    secondmate|session-bootstrap|standalone) printf '4\n' ;;
    *) printf '1\n' ;;
  esac
}

# A script may run under --jobs when it is individually proven isolated or is
# an exact repository member of a family carrying a recorded concurrent proof.
script_allows_concurrency() {
  local s=$1 family repo_script
  is_proven_isolated_script "$s" && return 0
  family=$(family_for_basename "$(basename "$s")")
  family_is_concurrent_safe "$family" || return 1
  while IFS= read -r repo_script; do
    [ "$repo_script" = "$s" ] && return 0
  done < <(all_repo_tests)
  return 1
}

# Cache the proven-isolated list in a shell variable, read without a fork.
# Membership is asked once per repository test while deriving the serial lane,
# so a per-call process substitution made lane listing tens of seconds on a
# loaded host. `read -d ''` slurps the whole file in one builtin.
FM_PROVEN_ISOLATED_CACHE=
fm_proven_isolated_cache_load() {
  local file
  [ -n "$FM_PROVEN_ISOLATED_CACHE" ] && return 0
  file=${TMPDIR:-/tmp}/fm-proven-isolated.$$.txt
  list_proven_isolated > "$file" || return 1
  IFS= read -r -d '' FM_PROVEN_ISOLATED_CACHE < "$file" || true
  rm -f "$file"
}

is_proven_isolated_script() {
  local want=$1
  fm_proven_isolated_cache_load || return 1
  case $'\n'"$FM_PROVEN_ISOLATED_CACHE"$'\n' in
    *$'\n'"$want"$'\n'*) return 0 ;;
  esac
  return 1
}

# The portable serial remainder: every tests/*.test.sh that is neither
# proven-isolated nor real-herdr-gated. Watcher, lock, AFK, real tmux, daemon,
# secondmate lifecycle, bootstrap, the live-harness-optin family, GUI-backend,
# and other unproven work stays here. Derived rather than enumerated so a newly added test
# lands here by default instead of falling out of every lane.
list_portable_serial() {
  local s base fam
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    base=${s##*/}
    family_for_basename_into "$base"
    if [ "$FM_FAMILY" = "real-herdr-gated" ]; then
      continue
    fi
    if is_proven_isolated_script "$s"; then
      continue
    fi
    printf '%s\n' "$s"
  done < <(all_repo_tests)
}

# Measured portable-serial script durations in milliseconds, from the CI timing
# artifacts recorded in docs/fm-test-portable-shards.md. Each value is the
# slowest of several green runs, so the balance holds on a slow runner rather
# than only on the fastest one measured. These are balance hints only: the shard
# partition stays complete and disjoint whatever they say, so a stale hint costs
# balance rather than coverage. That doc owns the refresh procedure.
portable_serial_weight_hints() {
  cat <<'EOF'
tests/fm-action-ledger.test.sh 6024
tests/fm-afk-contract.test.sh 15734
tests/fm-afk-inject-e2e.test.sh 33526
tests/fm-afk-pi-herdr-return-e2e.test.sh 89
tests/fm-afk-return.test.sh 20306
tests/fm-agy-harness.test.sh 48803
tests/fm-agy-signals-live-e2e.test.sh 171
tests/fm-ask-user-authority.test.sh 153
tests/fm-attention-check.test.sh 32697
tests/fm-backend-cmux-smoke.test.sh 61
tests/fm-backend-cmux.test.sh 3664
tests/fm-backend-orca.test.sh 41194
tests/fm-backend-tmux-smoke.test.sh 287
tests/fm-backend-zellij-smoke.test.sh 64
tests/fm-backend-zellij.test.sh 9346
tests/fm-backend.test.sh 22604
tests/fm-backlog-atomicity.test.sh 231208
tests/fm-backlog-handoff.test.sh 56798
tests/fm-backlog-read-bound.test.sh 24506
tests/fm-bearings-board-lavish-live-e2e.test.sh 91
tests/fm-bearings-board-render.test.sh 15271
tests/fm-bearings-board.test.sh 41771
tests/fm-bearings-snapshot.test.sh 172118
tests/fm-bootstrap-network-parallel.test.sh 9546
tests/fm-bootstrap.test.sh 43584
tests/fm-branch-supervision.test.sh 10408
tests/fm-busy-adapter-wiring.test.sh 29256
tests/fm-busy-state.test.sh 3115
tests/fm-calm-claude-mod-live-e2e.test.sh 166
tests/fm-calm-claude-mod-plugin.test.sh 107
tests/fm-calm-claude-mod.test.sh 1375
tests/fm-calm-pi-extension.test.sh 49193
tests/fm-check-unregister.test.sh 410
tests/fm-ci-workflow.test.sh 2183
tests/fm-classify-corr-token.test.sh 21713
tests/fm-classify-decision-key.test.sh 1077
tests/fm-claude-stop-autoarm-live-e2e.test.sh 75
tests/fm-claude-stop-autoarm.test.sh 60947
tests/fm-claude-trust.test.sh 12903
tests/fm-cmux-claude-composer-live-e2e.test.sh 108
tests/fm-codex-continuity-live-e2e.test.sh 167
tests/fm-composer-codex-idle-live-e2e.test.sh 75
tests/fm-composer-matrix-live-e2e.test.sh 92
tests/fm-contributions.test.sh 114187
tests/fm-control-relaunch.test.sh 81559
tests/fm-control-switch-model-live-e2e.test.sh 93
tests/fm-control.test.sh 63449
tests/fm-cursor-harness.test.sh 30135
tests/fm-cursor-primary-live-e2e.test.sh 105
tests/fm-cursor-primary.test.sh 53556
tests/fm-daemon.test.sh 27630
tests/fm-documentation-audiences.test.sh 768
tests/fm-done-outcome.test.sh 36637
tests/fm-durable-job.test.sh 4292
tests/fm-extension-binding.test.sh 8509
tests/fm-far-holds.test.sh 10259
tests/fm-fleet-backend.test.sh 15047
tests/fm-fleet-placement.test.sh 3002
tests/fm-fleet-snapshot-view.test.sh 11275
tests/fm-fleet-sync.test.sh 36759
tests/fm-flow-wait-analyze.test.sh 445
tests/fm-flow-wait-ledger.test.sh 1226
tests/fm-followup-ledger.test.sh 7771
tests/fm-gate-refuse.test.sh 5438
tests/fm-gemini-harness.test.sh 1069
tests/fm-gitignore-config.test.sh 97
tests/fm-gotmp.test.sh 1469
tests/fm-grok-continuity-live-e2e.test.sh 92
tests/fm-grok-stop-live-e2e.test.sh 91
tests/fm-guard-stale-banner.test.sh 15932
tests/fm-harness-adapter-instructions-live-e2e.test.sh 93
tests/fm-harness-adapter-references.test.sh 101
tests/fm-harness-liveness-drift-live-e2e.test.sh 874
tests/fm-harness-precedence.test.sh 4043
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh 76
tests/fm-herdr-session-cleanup.test.sh 6484
tests/fm-herdr-submit-confirm-live-e2e.test.sh 76
tests/fm-herdr-version-floor-live-e2e.test.sh 170
tests/fm-home-summary-refresh.test.sh 37039
tests/fm-inactive-reconcile.test.sh 50099
tests/fm-kimi-harness.test.sh 20189
tests/fm-lint-workflows.test.sh 925
tests/fm-live-gate.test.sh 1729
tests/fm-mail-check.test.sh 7257
tests/fm-mail.test.sh 11092
tests/fm-merge-path-window-stats.test.sh 155
tests/fm-muse-harness.test.sh 44760
tests/fm-muse-signals-live-e2e.test.sh 95
tests/fm-nm-test-contract.test.sh 679
tests/fm-no-mistakes-required.test.sh 344
tests/fm-omp-branch-live-e2e.test.sh 90
tests/fm-omp-branch.test.sh 93632
tests/fm-omp-calm-install.test.sh 89
tests/fm-omp-harness.test.sh 93560
tests/fm-omp-primary-live-e2e.test.sh 167
tests/fm-on.test.sh 10115
tests/fm-opencode-primary-live-e2e.test.sh 75
tests/fm-operational-input.test.sh 342
tests/fm-peek-remote.test.sh 902
tests/fm-pending-reply.test.sh 31287
tests/fm-pi-branch-extension.test.sh 73586
tests/fm-pi-branch-live-e2e.test.sh 106
tests/fm-pi-branch-responsiveness-live-e2e.test.sh 13107
tests/fm-pi-codex-native.test.sh 166
tests/fm-pi-primary-live-e2e.test.sh 74
tests/fm-pi-watch-extension.test.sh 52678
tests/fm-pi-windows-shell-invocation.test.sh 147
tests/fm-pr-check-security-1.test.sh 209600
tests/fm-pr-check-security-2.test.sh 209600
tests/fm-pr-check-security-3.test.sh 209600
tests/fm-pr-check-security-4.test.sh 209600
tests/fm-pr-reviewers.test.sh 273
tests/fm-pr-state-live-e2e.test.sh 76
tests/fm-pr-state.test.sh 900
tests/fm-pr-sweep.test.sh 15608
tests/fm-prime-swarm.test.sh 25971
tests/fm-procevent-quota.test.sh 2046
tests/fm-procevent-when.test.sh 22577
tests/fm-procevent.test.sh 250379
tests/fm-project-origin.test.sh 134
tests/fm-public-followup.test.sh 156803
tests/fm-queue-zero.test.sh 35683
tests/fm-quota-array-dispatch-live-e2e.test.sh 104
tests/fm-quota-choose.test.sh 1477
tests/fm-remote-backlog-handoff.test.sh 68799
tests/fm-remote-doctor.test.sh 13752
tests/fm-remote-entrypoint.test.sh 154
tests/fm-remote-herdr-guard.test.sh 3257
tests/fm-remote-job-orphan-reap.test.sh 3103
tests/fm-remote-job.test.sh 58696
tests/fm-remote-reply.test.sh 127509
tests/fm-remote-secondmate-lifecycle-e2e.test.sh 228473
tests/fm-remote-secondmate-parent-binding.test.sh 30906
tests/fm-remote-secondmate-trace-context.test.sh 61238
tests/fm-remote-transport-lanes.test.sh 63455
tests/fm-resume-watch.test.sh 25809
tests/fm-rovo-harness.test.sh 14394
tests/fm-rovo-signals-live-e2e.test.sh 109
tests/fm-secondmate-harness.test.sh 173824
tests/fm-secondmate-lifecycle-e2e.test.sh 8751
tests/fm-secondmate-liveness.test.sh 9977
tests/fm-secondmate-reconcile.test.sh 100419
tests/fm-secondmate-restart.test.sh 45761
tests/fm-secondmate-safety.test.sh 73385
tests/fm-secondmate-sync.test.sh 55430
tests/fm-send-agy-confirm.test.sh 3874
tests/fm-send-inbox-doorbell-live-e2e.test.sh 107
tests/fm-send-inbox.test.sh 40108
tests/fm-send-remote-delivery.test.sh 29746
tests/fm-send-resolve-key.test.sh 31748
tests/fm-send-secondmate-marker-herdr-e2e.test.sh 97
tests/fm-send-secondmate-marker.test.sh 5644
tests/fm-session-lock-ancestry.test.sh 2965
tests/fm-session-start.test.sh 223706
tests/fm-sessionstart-hook-live-e2e.test.sh 92
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh 91
tests/fm-sessionstart-nudge.test.sh 68859
tests/fm-shared-captain-inheritance.test.sh 6372
tests/fm-spawn-dispatch-profile.test.sh 139840
tests/fm-spawn-pool-base-freshen.test.sh 71085
tests/fm-spawn-worktree-settle.test.sh 9010
tests/fm-startup-memory-budget.test.sh 7872
tests/fm-startup-network.test.sh 63655
tests/fm-stat-shadowing.test.sh 92
tests/fm-stow-cascade.test.sh 2964
tests/fm-stow-trigger.test.sh 15697
tests/fm-subagent-pretool-check.test.sh 1279
tests/fm-supervision-events.test.sh 728
tests/fm-tangle-guard.test.sh 8104
tests/fm-task-delivery.test.sh 26185
tests/fm-task-inbox.test.sh 32799
tests/fm-tasks-axi.test.sh 1989
tests/fm-teardown-endpoint-safety.test.sh 67106
tests/fm-teardown.test.sh 187383
tests/fm-test-fixture-cleanup.test.sh 879
tests/fm-test-fixtures.test.sh 2445
tests/fm-test-isolation-proof.test.sh 2852
tests/fm-tmux-agent-liveness.test.sh 2169
tests/fm-tool-update-check.test.sh 14791
tests/fm-trace-context-lib.test.sh 248
tests/fm-trace-context-spawn.test.sh 51816
tests/fm-turnend-guard.test.sh 36685
tests/fm-update.test.sh 17005
tests/fm-vendor-auth-probe.test.sh 46598
tests/fm-voice-relay.test.sh 28707
tests/fm-wake-daemon-lifecycle-e2e.test.sh 8917
tests/fm-wake-drain-open-decisions-cursor.test.sh 21187
tests/fm-wake-drain-open-decisions.test.sh 7531
tests/fm-wake-drain-outcome-backstop.test.sh 47645
tests/fm-wake-drain-unread-status.test.sh 19020
tests/fm-wake-queue.test.sh 210016
tests/fm-watch-arm.test.sh 60121
tests/fm-watch-checkpoint.test.sh 6817
tests/fm-watch-recovery-loop.test.sh 59156
tests/fm-watch-triage-1.test.sh 236150
tests/fm-watch-triage-2.test.sh 236150
tests/fm-watch-triage-3.test.sh 236150
tests/fm-watch-triage-4.test.sh 236150
tests/fm-watcher-lock.test.sh 125809
tests/fm-wip-caps.test.sh 61979
EOF
}

# The portable-serial scripts with no measured hint, one per line. These fall
# back to PORTABLE_SERIAL_DEFAULT_WEIGHT_MS, so they are balanced on a guess
# rather than on evidence; the coverage guard bounds how many there may be.
portable_serial_unhinted() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-unhinted.XXXXXX") || return 1
  portable_serial_weight_hints | awk 'NF { print $1 }' | LC_ALL=C sort -u >"$tmp/hinted"
  list_portable_serial | LC_ALL=C sort -u >"$tmp/serial"
  LC_ALL=C comm -23 "$tmp/serial" "$tmp/hinted"
  rm -rf "$tmp"
}

portable_parallel_weight_for() {
  local want=$1 ms
  ms=$(portable_parallel_weight_hints | awk -v want="$want" '$1 == want { print $2; exit }')
  if [ -n "$ms" ]; then
    printf '%s\n' "$ms"
    return 0
  fi
  portable_serial_weight_for "$want"
}

portable_serial_weight_for() {
  local want=$1 path ms
  while read -r path ms; do
    if [ "$path" = "$want" ]; then
      printf '%s\n' "$ms"
      return 0
    fi
  done < <(portable_serial_weight_hints)
  printf '%s\n' "$PORTABLE_SERIAL_DEFAULT_WEIGHT_MS"
}

# Longest-processing-time assignment of the serial remainder to
# PORTABLE_SERIAL_SHARDS bins, printing "<shard>\t<ms>\t<script>" for every
# script. Deterministic: candidates are ordered by hint descending then path,
# and ties between equally loaded bins always take the lowest bin index.
#
# One awk pass joins the hint table to the derived serial list and one more
# packs the bins. The earlier per-script shell loop forked twice per script
# (weight lookup plus list membership) and took over a minute on a loaded host;
# the coverage guard calls this once per shard-count check, so the loop cost
# multiplied by 24. Joining in awk keeps lane selection proportional to file
# reads rather than process spawns.
portable_serial_assignments() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-assign.XXXXXX") || return 1
  portable_serial_weight_hints > "$tmp/hints" || { rm -rf "$tmp"; return 1; }
  list_portable_serial > "$tmp/serial" || { rm -rf "$tmp"; return 1; }
  awk -v def="$PORTABLE_SERIAL_DEFAULT_WEIGHT_MS" '
    NR == FNR { if (NF >= 2) hint[$1] = $2; next }
    NF {
      ms = ($1 in hint) ? hint[$1] : def
      print ms "\t" $1
    }
  ' "$tmp/hints" "$tmp/serial" |
    LC_ALL=C sort -k1,1nr -k2,2 |
    awk -F'\t' -v n="$PORTABLE_SERIAL_SHARDS" '
      {
        best = 1
        for (i = 2; i <= n; i++) if (load[i] + 0 < load[best] + 0) best = i
        load[best] += $1
        print best "\t" $1 "\t" $2
      }
    '
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# Parse "<k>of<n>" from a portable-serial shard lane and echo <k>, refusing when
# <n> disagrees with this script's configured count so a CI matrix built for a
# different shard count fails loudly instead of dropping tests.
portable_serial_shard_index() {
  local lane=$1 spec index count
  spec=${lane#portable-serial-}
  index=${spec%%of*}
  count=${spec#*of}
  case "$spec" in
    *of*) ;;
    *) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$index" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$count" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  if [ "$count" -ne "$PORTABLE_SERIAL_SHARDS" ]; then
    die "lane '$lane' asks for $count portable serial shards but this runner is configured for $PORTABLE_SERIAL_SHARDS (see --list-lanes)"
  fi
  if [ "$index" -lt 1 ] || [ "$index" -gt "$PORTABLE_SERIAL_SHARDS" ]; then
    die "lane '$lane' shard index is outside 1..$PORTABLE_SERIAL_SHARDS (see --list-lanes)"
  fi
  printf '%s\n' "$index"
}

select_proven_isolated() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(list_proven_isolated)
}

select_lane() {
  local want=$1 s shard idx found=0
  case "$want" in
    portable-parallel-1)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_1)
      ;;
    portable-parallel-2)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_2)
      ;;
    portable-serial)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_serial)
      ;;
    portable-serial-*)
      # One separate-runner shard of the same remainder, still serial in itself.
      shard=$(portable_serial_shard_index "$want")
      while IFS=$'\t' read -r idx _ms s; do
        [ -n "$s" ] || continue
        if [ "$idx" = "$shard" ]; then
          add_script "$s"
          found=1
        fi
      done < <(portable_serial_assignments)
      ;;
    real-herdr-gated)
      select_family real-herdr-gated
      found=1
      ;;
    *)
      die "unknown lane '$want' (see --list-lanes)"
      ;;
  esac
  [ "$found" -eq 1 ] || die "lane '$want' selected no tests"
}

run_coverage_guard() {
  local tmp missing extra a b shard unhinted serial_total shard_ms
  local serial_shard_max_ms over_budget _unused
  local p1_ms p1_unhinted p2_ms p2_unhinted parallel_max_ms parallel_imbalance_ms
  local -a saved_scripts=()
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-coverage.XXXXXX")

  all_repo_tests | LC_ALL=C sort -u >"$tmp/all"
  list_proven_isolated | LC_ALL=C sort -u >"$tmp/proven"
  list_portable_parallel_1 | LC_ALL=C sort -u >"$tmp/s1"
  list_portable_parallel_2 | LC_ALL=C sort -u >"$tmp/s2"

  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort | uniq -d >"$tmp/shard_dups"
  if [ -s "$tmp/shard_dups" ]; then
    log "coverage guard: portable parallel shards share scripts:"
    cat "$tmp/shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort -u >"$tmp/shards_union"
  missing=$(comm -23 "$tmp/proven" "$tmp/shards_union" || true)
  extra=$(comm -13 "$tmp/proven" "$tmp/shards_union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable shards must equal the proven-isolated set"
    [ -z "$missing" ] || { log "missing from shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond proven:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Serial (whole lane and each CI shard) + Herdr lane listings without
  # disturbing a caller's selection. The LPT partition is computed once: the
  # old loop re-derived it for every shard, which at 24 shards turned a
  # seconds-long guard into a multi-minute one on a loaded runner.
  saved_scripts=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
  SCRIPTS=()
  select_lane portable-serial
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/serial"
  portable_serial_assignments >"$tmp/serial_assignments" || {
    log "coverage guard: could not compute the portable serial shard partition"
    SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")
    rm -rf "$tmp"
    return 1
  }
  # One pass writes each shard's membership and packed load, so the guard reads
  # 8-line files instead of rescanning the 200-line assignment table 24 times.
  awk -F'\t' -v dir="$tmp" '
    {
      print $3 > (dir "/shard." $1 ".paths")
      load[$1] += $2
    }
    END {
      for (i in load) print load[i] + 0 > (dir "/shard." i ".ms")
    }
  ' "$tmp/serial_assignments"
  : >"$tmp/serial_shards_raw"
  : >"$tmp/serial_shard_loads"
  shard=1
  while [ "$shard" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    SCRIPTS=()
    if [ ! -f "$tmp/shard.$shard.paths" ]; then
      log "coverage guard: portable serial shard $shard of $PORTABLE_SERIAL_SHARDS is empty"
      SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")
      rm -rf "$tmp"
      return 1
    fi
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      add_script "$path"
    done <"$tmp/shard.$shard.paths"
    if [ "${#SCRIPTS[@]}" -eq 0 ]; then
      log "coverage guard: portable serial shard $shard of $PORTABLE_SERIAL_SHARDS is empty"
      SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")
      rm -rf "$tmp"
      return 1
    fi
    shard_ms=0
    [ ! -f "$tmp/shard.$shard.ms" ] || read -r shard_ms <"$tmp/shard.$shard.ms"
    printf '%s\t%s\n' "$shard" "$shard_ms" >>"$tmp/serial_shard_loads"
    printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" >>"$tmp/serial_shards_raw"
    shard=$((shard + 1))
  done
  SCRIPTS=()
  select_family real-herdr-gated
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/herdr"
  SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")

  # Every serial script runs in exactly one CI shard: no duplicate work across
  # runners, and no script silently left out of the required lane.
  LC_ALL=C sort "$tmp/serial_shards_raw" | uniq -d >"$tmp/serial_shard_dups"
  if [ -s "$tmp/serial_shard_dups" ]; then
    log "coverage guard: portable serial shards share scripts:"
    cat "$tmp/serial_shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/serial_shards_raw" >"$tmp/serial_shards"
  missing=$(comm -23 "$tmp/serial" "$tmp/serial_shards" || true)
  extra=$(comm -13 "$tmp/serial" "$tmp/serial_shards" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable serial shards must equal the portable serial lane"
    [ -z "$missing" ] || { log "missing from serial shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond serial lane:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  for pair in "shards_union:serial" "shards_union:herdr" "serial:herdr"; do
    a=${pair%%:*}
    b=${pair#*:}
    LC_ALL=C comm -12 "$tmp/$a" "$tmp/$b" >"$tmp/overlap"
    if [ -s "$tmp/overlap" ]; then
      log "coverage guard: overlap between $a and $b:"
      cat "$tmp/overlap" >&2
      rm -rf "$tmp"
      return 1
    fi
  done

  cat "$tmp/shards_union" "$tmp/serial" "$tmp/herdr" | LC_ALL=C sort >"$tmp/union_raw"
  uniq -d "$tmp/union_raw" >"$tmp/union_dups"
  if [ -s "$tmp/union_dups" ]; then
    log "coverage guard: duplicate scripts across lanes:"
    cat "$tmp/union_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/union_raw" >"$tmp/union"
  missing=$(comm -23 "$tmp/all" "$tmp/union" || true)
  extra=$(comm -13 "$tmp/all" "$tmp/union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: union of portable shards + portable serial + Herdr must equal tests/*.test.sh"
    [ -z "$missing" ] || { log "missing from union:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond inventory:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # The shard-count contract has a second half: 24 shards only deliver a fast
  # PR gate if each one stays within the five-minute target. Packed hint
  # milliseconds are the comparable quantity across runners, so enforce the
  # budget here from the same table that built the partition.
  read -r serial_shard_max_ms _unused < <(awk -F'\t' '
    BEGIN { max = 0 }
    { if ($2 + 0 > max) max = $2 + 0 }
    END { print max + 0, 0 }
  ' "$tmp/serial_shard_loads")
  over_budget=$(awk -F'\t' -v budget="$PORTABLE_SERIAL_MAX_SHARD_MS" '
    $2 + 0 > budget { printf "shard %s: %s ms (budget %s ms)\n", $1, $2, budget }
  ' "$tmp/serial_shard_loads")
  if [ -n "$over_budget" ]; then
    log "coverage guard: portable serial shards exceed the ${PORTABLE_SERIAL_MAX_SHARD_MS} ms per-shard budget:"
    printf '%s\n' "$over_budget" >&2
    log "rebalance: add shards, split a slow script, or refresh the duration hints (docs/fm-test-portable-shards.md)"
    rm -rf "$tmp"
    return 1
  fi

  # Hint drift is what makes a balanced-looking partition run unbalanced: the
  # shards are packed from hints, so every unmeasured script is balanced on a
  # guess and enough of them let one shard reach its CI job cap while another
  # runner sits idle. Bound the unmeasured share here rather than waiting for a
  # shard to time out.
  portable_serial_unhinted >"$tmp/unhinted"
  unhinted=$(wc -l <"$tmp/unhinted" | tr -d ' ')
  serial_total=$(wc -l <"$tmp/serial" | tr -d ' ')
  if [ "$serial_total" -gt 0 ] &&
    [ "$((unhinted * 100))" -gt "$((serial_total * PORTABLE_SERIAL_MAX_UNHINTED_PERCENT))" ]; then
    log "coverage guard: $unhinted of $serial_total portable serial scripts have no measured duration hint (max ${PORTABLE_SERIAL_MAX_UNHINTED_PERCENT}%)"
    log "refresh the hints from a green run's timing artifacts: docs/fm-test-portable-shards.md"
    cat "$tmp/unhinted" >&2
    rm -rf "$tmp"
    return 1
  fi

  if [ -x "$ROOT/bin/fm-test-isolation-proof.sh" ]; then
    "$ROOT/bin/fm-test-isolation-proof.sh" --list | LC_ALL=C sort -u >"$tmp/proof_list"
    if ! cmp -s "$tmp/proven" "$tmp/proof_list"; then
      log "coverage guard: embedded proven-isolated set diverges from bin/fm-test-isolation-proof.sh --list"
      LC_ALL=C comm -3 "$tmp/proven" "$tmp/proof_list" >&2 || true
      rm -rf "$tmp"
      return 1
    fi
  fi

  # Keep these estimates derived from the membership and hint owners; see the
  # header for the distinction between packed weights and measured job time.
  read -r p1_ms p1_unhinted <<<"$(list_portable_parallel_1 | portable_parallel_lane_weight)"
  read -r p2_ms p2_unhinted <<<"$(list_portable_parallel_2 | portable_parallel_lane_weight)"
  parallel_max_ms=$p1_ms
  [ "$p2_ms" -le "$parallel_max_ms" ] || parallel_max_ms=$p2_ms
  parallel_imbalance_ms=$((p1_ms - p2_ms))
  [ "$parallel_imbalance_ms" -ge 0 ] || parallel_imbalance_ms=$((-parallel_imbalance_ms))

  printf 'FM_TEST_COVERAGE ok total=%s parallel=%s parallel_max_ms=%s parallel_imbalance_ms=%s parallel_unhinted=%s serial=%s serial_shards=%s serial_shard_max_ms=%s serial_shard_budget_ms=%s serial_unhinted=%s herdr=%s\n' \
    "$(wc -l <"$tmp/all" | tr -d ' ')" \
    "$(wc -l <"$tmp/shards_union" | tr -d ' ')" \
    "$parallel_max_ms" \
    "$parallel_imbalance_ms" \
    "$((p1_unhinted + p2_unhinted))" \
    "$(wc -l <"$tmp/serial" | tr -d ' ')" \
    "$PORTABLE_SERIAL_SHARDS" \
    "$serial_shard_max_ms" \
    "$PORTABLE_SERIAL_MAX_SHARD_MS" \
    "$unhinted" \
    "$(wc -l <"$tmp/herdr" | tr -d ' ')"
  rm -rf "$tmp"
  return 0
}

aggregate_timing_json() {
  local out=$1
  shift
  [ "$#" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  command -v python3 >/dev/null 2>&1 || die "--aggregate-json requires python3"
  python3 - "$out" "$@" <<'PY'
import json, sys
from pathlib import Path

out = Path(sys.argv[1])
inputs = [Path(p) for p in sys.argv[2:]]
lanes = []
all_scripts = []
failed = 0
skipped = 0
timed_out = 0
retried = 0
total = 0
wall_ms = 0
for path in inputs:
    doc = json.loads(path.read_text(encoding="utf-8"))
    summary = doc.get("summary") or {}
    lane = {
        "path": str(path),
        "run_id": doc.get("run_id"),
        "selection": doc.get("selection"),
        "started_at": doc.get("started_at"),
        "finished_at": doc.get("finished_at"),
        "summary": summary,
    }
    lanes.append(lane)
    total += int(summary.get("total") or 0)
    failed += int(summary.get("failed") or 0)
    skipped += int(summary.get("skipped_gate") or 0)
    timed_out += int(summary.get("timed_out") or 0)
    retried += int(summary.get("retried_infra_flakes") or 0)
    wall_ms = max(wall_ms, int(summary.get("duration_ms") or 0))
    for s in doc.get("scripts") or []:
        row = dict(s)
        row["lane_selection"] = doc.get("selection")
        row["lane_run_id"] = doc.get("run_id")
        all_scripts.append(row)

all_scripts.sort(key=lambda s: (-int(s.get("duration_ms") or 0), s.get("path") or ""))
agg = {
    "kind": "aggregate",
    "lanes": lanes,
    "summary": {
        "lanes": len(lanes),
        "total": total,
        "failed": failed,
        "skipped_gate": skipped,
        "timed_out": timed_out,
        "retried_infra_flakes": retried,
        "critical_path_duration_ms": wall_ms,
    },
    "scripts": all_scripts,
    "slowest": all_scripts[:15],
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(agg, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"FM_TEST_AGGREGATE lanes={len(lanes)} total={total} failed={failed} skipped_gate={skipped} timed_out={timed_out} retried_infra_flakes={retried} critical_path_duration_ms={wall_ms}")
PY
}

all_repo_tests() {
  # Deterministic lexical order (same as bash glob expansion under LC_ALL=C).
  local f
  # shellcheck disable=SC2035
  for f in tests/*.test.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}


# Append unique relative-or-absolute script paths to SCRIPTS. The
# normalization is inlined rather than calling normalize_script_path through a
# command substitution: lane selection adds one script at a time, and a fork
# per addition made a serial-lane listing take seconds on a loaded host.
add_script() {
  local p existing
  p=$1
  case "$p" in
    tests/*|./tests/*) p=${p#./} ;;
    *.test.sh) [ -f "tests/$p" ] && p=tests/$p ;;
  esac
  for existing in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    [ "$existing" = "$p" ] && return 0
  done
  SCRIPTS+=("$p")
}

select_all() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(all_repo_tests)
}

select_family() {
  local want=$1 s base fam found=0
  [ -n "$want" ] || die "--family requires a name"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    base=${s##*/}
    family_for_basename_into "$base"
    if [ "$FM_FAMILY" = "$want" ]; then
      add_script "$s"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ] || die "no tests mapped to family '$want'"
}

families_for_test_reference() {  # <needle>...
  local s needle
  local found=0
  local -a needles=()
  for needle in "$@"; do needles+=(-e "$needle"); done
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "${needles[@]}" "$s"; then
      family_for_basename "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# Tests that name <needle>, selected as individual scripts rather than widened
# to each referencing test's whole family. A direct reference is per-script
# evidence, so it selects per script: one real-Herdr E2E sourcing a shared
# helper must not drag in every other script of that expensive family.
scripts_for_test_reference() {
  local needle=$1 s
  local found=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "$needle" "$s"; then
      printf '__script__:%s\n' "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# bin/ scripts other than <needle> itself that name <needle>.
bin_consumers_of() {
  local needle=$1 b
  for b in bin/*.sh bin/backends/*.sh; do
    [ -f "$b" ] || continue
    [ "$(basename "$b")" = "$needle" ] || ! grep -Fq "$needle" "$b" || printf '%s\n' "$b"
  done
}

# An unmapped bin/ path has no curated family of its own. Its blast radius is
# the tests that name it, plus the curated families of the bin/ scripts that
# consume it. Direct test references resolve per script (above) while consumer
# scripts resolve back through the curated map, so genuine family-level
# coupling a maintainer recorded is preserved while an incidental single-script
# reference no longer selects that script's whole family.
BIN_FALLBACK_DEPTH=0
families_for_unmapped_bin() {
  local path=$1 needle consumer out found=0
  needle=$(basename "$path")
  if out=$(scripts_for_test_reference "$needle"); then
    printf '%s\n' "$out"
    found=1
  fi
  if [ "$BIN_FALLBACK_DEPTH" -lt 2 ]; then
    BIN_FALLBACK_DEPTH=$((BIN_FALLBACK_DEPTH + 1))
    while IFS= read -r consumer; do
      [ -n "$consumer" ] || continue
      out=$(families_for_changed_path "$consumer" | grep -v '^__unmapped__:' || true)
      if [ -n "$out" ]; then
        printf '%s\n' "$out"
        found=1
      fi
    done < <(bin_consumers_of "$needle")
    BIN_FALLBACK_DEPTH=$((BIN_FALLBACK_DEPTH - 1))
  fi
  [ "$found" -eq 1 ]
}

# Conservative path → family map. Over-selects rather than under-selects.
# Never expands to the complete suite.
families_for_changed_path() {
  local path=$1 fixture_ref
  case "$path" in
    tests/fm-backend-herdr-eventwait.test.py)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    tests/*.test.sh)
      # A single test file change selects only that script via basename family
      # resolution in the caller; emit a marker family of __script__
      printf '%s\n' "__script__:$(basename "$path")"
      ;;
    bin/fm-test-run.sh)
      # Deliberately the WHOLE family, not just the two contract tests. This
      # runner executes every pure-contract-unit script, so a change to it is
      # only proven by running them: its own contract test passing says the
      # runner's logic is right, not that the suite it drives still runs.
      printf '%s\n' pure-contract-unit
      # Only this script wraps each suite in run_script_bounded's fixture Git
      # isolation, and only a standalone-family script proves it.
      printf '%s\n' "__script__:fm-test-fixtures.test.sh"
      ;;
    bin/fm-test-isolation-proof.sh)
      # Same reason as the runner above: the proof drives every
      # pure-contract-unit script. It runs each candidate directly, never
      # through run_script_bounded, so it cannot regress fixture Git isolation.
      printf '%s\n' pure-contract-unit
      ;;
    bin/backends/herdr*|bin/fm-herdr-lab.sh|tests/herdr-test-safety.sh|tests/herdr-client-pair-fixture.sh)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-herdr-session-cleanup.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/zellij*|tests/zellij-test-safety.sh)
      printf '%s\n' zellij
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/cmux*|tests/cmux-test-safety.sh)
      printf '%s\n' cmux
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/orca*|bin/backends/tmux.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' orca
      ;;
    bin/fm-backend.sh|bin/fm-backend-hometag-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-agent-process-lib.sh)
      # The shared harness-process classifier feeds both the tmux and Herdr
      # liveness verdicts, so a change to it is proven by both backends' suites.
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-watch*|bin/fm-wake*|bin/fm-inactive-reconcile.sh|\
    bin/fm-classify-lib.sh|bin/fm-daemon*|bin/fm-turnend-guard*|bin/fm-guard.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    bin/fm-afk*)
      printf '%s\n' afk
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-supervisor-target-lib.sh)
      printf '%s\n' watcher-wake-lock
      printf '%s\n' real-herdr-gated
      printf '%s\n' live-harness-optin
      printf '%s\n' afk
      ;;
    bin/fm-startup-memory-budget.sh|bin/fm-startup-memory-budget-lib.sh)
      printf '%s\n' secondmate
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-secondmate*|bin/fm-remote*|bin/fm-on.sh|bin/fm-home-seed.sh|\
    bin/fm-backlog-handoff.sh|bin/fm-backlog-receive.sh|bin/fm-procevent-remote-reply.sh|\
    bin/fm-config-inherit-lib.sh|bin/fm-config-push.sh|bin/fm-shared*|\
    bin/fm-stow-cascade.sh)
      printf '%s\n' secondmate
      ;;
    bin/fm-session-start.sh|bin/fm-fleet-sync.sh|\
    bin/fm-sessionstart-nudge.sh|bin/fm-startup-network.sh|bin/fm-tangle*|bin/fm-update.sh|\
    bin/fm-gate-refuse*|bin/fm-lock*)
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-bootstrap.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' "__script__:fm-brief.test.sh"
      ;;
    bin/fm-quota-axi-lib.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' "__script__:fm-procevent-quota.test.sh"
      printf '%s\n' "__script__:fm-quota-choose.test.sh"
      ;;
    bin/fm-procevent-quota.sh)
      printf '%s\n' "__script__:fm-procevent-quota.test.sh"
      ;;
    bin/fm-quota-choose.sh)
      printf '%s\n' "__script__:fm-quota-choose.test.sh"
      ;;
    .pi/extensions/fm-branch-supervision.ts|.pi/extensions/lib/fm-async-exec.ts|\
    .pi/extensions/lib/fm-branch-dispatch.ts|.pi/extensions/lib/fm-native-contract.ts)
      # The portable suites that actually load these files, named one by one.
      # Left unmapped, a Pi extension library resolves through the reference
      # scan, which widens to each referencing suite's WHOLE family - and
      # these suites sit in four different families, so that pulls in dozens
      # of suites with nothing to do with Pi.
      printf '%s\n' __script__:fm-pi-branch-extension.test.sh
      printf '%s\n' __script__:fm-pi-watch-extension.test.sh
      printf '%s\n' __script__:fm-calm-pi-extension.test.sh
      printf '%s\n' __script__:fm-watch-recovery-loop.test.sh
      printf '%s\n' __script__:fm-wake-queue.test.sh
      printf '%s\n' __script__:fm-pi-primary-types.test.sh
      # Whether an arriving outcome still lets the captain type is a fact only
      # a real Pi TUI can answer, so the live guards are selected too.
      printf '%s\n' live-harness-optin
      ;;
    .pi/extensions/lib/fm-operational-input.ts)
      # The same rule for the operational-input library, whose reach is wider:
      # every Pi extension that classifies or encodes operational text.
      printf '%s\n' __script__:fm-pi-windows-shell-invocation.test.sh
      printf '%s\n' __script__:fm-pi-branch-extension.test.sh
      printf '%s\n' __script__:fm-pi-watch-extension.test.sh
      printf '%s\n' __script__:fm-calm-pi-extension.test.sh
      printf '%s\n' __script__:fm-watch-recovery-loop.test.sh
      printf '%s\n' __script__:fm-turnend-guard.test.sh
      printf '%s\n' __script__:fm-sessionstart-nudge.test.sh
      printf '%s\n' __script__:fm-pi-primary-types.test.sh
      printf '%s\n' live-harness-optin
      ;;
    .claude/mods/firstmate-calm/*|.pi/extensions/lib/fm-calm-working-ship.ts|\
    .pi/extensions/lib/fm-calm-working-ship-sprite.ts)
      # The Claude Code Calm mod and the sprite core it shares with the Pi Calm
      # extension: the portable Node checks, the Pi suites that draw the shared
      # sprite, the Pi typecheck, and the Claude-dependent guards.
      printf '%s\n' __script__:fm-calm-claude-mod.test.sh
      printf '%s\n' __script__:fm-calm-pi-extension.test.sh
      printf '%s\n' __script__:fm-pi-primary-types.test.sh
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-sessionstart-run.sh|.claude/settings.json|.codex/hooks.json|\
    .pi/extensions/fm-primary-turnend-guard.ts)
      # The run tier's two harness-supplied facts (source vocabulary and
      # context-reset stdout injection) only show up against a real harness.
      printf '%s\n' __script__:fm-pi-windows-shell-invocation.test.sh
      printf '%s\n' session-bootstrap
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-extension.mjs|bin/fm-extension.sh|docs/examples/process-event-extension/*)
      printf '%s\n' __script__:fm-extension-binding.test.sh
      ;;
    bin/fm-procevent.sh|bin/fm-procevent-lib.sh|bin/fm-procevent-extension-capture.pl)
      printf '%s\n' __script__:fm-extension-binding.test.sh
      printf '%s\n' __script__:fm-procevent.test.sh
      printf '%s\n' __script__:fm-procevent-when.test.sh
      printf '%s\n' __script__:fm-remote-reply.test.sh
      ;;
    bin/fm-timeout-lib.sh)
      # The shared hard bound: session start's runtime bound, the fleet/bearings
      # snapshots, the vendor auth probe, the stow cascade's per-home step, and
      # the wedge detector's worktree write probe all depend on it.
      printf '%s\n' session-bootstrap
      printf '%s\n' snapshot-bearings
      printf '%s\n' pure-contract-unit
      printf '%s\n' secondmate
      printf '%s\n' watcher-wake-lock
      printf '%s\n' "__script__:fm-procevent-quota.test.sh"
      ;;
    bin/fm-pr-*|bin/fm-merge-local.sh|bin/fm-teardown.sh|bin/fm-review-diff.sh|\
    bin/fm-x-*|bin/fm-check*)
      printf '%s\n' pr-forge
      ;;
    bin/fm-nm-run-lib.sh)
      # Shared no-mistakes run-attribution primitives, sourced by both
      # bin/fm-crew-state.sh (pure-contract-unit) and bin/fm-teardown.sh's
      # pre-teardown run abort (pr-forge).
      printf '%s\n' pure-contract-unit
      printf '%s\n' pr-forge
      ;;
    bin/fm-control-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' session-bootstrap
      printf '%s\n' "__script__:fm-quota-choose.test.sh"
      ;;
    bin/fm-composer-lib.sh)
      # The shared shape catalogue is vendor-rendered signal; a change to it
      # re-selects the live guard (fm-composer-matrix-live-e2e) alongside the
      # portable families.
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-spawn.sh|bin/fm-send.sh|bin/fm-harness.sh|\
    bin/fm-peek.sh|bin/fm-composer*)
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-task-inbox-lib.sh)
      # The steering-inbox record/doorbell/ladder owner: fm-send's data plane
      # (backend-dispatch), the watcher's re-ring check (watcher-wake-lock),
      # and the live doorbell guard against real harnesses.
      printf '%s\n' backend-dispatch
      printf '%s\n' watcher-wake-lock
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-bearings-snapshot.sh|bin/fm-fleet-snapshot.sh|bin/fm-fleet-view.sh|bin/fm-contributions.sh|bin/fm-contributions.jq|\
    bin/fm-home-summary-refresh.sh)
      printf '%s\n' snapshot-bearings
      ;;
    bin/fm-install-herdr.sh|bin/fm-install-treehouse.sh|bin/fm-herdr-ci-cleanup.sh)
      printf '%s\n' pure-contract-unit
      # Pin or cleanup changes also select the real-Herdr family so the required
      # lane's contract coverage re-runs.
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-lint.sh|bin/fm-lint-workflows.sh|bin/fm-install-shellcheck.sh|\
    bin/fm-install-actionlint.sh|\
    bin/fm-brief.sh|bin/fm-ensure-agents-md.sh|bin/fm-crew-state.sh|\
    bin/fm-captain-hold.sh|bin/fm-decision-hold.sh|bin/fm-supervision*|bin/fm-transition-lib.sh|\
    bin/fm-tmux-lib.sh|bin/fm-marker-lib.sh|bin/fm-operational-input.sh|bin/fm-tasks-axi-lib.sh|\
    bin/fm-vendor-auth-probe.sh|\
    bin/fm-primary-scope-lib.sh|bin/fm-project-mode.sh|bin/fm-promote.sh|\
    bin/fm-ff-lib.sh|bin/fm-gotmp*|bin/*pretool*)
      printf '%s\n' pure-contract-unit
      ;;
    .agents/skills/quota-array-dispatch/SKILL.md)
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    .agents/skills/harness-adapters/SKILL.md|.agents/skills/harness-adapters/references/*)
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    .agents/skills/*/SKILL.md)
      printf '%s\n' pure-contract-unit
      ;;
    .github/workflows/ci.yml|.no-mistakes.yaml)
      printf '%s\n' pure-contract-unit
      printf '%s\n' real-herdr-gated
      ;;
    docs/fm-test-portable-shards.md|docs/fm-test-isolation-proof.md|\
    docs/fm-test-isolation-proof.json)
      printf '%s\n' pure-contract-unit
      ;;
    .github/*|.gitattributes|.tasks.toml|AGENTS.md|CLAUDE.md|CONTRIBUTING.md|\
    docs/configuration.md|docs/supervision-protocols/*)
      printf '%s\n' pure-contract-unit
      ;;
    tests/git-config-helpers.sh)
      # The reference scan is not transitive, so match the two helpers that
      # source this one as well: most suites inherit it only through them.
      families_for_test_reference git-config-helpers.sh lib.sh herdr-test-safety.sh \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    tests/fixtures/*/*)
      # A fixture belongs to whichever suite reads its directory, found by the
      # same reference scan used for shared helpers. Keyed on the directory
      # rather than the file so adding a fixture selects the same suite.
      # A removed fixture directory has no consuming suite left to select.
      fixture_ref=${path#tests/fixtures/}
      fixture_ref=${fixture_ref%%/*}
      if [ -d "tests/fixtures/$fixture_ref" ]; then
        families_for_test_reference "fixtures/$fixture_ref" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    tests/lib.sh|tests/*-helpers.sh|tests/fixtures.sh|tests/*-fixture.sh)
      # Shared top-level test files, selected by the suites that name them.
      # Must stay below the tests/fixtures/*/* arm: a case glob's * spans /, so
      # tests/*-fixture.sh would otherwise swallow a nested
      # tests/fixtures/<dir>/<name>-fixture.sh and scan for its basename
      # instead of the fixture directory its readers actually name.
      families_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    bin/*)
      # A deleted script has no consuming suite left to select, the same rule
      # the fixture case above applies. Refusing on its absent mapping would
      # make every retirement branch unable to select its changed tests.
      if [ -e "$path" ]; then
        families_for_unmapped_bin "$path" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    tests/*)
      printf '%s\n' "__unmapped__:$path"
      ;;
    README.md|LICENSE|assets/*|docs/*|.gitignore)
      ;;
    *)
      if [ -e "$path" ]; then
        families_for_test_reference "$path" \
          || printf '%s\n' "__unmapped__:$path"
      else
        # A retired source path with no remaining test consumer cannot select
        # a runnable suite. Known source paths above retain their mappings,
        # and a still-referenced removal is found by the same reference scan.
        families_for_test_reference "$path" || true
      fi
      ;;
  esac
}

select_changed() {
  local base=$1 path entry fam script_name s
  local -a wanted_families=()
  local -a wanted_scripts=()

  if ! git -C "$ROOT" rev-parse --verify "$base" >/dev/null 2>&1; then
    die "changed-file base ref not found: $base (pass --base <ref>)"
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$entry" in
        __script__:*)
          script_name=${entry#__script__:}
          wanted_scripts+=("$script_name")
          ;;
        __unmapped__:*)
          die "no changed-test mapping for source path: ${entry#__unmapped__:}"
          ;;
        *)
          wanted_families+=("$entry")
          ;;
      esac
    done < <(families_for_changed_path "$path")
  done < <(git -C "$ROOT" diff --name-only "${base}...HEAD" 2>/dev/null; \
           git -C "$ROOT" diff --name-only HEAD 2>/dev/null; \
           git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)

  # Dedup families
  local f seen_f
  local -a unique_families=()
  for f in "${wanted_families[@]+"${wanted_families[@]}"}"; do
    seen_f=0
    for u in "${unique_families[@]+"${unique_families[@]}"}"; do
      [ "$u" = "$f" ] && { seen_f=1; break; }
    done
    [ "$seen_f" -eq 0 ] && unique_families+=("$f")
  done

  for f in "${unique_families[@]+"${unique_families[@]}"}"; do
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if [ "$(family_for_basename "$(basename "$s")")" = "$f" ]; then
        add_script "$s"
      fi
    done < <(all_repo_tests)
  done

  for script_name in "${wanted_scripts[@]+"${wanted_scripts[@]}"}"; do
    if [ -f "tests/$script_name" ]; then
      add_script "tests/$script_name"
    fi
  done

  if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    log "no tests selected for changes vs $base (map is conservative; use --all for the complete suite)"
  fi
}

detect_gate_skip() {
  # True when the first non-empty output line is a skip: gate message.
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  case "$first" in
    skip:*) return 0 ;;
    *) return 1 ;;
  esac
}

# Echo the reason a gate skip gave, i.e. the first meaningful output line with
# its leading "skip:" removed. Tabs and stray whitespace are folded so the
# reason stays one field of the tab-separated record the JSON artifact is built
# from. Callers only use this once detect_gate_skip has already said yes.
gate_skip_reason() {
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  first=${first#skip:}
  printf '%s\n' "$first" | tr '\t' ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

# True when any output line contains "skip: <token>" (token may contain spaces).
detect_gate_skip_token() {
  local file=$1 token=$2
  [ -n "$token" ] || return 1
  grep -F -q "skip: $token" "$file" 2>/dev/null
}

apply_exclude_families() {
  local s fam keep ex
  local -a kept=()
  [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ] || return 0
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    fam=$(family_for_basename "$(basename "$s")")
    keep=1
    for ex in "${EXCLUDE_FAMILIES[@]+"${EXCLUDE_FAMILIES[@]}"}"; do
      if [ "$fam" = "$ex" ]; then
        keep=0
        break
      fi
    done
    [ "$keep" -eq 1 ] && kept+=("$s")
  done
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

write_json_artifact() {
  local out=$1
  local started=$2
  local finished=$3
  local run_id=$4
  local total=$5
  local failed=$6
  local skipped=$7
  local duration=$8
  local selection=$9
  local records_file=${10}
  local families_file=${11}

  if ! command -v python3 >/dev/null 2>&1; then
    die "--json requires python3 to emit a valid timing artifact"
  fi

  python3 - "$out" "$started" "$finished" "$run_id" "$total" "$failed" "$skipped" "$duration" "$selection" "$records_file" "$families_file" <<'PY'
import json, sys

out, started, finished, run_id, total, failed, skipped, duration, selection, records_file, families_file = sys.argv[1:]

scripts = []
with open(records_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        (path, family, expected, exit_s, dur_s, gate, reason,
         timeout_s, retry_signature, first_exit_s) = line.split("\t")
        scripts.append({
            "path": path,
            "family": family,
            "expected_gate_skip": expected,
            "duration_ms": int(dur_s),
            "exit": int(exit_s),
            "gate_skip": gate == "true",
            "gate_skip_reason": reason,
            "timed_out": int(timeout_s) > 0,
            "timeout_secs": int(timeout_s),
            "retried_infra_flake": retry_signature != "",
            "retry_signature": retry_signature,
            "first_attempt_exit": int(first_exit_s) if first_exit_s else None,
        })

families = []
with open(families_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        name, count_s, dur_s, failed_s = line.split("\t")
        families.append({
            "name": name,
            "count": int(count_s),
            "duration_ms": int(dur_s),
            "failed": int(failed_s),
        })

doc = {
    "run_id": run_id,
    "started_at": started,
    "finished_at": finished,
    "selection": selection,
    "summary": {
        "total": int(total),
        "failed": int(failed),
        "skipped_gate": int(skipped),
        "timed_out": sum(1 for s in scripts if s["timed_out"]),
        "retried_infra_flakes": sum(1 for s in scripts if s["retried_infra_flake"]),
        "duration_ms": int(duration),
    },
    "scripts": scripts,
    "families": families,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=all
      shift
      ;;
    --family)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--family requires a name"
      MODE=family
      FAMILY=$2
      shift 2
      ;;
    --family=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=family
      FAMILY=${1#--family=}
      shift
      ;;
    --lane)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--lane requires a name (see --list-lanes)"
      MODE=lane
      LANE=$2
      shift 2
      ;;
    --lane=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=lane
      LANE=${1#--lane=}
      shift
      ;;
    --proven-isolated)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=proven-isolated
      shift
      ;;
    --changed)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=changed
      shift
      ;;
    --base)
      [ "$#" -gt 1 ] || die "--base requires a git ref"
      BASE_REF=$2
      shift 2
      ;;
    --base=*)
      BASE_REF=${1#--base=}
      shift
      ;;
    --json)
      [ "$#" -gt 1 ] || die "--json requires a path"
      JSON_PATH=$2
      shift 2
      ;;
    --json=*)
      JSON_PATH=${1#--json=}
      shift
      ;;
    --jobs)
      [ "$#" -gt 1 ] || die "--jobs requires a positive integer"
      JOBS=$2
      JOBS_EXPLICIT=1
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#--jobs=}
      JOBS_EXPLICIT=1
      shift
      ;;
    --max-wall-ms)
      [ "$#" -gt 1 ] || die "--max-wall-ms requires a positive integer"
      MAX_WALL_MS=$2
      shift 2
      ;;
    --max-wall-ms=*)
      MAX_WALL_MS=${1#--max-wall-ms=}
      shift
      ;;
    --per-script-timeout-secs)
      [ "$#" -gt 1 ] || die "--per-script-timeout-secs requires a whole number of seconds or auto"
      PER_SCRIPT_TIMEOUT_SECS=$2
      shift 2
      ;;
    --per-script-timeout-secs=*)
      PER_SCRIPT_TIMEOUT_SECS=${1#--per-script-timeout-secs=}
      shift
      ;;
    --retry-infra-flakes)
      RETRY_INFRA_FLAKES=1
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-scheduled)
      LIST_SCHEDULED=1
      shift
      ;;
    --list-families)
      LIST_FAMILIES=1
      shift
      ;;
    --list-concurrent-safe-families)
      LIST_CONCURRENT_SAFE_FAMILIES=1
      shift
      ;;
    --concurrent-safe-family-jobs-max)
      [ "$#" -gt 1 ] || die "--concurrent-safe-family-jobs-max requires a family name"
      concurrent_safe_family_jobs_max "$2"
      exit 0
      ;;
    --concurrent-safe-family-jobs-max=*)
      concurrent_safe_family_jobs_max "${1#--concurrent-safe-family-jobs-max=}"
      exit 0
      ;;
    --list-lanes)
      LIST_LANES=1
      shift
      ;;
    --check-coverage)
      CHECK_COVERAGE=1
      shift
      ;;
    --aggregate-json)
      [ "$#" -gt 1 ] || die "--aggregate-json requires an output path"
      AGGREGATE_OUT=$2
      shift 2
      # Remaining args after options will be collected as inputs below via MODE.
      # For aggregation we accept only input JSON paths as free args after this.
      MODE=aggregate
      ;;
    --exclude-family)
      [ "$#" -gt 1 ] || die "--exclude-family requires a name"
      EXCLUDE_FAMILIES+=("$2")
      shift 2
      ;;
    --exclude-family=*)
      EXCLUDE_FAMILIES+=("${1#--exclude-family=}")
      shift
      ;;
    --fail-on-gate-skip)
      [ "$#" -gt 1 ] || die "--fail-on-gate-skip requires a token (e.g. 'herdr not found')"
      FAIL_ON_GATE_SKIP=$2
      shift 2
      ;;
    --fail-on-gate-skip=*)
      FAIL_ON_GATE_SKIP=${1#--fail-on-gate-skip=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        SCRIPTS+=("$1")
        shift
      done
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ "${MODE:-}" = "aggregate" ]; then
        SCRIPTS+=("$1")
      elif [ -z "$MODE" ] || [ "$MODE" = scripts ]; then
        MODE=scripts
        SCRIPTS+=("$1")
      else
        die "script paths cannot be combined with --$MODE"
      fi
      shift
      ;;
  esac
done

if [ "$LIST_FAMILIES" -eq 1 ]; then
  list_known_families
  exit 0
fi

if [ "$LIST_CONCURRENT_SAFE_FAMILIES" -eq 1 ]; then
  list_concurrent_safe_families
  exit 0
fi

if [ "$LIST_LANES" -eq 1 ]; then
  list_known_lanes
  exit 0
fi

if [ "$CHECK_COVERAGE" -eq 1 ]; then
  run_coverage_guard
  exit $?
fi

if [ "${MODE:-}" = "aggregate" ]; then
  [ -n "$AGGREGATE_OUT" ] || die "--aggregate-json requires an output path"
  [ "${#SCRIPTS[@]}" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || die "aggregate input not found: $s"
  done
  aggregate_timing_json "$AGGREGATE_OUT" "${SCRIPTS[@]}"
  exit 0
fi

case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"
[ "$JOBS" -le "$JOBS_MAX" ] || die "--jobs is capped at $JOBS_MAX (got $JOBS)"

if [ -n "$STEP_BUDGET_SECS" ]; then
  case "$STEP_BUDGET_SECS" in
    *[!0-9]*) die "FM_TEST_STEP_BUDGET_SECS requires a positive integer" ;;
  esac
  [ "$STEP_BUDGET_SECS" -gt 0 ] || die "FM_TEST_STEP_BUDGET_SECS requires a positive integer"
fi
if [ -n "$MAX_WALL_MS" ]; then
  case "$MAX_WALL_MS" in
    ''|*[!0-9]*) die "--max-wall-ms requires a positive integer" ;;
  esac
  [ "$MAX_WALL_MS" -gt 0 ] || die "--max-wall-ms requires a positive integer"
fi

case "$PER_SCRIPT_TIMEOUT_SECS" in
  auto) ;;
  ''|*[!0-9]*) die "--per-script-timeout-secs requires a whole number of seconds or auto (0 disables)" ;;
  *) PER_SCRIPT_TIMEOUT_SECS=$((10#$PER_SCRIPT_TIMEOUT_SECS)) ;;
esac

# Refuse before any suite is selected or run. The inspection modes execute
# nothing: --list-families, --list-concurrent-safe-families, --list-lanes,
# --check-coverage, --concurrent-safe-family-jobs-max and --aggregate-json have
# already exited above, and --list/--list-scheduled print their selection and
# exit below. An unset MODE still falls through to the usage error, so a caller
# who named no selection mode is told that rather than this.
if [ -n "${MODE:-}" ] && [ "$LIST_ONLY" -eq 0 ] && [ "$LIST_SCHEDULED" -eq 0 ]; then
  refuse_primary_checkout_for_task
fi

case "${MODE:-}" in
  all)
    select_all
    SELECTION_DESC="all"
    ;;
  family)
    select_family "$FAMILY"
    SELECTION_DESC="family=$FAMILY"
    ;;
  lane)
    select_lane "$LANE"
    SELECTION_DESC="lane=$LANE"
    ;;
  proven-isolated)
    select_proven_isolated
    SELECTION_DESC="proven-isolated"
    ;;
  changed)
    select_changed "$BASE_REF"
    SELECTION_DESC="changed:base=$BASE_REF"
    ;;
  scripts)
    # Normalize and re-add through add_script for consistent paths.
    raw=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
    SCRIPTS=()
    for s in "${raw[@]}"; do
      add_script "$s"
    done
    SELECTION_DESC="scripts"
    ;;
  *)
    die "select with --all, --family <name>, --lane <name>, --proven-isolated, --changed, or one or more script paths (see --help)"
    ;;
esac

apply_exclude_families
if [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ]; then
  SELECTION_DESC="${SELECTION_DESC};exclude-family=$(IFS=,; printf '%s' "${EXCLUDE_FAMILIES[*]}")"
fi
if [ -n "$FAIL_ON_GATE_SKIP" ]; then
  SELECTION_DESC="${SELECTION_DESC};fail-on-gate-skip=$FAIL_ON_GATE_SKIP"
fi
if [ "$LIST_ONLY" -eq 1 ] || [ "$LIST_SCHEDULED" -eq 1 ]; then
  if [ "$LIST_SCHEDULED" -eq 1 ]; then
    for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
      case "$MODE:$LANE" in
        lane:portable-parallel-1|lane:portable-parallel-2)
          printf '%s\t%s\n' "$(portable_parallel_weight_for "$s")" "$s"
          ;;
        *)
          printf '%s\t%s\n' "$(portable_serial_weight_for "$s")" "$s"
          ;;
      esac
    done | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k2,2 | cut -f2-
  else
    for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
      printf '%s\n' "$s"
    done
  fi
  exit 0
fi

# An empty selection is a clean result, not a no-op that falls through. Exiting
# here also keeps every array expansion below off the empty-array path: under
# `set -u`, bash 3.2 (the stock macOS shell) treats "${arr[@]}" on an empty
# array as an unbound-variable error, while bash 4.4+ makes it a harmless no-op.
# A contributor on stock macOS who changes only documentation must still get
# total=0 and exit 0 rather than a crash.
if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  log "nothing to run"
  empty_finished_ms=$(now_ms)
  empty_duration=$((empty_finished_ms - RUN_STARTED_MS))
  [ "$empty_duration" -ge 0 ] || empty_duration=0
  empty_rc=0
  printf 'FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=%s\n' "$empty_duration"
  # The budget covers the whole invocation, so a selection phase that outran it
  # still fails - reporting zero work is not the same as reporting no time.
  if [ -n "$MAX_WALL_MS" ]; then
    printf 'FM_TEST_BUDGET max_wall_ms=%s duration_ms=%s\n' "$MAX_WALL_MS" "$empty_duration"
    if [ "$empty_duration" -gt "$MAX_WALL_MS" ]; then
      log "wall-clock budget exceeded: ${empty_duration}ms > ${MAX_WALL_MS}ms for $SELECTION_DESC"
      empty_rc=1
    fi
  fi
  if [ -n "$JSON_PATH" ]; then
    empty_rec=$(mktemp)
    empty_fam=$(mktemp)
    : >"$empty_rec"
    : >"$empty_fam"
    empty_finished_iso=$(now_iso)
    mkdir -p "$(dirname "$JSON_PATH")"
    write_json_artifact "$JSON_PATH" "$RUN_STARTED_ISO" "$empty_finished_iso" \
      "fm-test-run-${RUN_STARTED_MS}-$$" 0 0 0 "$empty_duration" \
      "$SELECTION_DESC" "$empty_rec" "$empty_fam"
    rm -f "$empty_rec" "$empty_fam"
  fi
  exit "$empty_rc"
fi

# Verify selected scripts exist before starting.
for s in "${SCRIPTS[@]}"; do
  [ -f "$s" ] || die "test script not found: $s"
  [ -x "$s" ] || [ -r "$s" ] || die "test script not readable: $s"
done

# Plain --changed and a plain list of script paths both use the bounded
# representative-suite scheduler; numeric --jobs retains the strict all-script
# admission rule below. Naming scripts is how a local verification round asks
# for exactly those subjects, so it gets bounded concurrency rather than a
# serial chain of separate runs.
# The curated selections stay untouched: --lane composes CI shards whose serial
# lane must stay strictly serial, --family is what the required Herdr lane runs,
# and --all is a deliberate complete regression.
AUTO_CONCURRENCY=0
if { [ "$MODE" = changed ] || [ "$MODE" = scripts ]; } && [ "$JOBS_EXPLICIT" -eq 0 ]; then
  if [ "$MODE" = changed ] && [ "${#SCRIPTS[@]}" -gt 0 ] && [ "$PER_SCRIPT_TIMEOUT_SECS" = 0 ]; then
    PER_SCRIPT_TIMEOUT_SECS=auto
  fi
  auto_admissible=0
  for s in "${SCRIPTS[@]}"; do
    script_allows_concurrency "$s" && auto_admissible=$((auto_admissible + 1))
  done
  if [ "$auto_admissible" -gt 1 ]; then
    JOBS=$(cpu_count)
    [ "$JOBS" -le 4 ] || JOBS=4
    [ "$JOBS" -ge 1 ] || JOBS=1
    [ "$JOBS" -eq 1 ] || AUTO_CONCURRENCY=1
  fi
fi
if [ "$JOBS" -gt 1 ] || [ "$MODE" = changed ] || [ "$MODE" = scripts ]; then
  SELECTION_DESC="${SELECTION_DESC};jobs=$JOBS"
fi

# An explicit --jobs names a concurrency for exactly the selection given, so an
# unproven script in it is a refusal rather than something to schedule around.
if [ "$JOBS" -gt 1 ] && [ "$AUTO_CONCURRENCY" -eq 0 ]; then
  for s in "${SCRIPTS[@]}"; do
    if ! script_allows_concurrency "$s"; then
      die "--jobs $JOBS refused: $s is not in the proven-isolated set (see bin/fm-test-isolation-proof.sh --list) and its family has no recorded concurrent proof. Unproven stateful scripts stay serial."
    fi
    if ! is_proven_isolated_script "$s"; then
      family=$(family_for_basename "$(basename "$s")")
      family_jobs_max=$(concurrent_safe_family_jobs_max "$family")
      [ "$JOBS" -le "$family_jobs_max" ] \
        || die "--jobs $JOBS refused: family $family is proven only up to $family_jobs_max concurrent workers"
    fi
  done
fi

# Split the run into proven concurrent phases and an unproven remainder.
# Individually proven scripts share one phase. Scripts admitted only by a family
# proof get a separate phase per family, because that proof establishes safety
# only among members of that family. The serial remainder runs after every
# concurrent phase, never beside another test.
CONCURRENT_SCRIPTS=()
SERIAL_TAIL_SCRIPTS=()
CONCURRENT_PHASE_BREAK=__fm_test_concurrent_phase_break__
if [ "$JOBS" -gt 1 ]; then
  SCHEDULE_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-test-sched.XXXXXX")
  : >"$SCHEDULE_TMP"
  for s in "${SCRIPTS[@]}"; do
    if script_allows_concurrency "$s"; then
      if is_proven_isolated_script "$s"; then
        phase=0
      else
        family=$(family_for_basename "$(basename "$s")")
        phase=1
        while IFS= read -r admitted_family; do
          [ "$family" = "$admitted_family" ] && break
          phase=$((phase + 1))
        done < <(list_concurrent_safe_families)
      fi
      # Longest first within each isolation phase: workers are handed scripts
      # in order, so starting the longest last strands it at the tail.
      printf '%s\t%s\t%s\n' "$phase" "$(portable_serial_weight_for "$s")" "$s" >>"$SCHEDULE_TMP"
    else
      SERIAL_TAIL_SCRIPTS+=("$s")
    fi
  done
  previous_phase=
  while IFS=$'\t' read -r phase _weight s; do
    [ -n "$s" ] || continue
    if [ -n "$previous_phase" ] && [ "$phase" != "$previous_phase" ]; then
      CONCURRENT_SCRIPTS+=("$CONCURRENT_PHASE_BREAK")
    fi
    CONCURRENT_SCRIPTS+=("$s")
    previous_phase=$phase
  done < <(LC_ALL=C sort -t"$(printf '\t')" -k1,1n -k2,2nr -k3,3 "$SCHEDULE_TMP")
  rm -f "$SCHEDULE_TMP"
fi

if [ "$PER_SCRIPT_TIMEOUT_SECS" != 0 ] || [ -n "$STEP_BUDGET_SECS" ]; then
  [ -r "$ROOT/bin/fm-timeout-lib.sh" ] || die "per-script timeout helper not found: bin/fm-timeout-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$ROOT/bin/fm-timeout-lib.sh"
fi

RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run.XXXXXX")
RECORDS="$RUN_TMP/records.tsv"
FAMILIES_TSV="$RUN_TMP/families.tsv"
: >"$RECORDS"
declare -a WORKER_PIDS=()
declare -a WORKER_IDX=()
declare -a WORKER_SCRIPTS=()

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup_run() {
  rm -rf "$RUN_TMP"
}

trap cleanup_run EXIT

RUN_ID="fm-test-run-${RUN_STARTED_MS}-$$"
TOTAL=0
FAILED=0
SKIPPED_GATE=0
AGG_RC=0

# Family accumulators as TSV lines updated in-memory via temp files.
# family -> count, duration_ms, failed
family_bump() {
  local fam=$1 dur=$2 failed_delta=$3
  local line name count duration failed_count rest
  local found=0
  local tmp="$RUN_TMP/families.new"
  : >"$tmp"
  if [ -s "$FAMILIES_TSV" ]; then
    while IFS= read -r line; do
      name=${line%%$'\t'*}
      rest=${line#*$'\t'}
      count=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      duration=${rest%%$'\t'*}
      failed_count=${rest#*$'\t'}
      if [ "$name" = "$fam" ]; then
        count=$((count + 1))
        duration=$((duration + dur))
        failed_count=$((failed_count + failed_delta))
        found=1
      fi
      printf '%s\t%s\t%s\t%s\n' "$name" "$count" "$duration" "$failed_count" >>"$tmp"
    done <"$FAMILIES_TSV"
  fi
  if [ "$found" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$fam" 1 "$dur" "$failed_delta" >>"$tmp"
  fi
  mv "$tmp" "$FAMILIES_TSV"
}

# Sidecars beside a script's captured output <out>, written by
# run_script_attempts and read back here so the serial path and a concurrent
# worker subshell report through one place: <out>.timeout holds the bound a
# timed-out script hit, <out>.budget names a script the shared step budget cut
# short or never started, and <out>.retry holds "<signature>\t<first exit>" for a
# script retried as an infrastructure flake.
record_script_result() {
  local script=$1 rc=$2 duration=$3 out=$4 end_iso=$5
  local base family expected gate_skip gate_reason fail_delta
  local timeout_secs=0 retry_signature='' retry_first_exit=''
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")

  if [ -n "$FAIL_ON_GATE_SKIP" ] && detect_gate_skip_token "$out" "$FAIL_ON_GATE_SKIP"; then
    log "required gate skip token seen in $script: skip: $FAIL_ON_GATE_SKIP"
    rc=1
  fi

  gate_skip=false
  gate_reason=
  if [ "$rc" -eq 0 ] && detect_gate_skip "$out"; then
    gate_skip=true
    gate_reason=$(gate_skip_reason "$out")
    SKIPPED_GATE=$((SKIPPED_GATE + 1))
    # A capability skip is the runner's only record of what this host could not
    # exercise, so name it rather than leaving a silent green.
    log "gate skip: $script: ${gate_reason:-<no reason given>}"
  fi

  if [ -s "$out.timeout" ]; then
    timeout_secs=$(cat "$out.timeout")
    gha_annotate error "$script" "Test timed out" \
      "$script exceeded its per-script bound of ${timeout_secs}s and was terminated"
  fi
  if [ -s "$out.budget" ]; then
    gha_annotate error "$script" "Step budget exhausted" "$(cat "$out.budget")"
  fi
  if [ -s "$out.retry" ]; then
    IFS=$'\t' read -r retry_signature retry_first_exit <"$out.retry"
    log "retried infra flake: $script: signature=$retry_signature first_exit=$retry_first_exit exit=$rc"
    gha_annotate warning "$script" "Retried infra flake" \
      "$script failed with infrastructure signature $retry_signature (exit $retry_first_exit) and was retried once; retry exit $rc"
  fi

  printf 'FM_TEST_END %s %s exit=%s duration_ms=%s gate_skip=%s\n' \
    "$end_iso" "$script" "$rc" "$duration" "$gate_skip"

  fail_delta=0
  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    fail_delta=1
    AGG_RC=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$script" "$family" "$expected" "$rc" "$duration" "$gate_skip" "$gate_reason" \
    "$timeout_secs" "$retry_signature" "$retry_first_exit" >>"$RECORDS"
  family_bump "$family" "$duration" "$fail_delta"
  TOTAL=$((TOTAL + 1))
}

# Run <script> once, capturing output to <out>. <stream> 1 also echoes it live.
# <id> only has to be unique within this run. When the script has a positive
# bound (script_timeout_secs), an attempt that outruns it is terminated, reported
# as exit 124 unless a nonzero test exit was recorded, and named by a
# "not ok - timed out:" line: a hung script must
# become a bounded, explained failure rather than an unbounded suite, because an
# unbounded suite is what silently outruns its caller's budget.
run_script_bounded() {  # <script> <out> <stream> <id>
  local script=$1 out=$2 stream=$3 id=$4 bound
  # Declaring the variables local first keeps the helper's export scoped to this
  # call and its child script, so the runner's own environment is left as the
  # caller had it.
  local GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
  # shellcheck source=tests/git-config-helpers.sh
  . "$ROOT/tests/git-config-helpers.sh" || return
  local rc budget_capped=0
  : "$id"
  rm -f "$out.budget"
  bound=$(script_timeout_secs "$script")
  if [ -n "$STEP_BUDGET_SECS" ]; then
    local remaining
    remaining=$(( (RUN_STARTED_MS + STEP_BUDGET_SECS * 1000 - $(now_ms)) / 1000 ))
    if [ "$remaining" -le 0 ]; then
      printf 'not ok - not started: %s exhausted the shared step budget of %ss before starting (infrastructure failure)\n' \
        "$script" "$STEP_BUDGET_SECS" | tee "$out.budget" >"$out"
      rm -f "$out.process" "$out.process.exit" "$out.timeout"
      [ "$stream" -eq 1 ] && cat "$out"
      return 125
    fi
    if [ "$bound" -eq 0 ] || [ "$bound" -gt "$remaining" ]; then
      bound=$remaining
      budget_capped=1
    fi
  fi
  local outcome="$out.process" completed="$out.completed" program
  rm -f "$outcome" "$outcome.exit" "$completed"
  # shellcheck disable=SC2016 # Perl expands these variables, not the shell.
  program='use POSIX qw(:sys_wait_h);
    my ($record, @command) = @ARGV;
    my $pid = fork;
    if (!defined $pid) { open(my $f, ">", $record); print $f "start-error"; exit 125 }
    if (!$pid) {
      exec @command;
      open(my $f, ">", $record); print $f "start-error"; exit 125;
    }
    waitpid($pid, 0);
    my $status = $?;
    if (-s $record) { exit 125 }
    open(my $f, ">", $record) or exit 125;
    if (WIFSIGNALED($status)) {
      my $signal = WTERMSIG($status); print $f "signal-$signal"; exit(128 + $signal);
    }
    my $code = WEXITSTATUS($status);
    open(my $exit_record, ">", "$record.exit") or exit 125;
    print $exit_record $code; close($exit_record);
    print $f "exit"; exit($code);'
  local interpreter=${FM_TEST_SCRIPT_BASH:-bash}
  set +e
  if [ "$stream" -eq 1 ]; then
    if [ "$bound" -gt 0 ]; then
      # shellcheck disable=SC2016 # The child bash expands this literal command body.
      fm_run_timed "$bound" bash -c \
        'perl -e "$1" "$2" "$3" "$4" 2>&1 | tee "$5"; rc=${PIPESTATUS[0]}; printf "%s\n" "$rc" >"$6"; exit "$rc"' \
        _ "$program" "$outcome" "$interpreter" "$script" "$out" "$completed"
      rc=$?
    else
      perl -e "$program" "$outcome" "$interpreter" "$script" 2>&1 | tee "$out"
      rc=${PIPESTATUS[0]}
    fi
  elif [ "$bound" -gt 0 ]; then
    fm_run_timed "$bound" perl -e "$program" "$outcome" "$interpreter" "$script" >"$out" 2>&1
    rc=$?
  else
    perl -e "$program" "$outcome" "$interpreter" "$script" >"$out" 2>&1
    rc=$?
  fi
  if [ "$bound" -gt 0 ] && [ "$rc" -eq 124 ] && {
    { [ "$stream" -eq 1 ] && [ ! -s "$completed" ]; } ||
    { [ "$stream" -ne 1 ] && [ "$(cat "$outcome" 2>/dev/null)" != exit ]; }
  }; then
    if [ "$budget_capped" -eq 1 ]; then
      printf 'not ok - budget exhausted: %s was terminated after %ss when the shared step budget of %ss ran out (infrastructure failure)\n' \
        "$script" "$bound" "$STEP_BUDGET_SECS" | tee "$out.budget" >>"$out"
      rc=125
    else
      printf 'not ok - timed out: %s exceeded its per-script bound of %ss and was terminated\n' \
        "$script" "$bound" >>"$out"
      printf '%s\n' "$bound" >"$out.timeout"
    fi
    [ "$stream" -eq 1 ] && tail -1 "$out"
    if [ "$(cat "$outcome" 2>/dev/null)" = exit ]; then
      local script_exit
      script_exit=$(cat "$outcome.exit")
      [ "$script_exit" -eq 0 ] || rc=$script_exit
    fi
  fi
  return "$rc"
}

# Run <script> through run_script_bounded and, under --retry-infra-flakes,
# rerun it exactly once after a process signal, startup failure, or timeout,
# unless a test-produced exit was already recorded. The retry's exit is returned.
# A streamed first attempt was already shown live; a captured one is kept in
# <out>.prelude, followed by the FM_TEST_RETRY marker,
# so a worker's replay still shows both attempts while <out> holds the attempt
# that decides the result.
run_script_attempts() {  # <script> <out> <stream> <id>
  local script=$1 out=$2 stream=$3 id=$4 rc signature marker
  rm -f "$out.timeout" "$out.retry" "$out.prelude"
  run_script_bounded "$script" "$out" "$stream" "$id"
  rc=$?
  if [ "$rc" -eq 0 ] || [ "$RETRY_INFRA_FLAKES" -ne 1 ] || [ -e "$out.budget" ]; then
    return "$rc"
  fi
  if [ "$(cat "$out.process" 2>/dev/null)" = exit ]; then
    return "$rc"
  fi
  if [ -s "$out.timeout" ]; then
    signature=timeout
  else
    signature=$(cat "$out.process" 2>/dev/null) || return "$rc"
    case "$signature" in signal-*|start-error) ;; *) return "$rc" ;; esac
  fi
  if [ -n "$STEP_BUDGET_SECS" ]; then
    local remaining bound
    remaining=$(( (RUN_STARTED_MS + STEP_BUDGET_SECS * 1000 - $(now_ms)) / 1000 ))
    bound=$(script_timeout_secs "$script")
    if [ "$remaining" -le "$bound" ]; then
      log "not retried: $script: ${remaining}s of the shared step budget of ${STEP_BUDGET_SECS}s cannot cover its ${bound}s bound (signature=$signature first_exit=$rc)"
      return "$rc"
    fi
  fi
  rm -f "$out.timeout"
  marker=$(printf 'FM_TEST_RETRY %s %s signature=%s first_exit=%s' \
    "$(now_iso)" "$script" "$signature" "$rc")
  if [ "$stream" -eq 1 ]; then
    printf '%s\n' "$marker"
  else
    { cat "$out"; printf '%s\n' "$marker"; } >"$out.prelude"
  fi
  printf '%s\t%s\n' "$signature" "$rc" >"$out.retry"
  run_script_bounded "$script" "$out" "$stream" "$id.retry"
}

run_one_serial() {
  local script=$1
  local base family expected out begin_iso begin_ms end_ms end_iso duration rc
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")
  out="$RUN_TMP/out.$TOTAL"
  begin_iso=$(now_iso)
  begin_ms=$(now_ms)

  printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
    "$begin_iso" "$script" "$family" "$expected"

  set +e
  # Stream live output while retaining a copy for gate-skip detection.
  run_script_attempts "$script" "$out" 1 "s$TOTAL"
  rc=$?
  set -e
  : "${rc:=1}"

  end_ms=$(now_ms)
  end_iso=$(now_iso)
  duration=$((end_ms - begin_ms))
  if [ "$duration" -lt 0 ]; then
    duration=0
  fi
  record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
}

if [ "$JOBS" -eq 1 ]; then
  for script in "${SCRIPTS[@]}"; do
    run_one_serial "$script"
  done
else
  # Bounded concurrent execution for admitted scripts. Each worker gets a
  # private mode-0700 TMPDIR so mktemp roots cannot collide. Native Windows
  # Bash layers report synthetic POSIX modes, so retain chmod there but enforce
  # its observed mode only where the host reports real POSIX permissions.
  # Retries are never a green strategy: the only retry is the single
  # --retry-infra-flakes rerun on a process-level infrastructure failure.
  worker_n=0
  active_workers=0

  worker_root_mode_is_enforceable() {
    case "$(uname -s)" in
      MINGW*|MSYS*) return 1 ;;
      *) return 0 ;;
    esac
  }

  wait_one_job_worker() {
    local slot=$1 pid idx work script rc duration mode out end_iso
    pid=${WORKER_PIDS[$slot]}
    idx=${WORKER_IDX[$slot]}
    script=${WORKER_SCRIPTS[$slot]}
    set +e
    wait "$pid"
    set -e
    unset 'WORKER_PIDS[slot]'
    unset 'WORKER_IDX[slot]'
    unset 'WORKER_SCRIPTS[slot]'
    active_workers=$((active_workers - 1))
    work="$RUN_TMP/w$idx"
    rc=$(cat "$work/exit" 2>/dev/null || echo 1)
    duration=$(cat "$work/duration_ms" 2>/dev/null || echo 0)
    out="$work/output"
    end_iso=$(now_iso)
    # Replay captured output after the worker finishes so markers stay ordered.
    # A retried script's first attempt and its FM_TEST_RETRY marker come first.
    if [ -s "$out.prelude" ]; then
      cat "$out.prelude"
    fi
    if [ -s "$out" ]; then
      cat "$out"
    fi
    if worker_root_mode_is_enforceable; then
      mode=$(stat -c %a "$work" 2>/dev/null || /usr/bin/stat -f %Lp "$work" 2>/dev/null || echo unknown)
      case "$mode" in
        700|0700) ;;
        *)
          log "isolation failure: worker root mode is $mode, expected 0700 ($work)"
          rc=1
          ;;
      esac
    fi
    record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
  }

  worker_pid_is_running() {
    local want=$1 running inventory="$RUN_TMP/running-pids"
    # Keep `jobs` in this shell. A process substitution runs it in a subshell
    # without this shell's job table on Bash 3.2/5.x, falsely reporting every
    # worker complete and making the scheduler wait for the oldest PID.
    jobs -r -p >"$inventory"
    while IFS= read -r running; do
      [ "$running" = "$want" ] && return 0
    done <"$inventory"
    return 1
  }

  wait_one_completed_job_worker() {
    local slot work
    while :; do
      for slot in "${!WORKER_PIDS[@]}"; do
        work="$RUN_TMP/w${WORKER_IDX[$slot]}"
        if [ -f "$work/exit" ] || ! worker_pid_is_running "${WORKER_PIDS[$slot]}"; then
          wait_one_job_worker "$slot"
          return
        fi
      done
      sleep 0.01
    done
  }

  for script in "${CONCURRENT_SCRIPTS[@]+"${CONCURRENT_SCRIPTS[@]}"}"; do
    if [ "$script" = "$CONCURRENT_PHASE_BREAK" ]; then
      while [ "$active_workers" -gt 0 ]; do
        wait_one_completed_job_worker
      done
      continue
    fi
    while [ "$active_workers" -ge "$JOBS" ]; do
      wait_one_completed_job_worker
    done
    worker_n=$((worker_n + 1))
    work="$RUN_TMP/w$worker_n"
    mkdir -p "$work/tmp"
    chmod 0700 "$work" "$work/tmp" || die "could not chmod 0700 worker root $work"
    base=$(basename "$script")
    family=$(family_for_basename "$base")
    expected=$(expected_gate_skip_for_family "$family")
    printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
      "$(now_iso)" "$script" "$family" "$expected"
    (
      trap - EXIT HUP INT TERM
      set +e
      export TMPDIR="$work/tmp"
      export TMP="$work/tmp"
      unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE \
        FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND 2>/dev/null || true
      cd "$ROOT" || exit 1
      begin_ms=$(now_ms)
      set +e
      run_script_attempts "$script" "$work/output" 0 "w$worker_n"
      rc=$?
      set -e
      end_ms=$(now_ms)
      duration=$((end_ms - begin_ms))
      if [ "$duration" -lt 0 ]; then
        duration=0
      fi
      printf '%s\n' "$duration" >"$work/duration_ms"
      printf '%s\n' "$rc" >"$work/exit"
      exit 0
    ) &
    worker_pid=$!
    WORKER_PIDS[worker_n]=$worker_pid
    WORKER_IDX[worker_n]=$worker_n
    WORKER_SCRIPTS[worker_n]=$script
    active_workers=$((active_workers + 1))
  done
  while [ "$active_workers" -gt 0 ]; do
    wait_one_completed_job_worker
  done
  # Unproven remainder, after every concurrent worker has finished.
  for script in "${SERIAL_TAIL_SCRIPTS[@]+"${SERIAL_TAIL_SCRIPTS[@]}"}"; do
    run_one_serial "$script"
  done
fi

RUN_FINISHED_ISO=$(now_iso)
RUN_FINISHED_MS=$(now_ms)
RUN_DURATION=$((RUN_FINISHED_MS - RUN_STARTED_MS))
if [ "$RUN_DURATION" -lt 0 ]; then
  RUN_DURATION=0
fi

printf 'FM_TEST_SUMMARY total=%s failed=%s skipped_gate=%s duration_ms=%s\n' \
  "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION"

if [ -s "$FAMILIES_TSV" ]; then
  # Stable family summary order by name.
  sort -t$'\t' -k1,1 "$FAMILIES_TSV" | while IFS=$'\t' read -r name count duration failed_count; do
    printf 'FM_TEST_SUMMARY_FAMILY family=%s count=%s duration_ms=%s failed=%s\n' \
      "$name" "$count" "$duration" "$failed_count"
  done
fi

# Timed-out and retried scripts, one line each in run order, so a lane's log
# tail names every hang and every retried infrastructure flake without
# scrolling back. Record columns 8-10 are timeout_secs, retry signature, and
# the first attempt's exit; awk keeps empty columns in place.
if [ -s "$RECORDS" ]; then
  awk -F'\t' '
    $8 > 0 { printf "FM_TEST_TIMED_OUT script=%s bound_secs=%s\n", $1, $8 }
    $9 != "" { printf "FM_TEST_RETRIED_FLAKE script=%s signature=%s first_exit=%s exit=%s\n", $1, $9, $10, $4 }
  ' "$RECORDS"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && awk -F'\t' '$8 > 0 || $9 != "" { found = 1 } END { exit !found }' "$RECORDS"; then
    awk -F'\t' '
      BEGIN {
        print "### Behavior test timeouts and retried infra flakes"
        print ""
        print "| Script | Outcome | Detail |"
        print "|---|---|---|"
      }
      $8 > 0 { printf "| `%s` | timed out | terminated after its %ss per-script bound |\n", $1, $8 }
      $9 != "" {
        printf "| `%s` | retried infra flake, %s | signature %s, first exit %s, retry exit %s |\n", $1, ($4 == 0 ? "passed on retry" : "failed on retry"), $9, $10, $4
      }
    ' "$RECORDS" >>"$GITHUB_STEP_SUMMARY" || log "could not append to GITHUB_STEP_SUMMARY: $GITHUB_STEP_SUMMARY"
  fi
fi

# Slowest scripts (top 15) from records.
if [ -s "$RECORDS" ]; then
  rank=1
  sort -t$'\t' -k5,5nr "$RECORDS" | head -n 15 | while IFS=$'\t' read -r path _family _expected _rc duration _gate; do
    printf 'FM_TEST_SLOWEST rank=%s script=%s duration_ms=%s\n' \
      "$rank" "$path" "$duration"
    rank=$((rank + 1))
  done
fi

if [ -n "$JSON_PATH" ]; then
  mkdir -p "$(dirname "$JSON_PATH")"
  # Families file may be unsorted; write_json reads as-is (deterministic sort in python).
  if [ -s "$FAMILIES_TSV" ]; then
    sort -t$'\t' -k1,1 "$FAMILIES_TSV" -o "$FAMILIES_TSV"
  else
    : >"$FAMILIES_TSV"
  fi
  set +e
  write_json_artifact "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION" \
    "$SELECTION_DESC" "$RECORDS" "$FAMILIES_TSV"
  json_rc=$?
  set -e
  if [ "$json_rc" -eq 0 ]; then
    log "wrote timing artifact: $JSON_PATH"
  else
    log "timing artifact finalization failed: $JSON_PATH"
    AGG_RC=1
  fi
fi

if [ -n "$MAX_WALL_MS" ]; then
  printf 'FM_TEST_BUDGET max_wall_ms=%s duration_ms=%s\n' "$MAX_WALL_MS" "$RUN_DURATION"
  if [ "$RUN_DURATION" -gt "$MAX_WALL_MS" ]; then
    log "wall-clock budget exceeded: ${RUN_DURATION}ms > ${MAX_WALL_MS}ms for $SELECTION_DESC"
    AGG_RC=1
  fi
fi

exit "$AGG_RC"
