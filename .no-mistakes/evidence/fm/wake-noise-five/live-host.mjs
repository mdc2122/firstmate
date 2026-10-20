// Disposable host: loads the real .omp watch extension, which spawns the real
// bin/fm-watch-arm.sh / bin/fm-watch.sh against an isolated FM_HOME. Only omp's
// ExtensionAPI surface is stood in by this host.
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync, chmodSync } from "node:fs";
const repo = process.env.FM_ROOT_OVERRIDE;
const state = `${process.env.FM_HOME}/state`;
const log = (...a) => console.log("[host]", ...a);
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const handlers = new Map(); const sent = [];
const mod = await import(pathToFileURL(`${repo}/.omp/extensions/fm-primary-omp-watch.ts`).href);
mod.default({
  on(e, h) { handlers.set(e, h); },
  registerCommand() {}, registerTool() {},
  sendUserMessage(m, o) { sent.push(m); log(`omp received wake #${sent.length} (${o?.deliverAs}):`, m.split("\n")[0]); return undefined; },
});
await handlers.get("session_start")({}, {});
const waitFor = async (pred, what, ms = 120000) => {
  const d = Date.now() + ms;
  while (Date.now() < d && !pred()) await new Promise((r) => setTimeout(r, 200));
  if (!pred()) throw new Error(`timed out waiting for ${what}`);
};
const check = (name, text) => {
  const p = `${state}/${name}.check.sh`;
  writeFileSync(p, `#!/usr/bin/env bash\nm="${state}/.${name}.fired"\n[ -e "$m" ] && exit 0\n: > "$m"\necho '${text}'\n`);
  chmodSync(p, 0o700);
  const r = spawnSync(`${repo}/bin/fm-check-register.sh`, [name], { env: process.env, encoding: "utf8" });
  log(`registered ${name}.check.sh via real fm-check-register.sh (exit ${r.status}) ${r.stderr.trim()}`);
};
const drain = () => {
  const env = { ...process.env };
  const r = spawnSync(`${repo}/bin/fm-wake-drain.sh`, [], { env, encoding: "utf8" });
  log("real fm-wake-drain.sh stdout:\n" + r.stdout.trim());
  const m = r.stderr.match(/--ack-through (\d+) --recovery-generation (\S+)/);
  if (!m) throw new Error(`drain gave no ack line: ${r.stderr}`);
  const a = spawnSync(`${repo}/bin/fm-wake-drain.sh`, ["--ack-through", m[1], "--recovery-generation", m[2]], { env, encoding: "utf8" });
  log(`main acknowledged through row ${m[1]} (exit ${a.status})`);
};
const queue = () => (existsSync(`${state}/.wake-queue`) ? readFileSync(`${state}/.wake-queue`, "utf8") : "");

check("audit", "audit window unreviewed");
await waitFor(() => sent.some((m) => m.includes("audit window unreviewed")), "first check wake");
log("queue after first wake:\n" + queue().trim());
// main handles the first wake's row through a later drain, before omp hands the parked wake over
drain();
check("deploy", "deploy failed on host b");
await waitFor(() => sent.some((m) => m.includes("deploy failed on host b")), "second check wake");
log("queue at consumption (second row still queued):\n" + queue().trim());

const wakes = sent.filter((m) => m.includes("FIRSTMATE WATCHER WAKE: check:"));
const msgs = [{ role: "user", content: [{ type: "text", text: "captain: status?" }], timestamp: 100 },
  ...wakes.map((m, i) => ({ role: "user", content: [{ type: "text", text: m }], timestamp: 101 + i }))];
for (const message of msgs) await handlers.get("message_start")({ message }, {});
const result = await handlers.get("context")({ type: "context", messages: msgs }, {});
const seen = (result?.messages ?? msgs).map((m) => m.content.map((p) => p.text).join("\n"));
console.log("\n=== model context after omp hands over the backlog ===");
seen.forEach((t, i) => console.log(`--- message ${i} ---\n${t}`));
console.log("\n=== state/.watch-triage.log (drop lines) ===");
try { console.log(readFileSync(`${state}/.watch-triage.log`, "utf8").split("\n").filter((l) => l.includes("superseded")).join("\n")); } catch { console.log("(none)"); }
const firstDropped = /watcher: superseded wake dropped \(wake row \d+ already acknowledged\): check: .*audit window unreviewed - no action needed/.test(seen[1]);
const secondKept = seen[2] === wakes[1];
console.log(`\nRESULT acknowledged-wake-dropped=${firstDropped} queued-wake-kept=${secondKept}`);
await handlers.get("session_shutdown")({}, {});
process.exit(firstDropped && secondKept ? 0 : 1);
