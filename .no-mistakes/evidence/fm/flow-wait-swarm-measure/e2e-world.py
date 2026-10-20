import json, os, sqlite3, sys
root = sys.argv[1]
fm = os.path.join(root, "home", "fm"); mate = os.path.join(root, "home", "mate")
for d in (fm, mate):
    os.makedirs(os.path.join(d, "state"), exist_ok=True); os.makedirs(os.path.join(d, "data", "beads", ".beads"), exist_ok=True)
open(os.path.join(fm, "data", "secondmates.md"), "w").write(f"- mate (home: {mate}; scope: research)\n")
open(os.path.join(fm, "data", "backlog.md"), "w").write(
    "# Backlog\n## In flight\n- [ ] sw-live - still running swarm (kind: scout)\n- [ ] sw-ship - ship swarm (kind: ship)\n"
    "- [ ] sw-stall - stopped swarm\n## Done\n- [x] sw-gone - finished elsewhere\n")
def write(p, rows):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").writelines(json.dumps(r) + "\n" for r in rows)
def user(t, x): return {"type": "message", "timestamp": t, "message": {"role": "user", "content": [{"type": "text", "text": x}]}}
def call(t, body, stop="toolUse"):
    return {"type": "message", "timestamp": t, "message": {"role": "assistant", "stopReason": stop, "content": [{"type": "toolCall", "arguments": {"code": body}}]}}
def swarm(home, task, rows):
    write(os.path.join(home, "data", task, "sessions", "root.jsonl"),
          [{"type": "session", "timestamp": rows[0]["timestamp"]}] + rows)
T = lambda hm: f"2026-10-12T{hm}:00Z"
# swarm in secondmate home finishing with direct open() append
swarm(mate, "mate-swarm", [user(T("09:00"), f"Begin from {mate}/data/mate-swarm/kickoff.md"),
      call(T("09:30"), f"with open('{mate}/state/mate-swarm.status','a') as f: f.write('done: mate report\\n')", "stop")])
# live readout: row In flight, no done -> in-flight; root mid-call -> no tail stall
swarm(fm, "sw-live", [user(T("10:00"), f"Begin from {fm}/data/sw-live/kickoff.md"), call(T("10:05"), "print(1)")])
# row In flight, root stopped (turn_end) long ago -> in-flight with worker_stall tail
swarm(fm, "sw-stall", [user(T("10:00"), f"Begin from {fm}/data/sw-stall/kickoff.md"), call(T("10:05"), "print(1)", "stop")])
# row under Done, no done: line -> closed-not-live
swarm(fm, "sw-gone", [user(T("10:00"), f"Begin from {fm}/data/sw-gone/kickoff.md"), call(T("10:05"), "print(1)", "stop")])
# ship-kind backlog row; second root session = relaunch
swarm(fm, "sw-ship", [user(T("11:00"), f"Begin from {fm}/data/sw-ship/kickoff.md"),
      call(T("11:10"), f"S='{fm}/state/sw-ship.status'\nwith open(S,'a') as f: f.write('done: shipped stuff\\n')", "stop")])
write(os.path.join(fm, "data", "sw-ship", "sessions", "root2.jsonl"),
      [{"type": "session", "timestamp": T("11:05")}, user(T("11:05"), f"Resume from {fm}/data/sw-ship/kickoff.md"), call(T("11:06"), "print(1)", "stop")])
# beads
def beads(home, issues, labels):
    db = sqlite3.connect(os.path.join(home, "data", "beads", ".beads", "beads.db"))
    db.executescript("create table issues(id text, created_at text, closed_at text, close_reason text, deleted_at text);"
                     "create table labels(issue_id text, label text);")
    db.executemany("insert into issues values (?,?,?,?,?)", issues); db.executemany("insert into labels values (?,?)", labels); db.commit()
beads(fm, [("b1", T("12:00"), T("13:00"), "Shipped: fixed thing", None),
           ("b2", T("12:00"), T("12:30"), "verified live", None),
           ("b3", "2026-10-10T12:00:00Z", "2026-10-10T13:00:00Z", "done", None),   # before window
           ("b4", T("12:00"), T("12:10"), "done", "2026-10-12T12:20:00Z"),          # deleted
           ("b5", T("12:00"), T("12:40"), "Superseded by b1", None)],
      [("b1", "mirror:steered-bead"), ("b2", "mirror:quiet-bead"), ("b3", "mirror:old-bead"), ("b4", "mirror:deleted-bead"), ("b5", "mirror:super")])
beads(mate, [("m1", T("14:00"), None, None, None)], [("m1", "mirror:mate-bead")])
# supervisor steer naming the bead row
from datetime import datetime
ep = int(datetime.fromisoformat("2026-10-12T12:15:00+00:00").timestamp())
write(os.path.join(fm, "state", "supervisor-actions.jsonl"),
      [{"at": "", "epoch": ep, "task": "steered-bead", "verb": "send", "action": "steer", "target": "steered-bead", "origin": "direct"}])
