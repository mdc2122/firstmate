// Firstmate primary watcher bridge for omp (Oh My Pi).
//
// A port of .pi/extensions/fm-primary-pi-watch.ts for the omp fork. The arm,
// successor, retry, and replacement-handoff logic is the Pi contract verbatim;
// the omp-specific differences are stated once here:
//   - omp auto-discovers this file from <cwd>/.omp/extensions with no trust
//     gate, so an omp primary or secondmate started inside its home loads it
//     without -e (naming it both ways loads it twice - verified, omp 18.1.11).
//   - pi.sendUserMessage returns synchronously (no promise) in omp, so "Pi
//     accepted the follow-up" collapses to "the call returned"; consumption is
//     still tracked at before_agent_start / message_start exactly as on Pi.
//   - omp reports no session_shutdown reason, so EVERY shutdown with a pending
//     actionable close persists the replacement handoff. Each record is bound
//     to its own wake row when its close is observed: the queue sequence the
//     watcher just appended before printing the reason, plus the unacknowledged
//     state/.watcher-down generation as a staleness guard. Acknowledgement is
//     decided per wake: the next owning session_start, in this process or a
//     later one, replays a record only while that exact sequence is still
//     queued in state/.wake-queue and the recovery generation is unchanged;
//     any other record main already acknowledged is retired unreplayed. The
//     generation is shared by every row of an episode, so it never keeps a
//     record alive on its own. A record with no readable binding is always
//     replayed, so an unacknowledged close is never lost across /new or a restart.
//   - The supervision branch is OFF unless config/omp-supervision-branch turns
//     it on (docs/configuration.md "omp supervision branch"); the mode is read
//     once at load. Off, every actionable wake is delivered to main exactly as
//     before. `on` offers each eligible wake to .omp/extensions/
//     fm-omp-branch-supervision.ts first over pi.events, exactly as the Pi
//     watcher does, and a rejected or declined offer falls back to main.
//     `report-only` always delivers to main and then hands a shadow copy to the
//     branch without waiting on it. No calm presentation hooks exist.
//   - The arming tool is fm_watch_arm_omp and its human fallback
//     /fm-watch-arm-omp; the loaded-build marker is state/.omp-watch-extension-loaded.
//
// Session-generation ownership (stated once here):
// omp emits session_shutdown for ordinary same-process replacements (/new,
// /resume, /fork) as well as terminal quit. This extension binds one generation
// per session activation. Only the active live generation may start, stop,
// rearm, or clear the arm child. An owning replacement session_start (or fresh
// factory bind) arms its new generation without a model turn. A replacement
// handoff carries actionable closes that were still pending delivery; its
// durable state lives at state/extensions/omp-primary-watch/session-replacement-actionable.json.
// Stale callbacks from a prior generation are no-ops against the active replacement.
// omp also binds this module's factory for every in-process task subagent
// (verified omp 18.2.6; the advisor binds no extensions), and that helper's
// session_start and session_shutdown arrive while the owner is still live. A
// generation therefore claims the process only when no live generation owns
// it; a helper that finds a live owner stays inert and its shutdown touches
// nothing, while a genuine replacement follows the owner's shutdown and claims.
// Every instance appends one line per load, session_start, and session_shutdown,
// tagged owner or inert, to state/extensions/omp-primary-watch/session-generations.log.
//
// Delivery versus consumption (stated once here):
// A main follow-up is delivered once omp accepts it (sendUserMessage returns).
// The successor pipeline never waits for the model to read it: a follow-up
// queued while main is streaming joins the running run without ever raising
// before_agent_start, so waiting on that event stalls every later close.
// Consumption is tracked only so a replacement can replay a follow-up omp had
// not consumed. An idle main consumes at before_agent_start; a streaming main
// consumes at the user message_start carrying the exact wake text; either
// event finishes the pending record, and a still-unconsumed record rides the
// replacement handoff.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
// typebox resolves inside omp's extension loader (verified, omp 18.1.11); the
// injected TypeBox compatibility shim keeps it available for tool parameters.
import { Type } from "typebox";
// The operational-input encoder is shared with the omp extensions; its owner
// resolves bin/fm-operational-input.sh relative to its own location, which is
// the same repository root this file lives in.
import {
  encodeFirstmateOperationalInput,
  encodeFirstmateOperationalInputWith,
} from "../../.pi/extensions/lib/fm-operational-input.ts";
import type { OmpBranchShadowWake } from "./lib/fm-omp-branch.ts";

// The omp extension API surface this file uses. omp is a Pi fork and ships no
// separately installable type package, so the contract is declared locally
// rather than imported from the Pi package name.
type ExtensionAPI = {
  on?: (event: string, handler: (event: any, ctx: any) => unknown) => void;
  sendUserMessage: (content: string, options?: { deliverAs?: string }) => unknown;
  registerCommand?: (name: string, command: { description: string; handler: (args: string, ctx: any) => Promise<void> | void }) => void;
  registerTool?: (tool: Record<string, unknown>) => void;
  events?: { emit(channel: string, data: unknown): void };
};

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "other";

type CloseClassification = {
  kind: "actionable" | "failure";
  message: string;
};

type Restoration = {
  failure: string;
  recovery?: { generation: string; watcherPid: string };
};

type PendingActionableClose = {
  version: 1;
  token: string;
  message: string;
  predecessorArmPid: string;
  delivered?: true;
  // Acknowledgement binding captured when the close was observed; absent when
  // the wake queue state was unreadable, which always replays.
  wakeQueueSeq?: number;
  recoveryGeneration?: string;
};

type ReplacementActionableHandoff = {
  version: 2;
  pending: PendingActionableClose[];
};

type UnconsumedWake = {
  content: string;
  pending: PendingActionableClose;
};

type SessionGeneration = {
  id: number;
  stopping: boolean;
  replacement: boolean;
  child: ChildProcess | null;
  retryTimer: ReturnType<typeof setTimeout> | null;
  cleanupTimer: ReturnType<typeof setTimeout> | null;
  retryFailures: number;
  restoring: boolean;
  // True only while restoreAfterActionableClose is starting and verifying a
  // successor. The rest of a delivery (handling confirmation, a supervision
  // branch turn, the main follow-up) runs with a live watcher already in place.
  verifying: boolean;
  seq: number;
  pendingActionables: PendingActionableClose[];
  cleanupFailure: string;
  // Main follow-ups omp has accepted but not yet consumed, by pending token.
  // Never cleared at shutdown: a delivery continuation that runs after the
  // replacement began reads it to tell a main-queued wake (replayed) from a
  // branch-handled one (finished).
  unconsumedWakes: Map<string, UnconsumedWake>;
  // A verified successor's failure close that arrived while the pipeline was
  // still verifying the successor for an earlier close; its bounded retry runs
  // once that delivery settles instead of being skipped by the single-flight guard.
  deferredClose: { message: string; predecessorArmPid: string } | null;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
// The supervision branch's support is loaded only when this home has a
// config/omp-supervision-branch file. The imports are dynamic on purpose: an
// omp home without that file must import nothing beyond what this watcher
// always needed, so a branch dependency can never change its behavior.
// lib/fm-omp-branch.ts owns the file's format; the mode is read once per load
// and a change takes effect at the next restart, the boundary the branch
// extension uses too.
const branchSupport = await (async () => {
  if (!existsSync(`${config}/omp-supervision-branch`)) return null;
  const { readOmpBranchMode, FM_OMP_BRANCH_SHADOW_EVENT } = await import("./lib/fm-omp-branch.ts");
  const mode = readOmpBranchMode(config);
  if (mode === "off") return null;
  const dispatch = await import("../../.pi/extensions/lib/fm-branch-dispatch.ts");
  const { runCommandAsync } = await import("../../.pi/extensions/lib/fm-async-exec.ts");
  return {
    mode,
    runCommandAsync,
    FM_OMP_BRANCH_SHADOW_EVENT,
    classifyWakeForBranch: dispatch.classifyWakeForBranch,
    createBranchDispatchOffer: dispatch.createBranchDispatchOffer,
    FM_BRANCH_DISPATCH_EVENT: dispatch.FM_BRANCH_DISPATCH_EVENT,
  };
})();
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const marker = `${state}/.omp-watch-extension-loaded`;
const handoffDir = `${state}/extensions/omp-primary-watch`;
const actionableHandoff = `${handoffDir}/session-replacement-actionable.json`;
const wakeQueue = `${state}/.wake-queue`;
const wakeQueueSeqFile = `${state}/.wake-queue.seq`;
const recoveryMarker = `${state}/.watcher-down`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
// Stays above the arm's confirm budget (30s in bin/fm-watch-arm.sh): a slow but
// successful watcher start must not be SIGTERMed mid-confirmation.
const armReadyTimeoutMs = positiveInteger(
  "FM_OMP_ARM_READY_TIMEOUT_MS",
  35000,
);
const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const repairOnlyHint = "call fm_watch_arm_omp again only after a later notification says the cycle is missing, failed, or unhealthy";
const shuttingDownMessage = "watcher: not armed - omp session is shutting down";
const inertHelperMessage = "watcher: unchanged - another live omp session in this process owns the watcher";

let nextGenerationId = 0;
let nextHandoffId = 0;
let loadedInstances = 0;
let activeGeneration: SessionGeneration | null = null;
let replacementHandoff: PendingActionableClose[] | null = null;
type ReplacementActionableReceiver = (pending: PendingActionableClose) => void;
type ActionableDeliveryClaim = {
  owner: SessionGeneration;
  settlement: Promise<"delivered" | "failed">;
};
type ReplacementCoordinator = {
  receiver: ReplacementActionableReceiver | null;
  pending: PendingActionableClose[];
  nextTokenId: number;
  deliveries: Map<string, ActionableDeliveryClaim>;
};
type ReplacementCoordinatorGlobal = typeof globalThis & {
  __firstmateOmpWatchReplacements?: Map<string, ReplacementCoordinator>;
};
const replacementCoordinatorGlobal = globalThis as ReplacementCoordinatorGlobal;
const replacementCoordinators = replacementCoordinatorGlobal.__firstmateOmpWatchReplacements ??= new Map<string, ReplacementCoordinator>();
function replacementCoordinatorFor(handoff: string): ReplacementCoordinator {
  const existing = replacementCoordinators.get(handoff);
  if (existing) return existing;
  const created: ReplacementCoordinator = {
    receiver: null,
    pending: [],
    nextTokenId: 0,
    deliveries: new Map(),
  };
  replacementCoordinators.set(handoff, created);
  return created;
}
const replacementCoordinator = replacementCoordinatorFor(actionableHandoff);
const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
const armClose = new WeakMap<ChildProcess, Promise<void>>();
// Children the extension itself asked to exit; their close is not a failure
// of the successor and never earns a deferred retry.
const armRetired = new WeakSet<ChildProcess>();
const armRecovery = new WeakMap<ChildProcess, { generation: string; watcherPid: string }>();
const armPendingActionable = new WeakMap<ChildProcess, PendingActionableClose>();

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  if (lockPid === String(process.pid)) return "owned";
  return pidAlive(lockPid) ? "other" : "missing";
}

// Only the process named in state/.lock owns this session: the ownership proof
// (bin/fm-wake-lib.sh fm_omp_extension_owns_supervision) binds this marker's
// pid to the lock's pid. A nested omp the session runs from this home
// (fm-spawn's `omp models --json` probe, an ad-hoc `omp -p`) auto-discovers
// this file but is not the lock holder, so it neither records the marker nor
// activates the watch.
function markLoaded(): void {
  if (lockOwnership() === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function actionableLine(output: string): string {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function completedActionableLine(output: string): string {
  const newline = output.lastIndexOf("\n");
  return newline < 0 ? "" : actionableLine(output.slice(0, newline + 1));
}

// The text omp carries in a user message_start: sendUserMessage wraps a string
// as one text part, so the joined text parts equal the sent content.
function userMessageText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const part of content) {
    if (
      typeof part === "object" && part !== null &&
      (part as { type?: unknown }).type === "text" &&
      typeof (part as { text?: unknown }).text === "string"
    ) {
      parts.push((part as { text: string }).text);
    }
  }
  return parts.join("\n");
}

function nodeErrorCode(error: unknown): string {
  return typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code ?? "")
    : "";
}

function readOptional(path: string): string {
  try {
    return readFileSync(path, "utf8");
  } catch (error) {
    if (nodeErrorCode(error) === "ENOENT") return "";
    throw error;
  }
}

// The unacknowledged recovery generation in state/.watcher-down, or "" when
// there is none; bin/fm-wake-lib.sh owns the token grammar.
function unackedRecoveryGeneration(): string {
  const match = readOptional(recoveryMarker).match(/^(?:pending|announced):(?:handling|downtime):([A-Za-z0-9._-]+)\n$/);
  return match ? match[1] : "";
}

// Bind a close to its own wake row: the watcher queued that row, advancing the
// sequence counter, immediately before printing the close's reason.
function acknowledgementBinding(): Pick<PendingActionableClose, "wakeQueueSeq" | "recoveryGeneration"> {
  try {
    const seq = readFileSync(wakeQueueSeqFile, "utf8").trim();
    if (!/^[0-9]+$/.test(seq)) return {};
    return { wakeQueueSeq: Number(seq), recoveryGeneration: unackedRecoveryGeneration() };
  } catch {
    return {};
  }
}

// docs/watcher-continuity.md owns this per-wake replay rule: a bound record
// replays only while its own row is still queued under an unchanged generation.
function actionableStillUnacknowledged(pending: PendingActionableClose): boolean {
  if (pending.wakeQueueSeq === undefined) return true;
  try {
    if (pending.recoveryGeneration !== unackedRecoveryGeneration()) return false;
    return readOptional(wakeQueue)
      .split("\n")
      .some((row) => row.split("\t")[1] === String(pending.wakeQueueSeq));
  } catch {
    return true;
  }
}

function createPendingActionable(message: string, predecessorArmPid: string): PendingActionableClose {
  return {
    version: 1,
    token: `${process.pid}-${Date.now()}-${++replacementCoordinator.nextTokenId}`,
    message,
    predecessorArmPid,
    ...acknowledgementBinding(),
  };
}

function validatePendingActionable(value: unknown): PendingActionableClose {
  if (
    typeof value !== "object" || value === null ||
    (value as { version?: unknown }).version !== 1 ||
    typeof (value as { token?: unknown }).token !== "string" ||
    !/^[0-9]+-[0-9]+-[0-9]+$/.test((value as { token: string }).token) ||
    typeof (value as { message?: unknown }).message !== "string" ||
    !actionableLine((value as { message: string }).message) ||
    typeof (value as { predecessorArmPid?: unknown }).predecessorArmPid !== "string" ||
    !/^[0-9]*$/.test((value as { predecessorArmPid: string }).predecessorArmPid) ||
    ((value as { delivered?: unknown }).delivered !== undefined &&
      (value as { delivered?: unknown }).delivered !== true) ||
    ((value as { wakeQueueSeq?: unknown }).wakeQueueSeq !== undefined &&
      !Number.isSafeInteger((value as { wakeQueueSeq?: unknown }).wakeQueueSeq)) ||
    ((value as { wakeQueueSeq?: unknown }).wakeQueueSeq !== undefined) !==
      ((value as { recoveryGeneration?: unknown }).recoveryGeneration !== undefined) ||
    ((value as { recoveryGeneration?: unknown }).recoveryGeneration !== undefined &&
      !/^[A-Za-z0-9._-]*$/.test(String((value as { recoveryGeneration?: unknown }).recoveryGeneration)))
  ) {
    throw new Error(`invalid omp replacement actionable handoff at ${actionableHandoff}`);
  }
  return value as PendingActionableClose;
}

function validateReplacementHandoff(value: unknown): PendingActionableClose[] {
  if (
    typeof value !== "object" || value === null ||
    (value as { version?: unknown }).version !== 2 ||
    !Array.isArray((value as { pending?: unknown }).pending) ||
    (value as { pending: unknown[] }).pending.length === 0
  ) {
    throw new Error(`invalid omp replacement actionable handoff at ${actionableHandoff}`);
  }
  const pending = (value as { pending: unknown[] }).pending.map(validatePendingActionable);
  if (new Set(pending.map((item) => item.token)).size !== pending.length) {
    throw new Error(`invalid omp replacement actionable handoff at ${actionableHandoff}`);
  }
  return pending;
}

function writeReplacementHandoff(pending: PendingActionableClose[]): void {
  replacementHandoff = [...pending];
  mkdirSync(handoffDir, { recursive: true });
  const temporary = `${actionableHandoff}.tmp-${process.pid}-${++nextHandoffId}`;
  const handoff: ReplacementActionableHandoff = { version: 2, pending };
  try {
    writeFileSync(temporary, `${JSON.stringify(handoff)}\n`, { mode: 0o600 });
    renameSync(temporary, actionableHandoff);
  } catch (error) {
    try {
      unlinkSync(temporary);
    } catch {
      // Preserve the original handoff publication error.
    }
    throw error;
  }
}

function persistReplacementHandoff(pending: PendingActionableClose[]): void {
  if (pending.length === 0) return;
  writeReplacementHandoff(pending);
}

function loadReplacementHandoff(): PendingActionableClose[] {
  try {
    const pending = validateReplacementHandoff(JSON.parse(readFileSync(actionableHandoff, "utf8")));
    replacementHandoff = pending;
    return [...pending];
  } catch (error) {
    if (nodeErrorCode(error) === "ENOENT") {
      replacementHandoff = null;
      return [];
    }
    throw error;
  }
}

function mergeReplacementHandoff(pending: PendingActionableClose): void {
  let stored: PendingActionableClose[] = [];
  try {
    stored = validateReplacementHandoff(JSON.parse(readFileSync(actionableHandoff, "utf8")));
  } catch (error) {
    if (nodeErrorCode(error) !== "ENOENT") throw error;
  }
  if (!stored.some((item) => item.token === pending.token)) stored.push(pending);
  writeReplacementHandoff(stored);
}

function clearReplacementHandoff(pending: PendingActionableClose): void {
  try {
    const stored = validateReplacementHandoff(JSON.parse(readFileSync(actionableHandoff, "utf8")));
    const remaining = stored.filter((item) => item.token !== pending.token);
    if (remaining.length === stored.length) return;
    if (remaining.length > 0) {
      writeReplacementHandoff(remaining);
    } else {
      replacementHandoff = null;
      unlinkSync(actionableHandoff);
    }
  } catch (error) {
    if (nodeErrorCode(error) !== "ENOENT") throw error;
  }
}

function classifyClose(stdout: string, stderr: string, code: number | null, signal: NodeJS.Signals | null): CloseClassification {
  const combined = `${stdout}\n${stderr}`.trim();
  const reason = actionableLine(combined);
  if (reason) return { kind: "actionable", message: reason };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - omp extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - omp extension arm child ended from ${signal}${combined ? `\n${combined}` : ""}`,
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - omp extension arm cycle ended without an actionable reason",
  };
}

function createGeneration(): SessionGeneration {
  return {
    id: ++nextGenerationId,
    stopping: false,
    replacement: false,
    child: null,
    retryTimer: null,
    cleanupTimer: null,
    retryFailures: 0,
    restoring: false,
    verifying: false,
    seq: 0,
    pendingActionables: [],
    cleanupFailure: "",
    unconsumedWakes: new Map(),
    deferredClose: null,
  };
}

// A generation takes over the process's watcher only when no other live
// generation owns it. omp binds this module's factory again for every
// in-process task subagent (prepared-extension rebind, verified omp 18.2.6)
// while the owner is still live; such a helper must never displace the owner.
// A genuine replacement always follows the owner's session_shutdown, which
// marks the owner stopping first, so it can claim.
function claimGeneration(generation: SessionGeneration): boolean {
  if (activeGeneration === generation) return true;
  if (activeGeneration && !activeGeneration.stopping) return false;
  activeGeneration = generation;
  return true;
}

function recordSessionEvent(generation: SessionGeneration, instance: number, event: string): void {
  const role = activeGeneration === generation ? "owner" : "inert";
  try {
    mkdirSync(handoffDir, { recursive: true });
    appendFileSync(
      `${handoffDir}/session-generations.log`,
      `${new Date().toISOString()} pid=${process.pid} instance=${instance}/${loadedInstances} gen=${generation.id} ${event} ${role}\n`,
    );
  } catch {
    // Diagnostics never affect watcher continuity.
  }
}

function generationIsLive(generation: SessionGeneration): boolean {
  return activeGeneration === generation && !generation.stopping;
}

function refusalMessage(generation: SessionGeneration): string {
  return generation.stopping ? shuttingDownMessage : inertHelperMessage;
}

function stopGeneration(generation: SessionGeneration): ChildProcess | null {
  generation.stopping = true;
  if (generation.retryTimer) clearTimeout(generation.retryTimer);
  if (generation.cleanupTimer) clearTimeout(generation.cleanupTimer);
  generation.retryTimer = null;
  generation.cleanupTimer = null;
  const child = generation.child;
  if (child) child.kill("SIGTERM");
  generation.child = null;
  return child;
}

async function waitForGenerationChildClose(armChild: ChildProcess | null): Promise<void> {
  if (!armChild) return;
  const closed = armClose.get(armChild);
  if (!closed) return;
  await new Promise<void>((resolveWait) => {
    const timer = setTimeout(resolveWait, armRetireTimeoutMs);
    void closed.then(() => {
      clearTimeout(timer);
      resolveWait();
    });
  });
}

async function stopSessionGeneration(generation: SessionGeneration, replacement: boolean): Promise<void> {
  generation.replacement = replacement;
  let persistedTokens = "";
  try {
    if (replacement && generation.pendingActionables.length > 0) {
      persistReplacementHandoff(generation.pendingActionables);
      persistedTokens = generation.pendingActionables.map((pending) => pending.token).join("\n");
    }
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    for (const pending of generation.pendingActionables) {
      if (replacementCoordinator.pending.some((item) => item.token === pending.token)) continue;
      replacementCoordinator.pending.push({
        ...pending,
        message: `${pending.message}\n\nwatcher: FAILED - omp extension could not persist a replacement-session actionable wake\n${detail}`,
      });
    }
    throw error;
  } finally {
    const child = stopGeneration(generation);
    await waitForGenerationChildClose(child);
  }
  const currentTokens = generation.pendingActionables.map((pending) => pending.token).join("\n");
  if (replacement && currentTokens && currentTokens !== persistedTokens) {
    persistReplacementHandoff(generation.pendingActionables);
  }
}

const cleanupOnProcessExit = () => {
  if (activeGeneration) stopGeneration(activeGeneration);
};
process.once("exit", cleanupOnProcessExit);

export default function (pi: ExtensionAPI) {
  const instance = ++loadedInstances;
  let generation = createGeneration();
  claimGeneration(generation);
  recordSessionEvent(generation, instance, "load");

  async function sendWake(
    owner: SessionGeneration,
    message: string,
    pending?: PendingActionableClose,
  ): Promise<boolean> {
    if (!generationIsLive(owner)) return false;
    const body = `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`;
    const content = branchSupport
      ? await encodeFirstmateOperationalInputWith(branchSupport.runCommandAsync, "watcher", body)
      : encodeFirstmateOperationalInput("watcher", body);
    if (!generationIsLive(owner)) return false;
    if (pending) owner.unconsumedWakes.set(pending.token, { content, pending });
    try {
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
    } catch (error) {
      if (pending) owner.unconsumedWakes.delete(pending.token);
      throw error;
    }
    // Accepted by omp (sendUserMessage returns synchronously there; awaiting a
    // non-promise resolves at once). A generation replaced while omp was
    // accepting it may have lost the follow-up with the old session, so report
    // it undelivered and let the replacement replay the still-pending record.
    return generationIsLive(owner);
  }

  // omp consumed a main follow-up: an idle main at before_agent_start, a
  // streaming main at the user message_start that joins the running run.
  function consumeWake(owner: SessionGeneration, text: string): void {
    for (const [token, wake] of owner.unconsumedWakes) {
      if (wake.content !== text) continue;
      owner.unconsumedWakes.delete(token);
      wake.pending.delivered = true;
      try {
        finishPendingActionable(owner, wake.pending);
      } catch (error) {
        surfaceCleanupFailure(owner, error);
        schedulePendingCleanup(owner);
      }
      return;
    }
  }

  function confirmationResult(
    recovery: { generation: string; watcherPid: string },
    status: number | null,
    stderrText: string,
  ): { ok: boolean; detail: string } {
    if (status === 0) return { ok: true, detail: "" };
    const stderr = stderrText.trim();
    return {
      ok: false,
      detail: `watcher: FAILED - handling delivery confirmation was rejected (status=${status ?? "none"} generation=${recovery.generation} watcherPid=${recovery.watcherPid})${stderr ? `\n${stderr}` : ""}`,
    };
  }

  // With the supervision branch configured the confirmation is awaited (F6 in
  // .omp/extensions/fm-omp-branch-supervision.ts); with it off this is the
  // unchanged synchronous call.
  async function confirmHandlingDelivery(recovery: { generation: string; watcherPid: string }): Promise<{
    ok: boolean;
    detail: string;
  }> {
    const args = [armScript, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid];
    const env = { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot };
    if (branchSupport) {
      const result = await branchSupport.runCommandAsync("bash", args, { cwd: fmRoot, env });
      return confirmationResult(recovery, result.status, result.stderr || "");
    }
    try {
      const result = spawnSync("bash", args, { cwd: fmRoot, encoding: "utf8", env });
      return confirmationResult(recovery, result.status, result.stderr || "");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return {
        ok: false,
        detail: `watcher: FAILED - handling delivery confirmation could not be executed (generation=${recovery.generation} watcherPid=${recovery.watcherPid})\n${message}`,
      };
    }
  }

  async function confirmHandlingDeliveryWithRetry(
    owner: SessionGeneration,
    recovery: { generation: string; watcherPid: string },
  ): Promise<{ ok: boolean; detail: string }> {
    const snapshot = (): { generation: string; watcherPid: string } => {
      const current = owner.child ? armRecovery.get(owner.child) : undefined;
      return current ?? recovery;
    };
    const first = await confirmHandlingDelivery(snapshot());
    if (first.ok) return first;
    return confirmHandlingDelivery(snapshot());
  }

  // `on`: offer the wake to the supervision branch first, exactly as the Pi
  // watcher does; classifyWakeForBranch owns eligibility. An accepted offer
  // whose settlement rejects falls through to main (F7), and so does an offer
  // nobody accepts.
  async function offerWakeToBranch(message: string): Promise<boolean> {
    if (branchSupport?.mode !== "on") return false;
    const { scope, heartbeat, eligible } = branchSupport.classifyWakeForBranch(state, message);
    const offer = branchSupport.createBranchDispatchOffer(message, scope.projects, heartbeat, eligible);
    pi.events?.emit(branchSupport.FM_BRANCH_DISPATCH_EVENT, offer);
    if (!offer.accepted) return false;
    try {
      await offer.settlement;
      return true;
    } catch {
      return false;
    }
  }

  // `report-only`: the rows the branch would have been granted, captured before
  // main can drain them, so the shadow reasons over the same queue state.
  function shadowWakeFor(message: string): OmpBranchShadowWake | null {
    if (branchSupport?.mode !== "report-only") return null;
    const { scope, heartbeat, eligible } = branchSupport.classifyWakeForBranch(state, message);
    if (!eligible) return null;
    const seqs = new Set(scope.eligibleSeqs);
    let rows: string[] = [];
    try {
      rows = readOptional(wakeQueue).split("\n").filter((row) => seqs.has(row.split("\t")[1] ?? ""));
    } catch {
      return null;
    }
    return { message, heartbeat, rows, tasks: [...scope.eligibleTasks] };
  }

  async function deliverActionableWake(
    owner: SessionGeneration,
    message: string,
    repairFailed: boolean,
    pending: PendingActionableClose,
    recovery?: { generation: string; watcherPid: string },
  ): Promise<boolean> {
    if (!generationIsLive(owner)) return false;
    if (recovery) {
      const confirmed = await confirmHandlingDeliveryWithRetry(owner, recovery);
      if (!confirmed.ok) {
        const watcherPid = recovery.watcherPid;
        const confirmedChild = owner.child;
        if (!pidAlive(watcherPid) && confirmedChild && armRecovery.get(confirmedChild)?.watcherPid === watcherPid) {
          await retireArm(confirmedChild);
        }
        return await sendWake(owner, `${message}\n\n${confirmed.detail}`, pending);
      }
    }
    // A watcher-repair failure is main's alone: only main can repair the cycle.
    if (!repairFailed && await offerWakeToBranch(message)) return generationIsLive(owner);
    const shadow = repairFailed ? null : shadowWakeFor(message);
    const delivered = await sendWake(owner, message, pending);
    if (delivered && shadow && branchSupport) pi.events?.emit(branchSupport.FM_OMP_BRANCH_SHADOW_EVENT, shadow);
    return delivered;
  }

  function surfaceFailure(owner: SessionGeneration, message: string): void {
    void sendWake(owner, message).catch(() => {
      // omp owns delivery errors; continuity restoration never waits on prompting.
    });
  }

  function enqueuePendingActionable(
    owner: SessionGeneration,
    pending: PendingActionableClose,
  ): void {
    if (owner.pendingActionables.some((item) => item.token === pending.token)) return;
    owner.pendingActionables.push(pending);
    if (owner.stopping && owner.replacement) {
      let replacementPending = pending;
      try {
        mergeReplacementHandoff(pending);
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        replacementPending = {
          ...pending,
          message: `${pending.message}\n\nwatcher: FAILED - omp extension could not persist a late replacement-session actionable wake\n${detail}`,
        };
      }
      if (replacementCoordinator.receiver) {
        replacementCoordinator.receiver(replacementPending);
      } else if (replacementPending !== pending) {
        replacementCoordinator.pending.push(replacementPending);
      }
    }
  }

  function finishPendingActionable(owner: SessionGeneration, pending: PendingActionableClose): void {
    clearReplacementHandoff(pending);
    const index = owner.pendingActionables.findIndex((item) => item.token === pending.token);
    if (index >= 0) owner.pendingActionables.splice(index, 1);
    owner.cleanupFailure = "";
  }

  function surfaceCleanupFailure(
    owner: SessionGeneration,
    error: unknown,
  ): void {
    const detail = error instanceof Error ? error.message : String(error);
    if (owner.cleanupFailure === detail) return;
    owner.cleanupFailure = detail;
    surfaceFailure(owner, `watcher: FAILED - omp extension could not clear a delivered replacement-session actionable wake\n${detail}`);
  }

  function schedulePendingCleanup(owner: SessionGeneration): void {
    if (!generationIsLive(owner) || owner.cleanupTimer) return;
    const timer = setTimeout(() => {
      if (owner.cleanupTimer === timer) owner.cleanupTimer = null;
      void processPendingActionables(owner);
    }, retryDelay(1));
    timer.unref();
    owner.cleanupTimer = timer;
  }

  async function processPendingActionables(owner: SessionGeneration): Promise<void> {
    if (!generationIsLive(owner) || owner.restoring || owner.pendingActionables.length === 0) return;
    owner.restoring = true;
    const attemptedCleanup = new Set<string>();
    try {
      while (generationIsLive(owner) && owner.pendingActionables.length > 0) {
        for (const delivered of owner.pendingActionables.filter((item) => item.delivered && !attemptedCleanup.has(item.token))) {
          attemptedCleanup.add(delivered.token);
          try {
            finishPendingActionable(owner, delivered);
          } catch (error) {
            surfaceCleanupFailure(owner, error);
          }
        }
        // A record omp has accepted but not consumed is neither redelivered
        // nor finished here: consumption finishes it, replacement replays it.
        const pending = owner.pendingActionables.find(
          (item) => !item.delivered && !owner.unconsumedWakes.has(item.token),
        );
        if (!pending) break;
        const existingClaim = replacementCoordinator.deliveries.get(pending.token);
        if (existingClaim && existingClaim.owner !== owner) {
          const settlement = await existingClaim.settlement;
          if (!generationIsLive(owner)) return;
          if (settlement === "delivered") {
            pending.delivered = true;
            continue;
          }
          if (replacementCoordinator.deliveries.get(pending.token) === existingClaim) {
            replacementCoordinator.deliveries.delete(pending.token);
          }
        }
        let settleClaim: (settlement: "delivered" | "failed") => void = () => {};
        const settlement = new Promise<"delivered" | "failed">((resolveSettlement) => {
          settleClaim = resolveSettlement;
        });
        const deliveryClaim = { owner, settlement };
        replacementCoordinator.deliveries.set(pending.token, deliveryClaim);
        const releaseClaim = (): void => {
          if (replacementCoordinator.deliveries.get(pending.token) === deliveryClaim) {
            replacementCoordinator.deliveries.delete(pending.token);
          }
        };
        try {
          // A new restoration supersedes whatever became of the previous
          // successor; only a failure during this delivery is retried after it.
          owner.deferredClose = null;
          owner.verifying = true;
          let restoration: Restoration;
          try {
            restoration = await restoreAfterActionableClose(owner, pending.predecessorArmPid);
          } finally {
            owner.verifying = false;
          }
          if (!generationIsLive(owner)) {
            settleClaim("failed");
            releaseClaim();
            return;
          }
          const message = restoration.failure ? `${pending.message}\n\n${restoration.failure}` : pending.message;
          const delivered = await deliverActionableWake(owner, message, Boolean(restoration.failure), pending, restoration.recovery);
          if (!delivered) {
            settleClaim("failed");
            releaseClaim();
            return;
          }
          const awaitingConsumption = owner.unconsumedWakes.has(pending.token);
          if (awaitingConsumption && !generationIsLive(owner)) {
            // omp accepted the follow-up, then the session was replaced before
            // this continuation ran: the shutdown persisted the still-pending
            // record, so a replacement waiting on this claim must replay it.
            settleClaim("failed");
            releaseClaim();
            return;
          }
          settleClaim("delivered");
          if (!awaitingConsumption) {
            // omp consumed it before this ran.
            pending.delivered = true;
            try {
              finishPendingActionable(owner, pending);
            } catch (error) {
              surfaceCleanupFailure(owner, error);
            }
          }
          releaseClaim();
        } catch (error) {
          settleClaim("failed");
          releaseClaim();
          throw error;
        }
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      surfaceFailure(owner, `watcher: FAILED - omp extension could not deliver an actionable wake\n${detail}`);
    } finally {
      if (generationIsLive(owner)) {
        owner.restoring = false;
        if (owner.pendingActionables.some((pending) => pending.delivered)) schedulePendingCleanup(owner);
        // No bare arm is launched here. A generation without a child at this
        // point has either delivered a typed restoration failure after its
        // bounded retries, which hands repair to main through fm_watch_arm_omp
        // (one more silent launch past the bound could hold a hung child that
        // the repair call would then report as "unchanged"), or lost a
        // verified successor during the delivery, which takes the ordinary
        // bounded, lock-checked retry it would have taken had the pipeline
        // been idle.
        const deferred = owner.deferredClose;
        owner.deferredClose = null;
        if (deferred && !owner.child && !owner.retryTimer) {
          scheduleRetry(owner, deferred.message, deferred.predecessorArmPid);
        }
      }
    }
  }

  const receiveReplacementActionable: ReplacementActionableReceiver = (pending) => {
    if (!generationIsLive(generation)) return;
    enqueuePendingActionable(generation, pending);
    void processPendingActionables(generation);
  };

  function retryDelay(attempt: number): number {
    return Math.min(retryMaxMs, retryBaseMs * 2 ** Math.max(0, attempt - 1));
  }

  function waitForRetry(attempt: number): Promise<void> {
    return new Promise((resolveRetry) => {
      const timer = setTimeout(resolveRetry, retryDelay(attempt));
      timer.unref();
    });
  }

  function waitForReadiness(armChild: ChildProcess): Promise<boolean> {
    const readiness = armReadiness.get(armChild);
    if (!readiness) return Promise.resolve(false);
    return new Promise((resolveReady) => {
      const timer = setTimeout(() => resolveReady(false), armReadyTimeoutMs);
      timer.unref();
      void readiness.then((ready) => {
        clearTimeout(timer);
        resolveReady(ready);
      });
    });
  }

  async function retireArm(armChild: ChildProcess | null): Promise<boolean> {
    if (!armChild) return true;
    armRetired.add(armChild);
    armChild.kill("SIGTERM");
    const closed = armClose.get(armChild);
    if (!closed) return false;
    return new Promise((resolveRetired) => {
      const timer = setTimeout(() => resolveRetired(false), armRetireTimeoutMs);
      timer.unref();
      void closed.then(() => {
        clearTimeout(timer);
        resolveRetired(true);
      });
    });
  }

  async function restoreAfterActionableClose(owner: SessionGeneration, predecessorArmPid: string): Promise<Restoration> {
    let failure = "";
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (!generationIsLive(owner)) return { failure: "" };
      const replacement = startArm(owner, predecessorArmPid);
      const successorChild = owner.child;
      if (replacement.ok && successorChild && await waitForReadiness(successorChild)) {
        return { failure: "", recovery: armRecovery.get(successorChild) };
      }
      if (replacement.ok) {
        failure = "watcher: FAILED - omp extension could not verify a ready successor watcher";
        if (!(await retireArm(successorChild))) {
          return {
            failure: `${failure}\nwatcher: FAILED - omp extension could not restore watcher continuity because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`,
          };
        }
      } else {
        failure = /(?:read-only|no live session)/.test(replacement.message)
          ? `watcher: FAILED - omp extension cannot restore continuity because this session no longer owns the lock\n${replacement.message}`
          : `watcher: FAILED - omp extension could not start the successor watcher cycle\n${replacement.message}`;
        if (/(?:read-only|no live session)/.test(replacement.message)) break;
      }
      if (attempt === retryLimit) break;
      await waitForRetry(attempt + 1);
    }
    return { failure: `${failure}\nwatcher: FAILED - omp extension could not restore watcher continuity after ${retryLimit} retries` };
  }

  function scheduleRetry(owner: SessionGeneration, message: string, predecessorArmPid: string): void {
    if (!generationIsLive(owner) || owner.child || owner.retryTimer) return;
    const ownership = lockOwnership();
    if (ownership !== "owned") {
      surfaceFailure(owner, `watcher: FAILED - omp extension cannot restore continuity because this session no longer owns the lock\n${message}`);
      return;
    }
    owner.retryFailures += 1;
    if (owner.retryFailures > retryLimit) {
      surfaceFailure(owner, `watcher: FAILED - omp extension could not restore watcher continuity after ${retryLimit} retries\n${message}`);
      return;
    }
    const timer = setTimeout(() => {
      if (owner.retryTimer === timer) owner.retryTimer = null;
      if (!generationIsLive(owner)) return;
      const result = startArm(owner, predecessorArmPid);
      if (!result.ok) {
        surfaceFailure(owner, `watcher: FAILED - omp extension could not launch a continuity retry\n${result.message}`);
      }
    }, retryDelay(owner.retryFailures));
    timer.unref();
    owner.retryTimer = timer;
  }

  function startArm(owner: SessionGeneration, predecessorArmPid = ""): ArmResult {
    if (!generationIsLive(owner)) return { ok: false, message: refusalMessage(owner) };
    const ownership = lockOwnership();
    if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    if (ownership === "missing") {
      return {
        ok: false,
        message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_omp to re-arm",
      };
    }
    markLoaded();
    if (owner.child) {
      return {
        ok: true,
        message: `watcher: unchanged - omp extension already owns an arm child; no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    if (owner.retryTimer) {
      return {
        ok: true,
        message: `watcher: unchanged - omp extension already owns a scheduled continuity retry; no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    const id = ++owner.seq;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
      FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
    };
    const armChild = spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    owner.child = armChild;
    let stdout = "";
    let stderr = "";
    let settled = false;
    let readinessSettled = false;
    let verified = false;
    let resolveReadiness: (ready: boolean) => void = () => {};
    let resolveClosed: () => void = () => {};
    const readiness = new Promise<boolean>((resolveReady) => {
      resolveReadiness = resolveReady;
    });
    armReadiness.set(armChild, readiness);
    const closed = new Promise<void>((resolveClosedChild) => {
      resolveClosed = resolveClosedChild;
    });
    armClose.set(armChild, closed);
    const settleReadiness = (ready: boolean): void => {
      if (readinessSettled) return;
      readinessSettled = true;
      verified = ready;
      resolveReadiness(ready);
    };
    const observeEstablishedArm = (): void => {
      const combined = `${stdout}\n${stderr}`;
      const recovery = combined.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
      if (recovery) armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
      if (/^watcher: (?:started|attached)\b/m.test(combined)) {
        settleReadiness(true);
      }
      const reason = completedActionableLine(stdout) || completedActionableLine(stderr);
      if (reason && !armPendingActionable.has(armChild)) {
        const pending = createPendingActionable(reason, String(armChild.pid ?? ""));
        armPendingActionable.set(armChild, pending);
        enqueuePendingActionable(owner, pending);
      }
    };
    const releaseChild = (): void => {
      if (owner.child === armChild) owner.child = null;
    };
    armChild.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      observeEstablishedArm();
    });
    armChild.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
      observeEstablishedArm();
    });
    armChild.on("close", (code: number | null, signal: NodeJS.Signals | null) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      const classification = classifyClose(stdout, stderr, code, signal);
      const predecessor = String(armChild.pid ?? "");
      if (classification.kind === "actionable") {
        const pending = armPendingActionable.get(armChild) ?? createPendingActionable(classification.message, predecessor);
        enqueuePendingActionable(owner, pending);
        if (!generationIsLive(owner)) return;
        owner.retryFailures = 0;
        // A delivery past its successor check (handling confirmation, a
        // supervision branch turn, the main follow-up) can run for minutes.
        // Queueing this close behind it would leave the home with no watcher
        // for that whole turn, so start its successor now; the pipeline's own
        // restoration for this close then finds and verifies that child.
        if (owner.restoring && !owner.verifying && !owner.child && !owner.retryTimer) {
          startArm(owner, predecessor);
        }
        void processPendingActionables(owner);
        return;
      }
      if (!generationIsLive(owner)) return;
      if (owner.verifying) {
        // The pipeline is still verifying the successor for its current close.
        // A verified successor that failed on its own keeps its bounded retry
        // for the end of that delivery; an unready child closing here was
        // retired by the restoration itself.
        if (verified && !armRetired.has(armChild)) {
          owner.deferredClose = { message: classification.message, predecessorArmPid: predecessor };
        }
        return;
      }
      scheduleRetry(owner, classification.message, predecessor);
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!generationIsLive(owner)) return;
      if (owner.verifying) return;
      scheduleRetry(owner, `watcher: FAILED - omp extension arm child ${id} failed: ${error.message}`, String(armChild.pid ?? ""));
    });
    return {
      ok: true,
      message: `watcher: started omp extension arm child ${id}; future ordinary re-arms are automatic; ${repairOnlyHint}`,
    };
  }

  function activateOwnedWatch(owner: SessionGeneration): ArmResult {
    if (!generationIsLive(owner)) return { ok: false, message: refusalMessage(owner) };
    if (lockOwnership() !== "owned") return startArm(owner);
    replacementCoordinator.receiver = receiveReplacementActionable;
    let pending: PendingActionableClose[] = [];
    let loadFailure = "";
    try {
      pending = loadReplacementHandoff();
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      loadFailure = `watcher: FAILED - omp extension could not load a replacement-session actionable wake\n${detail}`;
    }
    const inProcessPending = replacementCoordinator.pending.splice(0);
    for (const actionable of [...pending, ...inProcessPending]) {
      if (actionableStillUnacknowledged(actionable)) {
        enqueuePendingActionable(owner, actionable);
        continue;
      }
      // Main already acknowledged this close's wake before the restart.
      try {
        clearReplacementHandoff(actionable);
      } catch (error) {
        surfaceCleanupFailure(owner, error);
      }
    }
    if (owner.pendingActionables.length > 0) {
      if (loadFailure) surfaceFailure(owner, loadFailure);
      const armResult = startArm(owner, owner.pendingActionables[0].predecessorArmPid);
      if (!armResult.ok) {
        surfaceFailure(owner, `watcher: FAILED - omp extension could not arm before replacement wake delivery\n${armResult.message}`);
      }
      void processPendingActionables(owner);
      return armResult;
    }
    const result = startArm(owner);
    if (loadFailure) surfaceFailure(owner, `${loadFailure}\n${result.message}`);
    return result;
  }

  pi.on?.("before_agent_start", (event) => {
    consumeWake(generation, String((event as { prompt?: unknown })?.prompt ?? ""));
  });
  pi.on?.("message_start", (event) => {
    const message = (event as { message?: { role?: unknown; content?: unknown } })?.message;
    if (!message || message.role !== "user") return;
    consumeWake(generation, userMessageText(message.content));
  });

  pi.on?.("session_start", async () => {
    if (generation.stopping) generation = createGeneration();
    // A helper session (an in-process task subagent) finds the owner live and
    // stays inert: it neither arms, replays handoffs, nor takes the receiver.
    const claimed = claimGeneration(generation);
    recordSessionEvent(generation, instance, "session_start");
    if (!claimed) return;
    markLoaded();
    if (lockOwnership() !== "owned") return;
    activateOwnedWatch(generation);
  });
  pi.on?.("session_shutdown", async () => {
    // A helper's shutdown never touches the owner: its own generation holds no
    // child, pending close, or receiver.
    recordSessionEvent(generation, instance, "session_shutdown");
    if (activeGeneration !== generation) {
      generation.stopping = true;
      return;
    }
    // omp carries no shutdown reason (verified: `reason` is undefined), so the
    // replacement handoff is always persisted when anything is pending; the
    // next owning start skips any record whose wake main has since acknowledged.
    if (replacementCoordinator.receiver === receiveReplacementActionable) replacementCoordinator.receiver = null;
    await stopSessionGeneration(generation, true);
  });

  pi.registerCommand?.("fm-watch-arm-omp", {
    description: "Arm firstmate watcher supervision through the omp extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = activateOwnedWatch(generation);
      ctx?.ui?.notify?.(result.message, result.ok ? "info" : "warning");
    },
  });

  pi.registerTool?.({
    name: "fm_watch_arm_omp",
    label: "Arm firstmate watcher",
    description: "Start the first required omp watcher cycle, or repair one only after a notification says the cycle is missing, failed, or unhealthy. Do not call after ordinary work or ordinary notifications; the omp extension re-arms automatically. Never run bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Start the first required omp watcher cycle or repair a cycle reported missing, failed, or unhealthy; ordinary re-arming is automatic.",
    promptGuidelines: [
      "Call fm_watch_arm_omp only for the first required cycle or after a notification says the cycle is missing, failed, or unhealthy. Do not call it after ordinary work, turn completion, or ordinary signal, stale, check, or heartbeat handling because the omp extension owns re-arming. Never run bin/fm-watch-arm.sh through bash.",
    ],
    parameters: Type.Object({}),
    execute: async () => {
      const result = activateOwnedWatch(generation);
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  markLoaded();
}
