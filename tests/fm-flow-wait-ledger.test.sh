#!/usr/bin/env bash
# Tests that bin/fm-flow-wait.py reads supervisor touches from the action
# ledger (bin/fm-action-ledger-lib.sh) and steers from a torn-down task's
# archived inbox (data/<id>/inbox/), and that it classifies one fixture window
# the same whether those facts come from the ledger or from the supervisor
# transcript the baseline readout was built from.
#
# The fixture home holds three scouts, all spawned and finished in the window:
#   quiet    no touch at all                          -> zero-touch
#   steered  one fm-send steer; the worker transcript never shows the record,
#            so its body comes only from the teardown archive and its send only
#            from the supervisor source; it answers the open needs-decision
#                                                      -> 1 steer touch and a
#                                                         human_answer wait
#   relaunch one fm-control relaunch                   -> 1 relaunch touch
# plus one automation row (origin fm-watch.sh) that must never count as a touch.
# A third run with neither the ledger nor the archive proves the fixture
# actually depends on both.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || fail "python3 is required by bin/fm-flow-wait.py"
TMP_ROOT=$(fm_test_tmproot fm-flow-wait-ledger-tests)
FLOW="$ROOT/bin/fm-flow-wait.py"

# Build one fixture world under <root>: a fake ~ holding the omp session tree
# and the firstmate home at <root>/home/fm.
# <supervisor-source> is "ledger" (state/supervisor-actions.jsonl), "transcript"
# (the home's omp supervisor session), or "none" (neither, and no archive).
make_world() {  # <root> <supervisor-source>
  local root=$1 source=$2
  mkdir -p "$root/home/fm/state" "$root/home/fm/data"
  python3 - "$root" "$source" <<'PY'
import json, os, sys
root, source = sys.argv[1], sys.argv[2]
home = os.path.join(root, "home")
fm = os.path.join(home, "fm")
sess = os.path.join(home, ".omp", "agent", "sessions")

def iso(h, m, s=0):
    return f"2026-10-12T{h:02d}:{m:02d}:{s:02d}Z"

def epoch(h, m, s=0):
    from datetime import datetime
    return int(datetime.fromisoformat(iso(h, m, s).replace("Z", "+00:00")).timestamp())

def write(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")

def user(t, text):
    return {"type": "message", "timestamp": t, "message": {"role": "user", "content": [{"type": "text", "text": text}]}}

def status(t, task, line, stop="toolUse"):
    cmd = f"echo \"{line}\" >> '{fm}/state/{task}.status'"
    return {"type": "message", "timestamp": t, "message": {"role": "assistant", "stopReason": stop,
            "content": [{"type": "toolCall", "arguments": {"command": cmd}}]}}

def brief(task):
    return ("\u2063FIRSTMATE_OP: v1 launch-brief: # Task\nThis is a SCOUT task.\n"
            f"echo \"{{state}}: {{note}}\" >> '{fm}/state/{task}.status'\n")

steer_body = "Answer to your question: take option B and continue."
msg = f"schema=fm-task-inbox.v1\nat={iso(10, 30)}\n--\n{steer_body}\n"
workers = {
    "quiet": [user(iso(9, 0), brief("quiet")), status(iso(9, 5), "quiet", "done: findings in report", "stop")],
    "steered": [user(iso(10, 0), brief("steered")),
                status(iso(10, 10), "steered", "needs-decision [key=opt]: option A or B?", "stop"),
                status(iso(10, 40), "steered", "done: went with B", "stop")],
    "relaunch": [user(iso(11, 0), brief("relaunch")), status(iso(11, 5), "relaunch", "working: on it", "stop"),
                 status(iso(11, 20), "relaunch", "done: finished after relaunch", "stop")],
}
for task, rows in workers.items():
    write(os.path.join(sess, f"-orca-workspaces-{task}", "w.jsonl"), rows)

# The steered task is torn down: its inbox lives only in the teardown archive.
os.makedirs(os.path.join(fm, "data", "steered", "inbox", "handled"))
open(os.path.join(fm, "data", "steered", "inbox", "handled", "001.msg"), "w").write(msg)

actions = [("send", "steer", "steered", "steered", epoch(10, 30), "direct"),
           ("control", "relaunch", "relaunch", "relaunch", epoch(11, 10), "direct"),
           ("pr-check", "arm", "quiet", "https://github.com/example/repo/pull/9", epoch(9, 2), "fm-watch.sh")]
if source == "ledger":
    write(os.path.join(fm, "state", "supervisor-actions.jsonl"),
          [{"at": "", "epoch": e, "task": task, "verb": v, "action": a, "target": tgt, "origin": o}
           for v, a, task, tgt, e, o in actions])
elif source == "transcript":
    calls = [(iso(10, 30), "FM_HOME=~/fm bin/fm-send.sh steered 'Answer to your question'"),
             (iso(11, 10), "bin/fm-control.sh relaunch relaunch --note x")]
    write(os.path.join(sess, "-fm", "s.jsonl"),
          [{"type": "message", "timestamp": t, "message": {"role": "assistant",
            "content": [{"type": "toolCall", "arguments": {"command": c}}]}} for t, c in calls])
else:   # "none": no supervisor source and no archive
    import shutil
    shutil.rmtree(os.path.join(fm, "data", "steered"))
PY
}

run_flow() {  # <root> <out>
  local root=$1 out=$2
  HOME="$root/home" FM_HOME="$root/home/fm" CLIPROXY_KEY='' python3 "$FLOW" \
    --since 2026-10-12 --until 2026-10-13 --as-of 2026-10-12T23:00:00Z \
    --home "$root/home/fm" --cache-dir "$root/cache" --out "$out" \
    --sessions-dir "$root/home/.omp/agent/sessions" --nm-db "$root/nm.sqlite" \
    --release-queue "$root/none.jsonl" --no-github --no-flash >/dev/null 2>"$out.err"
}

make_nm_db() {  # <path>
  python3 - "$1" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("create table repos(id text, upstream_url text);"
                "create table runs(id text, repo_id text, branch text, status text, pr_url text,"
                " created_at text, ci_ready_at text, parked_ms integer);")
c.commit()
PY
}

# Per-task touches and wait classes the fixture must produce, as stable text.
classification() {  # <out>
  python3 - "$1" <<'PY'
import csv, sys
out = sys.argv[1]
tasks = {r["task"]: r for r in csv.DictReader(open(f"{out}/tasks.csv"))}
for t in sorted(tasks):
    r = tasks[t]
    print(t, r["outcome"], r["touches"], r["touch_types"] or "-", r["zero_touch"],
          "human_answer=" + r["wait_human_answer_h"])
PY
}

test_ledger_and_transcript_classify_the_same() {
  local w ledger_out transcript_out none_out got want
  for w in ledger transcript none; do
    mkdir -p "$TMP_ROOT/$w"
    make_world "$TMP_ROOT/$w" "$w"
    make_nm_db "$TMP_ROOT/$w/nm.sqlite"
    run_flow "$TMP_ROOT/$w" "$TMP_ROOT/$w/out" \
      || fail "fm-flow-wait.py failed on the $w fixture: $(cat "$TMP_ROOT/$w/out.err")"
  done
  ledger_out=$(classification "$TMP_ROOT/ledger/out")
  transcript_out=$(classification "$TMP_ROOT/transcript/out")
  none_out=$(classification "$TMP_ROOT/none/out")
  want='quiet live-proven 0 - True human_answer=0.0
relaunch live-proven 1 relaunch:1 False human_answer=0.0
steered live-proven 1 steer:1 False human_answer=0.33'
  assert_equals "$want" "$ledger_out" "ledger-sourced classification"
  assert_equals "$transcript_out" "$ledger_out" "the ledger must classify the window exactly as the transcript baseline does"
  assert_not_equals "$ledger_out" "$none_out" "the fixture must depend on the ledger and the archive"
  got=$(jq -r '.zero_touch_live, .settled, .zero_touch_share_of_settled_pct' "$TMP_ROOT/ledger/out/summary.json" | tr '\n' ' ')
  assert_equals '1 3 33.3 ' "$got" "zero-touch share read from the ledger"
  grep -F 'take option B' "$TMP_ROOT/ledger/out/steers.csv" | grep -q ',live-inbox,' \
    || fail "the steer body was not read from the archived inbox: $(cat "$TMP_ROOT/ledger/out/steers.csv")"
  jq -e '[.coverage.supervisor_transcripts[] | select(.file == "state/supervisor-actions.jsonl")] | length == 1' \
    "$TMP_ROOT/ledger/out/summary.json" >/dev/null \
    || fail "summary coverage does not name the action ledger it read"
  pass "touches read from the action ledger and an archived inbox classify the fixture exactly as the transcript baseline"
}

test_automation_rows_are_not_touches() {
  # The fixture's fm-watch.sh pr-check row names the quiet task; it stays zero-touch.
  grep -q '^quiet,' "$TMP_ROOT/ledger/out/touches.csv" \
    && fail "an automation-origin ledger row was counted as a human touch"
  pass "a ledger row written by firstmate automation is never a human touch"
}

test_ledger_and_transcript_classify_the_same
test_automation_rows_are_not_touches
