#!/usr/bin/env bash
# Tests for the context-volume stow trigger: bin/fm-stow-trigger.sh (threshold,
# one-wake-per-context-cycle latch, durable stow-due wake) and the omp and Pi
# primary guard extensions and the Claude Code hooks that report to it.
#
# The gap it closes: a daily stow reminder comes due long after a busy session
# has already compacted, so knowledge held only in conversation is condensed
# away before /stow captures it. Each case drives the public commands and
# asserts how many stow-due rows reach the durable wake queue.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TRIGGER="$ROOT/bin/fm-stow-trigger.sh"
TMP_ROOT=$(fm_test_tmproot fm-stow-trigger)

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

trig() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$TRIGGER" "$@"
}

stow_rows() {  # <home>
  awk -F '\t' '$3 == "check" && $4 == "stow-due"' "$1/state/.wake-queue" 2>/dev/null | wc -l | tr -d ' '
}

# Firstmate handling the wake: acknowledge every queued row.
drain_queue() {  # <home>
  : > "$1/state/.wake-queue"
}

stow_at() {  # <home> <epoch>
  fm_touch_epoch "$2" "$1/state/.last-stow"
}

test_threshold_crossing_wakes_once_per_cycle() {
  local home out
  home=$(make_home cycle)
  out=$(trig "$home" context 40)
  [ -z "$out" ] || fail "below the threshold must stay silent, got: $out"
  assert_equals 0 "$(stow_rows "$home")" "below the threshold queued a wake"

  out=$(trig "$home" context 71)
  assert_contains "$out" "check: stow-due: context 71% (threshold 70%)" "crossing the default threshold did not print the wake reason"
  assert_equals 1 "$(stow_rows "$home")" "crossing the threshold did not queue exactly one wake"

  # Handled and acknowledged, but no stow ran: still one wake per cycle.
  drain_queue "$home"
  out=$(trig "$home" context 85)
  [ -z "$out" ] || fail "a second crossing in the same cycle woke again: $out"
  out=$(trig "$home" compacting 95)
  [ -z "$out" ] || fail "compaction after this cycle's wake woke again: $out"
  assert_equals 0 "$(stow_rows "$home")" "the latch let a second wake through"

  # Compaction finished: a new cycle re-arms the latch.
  trig "$home" cycle
  out=$(trig "$home" context 20)
  [ -z "$out" ] || fail "a fresh cycle below the threshold woke: $out"
  out=$(trig "$home" context 72)
  assert_contains "$out" "context 72%" "the next cycle's crossing did not wake"
  assert_equals 1 "$(stow_rows "$home")" "the next cycle did not queue exactly one wake"
  pass "fm-stow-trigger: one wake at the threshold per context cycle, re-armed by compaction"
}

test_stow_at_high_usage_satisfies_the_cycle() {
  local home out now
  home=$(make_home stowed)
  now=$(date +%s)
  trig "$home" cycle
  # A stow that ran before usage reached the threshold (the daily floor on a
  # quiet morning) does not cover the later busy part of the cycle.
  stow_at "$home" $((now - 3600))
  out=$(trig "$home" context 75)
  assert_contains "$out" "stow-due: context 75%" "an older stow suppressed the crossing"
  drain_queue "$home"

  # A new cycle where the stow lands after usage is already high: no wake,
  # and staying high never wakes later.
  trig "$home" cycle
  stow_at "$home" $((now + 60))
  out=$(trig "$home" context 80)
  [ -z "$out" ] || fail "a stow already done at high usage still woke: $out"
  out=$(trig "$home" context 90)
  [ -z "$out" ] || fail "sustained high usage after a stow woke: $out"
  out=$(trig "$home" compacting 96)
  [ -z "$out" ] || fail "compaction after a stow this cycle woke: $out"
  assert_equals 0 "$(stow_rows "$home")" "a stow this cycle did not satisfy the latch"
  pass "fm-stow-trigger: a stow at high usage satisfies the cycle; one before it does not"
}

test_compaction_wakes_when_threshold_never_crossed() {
  local home out
  home=$(make_home compact)
  trig "$home" cycle
  # Usage jumped straight past the threshold inside one agent loop, so the
  # first report is the compaction itself.
  out=$(trig "$home" compacting 93)
  assert_contains "$out" "check: stow-due: context 93% at compaction" "compaction with no stow this cycle did not wake"
  out=$(trig "$home" context 95)
  [ -z "$out" ] || fail "a crossing after the compaction wake woke again: $out"
  out=$(trig "$home" compacting)
  [ -z "$out" ] || fail "a second compaction notice in the same cycle woke: $out"
  assert_equals 1 "$(stow_rows "$home")" "compaction did not queue exactly one wake"
  pass "fm-stow-trigger: compaction queues the wake when the threshold was skipped"
}

test_configured_threshold_and_no_duplicate_rows() {
  local home out
  home=$(make_home config)
  printf '85\n' > "$home/config/stow-context-threshold"
  assert_equals 85 "$(trig "$home" threshold)" "configured threshold not read"
  out=$(trig "$home" context 80)
  [ -z "$out" ] || fail "80% woke under an 85% threshold: $out"
  out=$(trig "$home" context 85)
  assert_contains "$out" "(threshold 85%)" "the configured threshold did not wake at its value"

  # An unacknowledged stow-due row is never duplicated, even across a new cycle.
  trig "$home" cycle
  trig "$home" context 90 >/dev/null
  assert_equals 1 "$(stow_rows "$home")" "a still-queued stow-due row was duplicated"

  for bad in abc 0 101 ''; do
    printf '%s\n' "$bad" > "$home/config/stow-context-threshold"
    assert_equals 70 "$(trig "$home" threshold)" "invalid threshold '$bad' did not fall back to 70"
  done
  expect_code 2 "$(trig "$home" context nope >/dev/null 2>&1; echo $?)" "an invalid percent was accepted"
  pass "fm-stow-trigger: config/stow-context-threshold is honored, invalid values fall back, rows never duplicate"
}

# The guard extensions over a fake harness API: only the fleet-lock holder
# reports, agent_end carries usage, before-compact never cancels, and compaction
# starts a new cycle.
run_extension_case() {  # <harness-dir: .omp|.pi> <label>
  local dir=$1 label=$2 repo home out status
  repo="$TMP_ROOT/ext-${dir#.}/repo"; home="$TMP_ROOT/ext-${dir#.}/home"
  mkdir -p "$repo/$dir/extensions" "$repo/.pi/extensions/lib" "$repo/bin" "$home/state"
  cp "$ROOT/$dir/extensions/fm-primary-turnend-guard.ts" "$repo/$dir/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$repo/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$TRIGGER" "$ROOT/bin/"*-lib.sh "$repo/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-sessionstart-run.sh"
  chmod +x "$repo/bin/"*.sh
  out=$(FM_HOME="$home" EXT="$repo/$dir/extensions/fm-primary-turnend-guard.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
for (const name of ["agent_end", "session_before_compact", "session_compact"]) {
  if (!handlers.has(name)) throw new Error(`${name} handler was not registered`);
}
const rows = () => existsSync(`${state}/.wake-queue`)
  ? readFileSync(`${state}/.wake-queue`, "utf8").split("\n").filter((l) => l.split("\t")[3] === "stow-due")
  : [];
const settle = async (want) => {
  for (let i = 0; i < 100; i += 1) {
    if (rows().length === want) return;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`expected ${want} stow-due rows, saw ${rows().length}`);
};
const ctx = (percent) => ({ getContextUsage: () => ({ tokens: 1, contextWindow: 100, percent }), sessionManager: { getSessionId: () => "s1" } });
// Not the fleet-lock holder: inert.
writeFileSync(`${state}/.lock`, "1\n");
handlers.get("agent_end")({ type: "agent_end", messages: [] }, ctx(99));
await new Promise((r) => setTimeout(r, 300));
if (rows().length !== 0 || existsSync(`${state}/.stow-trigger`)) throw new Error("a non-owner session reported usage");
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
handlers.get("agent_end")({ type: "agent_end", messages: [] }, ctx(30));
handlers.get("agent_end")({ type: "agent_end", messages: [] }, ctx(null));
await new Promise((r) => setTimeout(r, 300));
if (rows().length !== 0) throw new Error("below-threshold or unknown usage woke");
handlers.get("agent_end")({ type: "agent_end", messages: [] }, ctx(74.6));
await settle(1);
if (!rows()[0].includes("check: stow-due: context 74%")) throw new Error(`wake payload was ${rows()[0]}`);
const before = handlers.get("session_before_compact")({ type: "session_before_compact" }, ctx(97));
if (before !== undefined) throw new Error(`before-compact must not cancel or customize: ${JSON.stringify(before)}`);
await new Promise((r) => setTimeout(r, 300));
if (rows().length !== 1) throw new Error("compaction re-woke inside the same cycle");
writeFileSync(`${state}/.wake-queue`, "");
await handlers.get("session_compact")({ type: "session_compact" }, ctx(null));
for (let i = 0; i < 100 && !readFileSync(`${state}/.stow-trigger`, "utf8").includes("fired=0"); i += 1) {
  await new Promise((r) => setTimeout(r, 50));
}
handlers.get("agent_end")({ type: "agent_end", messages: [] }, ctx(80));
await settle(1);
await handlers.get("session_shutdown")?.({}, {});
EOF
)
  status=$?
  expect_code 0 "$status" "$label guard stow-trigger contract: $out"
  pass "$label guard: owner-only usage reports, one wake per cycle, before-compact never cancels, compaction re-arms"
}

test_omp_guard_reports_context_usage() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found"; return 0; }
  run_extension_case .omp omp
}

test_pi_guard_reports_context_usage() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found"; return 0; }
  run_extension_case .pi Pi
}

# A new session's startup `cycle` report can be dropped: the harness may run it
# before the session takes state/.lock, while the lock still names the previous
# session. The first report from the new holder then starts the cycle itself, so
# neither the previous session's fired latch nor its later stow suppresses it.
test_new_lock_holder_starts_a_new_cycle() {
  local fired_home stowed_home now out
  fired_home=$(make_home holder-fired)
  stowed_home=$(make_home holder-stowed)
  now=$(date +%s)
  printf '111\n' > "$fired_home/state/.lock"
  printf '111\n' > "$stowed_home/state/.lock"
  trig "$fired_home" cycle
  trig "$fired_home" context 75 >/dev/null
  drain_queue "$fired_home"
  trig "$stowed_home" cycle
  trig "$stowed_home" context 40
  stow_at "$stowed_home" $((now + 1))
  sleep 2

  printf '222\n' > "$fired_home/state/.lock"
  printf '222\n' > "$stowed_home/state/.lock"
  out=$(trig "$fired_home" context 80)
  assert_contains "$out" "stow-due: context 80%" "a previous session's fired latch suppressed the new holder's crossing"
  out=$(trig "$stowed_home" compacting)
  assert_contains "$out" "at compaction" "a previous session's later stow suppressed the new holder's compaction"
  out=$(trig "$fired_home" compacting)
  [ -z "$out" ] || fail "the same holder woke twice in one cycle: $out"
  assert_equals 1 "$(stow_rows "$fired_home")" "the new holder did not queue exactly one wake"
  assert_equals 1 "$(stow_rows "$stowed_home")" "the new holder did not queue exactly one wake"

  # A record written before holders were recorded starts a new cycle once.
  drain_queue "$fired_home"
  printf 'fm-stow-trigger-v1\ncycle=%s\nabove=%s\nfired=%s\n' "$now" "$now" "$now" > "$fired_home/state/.stow-trigger"
  out=$(trig "$fired_home" compacting)
  assert_contains "$out" "at compaction" "a holderless record kept suppressing the wake"
  out=$(trig "$fired_home" compacting)
  [ -z "$out" ] || fail "a holderless record started more than one new cycle: $out"
  pass "fm-stow-trigger: a new fleet-lock holder starts a new cycle despite a dropped startup report"
}

# The tracked Claude Code hooks, run as Claude runs them: the command string
# from .claude/settings.json under bash, with the JSON payload on stdin, as a
# child of a long-lived claude-named session process. Only the fleet-lock holder
# reports, PreCompact queues one wake per cycle, and SessionStart (but not a
# resume) starts a new cycle. Nothing reaches stdout and every run exits 0.
test_claude_precompact_hook_wakes_once_per_cycle() {
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; return 0; }
  local dir fakebin precompact sessionstart out session_pid
  dir="$TMP_ROOT/claude-home"
  mkdir -p "$dir/state" "$dir/bin"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp "$TRIGGER" "$ROOT/bin/fm-stow-trigger-claude.sh" "$ROOT/bin/"*-lib.sh "$dir/bin/"
  chmod +x "$dir/bin/"*.sh
  fakebin=$(fm_fakebin "$TMP_ROOT/claude-fakebin")
  ln -s /bin/bash "$fakebin/claude"
  precompact=$(jq -r '.hooks.PreCompact[].hooks[].command' "$ROOT/.claude/settings.json")
  sessionstart=$(jq -r '.hooks.SessionStart[].hooks[].command | select(contains("fm-stow-trigger"))' "$ROOT/.claude/settings.json")
  [ -n "$precompact" ] && [ -n "$sessionstart" ] || fail "tracked Claude stow-trigger hooks are missing"
  # shellcheck disable=SC2016
  local take_lock='printf "%s\n" "$PPID" > "$FM_HOME/state/.lock"'

  # One fake Claude session: every hook runs as its child, so its pid is the
  # session pid a real lock would name.
  session_start() {
    rm -f "$dir/hooks.fifo"
    mkfifo "$dir/hooks.fifo"
    # shellcheck disable=SC2016
    env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$dir" FM_HOME="$dir" "$fakebin/claude" -c '
      while IFS= read -r cmd && IFS= read -r payload; do
        rc=0
        printf "%s\n" "$payload" | bash -c "$cmd" > "$FM_HOME/hook.out" 2>/dev/null || rc=$?
        printf "%s\n" "$rc" > "$FM_HOME/hook.rc"
      done < "$FM_HOME/hooks.fifo"' &
    session_pid=$!
    exec 7> "$dir/hooks.fifo"
  }
  session_end() {
    exec 7>&-
    wait "$session_pid"
  }
  hook() {  # <command> <payload>; prints the hook's stdout, returns its status
    rm -f "$dir/hook.rc"
    printf '%s\n%s\n' "$1" "$2" >&7
    for _ in $(seq 1 200); do
      [ -s "$dir/hook.rc" ] && break
      sleep 0.05
    done
    cat "$dir/hook.out"
    return "$(cat "$dir/hook.rc")"
  }
  settle() {  # <want>
    for _ in $(seq 1 100); do
      [ "$(stow_rows "$dir")" = "$1" ] && grep -q '^fired=[1-9]' "$dir/state/.stow-trigger" 2>/dev/null && return 0
      sleep 0.05
    done
    fail "expected $1 stow-due rows and a fired latch, saw $(stow_rows "$dir") rows"
  }
  cycled() {
    for _ in $(seq 1 100); do
      grep -qx 'fired=0' "$dir/state/.stow-trigger" 2>/dev/null && return 0
      sleep 0.05
    done
    fail "SessionStart did not start a new stow cycle"
  }
  quiet() {  # <label>
    sleep 0.5
    assert_equals 0 "$(stow_rows "$dir")" "$1"
  }
  local pre='{"session_id":"s1","hook_event_name":"PreCompact","trigger":"auto"}'

  session_start
  printf '1\n' > "$dir/state/.lock"
  out=$(hook "$precompact" "$pre") || fail "PreCompact hook exited non-zero for a non-owner"
  [ -z "$out" ] || fail "PreCompact hook printed on stdout: $out"
  quiet "a non-owner Claude session queued a stow wake"
  [ ! -e "$dir/state/.stow-trigger" ] || fail "a non-owner Claude session wrote the stow latch"

  hook "$take_lock" '{}'
  out=$(hook "$sessionstart" '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup"}') \
    || fail "SessionStart hook exited non-zero"
  [ -z "$out" ] || fail "SessionStart hook printed on stdout: $out"
  cycled
  out=$(hook "$precompact" "$pre") || fail "PreCompact hook exited non-zero"
  [ -z "$out" ] || fail "PreCompact hook printed on stdout: $out"
  settle 1
  awk -F '\t' '$4 == "stow-due"' "$dir/state/.wake-queue" | grep -F "at compaction" >/dev/null \
    || fail "the Claude PreCompact wake did not carry the compaction reason"

  drain_queue "$dir"
  hook "$precompact" "$pre" >/dev/null
  quiet "a second PreCompact in the same cycle woke again"

  # A resumed session keeps its context, so it keeps its cycle too.
  hook "$sessionstart" '{"session_id":"s1","hook_event_name":"SessionStart","source":"resume"}' >/dev/null
  sleep 0.5
  hook "$precompact" "$pre" >/dev/null
  quiet "a resume re-armed the latch"

  # Compaction finished: Claude opens the session again with source compact.
  hook "$sessionstart" '{"session_id":"s1","hook_event_name":"SessionStart","source":"compact"}' >/dev/null
  cycled
  hook "$precompact" "$pre" >/dev/null
  settle 1
  session_end

  # The next session's startup report runs while state/.lock still names the
  # ended session, so it is dropped; its first compaction must still wake.
  drain_queue "$dir"
  session_start
  hook "$sessionstart" '{"session_id":"s2","hook_event_name":"SessionStart","source":"startup"}' >/dev/null
  sleep 0.5
  grep -q '^fired=[1-9]' "$dir/state/.stow-trigger" || fail "the stale-lock startup report was not dropped"
  hook "$take_lock" '{}'
  hook "$precompact" '{"session_id":"s2","hook_event_name":"PreCompact","trigger":"auto"}' >/dev/null
  settle 1
  session_end
  pass "Claude PreCompact hook: owner-only, one stow-due wake per cycle, re-armed by SessionStart but not resume or a dropped startup, silent on stdout"
}

test_threshold_crossing_wakes_once_per_cycle
test_stow_at_high_usage_satisfies_the_cycle
test_compaction_wakes_when_threshold_never_crossed
test_configured_threshold_and_no_duplicate_rows
test_new_lock_holder_starts_a_new_cycle
test_omp_guard_reports_context_usage
test_pi_guard_reports_context_usage
test_claude_precompact_hook_wakes_once_per_cycle
