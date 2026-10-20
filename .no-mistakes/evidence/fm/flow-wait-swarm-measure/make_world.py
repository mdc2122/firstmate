import json, os, sqlite3, sys
root = sys.argv[1]
home = os.path.join(root, "home")
fm = os.path.join(home, "fm"); mate = os.path.join(home, "mate")
for h in (fm, mate):
    os.makedirs(os.path.join(h, "state"), exist_ok=True)
    os.makedirs(os.path.join(h, "data", "beads", ".beads"), exist_ok=True)
open(os.path.join(fm, "data", "secondmates.md"), "w").write(
    f"- mate (home: {mate}; scope: viral-moment beads crew)\n")
open(os.path.join(fm, "data", "backlog.md"), "w").write(
    "# Backlog\n\n## In flight\n- [ ] swarm-live - long research swarm (kind: scout)\n"
    "- [ ] swarm-ship - shipping swarm (kind: ship)\n\n## Done\n- [x] swarm-gone - stalled swarm (done 2026-10-12)\n")
def write(p, rows):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f: f.writelines(json.dumps(r) + "\n" for r in rows)
def user(t, x): return {"type": "message", "timestamp": t, "message": {"role": "user", "content": [{"type": "text", "text": x}]}}
def call(t, body, stop="toolUse", key="code"):
    return {"type": "message", "timestamp": t, "message": {"role": "assistant", "stopReason": stop, "content": [{"type": "toolCall", "arguments": {key: body}}]}}
def hdr(t, d=None):
    h = {"type": "session", "timestamp": t}
    if d is not None: h["rlmDepth"] = d
    return h
def append(h, task, line): return f"with open('{h}/state/{task}.status', 'a') as f:\n    f.write('{line}\\n')"
T = lambda hh, mm: f"2026-10-12T{hh:02d}:{mm:02d}:00Z"
# 1 zero-touch swarm in the primary home, with 3 child sessions (depth 1 and a child prompt)
d = os.path.join(fm, "data", "swarm-quiet", "sessions")
write(f"{d}/root.jsonl", [hdr(T(8,0)), user(T(8,0), f"Read {fm}/data/swarm-quiet/kickoff.md and begin."),
      call(T(8,30), "rlm.spawn(...)"), call(T(9,0), append(fm, "swarm-quiet", "done: report.md written"), "stop")])
for i in range(2):
    write(f"{d}/child{i}.jsonl", [hdr(T(8,1), 1), user(T(8,1), f"Read {fm}/data/swarm-quiet/kickoff.md part {i}"), call(T(8,20), "print(1)", "stop")])
write(f"{d}/child-prompt.jsonl", [hdr(T(8,2)), user(T(8,2), "Rule: every reply you send must contain at least one tool call until your evidence file is written. "
      f"Your final step is writing {fm}/data/swarm-quiet/evidence/a.md."), call(T(8,25), "print(1)", "stop")])
# 2 swarm relaunched by a second root session (one relaunch touch expected)
d = os.path.join(fm, "data", "swarm-relaunch", "sessions")
write(f"{d}/a.jsonl", [hdr(T(10,0)), user(T(10,0), f"Read {fm}/data/swarm-relaunch/kickoff.md and begin."), call(T(10,10), "print(1)", "stop")])
write(f"{d}/b.jsonl", [hdr(T(11,0)), user(T(11,0), f"Resume: read {fm}/data/swarm-relaunch/kickoff.md and continue."),
      call(T(11,30), append(fm, "swarm-relaunch", "done: finished"), "stop")])
# 3 live readout swarms (no --as-of): no done line; row In flight -> in-flight; row in Done -> closed-not-live
for t in ("swarm-live", "swarm-gone"):
    write(os.path.join(fm, "data", t, "sessions", "r.jsonl"), [hdr(T(12,0)), user(T(12,0), f"Read {fm}/data/{t}/kickoff.md and begin."), call(T(12,30), "print(1)", "stop")])
# 4 ship-kind swarm from backlog
write(os.path.join(fm, "data", "swarm-ship", "sessions", "r.jsonl"), [hdr(T(13,0)), user(T(13,0), f"Read {fm}/data/swarm-ship/kickoff.md and begin."),
      call(T(13,40), append(fm, "swarm-ship", "done: shipped"), "stop")])
# 5 swarm in the secondmate home
write(os.path.join(mate, "data", "mate-swarm", "sessions", "r.jsonl"), [hdr(T(14,0)), user(T(14,0), f"Read {mate}/data/mate-swarm/brief.md and begin."),
      call(T(14,20), append(mate, "mate-swarm", "done: mate report"), "stop")])
# beads crew in the secondmate home
db = sqlite3.connect(os.path.join(mate, "data", "beads", ".beads", "beads.db"))
db.executescript("create table issues(id text, created_at text, closed_at text, close_reason text, deleted_at text);create table labels(issue_id text, label text);")
rows = [("b1","merged-sha","Merged in 3f2a9c1d"), ("b2","shipped-row","Shipped to prod"), ("b3","pr-row","see https://github.com/acme/vm/pull/42"),
        ("b4","wontfix-row","wontfix"), ("b5","superseded-row","superseded by fm-9"), ("b6","blocked-row","blocked: waiting on API key"),
        ("b7","open-row",None), ("b8","verified-row","VERIFIED live")]
for i,(bid,row,reason) in enumerate(rows):
    db.execute("insert into issues values (?,?,?,?,null)", (bid, f"2026-10-12T{15+i%5:02d}:00:00.000000+00:00",
               None if bid=="b7" else f"2026-10-12T{15+i%5:02d}:45:00.000000+00:00", reason))
    db.execute("insert into labels values (?,?)", (bid, f"mirror:{row}"))
db.commit()
# primary nm db
c = sqlite3.connect(os.path.join(root, "nm.sqlite"))
c.executescript("create table repos(id text, upstream_url text);create table runs(id text, repo_id text, branch text, status text, pr_url text, created_at text, ci_ready_at text, parked_ms integer);")
