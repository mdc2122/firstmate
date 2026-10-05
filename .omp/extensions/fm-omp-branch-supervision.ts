// Firstmate supervision branch for the omp (Oh My Pi) primary.
//
// A port of .pi/extensions/fm-branch-supervision.ts. docs/pi-supervision-branch.md
// owns the branch contract (wake eligibility, the outcome store, leases, the
// role partition, the processing request main acknowledges); this header states
// only what differs on omp, and docs/supervision-protocols/omp.md is the
// operator-facing owner of the omp mode switch.
//
// OFF BY DEFAULT. config/omp-supervision-branch selects the mode once per
// process at load (docs/configuration.md "omp supervision branch"):
//   - absent / anything else: this file registers nothing and stays inert, so
//     an omp home behaves exactly as it did before the file existed.
//   - `on`: the omp watcher offers each eligible wake here first; the branch
//     drains its granted rows, handles them under leases, and reports durable
//     outcomes into main, exactly as on Pi.
//   - `report-only`: a shadow. The watcher still delivers every wake to main
//     and also hands a copy here; the branch reasons about it with every
//     mutating command refused, and records what it would have done in
//     state/omp-branch-shadow.jsonl. It never drains, acknowledges, claims a
//     lease, publishes a row grant, or writes the outcome store.
// A mode change on disk after load disables this generation until a restart,
// because the bash lease gate (bin/fm-lease-lib.sh) follows the file live.
//
// Safety guards (report data/omp-second-conversation section 5):
//   F1 ownership: the branch enables only after BOTH this process's own pid
//      walk and `bin/fm-lock.sh owned` (the same identity rule that decides
//      acquisition) confirm this session holds the fleet lock, and re-checks
//      both before every side effect: activation, every branch shell command,
//      every store write, every grant change, every delivery into main.
//   F2 actor: omp drops spawnHook env for model shells, so the branch's bash is
//      its own tool that runs every command behind a readonly
//      FM_SUPERVISION_ACTOR=branch prefix.
//   F3 main's actor: bin/fm-lease-lib.sh treats an omp tool shell (OMPCODE=1)
//      as a lease context while this home's mode is `on`, so main's shell
//      reads a live branch lease as live and is refused.
//   F4 /restart: stored outcomes reconcile at every owning session start, and
//      bin/fm-session-start.sh runs the lease sweep and startup replay on omp
//      when the mode is not off; the watcher's replacement handoff replays an
//      unfinished wake.
//   F5 one watcher: the branch session disables extension discovery and binds
//      no extension, so it can never load the watcher or turn-end guard.
//   F6 async: nothing on the delivery path runs a synchronous child process;
//      every script call is awaited (lib/fm-async-exec.ts).
//   F7 hand-back: every accepted wake that cannot reach a working branch, or
//      whose prompt settles without a durable report, rejects its settlement
//      to the watcher, which delivers the wake to main.
//
// Outcome visibility: omp has no entry renderer, and a displayed custom
// message enters model context. Captain outcomes therefore persist as one
// sequence-keyed appendEntry record (durable, idempotent, out of context) and
// show in a widget above the editor until main acknowledges them; main
// processes them through the same typed processing request as on Pi. Routine
// outcomes stay rendered sailboat notes (display:true custom messages), except
// a silent one: unlike Pi, where only a no-change fleet heartbeat may be
// silent, the omp branch may mark any routine outcome that reports no state
// change (a worker still working, nothing new) silent. A silent row is stored
// and marked read like any other but sends nothing into main's conversation,
// so it never reaches the captain's screen or main's context; main still reads
// it on demand through fm_branch_outcomes.
//
// Model and effort: config/supervision-branch-model is resolved through omp's
// own ctx.models; config/supervision-branch-effort is applied as the branch's
// thinking level. Absent pins follow main's current model and effort.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "typebox";
import { runCommandAsync } from "../../.pi/extensions/lib/fm-async-exec.ts";
import {
  activateEligibleRowsOwner,
  deactivateEligibleRowsOwner,
  FM_BRANCH_DISPATCH_EVENT,
  releaseEligibleRowsSnapshot,
  scopeForUnreadWake,
  writeEligibleRowsSnapshot,
  type BranchDispatchOffer,
} from "../../.pi/extensions/lib/fm-branch-dispatch.ts";
import {
  classifyFirstmateOperationalTextWith,
  encodeFirstmateOperationalInputWith,
} from "../../.pi/extensions/lib/fm-operational-input.ts";
import {
  FM_OMP_BRANCH_SHADOW_EVENT,
  readOmpBranchMode,
  readOnlyCommandRefusal,
  type OmpBranchMode,
  type OmpBranchShadowWake,
} from "./lib/fm-omp-branch.ts";

// --- the omp API surface this file uses, declared locally (omp ships no type
// package; the watcher extension makes the same choice) -----------------------
type SessionEntryLike = {
  type: string;
  customType?: string;
  data?: unknown;
  message?: { role?: string; content?: unknown; stopReason?: string; errorMessage?: string };
};
type ReadonlyEntries = {
  getSessionFile(): string | undefined;
  getEntries(): SessionEntryLike[];
};
type BranchAgentSession = {
  prompt(text: string): Promise<unknown>;
  sendCustomMessage(message: { customType: string; content: string; display: boolean }, options?: Record<string, unknown>): Promise<unknown>;
  dispose(): unknown;
};
type OmpSdk = {
  createAgentSession(options: Record<string, unknown>): Promise<{ session: BranchAgentSession }>;
  SessionManager: { create(cwd: string, sessionDir?: string): ReadonlyEntries };
  AgentRegistry: new () => unknown;
};
type ModelQuery = { resolve(spec: string): unknown; current(): unknown };
type MainContext = {
  sessionManager?: ReadonlyEntries;
  models?: ModelQuery;
  model?: unknown;
  agent?: { kind?: string };
  ui?: { setWidget?(key: string, content: string[] | undefined): void };
};
type ToolResult = { content: Array<{ type: "text"; text: string }>; details?: unknown; isError?: boolean };
// omp treats an unmarked tool object passed as a session customTool as its
// CustomTool shape, whose execute receives the abort signal fifth, after
// onUpdate and the tool context (verified live, omp 18.4.4: a third-argument
// signal arrived as the update callback). The two main-session tools
// registered through pi.registerTool read only their params, so the same
// local type covers them without depending on argument order.
type ToolDefinition = {
  name: string;
  label: string;
  description: string;
  parameters: unknown;
  execute(toolCallId: string, params: Record<string, unknown>, onUpdate?: unknown, ctx?: unknown, signal?: AbortSignal): Promise<ToolResult>;
};
type ExtensionAPI = {
  on?: (event: string, handler: (event: unknown, ctx: MainContext | undefined) => unknown) => void;
  events?: { on(channel: string, handler: (data: unknown) => void): unknown };
  registerTool?: (tool: ToolDefinition & { promptSnippet?: string }) => void;
  sendMessage: (message: { customType: string; content: string; display: boolean; details?: unknown }, options?: Record<string, unknown>) => unknown;
  appendEntry: (customType: string, data?: unknown) => void;
  getThinkingLevel?: () => string | undefined;
  pi?: OmpSdk;
};

type Verdict = "routine" | "captain";
type OutcomeRow = { seq: number; task: string; verdict: Verdict; summary: string; silent: boolean };
type MirrorItem = { tag: "captain" | "main"; text: string };
type MirrorCursor = { file: string; index: number };

const extensionFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionFile), "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const afkFlag = join(state, ".afk");
const sessionsDir = join(state, "branch-session");
const sessionPointer = join(state, ".branch-session");
const mirrorCursorFile = join(state, ".branch-mirror-cursor");
const shadowLog = join(state, "omp-branch-shadow.jsonl");
const loadedMarker = join(state, ".omp-branch-extension-loaded");
const promptScript = join(fmRoot, "bin", "fm-branch-prompt.sh");
const outcomeScript = join(fmRoot, "bin", "fm-branch-outcome.sh");
const leaseScript = join(fmRoot, "bin", "fm-lease.sh");
const lockScript = join(fmRoot, "bin", "fm-lock.sh");
const wakeGrantScript = join(fmRoot, "bin", "fm-wake-grant.sh");
const modelPinFile = join(config, "supervision-branch-model");
const effortPinFile = join(config, "supervision-branch-effort");

// Same tool set in the same order on every request (part of the cached prefix).
const BRANCH_TOOL_NAMES = ["read", "bash", "fm_branch_report"] as const;
const branchCacheKey = `fm-branch-${createHash("sha256").update(fmHome).digest("hex").slice(0, 24)}`;
const MIRROR_MESSAGE_CAP = 4000;
const MERGE_NOTE_BOAT = "⛵";
const VISIBLE_OUTCOME_ANCHOR = "⚓";
const VISIBLE_OUTCOME_ENTRY_TYPE = "fm-branch-visible-outcome";
const OUTCOME_WIDGET_KEY = "fm-branch-outcomes";
const PROCESSING_MESSAGE_TYPE = "fm-branch-process";
const PROCESSING_TRIGGERED_ATTEMPTS = 2;
const PROVIDER_ERROR_LATCH_THRESHOLD = 2;
const PROVIDER_REPROBE_BASE_MS = 5 * 60 * 1000;
const PROVIDER_REPROBE_MAX_MS = 60 * 60 * 1000;
const BASH_DEFAULT_TIMEOUT_S = 600;
const BASH_OUTPUT_CAP = 256 * 1024;
const LOCK_ANCESTRY_DEPTH = 8;
const PROCESSING_INSTRUCTION =
  "This is a supervision processing request delivered automatically by the supervision branch. " +
  "It was not typed by the captain. " +
  "The outcomes below are already stored durably and already shown to the captain in the supervision outcomes panel; each fleet event is already handled, so do not re-drain, re-run, or acknowledge the wake. " +
  "Process each outcome now as firstmate: give the captain a visible response where one is due, answer or escalate a decision, act on a blocker or failure, or record that no further action is needed. " +
  "When every outcome below is processed, call fm_branch_processed with through={N} exactly once. " +
  "Until that call the outcomes stay open and are presented again; an answer that does not make that call never counts as processing.";
const REPORT_ONLY_INSTRUCTION =
  "REPORT-ONLY SHADOW: MAIN is handling this same wake right now. Do not run bin/fm-wake-drain.sh, acknowledge, claim leases, steer, control, or change any record; " +
  "every mutating command is refused. Read what you need, decide exactly what you would do, then call fm_branch_report once per affected task with the verdict you would give " +
  "and a summary that starts with WOULD: and names each command you would run. The queued rows this wake carries are below.";

const scriptEnv = {
  ...process.env,
  FM_HOME: fmHome,
  FM_ROOT_OVERRIDE: fmRoot,
  FM_STATE_OVERRIDE: state,
  FM_CONFIG_OVERRIDE: config,
};

function textOfContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((part) => (part && typeof part === "object" && "text" in part && typeof part.text === "string" ? part.text : ""))
    .filter(Boolean)
    .join("\n");
}

function parseOutcomeRow(value: unknown): OutcomeRow | null {
  if (!value || typeof value !== "object") return null;
  const row = value as Record<string, unknown>;
  if (typeof row.seq !== "number" || !Number.isSafeInteger(row.seq) || row.seq < 1) return null;
  if (typeof row.task !== "string" || !row.task) return null;
  if (row.verdict !== "routine" && row.verdict !== "captain") return null;
  if (typeof row.summary !== "string" || !row.summary) return null;
  if (row.silent !== undefined && typeof row.silent !== "boolean") return null;
  const silent = row.silent === true;
  if (silent && row.verdict !== "routine") return null;
  return { seq: row.seq, task: row.task, verdict: row.verdict, summary: row.summary, silent };
}

function parseRows(stdout: string): OutcomeRow[] | null {
  const rows: OutcomeRow[] = [];
  for (const line of stdout.split("\n")) {
    if (!line) continue;
    let row: OutcomeRow | null;
    try {
      row = parseOutcomeRow(JSON.parse(line));
    } catch {
      row = null;
    }
    if (!row) return null;
    rows.push(row);
  }
  return rows;
}

function sameOutcome(left: OutcomeRow, right: OutcomeRow): boolean {
  return left.seq === right.seq && left.task === right.task && left.verdict === right.verdict &&
    left.summary === right.summary && left.silent === right.silent;
}

function readPin(file: string): string {
  try {
    return (readFileSync(file, "utf8").split("\n")[0] ?? "").trim();
  } catch {
    return "";
  }
}

function readMirrorCursor(): MirrorCursor {
  try {
    const parsed = JSON.parse(readFileSync(mirrorCursorFile, "utf8")) as Partial<MirrorCursor>;
    if (typeof parsed.file === "string" && typeof parsed.index === "number" && parsed.index >= 0) {
      return { file: parsed.file, index: Math.floor(parsed.index) };
    }
  } catch {
    // Absent or torn: re-mirror the current main session from its start.
  }
  return { file: "", index: 0 };
}

function capMirrorText(text: string): string {
  if (text.length <= MIRROR_MESSAGE_CAP) return text;
  const head = Math.ceil(MIRROR_MESSAGE_CAP / 2);
  return `${text.slice(0, head)}\n[mirror truncated: ${text.length - MIRROR_MESSAGE_CAP} characters omitted]\n${text.slice(-(MIRROR_MESSAGE_CAP - head))}`;
}

// This process's own ancestry walk to the session-lock pid, awaited so it never
// stops the TUI. It is one of the two ownership answers; bin/fm-lock.sh owned is
// the other, and both must agree.
async function pidWalkOwnsLock(): Promise<string> {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "";
  let pid = String(process.pid);
  for (let i = 0; i < LOCK_ANCESTRY_DEPTH; i += 1) {
    if (pid === lockPid) return lockPid;
    const result = await runCommandAsync("ps", ["-o", "ppid=", "-p", pid]);
    pid = result.status === 0 ? result.stdout.trim() : "";
    if (!pid || pid === "1") break;
  }
  return "";
}

// The branch's own shell. omp drops a spawnHook's env for model shells, so the
// actor identity rides a readonly command prefix that the command itself cannot
// silently undo (F2). Ownership is re-checked before every command (F1), and
// report-only refuses anything the read-only classifier cannot prove harmless.
function runBranchShell(command: string, timeoutSeconds: number, leaseHolderPid: string, signal?: AbortSignal): Promise<{ code: number | null; output: string }> {
  const prefixed = `export FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=${leaseHolderPid}
readonly FM_SUPERVISION_ACTOR FM_LEASE_HOLDER_PID
(
${command}
)`;
  return new Promise((resolveRun) => {
    let output = "";
    let truncated = false;
    let settled = false;
    const child = spawn("bash", ["-c", prefixed], {
      cwd: fmRoot,
      env: { ...scriptEnv, FM_SUPERVISION_ACTOR: "branch", FM_LEASE_HOLDER_PID: leaseHolderPid },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const finish = (code: number | null, extra = ""): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      resolveRun({ code, output: `${output}${truncated ? "\n[output truncated]" : ""}${extra}` });
    };
    const collect = (chunk: Buffer): void => {
      if (output.length >= BASH_OUTPUT_CAP) {
        truncated = true;
        return;
      }
      output += chunk.toString();
    };
    const abort = (): void => {
      child.kill("SIGTERM");
      finish(null, "\n[command aborted]");
    };
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      finish(null, `\n[command timed out after ${timeoutSeconds}s]`);
    }, timeoutSeconds * 1000);
    signal?.addEventListener("abort", abort);
    child.stdout.on("data", collect);
    child.stderr.on("data", collect);
    child.on("error", (error) => finish(null, `\n${error.message}`));
    child.on("close", (code) => finish(code));
  });
}

export default function (pi: ExtensionAPI) {
  const mode: OmpBranchMode = readOmpBranchMode(config);
  if (mode === "off") return;
  const reportOnly = mode === "report-only";

  type BranchSession = { session: BranchAgentSession; sessionManager: ReadonlyEntries; generation: number };
  let branch: BranchSession | null = null;
  let branchBroken = "";
  let consecutiveProviderErrors = 0;
  let providerRecovery: { cooldownMs: number; retryNotBefore: number; probeInFlight: boolean } | null = null;
  let durableReportRevision = 0;
  let wakeTaskScope: { rows: string[]; tasks: Set<string> } | null = null;
  let mainStreaming = false;
  let shuttingDown = false;
  // A helper session (an in-process task subagent) binds this factory again and
  // must stay inert; only the top-level session supervises.
  let helper = false;
  let generation = 0;
  let activatedGeneration = -1;
  let ownedLockPid = "";
  let branchChain: Promise<void> = Promise.resolve();
  let deliveryChain: Promise<void> = Promise.resolve();
  let currentMainSession: ReadonlyEntries | null = null;
  let mainContext: MainContext | null = null;
  type ProcessingState = { sequences: string; through: number; triggered: number; pending: boolean; nextTurnQueued: boolean };
  let processing: ProcessingState | null = null;
  let processedInitializedGeneration = -1;
  const pendingMirror: MirrorItem[] = [];
  const mirrorCollection: {
    collectAnchor: MirrorCursor | null;
    pendingCursor: MirrorCursor | null;
    stagedCaptain: { file: string; index: number; text: string } | null;
    reanchor: boolean;
  } = { collectAnchor: null, pendingCursor: null, stagedCaptain: null, reanchor: true };

  function enqueueDelivery<T>(unit: () => Promise<T>): Promise<T> {
    const queued = deliveryChain.then(unit);
    deliveryChain = queued.then(() => {}, () => {});
    return queued;
  }

  function rememberMain(ctx: MainContext | undefined): void {
    if (!ctx) return;
    mainContext = ctx;
    if (ctx.sessionManager) currentMainSession = ctx.sessionManager;
  }

  // F1. Both answers, uncached, at every boundary that asks: this process's
  // pid walk and bin/fm-lock.sh's own identity check. A mode change on disk
  // also ends this generation's authority (see the header).
  async function generationOwnsLock(expectedGeneration: number): Promise<boolean> {
    if (helper || shuttingDown || expectedGeneration !== generation) return false;
    if (readOmpBranchMode(config) !== mode) return false;
    const walked = await pidWalkOwnsLock();
    if (!walked) return false;
    const confirmed = await runCommandAsync("bash", [lockScript, "owned"], { cwd: fmRoot, env: scriptEnv });
    if (confirmed.status !== 0) return false;
    ownedLockPid = walked;
    return !shuttingDown && expectedGeneration === generation;
  }

  async function actingAsOwner(expectedGeneration = generation): Promise<boolean> {
    if (!(await generationOwnsLock(expectedGeneration))) return false;
    if (activatedGeneration !== expectedGeneration) {
      if (!reportOnly) {
        const released = await runCommandAsync("bash", [leaseScript, "release-actor", "--actor", "branch"], {
          cwd: fmRoot,
          env: { ...scriptEnv, FM_SUPERVISION_ACTOR: "branch" },
        });
        if (released.status !== 0 || !(await generationOwnsLock(expectedGeneration))) return false;
        if (!(await activateEligibleRowsOwner(state, wakeGrantScript, process.pid, String(expectedGeneration)))) return false;
        if (!(await generationOwnsLock(expectedGeneration))) {
          await deactivateEligibleRowsOwner(state, wakeGrantScript, process.pid, String(expectedGeneration));
          return false;
        }
      }
      try {
        mkdirSync(state, { recursive: true });
        writeFileSync(loadedMarker, `${mode}\n${process.pid}\n`);
      } catch {
        // Diagnostic marker only.
      }
      activatedGeneration = expectedGeneration;
    }
    return generationOwnsLock(expectedGeneration);
  }

  async function runOutcomeScript(args: string[]): Promise<{ ok: boolean; stdout: string; detail: string }> {
    const result = await runCommandAsync("bash", [outcomeScript, ...args], { cwd: fmRoot, env: scriptEnv });
    if (result.status === 0) return { ok: true, stdout: (result.stdout || "").trim(), detail: "" };
    return { ok: false, stdout: "", detail: `fm-branch-outcome.sh exited ${result.status ?? "none"}: ${(result.stderr || "").trim()}` };
  }

  function shadowRecord(record: Record<string, unknown>): void {
    mkdirSync(state, { recursive: true });
    appendFileSync(shadowLog, `${JSON.stringify({ epoch: Math.floor(Date.now() / 1000), ...record })}\n`);
  }

  function deliverNote(text: string): void {
    const message = { customType: "fm-branch-merge", content: `${MERGE_NOTE_BOAT} ${text}`, display: true };
    pi.sendMessage(message, mainStreaming ? { deliverAs: "nextTurn" } : {});
  }

  function recordSettledProviderError(detail: string): void {
    consecutiveProviderErrors += 1;
    if (consecutiveProviderErrors < PROVIDER_ERROR_LATCH_THRESHOLD && !providerRecovery) return;
    const firstLatch = !providerRecovery;
    const cooldownMs = firstLatch ? PROVIDER_REPROBE_BASE_MS : Math.min(PROVIDER_REPROBE_MAX_MS, providerRecovery!.cooldownMs * 2);
    branchBroken = detail;
    providerRecovery = { cooldownMs, retryNotBefore: Date.now() + cooldownMs, probeInFlight: false };
    if (firstLatch && !reportOnly) deliverNote("Supervision branch paused after repeated provider errors; main will handle wakes while it cools down.");
  }

  function recordDurableBranchReport(reportGeneration: number): void {
    if (reportGeneration !== generation) return;
    consecutiveProviderErrors = 0;
    if (!providerRecovery) return;
    branchBroken = "";
    providerRecovery = null;
    if (!reportOnly) deliverNote("Supervision branch recovered after a successful cooldown probe.");
  }

  // --- captain visibility: a durable out-of-context record plus a widget -----
  function visibleRecordExists(row: OutcomeRow): boolean | null {
    if (!currentMainSession) return null;
    let matching = false;
    for (const entry of currentMainSession.getEntries()) {
      if (entry.type !== "custom" || entry.customType !== VISIBLE_OUTCOME_ENTRY_TYPE) continue;
      const data = entry.data as { version?: unknown; seq?: unknown } | undefined;
      if (!data || data.seq !== row.seq) continue;
      const recorded = data.version === 1 ? parseOutcomeRow(data) : null;
      if (!recorded || !sameOutcome(recorded, row)) return null;
      matching = true;
    }
    return matching;
  }

  function ensureVisibleCaptainOutcome(row: OutcomeRow): boolean {
    const exists = visibleRecordExists(row);
    if (exists === null) return false;
    if (exists) return true;
    try {
      pi.appendEntry(VISIBLE_OUTCOME_ENTRY_TYPE, { version: 1, ...row });
    } catch {
      return false;
    }
    return visibleRecordExists(row) === true;
  }

  function renderOutcomeWidget(rows: OutcomeRow[]): void {
    const lines = rows.map((row) => `${VISIBLE_OUTCOME_ANCHOR} [seq ${row.seq}] ${row.task}: ${row.summary}`);
    try {
      mainContext?.ui?.setWidget?.(OUTCOME_WIDGET_KEY, lines.length > 0 ? lines : undefined);
    } catch {
      // The widget is presentation; the durable record and processing request
      // carry the outcome either way.
    }
  }

  async function readUnprocessedOutcomes(expectedGeneration: number): Promise<OutcomeRow[] | null> {
    if (!(await generationOwnsLock(expectedGeneration))) return null;
    const listed = await runOutcomeScript(["unprocessed"]);
    if (!listed.ok) return null;
    const rows = parseRows(listed.stdout);
    if (!rows || rows.some((row) => row.verdict !== "captain")) return null;
    return rows;
  }

  async function presentUnprocessedOutcomes(expectedGeneration: number): Promise<boolean> {
    const rows = await readUnprocessedOutcomes(expectedGeneration);
    if (rows === null) return false;
    renderOutcomeWidget(rows);
    if (rows.length === 0) {
      processing = null;
      return true;
    }
    const through = rows[rows.length - 1].seq;
    const sequences = rows.map((row) => row.seq).join(",");
    if (processing?.pending) return true;
    const listed = rows.map((row) => `[seq ${row.seq}] ${row.task}: ${row.summary}`).join("\n");
    const body = `${PROCESSING_INSTRUCTION.replace("{N}", String(through))}\n\n${listed}`;
    let content = body;
    try {
      content = await encodeFirstmateOperationalInputWith(runCommandAsync, "branch-outcome", body);
    } catch {
      // An untyped request main can still act on beats an unprocessed outcome.
    }
    if (!(await generationOwnsLock(expectedGeneration))) return false;
    if (processing?.pending) return true;
    if (!processing || processing.sequences !== sequences) {
      processing = { sequences, through, triggered: 0, pending: false, nextTurnQueued: false };
    }
    const message = { customType: PROCESSING_MESSAGE_TYPE, content, display: false };
    if (processing.triggered < PROCESSING_TRIGGERED_ATTEMPTS) {
      processing.triggered += 1;
      processing.pending = true;
      pi.sendMessage(message, { triggerTurn: true, deliverAs: "followUp" });
    } else if (!processing.nextTurnQueued) {
      processing.nextTurnQueued = true;
      processing.pending = true;
      pi.sendMessage(message, { deliverAs: "nextTurn" });
    }
    return true;
  }

  // Store order, cursor barrier, and replay semantics are the Pi contract
  // (docs/pi-supervision-branch.md "Two-stage noise filter").
  async function reconcileUnreadOutcomes(expectedGeneration: number, present = true): Promise<boolean> {
    if (!(await generationOwnsLock(expectedGeneration))) return false;
    if (processedInitializedGeneration !== expectedGeneration) {
      if (!(await runOutcomeScript(["processed-init"])).ok) return false;
      processedInitializedGeneration = expectedGeneration;
    }
    const unread = await runOutcomeScript(["unread"]);
    if (!unread.ok) return false;
    const rows = parseRows(unread.stdout);
    if (rows === null) return false;
    if (rows.length > 0 && !currentMainSession) return false;
    for (const row of rows) {
      if (!(await generationOwnsLock(expectedGeneration))) return false;
      if (row.verdict === "captain") {
        if (!ensureVisibleCaptainOutcome(row)) return false;
      } else if (!row.silent) {
        deliverNote(`${row.task}: ${row.summary}`);
      }
      if (!(await runOutcomeScript(["mark-read", "--through", String(row.seq)])).ok) return false;
    }
    if (!present) return true;
    return presentUnprocessedOutcomes(expectedGeneration);
  }

  function wakeScopeRefusal(task: string): string {
    if (!wakeTaskScope || wakeTaskScope.tasks.has(task)) return "";
    return `report refused: the wake being handled (row ${wakeTaskScope.rows.join(", ")}) names ${[...wakeTaskScope.tasks].sort().join(", ")}, not ${task}; report only that task, never fleet or a task from memory`;
  }

  const textResult = (text: string, isError = false): ToolResult => ({ content: [{ type: "text", text }], details: undefined, ...(isError ? { isError } : {}) });

  function createReportTool(toolGeneration: number, shadowWake: string): ToolDefinition {
    return {
      name: "fm_branch_report",
      label: "Report supervision outcome",
      description: reportOnly
        ? "Record what you would do for one handled fleet event in the report-only shadow log. Nothing reaches the captain or main."
        : "Record the outcome of one handled fleet event: write it durably to the outcome store, then merge it into the captain-facing main conversation. verdict captain records an exact outcome and opens one sequence-keyed processing turn on main that stays open until main acknowledges it; a routine note renders unless silent marks it as reporting no state change, in which case it is stored but never shown.",
      parameters: Type.Object({
        task: Type.String({ description: "The task id the event belongs to (or 'fleet' for fleet-wide events)" }),
        verdict: Type.String({ description: "routine or captain, exactly as the \"Verdict: routine or captain\" section of your system prompt decides" }),
        summary: Type.String({ description: "One or two sentences in captain outcome language; include the full https:// PR URL when a PR is involved" }),
        wake: Type.Optional(Type.String({ description: "The wake reason line this outcome answers" })),
        silent: Type.Optional(Type.Boolean({ description: "Routine only: true when handling found no state change (the worker is working or still working with nothing new, or a heartbeat review found nothing); the outcome is stored but never shown to the captain. Omit whenever anything changed or any action was taken." })),
      }),
      execute: async (_toolCallId, params) => {
        const task = String(params.task ?? "").trim();
        const verdict = String(params.verdict ?? "");
        const summary = String(params.summary ?? "").trim();
        const wake = String(params.wake ?? "").trim();
        const silent = params.silent === true;
        if (!task || !summary || (verdict !== "routine" && verdict !== "captain") || (silent && verdict !== "routine")) {
          if (silent && verdict === "captain") return textResult("invalid report: a captain outcome cannot be silent", true);
          return textResult("invalid report: task, verdict (routine|captain), and summary are required", true);
        }
        const refusal = wakeScopeRefusal(task);
        if (refusal) return textResult(refusal, true);
        return enqueueDelivery(async () => {
          if (!(await actingAsOwner(toolGeneration))) {
            return textResult("report refused: supervision session was replaced or lost lock ownership", true);
          }
          if (reportOnly) {
            try {
              shadowRecord({ type: "report", wake: wake || shadowWake, task, verdict, summary, silent });
            } catch (error) {
              return textResult(`shadow log append failed: ${error instanceof Error ? error.message : String(error)}`, true);
            }
            durableReportRevision += 1;
            return textResult("recorded in the report-only shadow log; nothing was delivered to main");
          }
          const appendArgs = ["append", "--task", task, "--verdict", verdict, "--summary", summary, "--silent", String(silent)];
          if (wake) appendArgs.push("--wake", wake);
          const appended = await runOutcomeScript(appendArgs);
          if (!appended.ok) return textResult(`outcome store append failed (nothing merged): ${appended.detail}`, true);
          durableReportRevision += 1;
          const seq = Number(appended.stdout);
          if (!Number.isSafeInteger(seq) || seq < 1 || !(await reconcileUnreadOutcomes(toolGeneration))) {
            return textResult(`recorded seq ${appended.stdout}, but visible delivery or cursor advancement failed`, true);
          }
          return textResult(`recorded seq ${appended.stdout} and delivered [${verdict}] into main`);
        });
      },
    };
  }

  function createBashTool(toolGeneration: number): ToolDefinition {
    return {
      name: "bash",
      label: "Bash",
      description: "Run a shell command in the firstmate home's code root and return its combined output.",
      parameters: Type.Object({
        command: Type.String({ description: "The command to run" }),
        timeout: Type.Optional(Type.Number({ description: "Timeout in seconds (default 600)" })),
      }),
      execute: async (_toolCallId, params, _onUpdate, _ctx, signal) => {
        // The live-proven argument position above is still an external
        // boundary, so only a genuine AbortSignal is honored.
        const abortSignal = signal instanceof AbortSignal ? signal : undefined;
        const command = String(params.command ?? "");
        if (!command.trim()) return textResult("bash refused: empty command", true);
        if (activatedGeneration !== toolGeneration || !(await generationOwnsLock(toolGeneration))) {
          return textResult("bash refused: supervision session was replaced or lost lock ownership", true);
        }
        if (reportOnly) {
          const refused = readOnlyCommandRefusal(command);
          if (refused) {
            try {
              shadowRecord({ type: "refused", command, reason: refused });
            } catch {
              // The refusal stands even when it cannot be recorded.
            }
            return textResult(`report-only: refused (${refused}); this command would have mutated fleet state - record it as an action you WOULD take in fm_branch_report instead`, true);
          }
        }
        const timeoutRaw = typeof params.timeout === "number" && params.timeout > 0 ? params.timeout : BASH_DEFAULT_TIMEOUT_S;
        const result = await runBranchShell(command, timeoutRaw, ownedLockPid, abortSignal);
        const text = result.output || "(no output)";
        return result.code === 0 ? textResult(text) : textResult(`${text}\n[exit ${result.code ?? "signal"}]`, true);
      },
    };
  }

  async function createBranch(branchGeneration: number, shadowWake: string): Promise<BranchSession> {
    const sdk = pi.pi;
    if (!sdk) throw new Error("omp did not expose its SDK to the extension");
    const prompt = await runCommandAsync("bash", [promptScript, "--harness", "omp"], { cwd: fmRoot, env: scriptEnv, maxBuffer: 4 * 1024 * 1024 });
    if (prompt.status !== 0 || !prompt.stdout || prompt.stdout.length < 1024) {
      throw new Error(`fm-branch-prompt.sh did not produce a usable branch prompt (status=${prompt.status ?? "none"}): ${(prompt.stderr || "").trim()}`);
    }
    if (!(await actingAsOwner(branchGeneration))) throw new Error("supervision session was replaced or lost lock ownership");
    const modelPin = readPin(modelPinFile);
    const models = mainContext?.models;
    const model = modelPin ? models?.resolve(modelPin) : (models?.current() ?? mainContext?.model);
    if (modelPin && !model) throw new Error(`supervision model pin ${modelPin} is unavailable to omp (config/supervision-branch-model)`);
    const effort = readPin(effortPinFile) || pi.getThinkingLevel?.();
    mkdirSync(sessionsDir, { recursive: true });
    const sessionManager = sdk.SessionManager.create(fmRoot, sessionsDir);
    const created = await sdk.createAgentSession({
      cwd: fmRoot,
      sessionManager,
      ...(model ? { model } : {}),
      ...(effort ? { thinkingLevel: effort } : {}),
      agentRegistry: new sdk.AgentRegistry(),
      bindProcessState: false,
      cacheWarming: false,
      // F5: no ambient or project extension ever binds into the branch, so it
      // can never load the watcher or the turn-end guard a second time.
      disableExtensionDiscovery: true,
      enableMCP: false,
      enableLsp: false,
      enableIrc: false,
      skills: [],
      rules: [],
      contextFiles: [],
      promptTemplates: [],
      slashCommands: [],
      systemPrompt: prompt.stdout,
      providerPromptCacheKey: branchCacheKey,
      toolNames: [...BRANCH_TOOL_NAMES],
      restrictToolNames: true,
      allowRestrictedCustomTools: true,
      customTools: [createBashTool(branchGeneration), createReportTool(branchGeneration, shadowWake)],
    });
    if (!(await actingAsOwner(branchGeneration))) {
      try {
        await created.session.dispose();
      } catch {}
      throw new Error("supervision session was replaced or lost lock ownership");
    }
    try {
      writeFileSync(sessionPointer, `${sessionManager.getSessionFile() ?? ""}\n`);
    } catch {
      // Operator-facing pointer only.
    }
    return { session: created.session, sessionManager, generation: branchGeneration };
  }

  async function ensureBranch(expectedGeneration: number, recoveryProbe: boolean, shadowWake: string): Promise<BranchSession> {
    if (!(await actingAsOwner(expectedGeneration))) throw new Error("supervision session was replaced or lost lock ownership");
    if (branchBroken && !(recoveryProbe && providerRecovery?.probeInFlight)) throw new Error(branchBroken);
    if (branch && branch.generation === expectedGeneration) return branch;
    try {
      branch = await createBranch(expectedGeneration, shadowWake);
      return branch;
    } catch (error) {
      if (expectedGeneration === generation && !shuttingDown) branchBroken = error instanceof Error ? error.message : String(error);
      throw error;
    }
  }

  async function collectMainDialog(): Promise<void> {
    const sessionManager = currentMainSession;
    if (!sessionManager) return;
    const file = sessionManager.getSessionFile() ?? "";
    const entries = sessionManager.getEntries();
    const anchor = mirrorCollection.collectAnchor ?? readMirrorCursor();
    const start = mirrorCollection.reanchor || anchor.file !== file ? 0 : Math.min(anchor.index, entries.length);
    mirrorCollection.reanchor = false;
    mirrorCollection.collectAnchor = { file, index: entries.length };
    mirrorCollection.pendingCursor = mirrorCollection.collectAnchor;
    for (let index = start; index < entries.length; index += 1) {
      const message = entries[index].type === "message" ? entries[index].message : undefined;
      if (!message || (message.role !== "user" && message.role !== "assistant")) continue;
      const text = textOfContent(message.content).trim();
      if (!text) continue;
      if (message.role === "user") {
        if (await classifyFirstmateOperationalTextWith(runCommandAsync, text)) continue;
        const staged = mirrorCollection.stagedCaptain;
        if (staged && staged.file === file && staged.index === index && staged.text === text) {
          mirrorCollection.stagedCaptain = null;
          continue;
        }
      }
      pendingMirror.push({ tag: message.role === "user" ? "captain" : "main", text: capMirrorText(text) });
    }
  }

  async function flushMirror(session: BranchAgentSession, expectedGeneration: number): Promise<void> {
    while (pendingMirror.length > 0) {
      if (!(await actingAsOwner(expectedGeneration))) throw new Error("supervision session no longer owns the fleet lock");
      const item = pendingMirror[0];
      await session.sendCustomMessage({ customType: "fm-main-mirror", content: `[${item.tag}] ${item.text}`, display: false }, {});
      pendingMirror.shift();
    }
    if (mirrorCollection.pendingCursor) {
      if (!(await actingAsOwner(expectedGeneration))) throw new Error("supervision session no longer owns the fleet lock");
      writeFileSync(mirrorCursorFile, `${JSON.stringify(mirrorCollection.pendingCursor)}\n`);
      mirrorCollection.pendingCursor = null;
    }
  }

  function settledProviderError(sessionManager: ReadonlyEntries, entryOffset: number): string | null {
    const entries = sessionManager.getEntries();
    for (let index = entries.length - 1; index >= entryOffset; index -= 1) {
      const message = entries[index].type === "message" ? entries[index].message : undefined;
      if (message?.role !== "assistant") continue;
      if (message.stopReason !== "error") return null;
      return message.errorMessage?.trim() || "assistant settled with stopReason error";
    }
    return null;
  }

  // One branch turn. `shadow` carries the report-only payload; without it this
  // is a real wake that claims its rows through the grant first.
  function enqueueWake(message: string, acceptedGeneration: number, recoveryProbe: boolean, shadow: OmpBranchShadowWake | null): Promise<void> {
    let granted = false;
    const delivery = branchChain
      .then(async () => {
        if (shuttingDown || acceptedGeneration !== generation) throw new Error("supervision session was replaced before handling the accepted wake");
        if (!(await enqueueDelivery(() => actingAsOwner(acceptedGeneration)))) throw new Error("supervision session no longer owns the fleet lock");
        if (!reportOnly && !(await enqueueDelivery(() => reconcileUnreadOutcomes(acceptedGeneration)))) {
          if (acceptedGeneration === generation) branchBroken = "could not reconcile unread supervision outcomes into main";
          throw new Error("could not reconcile unread supervision outcomes into main");
        }
        const branchForWake = await ensureBranch(acceptedGeneration, recoveryProbe, message);
        await collectMainDialog();
        await flushMirror(branchForWake.session, acceptedGeneration);
        if (!(await actingAsOwner(acceptedGeneration))) throw new Error("supervision session no longer owns the fleet lock");
        const heartbeat = /^heartbeat($|:)/.test(message);
        let prompt: string;
        if (shadow) {
          wakeTaskScope = shadow.heartbeat ? null : { rows: shadow.rows.map((row) => row.split("\t")[1] ?? ""), tasks: new Set(shadow.tasks) };
          prompt = `FIRSTMATE SUPERVISION WAKE: ${message}\n\n${REPORT_ONLY_INSTRUCTION}\n\n${shadow.rows.join("\n") || "(no branch-eligible rows were queued)"}`;
        } else {
          const scope = scopeForUnreadWake(state, heartbeat);
          if (scope.status === "empty" || (!scope.corrupted && scope.eligibleSeqs.length === 0)) return;
          if (scope.corrupted) throw new Error("the unread wake queue could not be read safely");
          if (!(await actingAsOwner(acceptedGeneration))) throw new Error("supervision session no longer owns the fleet lock");
          const grant = await writeEligibleRowsSnapshot(state, scope.eligibleSeqs, wakeGrantScript, String(acceptedGeneration));
          if (grant === "main-owned") throw new Error("the wake rows are already claimed by main");
          if (grant !== "published") throw new Error("could not record the branch's eligible row snapshot");
          granted = true;
          wakeTaskScope = heartbeat ? null : { rows: [...scope.eligibleSeqs], tasks: new Set(scope.eligibleTasks) };
          prompt = `FIRSTMATE SUPERVISION WAKE: ${message}\n\nHandle this per your operating procedure and finish with fm_branch_report.`;
        }
        const reportRevisionBeforePrompt = durableReportRevision;
        const entryOffset = branchForWake.sessionManager.getEntries().length;
        try {
          await branchForWake.session.prompt(prompt);
        } finally {
          wakeTaskScope = null;
        }
        const providerError = settledProviderError(branchForWake.sessionManager, entryOffset);
        if (providerError) {
          const detail = `supervision branch provider failed: ${providerError}`;
          if (branchForWake.generation === generation) recordSettledProviderError(detail);
          throw new Error(detail);
        }
        if (durableReportRevision <= reportRevisionBeforePrompt) {
          throw new Error("supervision branch prompt settled but produced no durable outcome for its wake");
        }
        recordDurableBranchReport(branchForWake.generation);
        if (granted && !(await releaseEligibleRowsSnapshot(state, wakeGrantScript, String(acceptedGeneration)))) {
          throw new Error("could not release the branch's settled wake-row grant");
        }
      })
      .catch(async (error: unknown) => {
        if (granted) await releaseEligibleRowsSnapshot(state, wakeGrantScript, String(acceptedGeneration));
        throw error;
      })
      .finally(() => {
        if (recoveryProbe && providerRecovery && acceptedGeneration === generation) {
          providerRecovery.probeInFlight = false;
          if (branchBroken && providerRecovery.retryNotBefore <= Date.now()) providerRecovery.retryNotBefore = Date.now() + providerRecovery.cooldownMs;
        }
      });
    branchChain = delivery.catch(() => {});
    return delivery;
  }

  // The recovery-probe gate shared by both offer paths. Returns null when main
  // keeps the wake, else whether this acceptance is a recovery probe.
  function branchAvailable(): boolean | null {
    if (helper || shuttingDown || activatedGeneration !== generation) return null;
    if (existsSync(afkFlag)) return null; // a legacy away daemon flag owns supervision
    const recoveryProbe = Boolean(branchBroken && providerRecovery && !providerRecovery.probeInFlight && Date.now() >= providerRecovery.retryNotBefore);
    if (branchBroken && !recoveryProbe) return null;
    if (recoveryProbe && providerRecovery) providerRecovery.probeInFlight = true;
    return recoveryProbe;
  }

  // accept() must run synchronously (lib/fm-branch-dispatch.ts owns that
  // handshake), and F6 forbids a synchronous child process here. The decision
  // therefore reads only in-memory state set by an activation that already
  // proved ownership through both answers (F1); the settlement then re-proves
  // ownership as its first step and rejects to the watcher's main path (F7) if
  // it cannot.
  pi.events?.on(FM_BRANCH_DISPATCH_EVENT, (data) => {
    if (reportOnly) return;
    const offer = data as BranchDispatchOffer;
    if (!offer || typeof offer.accept !== "function" || offer.eligible !== true) return;
    const recoveryProbe = branchAvailable();
    if (recoveryProbe === null) return;
    offer.accept(enqueueWake(offer.message, generation, recoveryProbe, null));
  });

  // Report-only: the watcher has already delivered this wake to main; the
  // branch only shadows it and never blocks the watcher.
  pi.events?.on(FM_OMP_BRANCH_SHADOW_EVENT, (data) => {
    if (!reportOnly) return;
    const shadow = data as OmpBranchShadowWake;
    if (!shadow || typeof shadow.message !== "string" || !Array.isArray(shadow.rows)) return;
    const recoveryProbe = branchAvailable();
    if (recoveryProbe === null) return;
    void enqueueWake(shadow.message, generation, recoveryProbe, shadow).catch((error: unknown) => {
      try {
        shadowRecord({ type: "unhandled", wake: shadow.message, error: error instanceof Error ? error.message : String(error) });
      } catch {
        // Nothing else to tell: main handled the wake.
      }
    });
  });

  async function activate(expectedGeneration: number): Promise<void> {
    const failed = await enqueueDelivery(async () => {
      if (!(await actingAsOwner(expectedGeneration))) return false;
      return !reportOnly && !(await reconcileUnreadOutcomes(expectedGeneration));
    });
    if (failed && expectedGeneration === generation) branchBroken = "could not reconcile unread supervision outcomes into main";
  }

  pi.on?.("session_start", async (_event, ctx) => {
    if (ctx?.agent?.kind === "sub") {
      helper = true;
      return;
    }
    rememberMain(ctx);
    shuttingDown = false;
    branchBroken = "";
    consecutiveProviderErrors = 0;
    providerRecovery = null;
    generation += 1;
    mirrorCollection.collectAnchor = null;
    mirrorCollection.pendingCursor = null;
    mirrorCollection.stagedCaptain = null;
    mirrorCollection.reanchor = true;
    await activate(generation);
  });

  pi.on?.("before_agent_start", async (event, ctx) => {
    if (helper) return;
    rememberMain(ctx);
    const promptGeneration = generation;
    if (activatedGeneration !== promptGeneration) return;
    await collectMainDialog();
    const prompt = String((event as { prompt?: unknown })?.prompt ?? "").trim();
    if (!prompt || promptGeneration !== generation || !currentMainSession) return;
    if (await classifyFirstmateOperationalTextWith(runCommandAsync, prompt)) return;
    const file = currentMainSession.getSessionFile() ?? "";
    const index = mirrorCollection.collectAnchor?.index ?? currentMainSession.getEntries().length;
    pendingMirror.push({ tag: "captain", text: prompt });
    mirrorCollection.stagedCaptain = { file, index, text: prompt };
  });

  pi.on?.("agent_start", () => {
    if (helper) return;
    mainStreaming = true;
    if (processing) processing.nextTurnQueued = false;
  });

  // omp has no agent_settled; agent_end without willContinue is the run
  // boundary where an ignored processing request is presented again.
  pi.on?.("agent_end", async (event, ctx) => {
    if (helper || (event as { willContinue?: unknown })?.willContinue === true) return;
    rememberMain(ctx);
    mainStreaming = false;
    if (processing) processing.pending = false;
    const settledGeneration = generation;
    // A cold start acquires the lock in its first turn, so a generation that
    // could not activate at session_start activates at the first run boundary.
    if (activatedGeneration !== settledGeneration) {
      await activate(settledGeneration);
      return;
    }
    if (reportOnly) return;
    await enqueueDelivery(async () => {
      if (!(await actingAsOwner(settledGeneration))) return;
      if (!(await reconcileUnreadOutcomes(settledGeneration, false))) {
        if (settledGeneration === generation) branchBroken = "could not reconcile unread supervision outcomes into main";
        return;
      }
      await presentUnprocessedOutcomes(settledGeneration);
    });
  });

  pi.on?.("session_shutdown", async (_event, ctx) => {
    if (helper || ctx?.agent?.kind === "sub") return;
    const closingGeneration = generation;
    shuttingDown = true;
    generation += 1;
    processing = null;
    pendingMirror.length = 0;
    currentMainSession = null;
    mirrorCollection.collectAnchor = null;
    mirrorCollection.pendingCursor = null;
    mirrorCollection.stagedCaptain = null;
    renderOutcomeWidget([]);
    if (branch) {
      try {
        await branch.session.dispose();
      } catch {
        // Already gone.
      }
      branch = null;
    }
    if (!reportOnly) await deactivateEligibleRowsOwner(state, wakeGrantScript, process.pid, String(closingGeneration));
  });

  if (reportOnly) return;

  pi.registerTool?.({
    name: "fm_branch_outcomes",
    label: "Read supervision branch outcomes",
    description: "Read the durable outcome store of the supervision branch: what fleet events it handled, each verdict, and each summary. Use when the captain asks what happened in the fleet.",
    promptSnippet: "Read what the supervision branch handled (durable outcome store).",
    parameters: Type.Object({
      recent: Type.Optional(Type.Number({ description: "How many most-recent outcomes to read (default 20)" })),
    }),
    execute: async (_toolCallId, params) => {
      const recent = typeof params.recent === "number" && params.recent >= 1 ? String(Math.floor(params.recent)) : "20";
      const listed = await enqueueDelivery(() => runOutcomeScript(["list", "--recent", recent]));
      if (!listed.ok) return textResult(`could not read the outcome store: ${listed.detail}`, true);
      return textResult(listed.stdout || "(no branch outcomes recorded)");
    },
  });

  pi.registerTool?.({
    name: "fm_branch_processed",
    label: "Acknowledge processed supervision outcomes",
    description: "Acknowledge that every captain-facing supervision outcome up to a sequence number has been processed by this conversation. Call it exactly once after handling a supervision processing request, with through set to the highest sequence that request listed; an outcome that is not acknowledged is presented again.",
    promptSnippet: "Acknowledge processed captain-facing supervision outcomes by sequence.",
    parameters: Type.Object({
      through: Type.Number({ description: "The highest outcome sequence number this conversation has processed" }),
    }),
    execute: async (_toolCallId, params) => {
      const raw = params.through;
      const through = typeof raw === "number" && Number.isSafeInteger(raw) && raw >= 1 ? raw : null;
      if (through === null) return textResult("acknowledgement refused: through must be a positive outcome sequence number", true);
      const acknowledgedGeneration = generation;
      return enqueueDelivery(async () => {
        if (!(await actingAsOwner(acknowledgedGeneration))) return textResult("acknowledgement refused: this session does not own the fleet lock", true);
        if (!processing || through > processing.through) {
          return textResult(`acknowledgement refused: seq ${through} was not listed in the active processing request`, true);
        }
        const marked = await runOutcomeScript(["mark-processed", "--through", String(through)]);
        if (!marked.ok) return textResult(`acknowledgement refused: ${marked.detail}`, true);
        const remaining = await readUnprocessedOutcomes(acknowledgedGeneration);
        if (remaining !== null) renderOutcomeWidget(remaining);
        if (remaining !== null && remaining.length === 0) processing = null;
        const open = remaining === null
          ? "the remaining outcomes could not be read"
          : remaining.length === 0
            ? "no captain outcome remains unprocessed"
            : `${remaining.length} newer captain outcome(s) remain unprocessed (seq ${remaining.map((row) => row.seq).join(", ")}) and will be presented again`;
        return textResult(`processed through seq ${through}; ${open}`);
      });
    },
  });
}
