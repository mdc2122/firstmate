import json, os, sys
root = sys.argv[1]
home = os.path.join(root, "home"); fm = os.path.join(home, "fm")
sess = os.path.join(home, ".omp", "agent", "sessions")
for d in (os.path.join(fm, "state"), os.path.join(fm, "data")):
    os.makedirs(d, exist_ok=True)
def write(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for r in rows: f.write(json.dumps(r) + "\n")
def user(t, text):
    return {"type": "message", "timestamp": t, "message": {"role": "user", "content": [{"type": "text", "text": text}]}}
def status(t, task, line):
    cmd = f"echo \"{line}\" >> '{fm}/state/{task}.status'"
    return {"type": "message", "timestamp": t, "message": {"role": "assistant", "stopReason": "stop",
            "content": [{"type": "toolCall", "arguments": {"command": cmd}}]}}
def brief(task, extra=""):
    return ("⁣FIRSTMATE_OP: v1 launch-brief: # Task\nThis is a SCOUT task.\n" + extra +
            f"echo \"{{state}}: {{one short line}}\" >> '{fm}/state/{task}.status'\nInbox: {fm}/state/{task}.inbox\n")
# measured in-window workers
write(os.path.join(sess, "-ws-quiet", "2026-10-12T05-00-00-000Z_q.jsonl"),
      [user("2026-10-12T05:00:00Z", brief("quiet")), status("2026-10-12T09:00:00Z", "quiet", "done: findings in report")])
write(os.path.join(sess, "-ws-late", "2026-10-12T20-00-00-000Z_l.jsonl"),
      [user("2026-10-12T20:00:00Z", brief("late")), status("2026-10-13T05:00:00Z", "late", "done: finished after cap")])
# launch briefs for uncovered rows (outside the measured window)
write(os.path.join(sess, "-ws-early", "2026-10-05T00-00-00-000Z_e.jsonl"),
      [user("2026-10-05T00:00:00Z", brief("early-row"))])
write(os.path.join(sess, "-ws-after", "2026-10-13T02-00-00-000Z_a.jsonl"),
      [user("2026-10-13T02:00:00Z", brief("after-row"))])
# a secondmate-ish brief whose own task is mate-self but which cites direct-row's inbox
write(os.path.join(sess, "-ws-mate", "2026-10-11T00-00-00-000Z_m.jsonl"),
      [user("2026-10-11T00:00:00Z", brief("mate-self", f"Hand the fix to {fm}/state/direct-row.inbox\n"))])
# main-home supervisor transcripts: holes 06->12 and 18->cap
write(os.path.join(sess, "-fm", "s1.jsonl"), [{"type": "message", "timestamp": t, "message": {"role": "assistant", "content": []}}
                                              for t in ("2026-10-11T22:00:00Z", "2026-10-12T06:00:00Z")])
write(os.path.join(sess, "-fm", "s2.jsonl"), [{"type": "message", "timestamp": t, "message": {"role": "assistant", "content": []}}
                                              for t in ("2026-10-12T12:00:00Z", "2026-10-12T18:00:00Z")])
open(os.path.join(fm, "data", "backlog.md"), "w").write(
    "## Done\n"
    "- [x] quiet - Quiet scout (kind: scout) (reported 2026-10-12)\n"
    "- [x] late - Late scout (kind: scout) (reported 2026-10-13)\n"
    "- [x] grok-sweep - Sweep the queue with a grok swarm (kind: scout) (reported 2026-10-12)\n"
    "- [x] primary-fix - Guard the primary home against reuse (kind: ship) (done 2026-10-12)\n"
    "- [x] beads-fix - Fix the flake the beads crew found (kind: ship) (done 2026-10-12)\n"
    "- [x] early-row - Started last week (kind: ship) (done 2026-10-12)\n"
    "- [x] after-row - Relaunched after the window (kind: ship) (done 2026-10-12)\n"
    "- [x] direct-row - Captain call recorded directly (kind: ship) (done 2026-10-12)\n")
