# Prime swarm kickoff: cur1 (mechanics; the mission is in the brief)

Model and effort: you are the root on omniroute-cursor/cursor-api/grok-4.7 at thinking "off"; spawn every child with model "cursor-api/grok-4.7" and thinking "off". RLM max depth 2.
Concurrency: at most 4 agents at once, root included.
Threads: no roles or topics are pre-assigned to children; you, the root, discover and choose your own threads of work from the brief.
No A/B tests, trials, pilots or lotteries; actions only.

Prepend this rule verbatim to every child prompt, with that child's own evidence file path:
"Rule: every reply you send must contain at least one tool call until your evidence file is written. Never reply with only a plan or status sentence. Your final step is writing <evidence file path>; only after it exists may you reply without a tool call."

Child evidence files go under /private/tmp/fmps-live.3tWm/home/data/cur1/evidence/. Supervise with a retry loop: after rlm.collect, re-spawn any thread whose evidence file is missing or under 3 KB as <thread>-r2, -r3 ... up to 4 attempts in all. Log every retry as one JSON line {"ts","event":"child_retry","thread","attempt","reason"} and every non-200 / 429 / quota or rate-limit reply as one JSON line, both to /private/tmp/fmps-live.3tWm/home/data/cur1/rate-limits.jsonl. On a quota exhausted / session owner unavailable reply: stop spawning, write report.md from what exists, record the stop and reset times, and end.

Write report.md progressively at /private/tmp/fmps-live.3tWm/home/data/cur1/report.md. It must contain a "Swarm method" section: model, effort, children spawned, depth used, attempts per thread, early stops, peak concurrency, limit replies, and seconds per model call where measurable.
Write only under /private/tmp/fmps-live.3tWm/home/data/cur1/. When done, append one line `done: <one-line conclusion>` to /private/tmp/fmps-live.3tWm/home/state/cur1.status.

Read /private/tmp/fmps-live.3tWm/brief.md and execute it fully.
