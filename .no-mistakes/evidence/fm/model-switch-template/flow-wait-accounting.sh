#!/usr/bin/env bash
# Feed the REAL inbox records and action-ledger rows the live switch-model run
# produced into bin/fm-flow-wait.py and show whether they count as firstmate
# touches. Task "switched" carries the fm-control notices (ship + secondmate
# carrier-prefixed); control task "handtyped" carries the 2026-10 baseline's
# hand-typed notice sent directly with fm-send.
set -u
ROOT=${ROOT:?}; E=${E:?}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
FM="$W/home/fm"; SESS="$W/home/.omp/agent/sessions"
mkdir -p "$FM/state" "$FM/data" "$SESS"
cp -R "$E/live-home/state/t1.inbox" "$FM/state/switched.inbox"
python3 - "$E/live-home/state/supervisor-actions.jsonl" "$FM" "$SESS" <<'PY'
import json, os, sys
src, fm, sess = sys.argv[1:]
rows = [json.loads(l) for l in open(src)]
first = min(r["epoch"] for r in rows)
out = []
for r in rows:
    r = dict(r, task="switched", target="switched"); out.append(r)
# control: the hand-typed notice, sent directly by firstmate 60s after the last switch
hand_at = first + 60
out.append({"at": "", "epoch": hand_at, "task": "handtyped", "verb": "send", "action": "steer", "target": "handtyped", "origin": "direct"})
open(os.path.join(fm, "state", "supervisor-actions.jsonl"), "w").write("".join(json.dumps(r) + "\n" for r in out))
from datetime import datetime, timezone
iso = lambda e: datetime.fromtimestamp(e, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
os.makedirs(os.path.join(fm, "state", "handtyped.inbox"))
open(os.path.join(fm, "state", "handtyped.inbox", "001.msg"), "w").write(
    f"schema=fm-task-inbox.v1\nat={iso(hand_at)}\n--\nYour model was switched in place (SWE-2 weekly quota and Cursor Opus are spent until 10-11/10-12; the main Claude account is cooling down). Same conversation, nothing else changes: resume exactly where you stopped and continue to your next status line.\n")
def user(t, text): return {"type": "message", "timestamp": t, "message": {"role": "user", "content": [{"type": "text", "text": text}]}}
def status(t, task, line):
    cmd = f"echo \"{line}\" >> '{fm}/state/{task}.status'"
    return {"type": "message", "timestamp": t, "message": {"role": "assistant", "stopReason": "stop", "content": [{"type": "toolCall", "arguments": {"command": cmd}}]}}
def brief(task):
    return ("⁣FIRSTMATE_OP: v1 launch-brief: # Task\nThis is a SCOUT task.\n" f"echo \"{{state}}: {{note}}\" >> '{fm}/state/{task}.status'\n")
for task in ("switched", "handtyped"):
    d = os.path.join(sess, f"-orca-workspaces-{task}"); os.makedirs(d)
    with open(os.path.join(d, "w.jsonl"), "w") as f:
        for r in (user(iso(first - 600), brief(task)), status(iso(first + 600), task, "done: findings in report")):
            f.write(json.dumps(r) + "\n")
PY
python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.executescript('create table repos(id text, upstream_url text); create table runs(id text, repo_id text, branch text, status text, pr_url text, created_at text, ci_ready_at text, parked_ms integer);')" "$W/nm.sqlite"
DAY=$(date -u +%Y-%m-%d); NEXT=$(date -u -v+1d +%Y-%m-%d)
HOME="$W/home" FM_HOME="$FM" CLIPROXY_KEY='' python3 "$ROOT/bin/fm-flow-wait.py" \
  --since "$DAY" --until "$NEXT" --as-of "$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ)" \
  --home "$FM" --cache-dir "$W/cache" --out "$W/out" --sessions-dir "$SESS" --nm-db "$W/nm.sqlite" \
  --release-queue "$W/none.jsonl" --no-github --no-flash >/dev/null 2>"$W/err" || { cat "$W/err"; exit 1; }
echo "== tasks.csv (task, outcome, touches, touch_types, zero_touch)"
python3 -c "
import csv,sys
for r in csv.DictReader(open(sys.argv[1])): print(r['task'], r['outcome'], r['touches'], r['touch_types'] or '-', r['zero_touch'])" "$W/out/tasks.csv"
echo "== steers.csv"
cat "$W/out/steers.csv"
echo "== touches.csv"
cat "$W/out/touches.csv"
