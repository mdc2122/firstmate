// Scripted OpenAI-compatible chat-completions server. Every request body is
// appended to requests.jsonl; replies are decided by the last message only.
import { createServer } from "node:http";
import { appendFileSync, writeFileSync, existsSync } from "node:fs";
const port = Number(process.env.PORT || 0);
const dir = process.env.LAB;
let n = 0;
function decide(body) {
  const msgs = body.messages || [];
  const last = msgs[msgs.length - 1] || {};
  const text = typeof last.content === "string" ? last.content : JSON.stringify(last.content || "");
  if (last.role === "tool") return { text: `TOOL RESULT: ${text}` };
  if (/HELPER-TASK/.test(text)) return { tool: { name: "fm_watch_arm_omp", args: {} } };
  if (/CALL_ARM/.test(text)) return { tool: { name: "fm_watch_arm_omp", args: {} } };
  if (/SPAWN_HELPER/.test(text)) {
    const taskTool = (body.tools || []).find((t) => t.function?.name === "task");
    const schema = taskTool?.function?.parameters || {};
    const args = { i: "run one helper", context: "Lab helper run.", tasks: [{ name: "helper", task: "HELPER-TASK: reply with exactly HELPER-DONE and nothing else. Do not call any tool." }] };
    return { tool: { name: "task", args } };
  }
  return { text: "OK" };
}
createServer((req, res) => {
  let raw = "";
  req.on("data", (c) => (raw += c));
  req.on("end", () => {
    if (!req.url.includes("chat/completions")) { res.writeHead(404); res.end(); return; }
    const body = JSON.parse(raw || "{}");
    n += 1;
    appendFileSync(`${dir}/requests.jsonl`, JSON.stringify({ n, model: body.model, stream: body.stream, tools: (body.tools || []).map((t) => t.function?.name), messages: body.messages }) + "\n");
    if (!existsSync(`${dir}/tools.json`)) writeFileSync(`${dir}/tools.json`, JSON.stringify(body.tools || [], null, 1));
    const d = decide(body);
    const id = `chatcmpl-${n}`;
    const created = Math.floor(Date.now() / 1000);
    const usage = { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 };
    const message = d.tool
      ? { role: "assistant", content: null, tool_calls: [{ id: `call_${n}`, type: "function", function: { name: d.tool.name, arguments: JSON.stringify(d.tool.args) } }] }
      : { role: "assistant", content: d.text };
    const finish = d.tool ? "tool_calls" : "stop";
    if (body.stream) {
      res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
      const chunk = (delta, finish_reason = null, extra = {}) =>
        res.write(`data: ${JSON.stringify({ id, object: "chat.completion.chunk", created, model: body.model, choices: [{ index: 0, delta, finish_reason }], ...extra })}\n\n`);
      chunk({ role: "assistant" });
      if (d.tool) chunk({ tool_calls: [{ index: 0, id: `call_${n}`, type: "function", function: { name: d.tool.name, arguments: JSON.stringify(d.tool.args) } }] });
      else chunk({ content: d.text });
      chunk({}, finish, { usage });
      res.write("data: [DONE]\n\n");
      res.end();
    } else {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ id, object: "chat.completion", created, model: body.model, choices: [{ index: 0, message, finish_reason: finish }], usage }));
    }
  });
}).listen(port, "127.0.0.1", function () { writeFileSync(`${dir}/port`, String(this.address().port)); console.log("listening", this.address().port); });
