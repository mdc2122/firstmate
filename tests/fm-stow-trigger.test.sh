#!/usr/bin/env bash
# Tests for the context-volume stow trigger: bin/fm-stow-trigger.sh (threshold,
# one-wake-per-context-cycle latch, durable stow-due wake) and the omp and Pi
# primary guard extensions that report context usage to it.
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

test_threshold_crossing_wakes_once_per_cycle
test_stow_at_high_usage_satisfies_the_cycle
test_compaction_wakes_when_threshold_never_crossed
test_configured_threshold_and_no_duplicate_rows
test_omp_guard_reports_context_usage
test_pi_guard_reports_context_usage
