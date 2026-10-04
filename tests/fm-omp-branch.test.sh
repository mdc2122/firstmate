#!/usr/bin/env bash
# Tests for the omp (Oh My Pi) supervision-branch port
# (.omp/extensions/fm-omp-branch-supervision.ts, docs/supervision-protocols/
# omp.md): the config/omp-supervision-branch mode gate, the F1-F7 safety
# guards from data/omp-second-conversation's report, and report-only shadow
# mode. The omp SDK is stubbed (fake pi API over in-process sessions); every
# fleet-record behavior runs the REAL bin scripts, and lock ownership is
# proven through a fake ps that reports the test shell's real pid as an `omp`
# harness, the same fixture shape tests/fm-session-start.test.sh uses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-branch)
export NODE_NO_WARNINGS=1

# Keep JavaScript heredocs outside command substitutions (the suite's Bash 3.2
# rule; tests/fm-pi-branch-extension.test.sh makes the same choice).
install_omp_branch_fixture() {  # <repo>
  local repo=$1 s
  mkdir -p \
    "$repo/.omp/extensions/lib" \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/typebox" \
    "$repo/bin"
  cp "$ROOT/.omp/extensions/fm-omp-branch-supervision.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.omp/extensions/lib/fm-omp-branch.ts" "$repo/.omp/extensions/lib/"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" \
    "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
  chmod +x "$repo/bin/fm-operational-input.sh"
  # The REAL fleet-record scripts the extension shells out to, wrapped so
  # their own script-relative libs keep resolving inside $ROOT/bin.
  for s in fm-branch-outcome.sh fm-lease.sh fm-wake-grant.sh fm-branch-prompt.sh fm-lock.sh; do
    printf '#!/usr/bin/env bash\nexec "%s/bin/%s" "$@"\n' "$ROOT" "$s" > "$repo/bin/$s"
    chmod +x "$repo/bin/$s"
  done
  printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/typebox/package.json"
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(p) { return { type: "object", properties: p }; },
  String(d) { return { ...(d ?? {}) }; },
  Optional(v) { return v; },
  Number(d) { return { ...(d ?? {}) }; },
  Boolean(d) { return { ...(d ?? {}) }; },
  Union(u) { return u; },
  Literal(v) { return v; },
};
JS
}

# A fake ps making the test shell's own real pid read as an `omp` harness, so
# both ownership proofs inside the extension - its own ppid walk to the lock
# holder AND `bin/fm-lock.sh owned`'s harness-ancestry identity - answer
# "owned" for the node process these tests drive. Every other pid reports
# itself normally, so decoys and helpers stay out.
make_omp_ancestry_ps() {  # <fakebin> <holder-pid>
  local fakebin=$1 holder=$2
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
pid=
prev=
for arg in "\$@"; do
  [ "\$prev" = "-p" ] && pid="\$arg"
  prev="\$arg"
done
case "\$*" in
  *"comm="*)
    [ "\$pid" = "$holder" ] && printf '/usr/local/bin/omp\n' || printf '/bin/bash\n'
    exit 0
    ;;
  *"args="*)
    [ "\$pid" = "$holder" ] && printf 'omp\n' || printf 'bash\n'
    exit 0
    ;;
esac
exec /bin/ps "\$@"
SH
  chmod +x "$fakebin/ps"
}

# A driver prelude shared by the extension tests: fake pi API, a fake branch
# session whose prompt runs the real fm_branch_report tool once (the behavior
# the durable-report gate counts), main session entries, and helpers that
# fire the handler set the way omp does. Each test's case code reads its
# values back through globalThis.__t. The JavaScript is literal by design.
# shellcheck disable=SC2016
DRIVER_PRELUDE='
const { pathToFileURL } = await import("node:url");
const { mkdirSync, readFileSync, writeFileSync } = await import("node:fs");

const home = process.env.FM_HOME;
mkdirSync(`${home}/state`, { recursive: true });
const mainEntries = [];
const sentToMain = [];
const widgets = {};
const branchPrompts = [];
const eventHandlers = new Map();
const handlers = new Map();
const tools = new Map();
const createdSessions = [];

const mainSessionManager = {
  getSessionFile: () => `${home}/main-session.jsonl`,
  getEntries: () => mainEntries,
};

const pi = {
  on: (e, h) => handlers.set(e, h),
  events: {
    on: (c, h) => eventHandlers.set(c, h),
    emit: (c, d) => eventHandlers.get(c)?.(d),
  },
  registerTool: (t) => tools.set(t.name, t),
  registerCommand: () => {},
  sendMessage: (m, o) => sentToMain.push({ ...m, ...(o ?? {}) }),
  sendUserMessage: () => {},
  appendEntry: (type, data) => mainEntries.push({ type: "custom", customType: type, data }),
  getThinkingLevel: () => "high",
  pi: {
    createAgentSession: async (opts) => {
      createdSessions.push(opts);
      const sessionEntries = [];
      const reportTool = opts.customTools.find((t) => t.name === "fm_branch_report");
      const session = {
        prompt: async (text) => {
          branchPrompts.push(text);
          sessionEntries.push({ type: "message", message: { role: "user", content: text } });
          if (process.env.PROMPT_BEHAVIOR === "report-routine") {
            await reportTool.execute("c1", { task: "task-1", verdict: "routine", summary: "handled event" });
          } else if (process.env.PROMPT_BEHAVIOR === "report-captain") {
            await reportTool.execute("c1", { task: "task-1", verdict: "captain", summary: "PR https://example.com/pr/1 is green" });
          } else if (process.env.PROMPT_BEHAVIOR === "provider-error") {
            sessionEntries.push({ type: "message", message: { role: "assistant", content: "x", stopReason: "error", errorMessage: "quota" } });
          } else {
            sessionEntries.push({ type: "message", message: { role: "assistant", content: "done", stopReason: "stop" } });
          }
          return true;
        },
        sendCustomMessage: async () => true,
        dispose: async () => {},
      };
      const sessionManager = {
        getSessionFile: () => `${home}/branch-session.jsonl`,
        getEntries: () => sessionEntries,
      };
      return { session, sessionManager };
    },
    SessionManager: { create: () => ({ getSessionFile: () => `${home}/branch-session.jsonl`, getEntries: () => [] }) },
    AgentRegistry: class {},
  },
};

const ctx = {
  sessionManager: mainSessionManager,
  models: {
    current: () => ({ provider: "cursor", id: "gpt-5.4-nano" }),
    resolve: (spec) => (spec === "cursor/gpt-5.4-nano" ? { provider: "cursor", id: "gpt-5.4-nano" } : undefined),
  },
  model: { provider: "cursor", id: "gpt-5.4-nano" },
  agent: { kind: "main" },
  ui: {
    setWidget: (key, content) => { widgets[key] = content; },
    notify: () => {},
  },
};

const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);

const dispatch = (message) => {
  const offer = {
    message, projects: [], heartbeat: /^heartbeat/.test(message),
    eligible: true, accepted: false, settlement: Promise.resolve(),
    accept(settlement = Promise.resolve()) { offer.accepted = true; offer.settlement = settlement; },
  };
  pi.events.emit("fm-branch-supervision:dispatch", offer);
  return offer;
};
const shadow = (message, rows = []) => {
  pi.events.emit("fm-omp-branch-supervision:shadow", { message, heartbeat: /^heartbeat/.test(message), rows, tasks: rows.map((row) => (row.split("\t")[3] ?? "").replace(/\.status$|\.turn-ended$/, "")).filter(Boolean) });
};
const fire = (event, ev = {}, c = ctx) => handlers.get(event)?.(ev, c);
const settled = () => new Promise((r) => setTimeout(r, Number(process.env.SETTLE_MS || 150)));
'

# The wake-queue row shape bin/fm-wake-grant.sh and scopeForUnreadWake read.
seed_branch_eligible_wake() {  # <home> <task> <seq>
  local home=$1 task=$2 seq=$3
  printf '%s\n' "$seq" > "$home/state/.wake-queue.seq"
  printf '1700000000\t%s\tsignal\t%s.status\tsignal: %s done\n' "$seq" "$task" "$task" >> "$home/state/.wake-queue"
  printf 'project=x\nharness=omp\n' > "$home/state/$task.meta"
  printf 'done: %s ready\n' "$task" > "$home/state/$task.status"
}

# --- mode gate ---------------------------------------------------------------

test_config_absent_and_off_are_inert() {
  local home repo out
  repo="$TMP_ROOT/absent-repo"
  home="$TMP_ROOT/absent-home"
  install_omp_branch_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  for mode in absent off bogus-value; do
    case "$mode" in
      absent) rm -f "$home/config/omp-supervision-branch" ;;
      *) printf '%s\n' "$mode" > "$home/config/omp-supervision-branch" ;;
    esac
    out=$(EXT="$repo/.omp/extensions/fm-omp-branch-supervision.ts" FM_HOME="$home" \
      DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module 2>&1 <<'EOF'
await eval(`(async () => { ${process.env.DRIVER_PRELUDE}; globalThis.__t = { handlers, tools }; })()`);
console.log(`handlers=${globalThis.__t.handlers.size} tools=${globalThis.__t.tools.size}`);
EOF
)
    [ "$out" = "handlers=0 tools=0" ] || fail "mode '$mode' registered branch behavior: $out"
  done
  [ ! -e "$home/state/omp-branch-shadow.jsonl" ] || fail "an off home created branch state"
  pass "config absent, off, and unknown leave the omp branch extension entirely inert"
}

# --- F1: both ownership proofs must agree before any side effect --------------

test_f1_walk_owned_but_fm_lock_refuses() {
  local repo home out
  repo="$TMP_ROOT/f1-repo"
  home="$TMP_ROOT/f1-home"
  install_omp_branch_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  printf 'on\n' > "$home/config/omp-supervision-branch"
  # The F1 fixture: this process's own walk says "owned" (the lock names the
  # test shell's real pid, which node's ancestry reaches), while fm-lock.sh
  # refuses - the exact 09-16 lockout shape the report names.
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '#!/usr/bin/env bash\necho "lock: not owned (refused)" >&2\nexit 1\n' > "$repo/bin/fm-lock.sh"
  chmod +x "$repo/bin/fm-lock.sh"
  out=$(EXT="$repo/.omp/extensions/fm-omp-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module 2>&1 <<'EOF'
await eval(`(async () => { ${process.env.DRIVER_PRELUDE}; globalThis.__t = { dispatch, fire, settled, sentToMain, tools, ctx }; })()`);
const { dispatch, fire, settled, sentToMain, tools, ctx } = globalThis.__t;
await fire("session_start", {}, ctx);
await settled();
const offer = dispatch("signal: task-1 done");
await settled();
console.log(`accepted=${offer.accepted} sent=${sentToMain.length} activated=${tools.has("fm_branch_report")}`);
EOF
)
  [ "$out" = "accepted=false sent=0 activated=false" ] || fail "the branch acted while fm-lock.sh refused: $out"
  pass "F1: the branch declines a wake when the pid walk says owned but fm-lock.sh refuses"
}

test_f1_ownership_rechecked_before_side_effects() {
  local repo home out
  repo="$TMP_ROOT/f1b-repo"
  home="$TMP_ROOT/f1b-home"
  install_omp_branch_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  printf 'on\n' > "$home/config/omp-supervision-branch"
  # The first fm-lock.sh call succeeds (activation), every later call refuses
  # (the re-check before a side effect) - so a wake that was accepted must
  # still reject before the branch builds or stores anything.
  cat > "$repo/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
counter="${FM_STATE_OVERRIDE:?}/.fm-lock-calls"
n=0
[ -f "$counter" ] && n=$(cat "$counter")
n=$((n + 1))
printf '%s' "$n" > "$counter"
[ "$n" -le 3 ] && { echo "lock: owned"; exit 0; }
echo "lock: not owned (revoked)" >&2
exit 1
SH
  chmod +x "$repo/bin/fm-lock.sh"
  printf '%s\n' "$$" > "$home/state/.lock"
  seed_branch_eligible_wake "$home" task-1 7
  out=$(EXT="$repo/.omp/extensions/fm-omp-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" PROMPT_BEHAVIOR=report-routine SETTLE_MS=300 \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module 2>&1 <<'EOF'
await eval(`(async () => { ${process.env.DRIVER_PRELUDE}; globalThis.__t = { dispatch, fire, settled, sentToMain, ctx, branchPrompts }; })()`);
const { dispatch, fire, settled, sentToMain, ctx, branchPrompts } = globalThis.__t;
await fire("session_start", {}, ctx);
await settled();
const offer = dispatch("signal: task-1 done");
if (!offer.accepted) { console.log("declined"); process.exit(1); }
try { await offer.settlement; console.log("settled"); } catch (error) { console.log(`rejected prompts=${branchPrompts.length} sent=${sentToMain.length}`); }
EOF
)
  case "$out" in
    rejected*prompts=0*sent=0) ;;
    *) fail "a side effect ran after fm-lock.sh revoked ownership: $out" ;;
  esac
  pass "F1: fm-lock.sh is re-checked before every branch side effect"
}

# --- F2: the branch's own bash prints actor=branch -----------------------------

test_f2_branch_actor_is_branch_in_its_shell() {
  local repo home out last
  repo="$TMP_ROOT/f2-repo"
  home="$TMP_ROOT/f2-home"
  install_omp_branch_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  printf 'on\n' > "$home/config/omp-supervision-branch"
  printf '%s\n' "$$" > "$home/state/.lock"
  make_omp_ancestry_ps "$TMP_ROOT/f2-ps" "$$"
  seed_branch_eligible_wake "$home" task-1 7
  out=$(EXT="$repo/.omp/extensions/fm-omp-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" PATH="$TMP_ROOT/f2-ps:$PATH" PROMPT_BEHAVIOR=report-routine SETTLE_MS=2000 \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module 2>&1 <<'EOF'
await eval(`(async () => { ${process.env.DRIVER_PRELUDE}; globalThis.__t = { dispatch, fire, settled, createdSessions, ctx, home }; })()`);
const { dispatch, fire, settled, ctx, home, createdSessions } = globalThis.__t;
await fire("session_start", {}, ctx);
await settled();
const { readFileSync } = await import("node:fs");
console.log("queue=", JSON.stringify(readFileSync(`${home}/state/.wake-queue`, "utf8")));
const { pathToFileURL: toURL } = await import("node:url");
const { scopeForUnreadWake } = await import(toURL(`${process.env.FM_ROOT_OVERRIDE}/.pi/extensions/lib/fm-branch-dispatch.ts`).href);
console.log("scope=", JSON.stringify(scopeForUnreadWake(process.env.FM_STATE_OVERRIDE, false)));
const offer = dispatch("signal: task-1 done");
if (!offer.accepted) { console.log("declined"); process.exit(1); }
try { await offer.settlement; console.log("settled-ok"); } catch (e) { console.log(`settled-err: ${e instanceof Error ? e.message : e}`); }
const bashTool = createdSessions.at(-1)?.customTools?.find((t) => t.name === "bash");
if (!bashTool) { console.log("branch session was not built"); process.exit(1); }
// The omp CustomTool argument order: (id, params, onUpdate, ctx, signal). A
// third-position update callback must never be mistaken for the signal (the
// live 18.4.4 shape that crashed every branch shell before the fix).
const result = await bashTool.execute("t1", { command: "echo actor=${FM_SUPERVISION_ACTOR:-unset} holder=${FM_LEASE_HOLDER_PID:-unset}" }, () => {}, {}, undefined);
console.log(result.content[0].text.trim());
EOF
)
  last=$(printf '%s\n' "$out" | tail -1)
  case "$last" in
    actor=branch*holder=$$) ;;
    *) fail "the branch shell did not see actor=branch with the lock holder pid: $out" ;;
  esac
  pass "F2: FM_SUPERVISION_ACTOR=branch reaches the branch's bash through the readonly command prefix"
}

# --- F3: main's omp shell is refused while the branch holds a lease ------------

test_f3_main_refused_while_branch_holds_lease() {
  local home out main_out main_rc
  home="$TMP_ROOT/f3-home"
  mkdir -p "$home/state" "$home/config"
  printf 'on\n' > "$home/config/omp-supervision-branch"
  printf '%s\n' "$$" > "$home/state/.lock"
  # The branch actor claims the lease; an omp tool shell (OMPCODE=1, no actor
  # variable) is main's shape under mode on, and the OTHER actor's live lease
  # must refuse it rather than be deleted.
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    OMPCODE=1 "$ROOT/bin/fm-lease.sh" claim task-x 2>&1) \
    || fail "the branch could not claim its lease: $out"
  main_out=$(env -u PI_CODING_AGENT -u FM_SUPERVISION_ACTOR OMPCODE=1 FM_HOME="$home" \
    "$ROOT/bin/fm-lease.sh" claim task-x 2>&1)
  main_rc=$?
  [ "$main_rc" -eq 6 ] || fail "main's omp shell was not refused by the live branch lease (rc=$main_rc): $main_out"
  [ -e "$home/state/.lease-task-x" ] || fail "main's refused claim deleted the branch's live lease"
  # Explicit main actor under mode on: claims free tasks, refused by branch.
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=main OMPCODE=1 "$ROOT/bin/fm-lease.sh" claim task-m 2>&1) \
    || fail "main's explicit actor could not claim a free task: $out"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=main OMPCODE=1 "$ROOT/bin/fm-lease.sh" claim task-x 2>&1)
  main_rc=$?
  [ "$main_rc" -eq 6 ] || fail "main's explicit actor was not refused by a live branch lease: $out"
  # Under mode off the same shell is no lease context: the stale branch file
  # is ignored, exactly as before the gate widened.
  printf 'off\n' > "$home/config/omp-supervision-branch"
  off_out=$(env -u PI_CODING_AGENT -u FM_SUPERVISION_ACTOR OMPCODE=1 FM_HOME="$home" \
    "$ROOT/bin/fm-lease.sh" claim task-other 2>&1) \
    || fail "an off-mode omp shell was refused: $off_out"
  pass "F3: main's omp shell is refused by a live branch lease under mode on and ignores it under mode off"
}

# --- F5: the branch session can never load extensions ---------------------------

test_f5_branch_never_loads_extensions() {
  local repo home out
  repo="$TMP_ROOT/f5-repo"
  home="$TMP_ROOT/f5-home"
  install_omp_branch_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  printf 'on\n' > "$home/config/omp-supervision-branch"
  printf '%s\n' "$$" > "$home/state/.lock"
  make_omp_ancestry_ps "$TMP_ROOT/f5-ps" "$$"
  seed_branch_eligible_wake "$home" task-1 7
  out=$(EXT="$repo/.omp/extensions/fm-omp-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" PATH="$TMP_ROOT/f5-ps:$PATH" PROMPT_BEHAVIOR=report-routine SETTLE_MS=2000 \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module 2>&1 <<'EOF'
await eval(`(async () => { ${process.env.DRIVER_PRELUDE}; globalThis.__t = { dispatch, fire, settled, createdSessions, ctx }; })()`);
const { dispatch, fire, settled, ctx, createdSessions } = globalThis.__t;
await fire("session_start", {}, ctx);
await settled();
const offer = dispatch("signal: task-1 done");
try { await offer.settlement; } catch (e) { console.log(`settled-err: ${e instanceof Error ? e.message : e}`); }
const opts = createdSessions.at(-1);
if (!opts) { console.log("session not built"); process.exit(1); }
console.log(`disable=${opts.disableExtensionDiscovery} toolNames=${(opts.toolNames ?? []).join(",")} extPaths=${opts.additionalExtensionPaths ?? "none"} custom=${opts.customTools?.map((t) => t.name).join(",")}`);
EOF
)
  [ "$out" = "disable=true toolNames=read,bash,fm_branch_report extPaths=none custom=bash,fm_branch_report" ] \
    || fail "the branch session did not stay extension-free with its fixed tool set: $out"
  pass "F5: the branch session disables extension discovery and runs exactly read,bash,fm_branch_report"
}

# --- F7: a failed branch wake hands its settlement back to main ----------------

test_f7_failed_branch_wake_returns_to_main() {
  local repo home out
  repo="$TMP_ROOT/f7-repo"
  home="$TMP_ROOT/f7-home"
  install_omp_branch_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  printf 'on\n' > "$home/config/omp-supervision-branch"
  printf '%s\n' "$$" > "$home/state/.lock"
  make_omp_ancestry_ps "$TMP_ROOT/f7-ps" "$$"
  seed_branch_eligible_wake "$home" task-1 7
  # The branch prompt settles WITHOUT a durable report: the offer's settlement
  # must reject so the watcher delivers the wake to main (F7).
  out=$(EXT="$repo/.omp/extensions/fm-omp-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" PATH="$TMP_ROOT/f7-ps:$PATH" SETTLE_MS=2000 \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module 2>&1 <<'EOF'
await eval(`(async () => { ${process.env.DRIVER_PRELUDE}; globalThis.__t = { dispatch, fire, settled, sentToMain, ctx, branchPrompts }; })()`);
const { dispatch, fire, settled, sentToMain, ctx, branchPrompts } = globalThis.__t;
await fire("session_start", {}, ctx);
await settled();
const offer = dispatch("signal: task-1 done");
if (!offer.accepted) { console.log("declined"); process.exit(1); }
try { await offer.settlement; console.log(`settled sent=${sentToMain.length}`); }
catch (error) { console.log(`rejected prompts=${branchPrompts.length}: ${error instanceof Error ? error.message : error}`); }
EOF
)
  case "$out" in
    "rejected prompts=1: "*"produced no durable outcome"*) ;;
    *) fail "a branch prompt with no durable report did not reject to main after exactly one prompt: $out" ;;
  esac
  pass "F7: a wake the branch cannot durably report hands its settlement back to the watcher for main delivery"
}

test_f7_handled_wake_writes_outcome_and_never_reaches_main() {
  local repo home out
  repo="$TMP_ROOT/f7b-repo"
  home="$TMP_ROOT/f7b-home"
  install_omp_branch_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  printf 'on\n' > "$home/config/omp-supervision-branch"
  printf '%s\n' "$$" > "$home/state/.lock"
  make_omp_ancestry_ps "$TMP_ROOT/f7b-ps" "$$"
  seed_branch_eligible_wake "$home" task-1 7
  seed_branch_eligible_wake "$home" task-1 11
  out=$(EXT="$repo/.omp/extensions/fm-omp-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" PATH="$TMP_ROOT/f7b-ps:$PATH" PROMPT_BEHAVIOR=report-routine SETTLE_MS=2000 \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module 2>&1 <<'EOF'
await eval(`(async () => { ${process.env.DRIVER_PRELUDE}; globalThis.__t = { dispatch, fire, settled, sentToMain, ctx }; })()`);
const { dispatch, fire, settled, sentToMain, ctx } = globalThis.__t;
await fire("session_start", {}, ctx);
await settled();
const offer = dispatch("signal: task-1 done");
if (!offer.accepted) { console.log("declined"); process.exit(1); }
try { await offer.settlement; console.log(`settled rawWakeOnMain=${sentToMain.filter((m) => String(m.content).includes("signal: task-1 done")).length}`); }
catch (error) { console.log(`rejected: ${error instanceof Error ? error.message : error}`); }
EOF
)
  [ "$out" = "settled rawWakeOnMain=0" ] || fail "a handled wake did not settle on the branch path without reaching main: $out"
  [ -e "$home/state/branch-outcomes.jsonl" ] || fail "the handled wake wrote no durable outcome: $out"
  jq -e -s 'length > 0 and all(.task == "task-1" and .verdict == "routine")' "$home/state/branch-outcomes.jsonl" >/dev/null \
    || fail "the outcome store does not hold the handled task-1 report: $(cat "$home/state/branch-outcomes.jsonl")"
  pass "F7's inverse: a wake the branch reports never reaches main as a wake and lands in the durable store"
}

# --- report-only mode -----------------------------------------------------------

test_report_only_refuses_mutating_commands_and_writes_shadow_log() {
  local repo home out
  repo="$TMP_ROOT/ro-repo"
  home="$TMP_ROOT/ro-home"
  install_omp_branch_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  printf 'report-only\n' > "$home/config/omp-supervision-branch"
  printf '%s\n' "$$" > "$home/state/.lock"
  make_omp_ancestry_ps "$TMP_ROOT/ro-ps" "$$"
  seed_branch_eligible_wake "$home" task-1 7
  out=$(EXT="$repo/.omp/extensions/fm-omp-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" PATH="$TMP_ROOT/ro-ps:$PATH" PROMPT_BEHAVIOR=report-routine SETTLE_MS=400 \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module 2>&1 <<'EOF'
await eval(`(async () => { ${process.env.DRIVER_PRELUDE}; globalThis.__t = { fire, settled, createdSessions, sentToMain, tools, ctx, shadow }; })()`);
const { fire, settled, ctx, shadow, createdSessions, tools } = globalThis.__t;
await fire("session_start", {}, ctx);
await settled();
const shadowRows = ["1\t2\tsignal\ttask-1.status\tsignal: task-1 done"];
shadow("signal: task-1 done", shadowRows);
for (let i = 0; i < 40 && createdSessions.length === 0; i += 1) await settled();
console.log(`created=${createdSessions.length}`);
const bashTool = createdSessions.at(-1)?.customTools?.find((t) => t.name === "bash");
if (!bashTool) { console.log("no branch session"); process.exit(1); }
const blocked = await bashTool.execute("t1", { command: "bin/fm-send.sh task-1 hello" }, () => {}, {}, undefined);
const allowed = await bashTool.execute("t2", { command: "echo actor-ok" }, () => {}, {}, undefined);
console.log(`blocked=${blocked.content[0].text}`);
console.log(`allowed=${allowed.isError ? "isError" : "ok"}`);
console.log(`tools=${[...tools.keys()].join(",")}`);
EOF
)
  case "$out" in
    *"report-only: refused"*) ;;
    *) fail "report-only did not refuse a mutating command: $out" ;;
  esac
  case "$out" in
    *"allowed=ok"*) ;;
    *) fail "report-only refused a read-only command: $out" ;;
  esac
  case "$out" in
    *"tools=") ;;
    *) fail "report-only registered main-facing tools: $out" ;;
  esac
  [ -e "$home/state/omp-branch-shadow.jsonl" ] || fail "report-only produced no shadow log"
  grep -q 'refused' "$home/state/omp-branch-shadow.jsonl" || fail "the shadow log did not record the refusal"
  [ ! -e "$home/state/branch-outcomes.jsonl" ] || fail "report-only wrote the real outcome store"
  pass "report-only refuses mutating commands, allows read-only ones, writes the shadow log, and registers no main-facing tools"
}

test_report_only_shadow_records_intended_verdict() {
  local repo home out
  repo="$TMP_ROOT/ro2-repo"
  home="$TMP_ROOT/ro2-home"
  install_omp_branch_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  printf 'report-only\n' > "$home/config/omp-supervision-branch"
  printf '%s\n' "$$" > "$home/state/.lock"
  make_omp_ancestry_ps "$TMP_ROOT/ro2-ps" "$$"
  seed_branch_eligible_wake "$home" task-1 7
  out=$(EXT="$repo/.omp/extensions/fm-omp-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" PATH="$TMP_ROOT/ro2-ps:$PATH" PROMPT_BEHAVIOR=report-routine SETTLE_MS=400 \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module 2>&1 <<'EOF'
await eval(`(async () => { ${process.env.DRIVER_PRELUDE}; globalThis.__t = { fire, settled, createdSessions, sentToMain, ctx, shadow }; })()`);
const { fire, settled, ctx, shadow, createdSessions, sentToMain } = globalThis.__t;
await fire("session_start", {}, ctx);
await settled();
shadow("signal: task-1 done", ["1\t2\tsignal\ttask-1.status\tsignal: task-1 done"]);
for (let i = 0; i < 40 && createdSessions.length === 0; i += 1) await settled();
console.log(`created=${createdSessions.length}`);
const report = createdSessions.at(-1)?.customTools?.find((t) => t.name === "fm_branch_report");
if (!report) { console.log("no report tool"); process.exit(1); }
const result = await report.execute("t1", { task: "task-1", verdict: "routine", summary: "WOULD: steer worker per playbook" });
console.log(`report=${result.content[0].text}`);
console.log(`main=${sentToMain.length}`);
EOF
)
  grep -q 'WOULD: steer worker per playbook' "$home/state/omp-branch-shadow.jsonl" \
    || fail "the shadow log does not record the intended verdict: $out"
  case "$out" in
    *"report-only shadow log"*) ;;
    *) fail "the report tool did not confirm the shadow write: $out" ;;
  esac
  [ ! -e "$home/state/branch-outcomes.jsonl" ] || fail "report-only wrote the real outcome store"
  pass "report-only records the would-do report in the shadow log and writes no real outcome"
}

# Each refused command is one bash splits differently from the classifier's
# quote masking, or one that runs a second program through an allowlisted one.
test_report_only_classifier_refuses_bash_quoting_bypasses() {
  local out
  out=$(LIB="$ROOT/.omp/extensions/lib/fm-omp-branch.ts" node --input-type=module 2>&1 <<'EOF'
const { pathToFileURL } = await import("node:url");
const { readOnlyCommandRefusal } = await import(pathToFileURL(process.env.LIB).href);
const refused = [
  String.raw`echo \'; bin/fm-send.sh task-1 hi; echo \'`,
  String.raw`grep "a\"b" f; bin/fm-lease.sh claim t; echo "c"`,
  String.raw`echo \' > x \'`,
  String.raw`echo \' & bin/fm-send.sh task-1 hi \'`,
  `echo 'unpaired; bin/fm-send.sh task-1 hi`,
  `echo "unpaired; bin/fm-send.sh task-1 hi`,
  "rg --pre ./run.sh pattern .",
  "rg --pre=./run.sh pattern .",
  "sort --compress-program=./run.sh f",
  "echo #'\ntouch /tmp/x\n#'",
  "echo ok # trailing",
  "cat f\nbin/fm-send.sh task-1 hi",
  "cat f\rbin/fm-send.sh task-1 hi",
  "sort -o out f",
  "sort -no out f",
  "sort --output=out f",
  "sort --o=out f",
  "sort --comp=./run.sh f",
  `sort -"o"out f`,
  "sed -i s/a/b/ f",
  "sed --in s/a/b/ f",
  "sed --in-place s/a/b/ f",
  "sed -e1wout f",
  "sed --expression=1wout f",
  "sed -f script.sed f",
  "sed -n 1wout f",
  "sed -n 1e/bin/date f",
  "rg --hostname-bin=./run.sh x",
  "sed s/a/b/w/tmp/x f",
  "sed -n s/a/b/w/tmp/x f",
  "sed s=a=b=w/tmp/out f",
  "sed -n s=a=date=e f",
  "sed -n 1,5p f",
  "sort -u f",
  "rg x .",
  "bin/fm-lease.sh claim=x check",
  "PATH=. cat f",
  "BASH_ENV=x.sh bin/fm-peek.sh t1",
];
const allowed = [
  "echo actor-ok", "grep 'a;b' f | wc -l", `echo "it's" 'say "hi"'`, "bin/fm-lease.sh check task-1",
  "bin/fm-crew-state.sh t1", "tail -5 state/t.status", "cd /x && cat f", "grep -n x f 2>/dev/null",
  "grep -n a=b f", "head -3 f | cut -d= -f2",
];
for (const command of refused) if (!readOnlyCommandRefusal(command)) console.log(`allowed a bypass: ${command}`);
for (const command of allowed) if (readOnlyCommandRefusal(command)) console.log(`refused a read-only command: ${command}`);
console.log("checked");
EOF
)
  [ "$out" = "checked" ] || fail "the report-only classifier misjudged a command: $out"
  pass "report-only refuses backslash, quote, comment, multi-line, redirection, background, assignment, and unlisted-program bypasses while allowing read-only commands"
}

test_config_absent_and_off_are_inert
test_f1_walk_owned_but_fm_lock_refuses
test_f1_ownership_rechecked_before_side_effects
test_f2_branch_actor_is_branch_in_its_shell
test_f3_main_refused_while_branch_holds_lease
test_f5_branch_never_loads_extensions
test_f7_failed_branch_wake_returns_to_main
test_f7_handled_wake_writes_outcome_and_never_reaches_main
test_report_only_refuses_mutating_commands_and_writes_shadow_log
test_report_only_shadow_records_intended_verdict
test_report_only_classifier_refuses_bash_quoting_bypasses

# --- the omp watcher's branch offer, driven through the real watch extension --

install_omp_watch_fixture() {  # <repo>
  local repo=$1
  mkdir -p "$repo/.omp/extensions/lib" "$repo/.pi/extensions/lib" "$repo/bin" "$repo/node_modules/typebox"
  cp "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.omp/extensions/lib/fm-omp-branch.ts" "$repo/.omp/extensions/lib/"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" \
    "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
  chmod +x "$repo/bin/fm-operational-input.sh"
  printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/typebox/package.json"
  printf 'export const Type = { Object(p) { return { type: "object", properties: p }; } };\n' > "$repo/node_modules/typebox/index.js"
  # The first arm child queues one branch-eligible signal row and closes with
  # it; every successor stays up, so exactly one wake exists.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
if [ ! -e "${FM_HOME:?}/state/.e2e-fired" ]; then
  : > "$FM_HOME/state/.e2e-fired"
  sleep 1
  printf '7\n' > "$FM_HOME/state/.wake-queue.seq"
  printf '1700000000\t7\tsignal\ttask-1.status\tsignal: task-1 done\n' >> "$FM_HOME/state/.wake-queue"
  printf 'signal: task-1 done\n'
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
}

# <mode> <branch-behavior: accept-resolve|accept-reject|decline>
run_watch_offer_case() {
  local mode=$1 behavior=$2 name repo home
  name="watch-$mode-$behavior"
  repo="$TMP_ROOT/$name/repo"
  home="$TMP_ROOT/$name/home"
  install_omp_watch_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  [ "$mode" = absent ] || printf '%s\n' "$mode" > "$home/config/omp-supervision-branch"
  printf 'project=x\nharness=omp\n' > "$home/state/task-1.meta"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 \
    FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 BEHAVIOR="$behavior" \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
const { pathToFileURL } = await import("node:url");
const { writeFileSync } = await import("node:fs");
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); const listeners = new Map(); const order = []; let tool = null;
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m) { order.push(`main:${m.includes("signal: task-1 done") ? "wake" : "other"}`); },
  events: { on(c, h) { listeners.set(c, h); }, emit(c, d) { listeners.get(c)?.(d); } },
};
// A scripted branch on the bus: what the branch extension would do.
pi.events.on("fm-branch-supervision:dispatch", (offer) => {
  order.push(`offer:eligible=${offer.eligible}`);
  if (process.env.BEHAVIOR === "decline") return;
  offer.accept(process.env.BEHAVIOR === "accept-reject" ? Promise.reject(new Error("no durable report")) : Promise.resolve());
});
pi.events.on("fm-omp-branch-supervision:shadow", (shadow) => {
  order.push(`shadow:rows=${shadow.rows.length}:tasks=${shadow.tasks.join(",")}`);
});
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await tool.execute();
await new Promise((r) => setTimeout(r, 2500));
process.stdout.write(order.join(" "));
process.exit(0);
EOF
}

test_watcher_offers_branch_first_and_falls_back_to_main() {
  local out
  out=$(run_watch_offer_case absent accept-resolve)
  [ "$out" = "main:wake" ] || fail "config absent: the watcher did not deliver straight to main with no offer: $out"
  out=$(run_watch_offer_case on accept-resolve)
  [ "$out" = "offer:eligible=true" ] || fail "mode on: an accepted, settled offer must keep the wake off main: $out"
  out=$(run_watch_offer_case on accept-reject)
  [ "$out" = "offer:eligible=true main:wake" ] || fail "mode on (F7): a rejected branch settlement must hand the wake to main: $out"
  out=$(run_watch_offer_case on decline)
  [ "$out" = "offer:eligible=true main:wake" ] || fail "mode on: a declined offer must fall back to main: $out"
  out=$(run_watch_offer_case report-only accept-resolve)
  [ "$out" = "main:wake shadow:rows=1:tasks=task-1" ] || fail "report-only: main must get the wake first, then the shadow copy, and no offer: $out"
  pass "the omp watcher offers wakes to the branch first under on, falls back to main on rejection or decline, and shadows after main under report-only"
}

test_watcher_offers_branch_first_and_falls_back_to_main
