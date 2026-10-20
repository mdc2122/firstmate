"""Disposable world for an end-to-end fm-flow-wait.py -> fm-flow-wait-analyze.py run."""
import json, os, sys
from datetime import datetime
root = sys.argv[1]
home = os.path.join(root, "home"); fm = os.path.join(home, "fm")
sess = os.path.join(home, ".omp", "agent", "sessions")
for d in ("state", "data"):
    os.makedirs(os.path.join(fm, d), exist_ok=True)
def ep(s): return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
def write(path, rows, mtime):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for r in rows: f.write(json.dumps(r) + "\n")
    os.utime(path, (ep(mtime), ep(mtime)))
def user(t, text): return {"type": "message", "timestamp": t, "message": {"role": "user", "content": [{"type": "text", "text": text}]}}
def status(t, task, line):
    return {"type": "message", "timestamp": t, "message": {"role": "assistant", "stopReason": "stop",
            "content": [{"type": "toolCall", "arguments": {"command": f"echo \"{line}\" >> '{fm}/state/{task}.status'"}}]}}
def brief(task, kind="SCOUT", extra=""):
    return (f"⁣FIRSTMATE_OP: v1 launch-brief: # Task\nThis is a {kind} task.\n{extra}"
            f"echo \"{{state}}: {{note}}\" >> '{fm}/state/{task}.status'\nInbox: {fm}/state/{task}.inbox\n")
# Real workers in the window (2026-10-09..2026-10-15).
workers = {
  "w-early": ("2026-10-09T02:00:00Z", "2026-10-09T05:00:00Z"),
  "w-span":  ("2026-10-10T06:00:00Z", "2026-10-12T06:00:00Z"),
  "w-late":  ("2026-10-13T00:00:00Z", "2026-10-14T20:00:00Z"),
}
for t, (a, b) in workers.items():
    write(os.path.join(sess, f"-orca-workspaces-{t}", "w.jsonl"),
          [user(a, brief(t)), status(b, t, "done: findings in report")], b)
# Main-home supervisor transcripts (session dir "-fm"): a hole 10-10T12 -> 10-11T12,
# a hole from window start to 10-09T01, and one from 10-14T12 to now_cap.
def sup(name, a, b):
    rows = [{"type": "message", "timestamp": t, "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}]}} for t in (a, b)]
    write(os.path.join(sess, "-fm", name), rows, b)
sup("s1.jsonl", "2026-10-09T01:00:00Z", "2026-10-10T12:00:00Z")
sup("s2.jsonl", "2026-10-11T12:00:00Z", "2026-10-14T12:00:00Z")
# Backlog rows closed in the window with no worker transcript.
open(os.path.join(fm, "data", "backlog.md"), "w").write(
  "## Done\n"
  "- [x] w-early - early scout (kind: scout) (reported 2026-10-09)\n"
  "- [x] primary-home-guard - Guard the primary home against reuse (kind: ship) (done 2026-10-12)\n"
  "- [x] prime-swarm-plan - Plan the swarm run (kind: scout) (reported 2026-10-11)\n"
  "- [x] beads-fix - Fix the flake the beads crew found (kind: ship) (done 2026-10-12)\n"
  "- [x] old-launch - launched long ago (kind: ship) (done 2026-10-10)\n"
  "- [x] cited-only - only cited by another brief (kind: ship) (done 2026-10-13)\n")
# Launch brief for old-launch before the window (session not counted as a worker in window).
p = os.path.join(sess, "-w", "2026-10-01T00-00-00-000Z_old.jsonl")
write(p, [user("2026-10-01T00:00:00Z", brief("old-launch", "SHIP"))], "2026-10-01T00:00:00Z")
# A secondmate brief that cites cited-only's inbox but names its own status line.
p = os.path.join(sess, "-w", "2026-10-12T00-00-00-000Z_mate.jsonl")
write(p, [user("2026-10-12T00:00:00Z", brief("mate-self", "SCOUT", f"Hand the fix to {fm}/state/cited-only.inbox\n"))], "2026-10-12T00:00:00Z")
