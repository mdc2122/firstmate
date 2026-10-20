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
# A run where the three tasks belonged to a since-retired secondmate home, whose
# ledger and archived inbox survive only under the primary's
# data/retired-secondmates/<id>/, must classify the same. A run with neither
# the ledger nor the archive proves the fixture actually depends on both.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || fail "python3 is required by bin/fm-flow-wait.py"
TMP_ROOT=$(fm_test_tmproot fm-flow-wait-ledger-tests)
FLOW="$ROOT/bin/fm-flow-wait.py"

# Build one fixture world under <root>: a fake ~ holding the omp session tree
# and the firstmate home at <root>/home/fm.
# <supervisor-source> is "ledger" (state/supervisor-actions.jsonl), "transcript"
# (the home's omp supervisor session), "retired" (the ledger and archive of a
# retired secondmate home, kept under data/retired-secondmates/mate/), or
# "none" (neither, and no archive).
make_world() {  # <root> <supervisor-source>
  local root=$1 source=$2
  mkdir -p "$root/home/fm/state" "$root/home/fm/data"
  python3 - "$root" "$source" <<'PY'
import json, os, sys
root, source = sys.argv[1], sys.argv[2]
home = os.path.join(root, "home")
fm = os.path.join(home, "fm")
sess = os.path.join(home, ".omp", "agent", "sessions")
# Where the workers' status logs and the supervisor's ledger and archive live.
owner = os.path.join(home, "mate") if source == "retired" else fm
keep = os.path.join(fm, "data", "retired-secondmates", "mate") if source == "retired" else None
if keep:
    os.makedirs(keep)
    open(os.path.join(keep, "home"), "w").write(owner + "\n")

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
    cmd = f"echo \"{line}\" >> '{owner}/state/{task}.status'"
    return {"type": "message", "timestamp": t, "message": {"role": "assistant", "stopReason": stop,
            "content": [{"type": "toolCall", "arguments": {"command": cmd}}]}}

def brief(task):
    return ("\u2063FIRSTMATE_OP: v1 launch-brief: # Task\nThis is a SCOUT task.\n"
            f"echo \"{{state}}: {{note}}\" >> '{owner}/state/{task}.status'\n")

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
data = os.path.join(keep, "data") if keep else os.path.join(fm, "data")
os.makedirs(os.path.join(data, "steered", "inbox", "handled"))
open(os.path.join(data, "steered", "inbox", "handled", "001.msg"), "w").write(msg)

actions = [("send", "steer", "steered", "steered", epoch(10, 30), "direct"),
           ("control", "relaunch", "relaunch", "relaunch", epoch(11, 10), "direct"),
           ("pr-check", "arm", "quiet", "https://github.com/example/repo/pull/9", epoch(9, 2), "fm-watch.sh")]
if source in ("ledger", "retired"):
    write(os.path.join(keep or os.path.join(fm, "state"), "supervisor-actions.jsonl"),
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
  local w ledger_out transcript_out retired_out none_out got want
  for w in ledger transcript retired none; do
    mkdir -p "$TMP_ROOT/$w"
    make_world "$TMP_ROOT/$w" "$w"
    make_nm_db "$TMP_ROOT/$w/nm.sqlite"
    run_flow "$TMP_ROOT/$w" "$TMP_ROOT/$w/out" \
      || fail "fm-flow-wait.py failed on the $w fixture: $(cat "$TMP_ROOT/$w/out.err")"
  done
  ledger_out=$(classification "$TMP_ROOT/ledger/out")
  transcript_out=$(classification "$TMP_ROOT/transcript/out")
  retired_out=$(classification "$TMP_ROOT/retired/out")
  none_out=$(classification "$TMP_ROOT/none/out")
  want='quiet live-proven 0 - True human_answer=0.0
relaunch live-proven 1 relaunch:1 False human_answer=0.0
steered live-proven 1 steer:1 False human_answer=0.33'
  assert_equals "$want" "$ledger_out" "ledger-sourced classification"
  assert_equals "$transcript_out" "$ledger_out" "the ledger must classify the window exactly as the transcript baseline does"
  assert_equals "$ledger_out" "$retired_out" "a retired secondmate's archived ledger and inbox must classify the window as the live ledger does"
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

test_brief_citing_another_tasks_status_joins_its_own_task() {
  # Shape of the 2026-10-09T21-32-36 launch brief: its task text cites another
  # task's status log (`status notes in <home>/state/anatomy.status`), and here
  # also quotes a literal append command for it, before the brief's own
  # status-append line names state/exploit.status. The session must join
  # exploit, not become a second launch of anatomy.
  local root="$TMP_ROOT/cited" got want
  mkdir -p "$root/home/fm/state" "$root/home/fm/data"
  python3 - "$root" <<'PY'
import json, os, sys
root = sys.argv[1]
fm = os.path.join(root, "home", "fm")
sess = os.path.join(root, "home", ".omp", "agent", "sessions")

def rows(task, at, done_at, prose=""):
    brief = ("\u2063FIRSTMATE_OP: v1 launch-brief: # Task\nThis is a SCOUT task.\n" + prose +
             f"# Rules\n   `echo \"{{state}}: {{one short line}}\" >> '{fm}/state/{task}.status'`\n")
    cmd = f"echo \"done: report\" >> '{fm}/state/{task}.status'"
    return [{"type": "message", "timestamp": at, "message": {"role": "user", "content": [{"type": "text", "text": brief}]}},
            {"type": "message", "timestamp": done_at, "message": {"role": "assistant", "stopReason": "stop",
             "content": [{"type": "toolCall", "arguments": {"command": cmd}}]}}]

cite = (f"An investigation (status notes in {fm}/state/anatomy.status) found the source.\n"
        f"It reported with `echo \"done: found it\" >> '{fm}/state/anatomy.status'`.\n")
for task, r in {"anatomy": rows("anatomy", "2026-10-12T09:00:00Z", "2026-10-12T09:30:00Z"),
                "exploit": rows("exploit", "2026-10-12T10:00:00Z", "2026-10-12T10:20:00Z", cite)}.items():
    os.makedirs(os.path.join(sess, f"-orca-workspaces-{task}"))
    with open(os.path.join(sess, f"-orca-workspaces-{task}", "w.jsonl"), "w") as f:
        f.writelines(json.dumps(x) + "\n" for x in r)
PY
  make_nm_db "$root/nm.sqlite"
  run_flow "$root" "$root/out" || fail "fm-flow-wait.py failed on the cited-status fixture: $(cat "$root/out.err")"
  got=$(python3 - "$root/out" <<'PY'
import csv, sys
for r in sorted(csv.DictReader(open(f"{sys.argv[1]}/tasks.csv")), key=lambda r: r["task"]):
    print(r["task"], r["spawn"], r["sessions"], r["touch_types"] or "-")
PY
)
  want='anatomy 2026-10-12T09:00:00Z 1 -
exploit 2026-10-12T10:00:00Z 1 -'
  assert_equals "$want" "$got" "a launch brief citing another task's status log must join its own task"
  pass "a launch brief joins the task its status-append line names, not a status log its task text cites"
}

test_swarm_and_beads_crew_dispatches_are_measured() {
  # A Prime swarm root runs in <home>/data/<id>/sessions/ with no launch brief and
  # appends its status from Python through a name bound in an earlier call; the
  # beads crew works mirror:<row-id> beads inside its own session. Each must become
  # a measured task, and neither may re-join a task a launch brief already owns.
  local root="$TMP_ROOT/dispatch" got want
  mkdir -p "$root/home/fm/state" "$root/home/fm/data/beads/.beads"
  python3 - "$root" <<'PY'
import json, os, sqlite3, sys
root = sys.argv[1]
fm = os.path.join(root, "home", "fm")
sess = os.path.join(root, "home", ".omp", "agent", "sessions")

def write(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.writelines(json.dumps(r) + "\n" for r in rows)

def user(t, text):
    return {"type": "message", "timestamp": t, "message": {"role": "user", "content": [{"type": "text", "text": text}]}}

def call(t, key, body, stop="toolUse"):
    return {"type": "message", "timestamp": t, "message": {"role": "assistant", "stopReason": stop,
            "content": [{"type": "toolCall", "arguments": {key: body}}]}}

# The swarm: the pasted kickoff lost a doubled letter ("kickof"), the status path is
# bound in one call and appended in a later one, and one captain question arrives.
swarm = os.path.join(fm, "data", "swarm-a", "sessions", "s.jsonl")
write(swarm, [
    {"type": "session", "timestamp": "2026-10-12T08:00:00Z"},
    user("2026-10-12T08:00:05Z", f"Read {fm}/data/swarm-a/kickof.md and begin."),
    call("2026-10-12T08:01:00Z", "code", f"STATUS = Path('{fm}/state/swarm-a.status')\nprint(STATUS.exists())"),
    user("2026-10-12T08:20:00Z", "Follow-up question from the captain: which source wins?"),
    call("2026-10-12T08:40:00Z", "code", "if 'done:' not in STATUS.read_text():\n    with STATUS.open('a') as f:\n"
         "        f.write('done: source B wins; report.md written\\n')", "stop"),
])
# Child sessions in the swarm's session directory are not launches: one with rlmDepth 1,
# and one whose first message is a child prompt naming the swarm's evidence directory.
write(os.path.join(fm, "data", "swarm-a", "sessions", "c1.jsonl"), [
    {"type": "session", "timestamp": "2026-10-12T08:05:00Z", "rlmDepth": 1},
    user("2026-10-12T08:05:01Z", f"Read {fm}/data/swarm-a/kickof.md section 2 and report."),
    call("2026-10-12T08:10:00Z", "code", "print(1)", "stop")])
write(os.path.join(fm, "data", "swarm-a", "sessions", "c2.jsonl"), [
    {"type": "session", "timestamp": "2026-10-12T08:06:00Z"},
    user("2026-10-12T08:06:01Z", "Rule: every reply you send must contain at least one tool call until your evidence "
         f"file is written. Your final step is writing {fm}/data/swarm-a/evidence/t1.md."),
    call("2026-10-12T08:11:00Z", "code", "print(1)", "stop")])
# A swarm still working at the readout instant with no done: line is in flight.
write(os.path.join(fm, "data", "swarm-b", "sessions", "s.jsonl"), [
    {"type": "session", "timestamp": "2026-10-12T21:00:00Z"},
    user("2026-10-12T21:00:05Z", f"Read {fm}/data/swarm-b/kickoff.md and begin."),
    call("2026-10-12T22:58:00Z", "code", "print(1)")])
# A sessions directory whose first message names another directory is not a swarm launch.
write(os.path.join(fm, "data", "notes", "sessions", "x.jsonl"),
      [user("2026-10-12T08:00:00Z", "Summarize these transcripts."),
       call("2026-10-12T08:05:00Z", "command", f"echo \"done: x\" >> '{fm}/state/notes.status'", "stop")])
# A launch-brief task whose row the crew also has a bead for keeps its launch-brief join.
brief = ("\u2063FIRSTMATE_OP: v1 launch-brief: # Task\nThis is a SCOUT task.\n"
         f"   `echo \"{{state}}: {{one short line}}\" >> '{fm}/state/briefed.status'`\n")
write(os.path.join(sess, "-orca-workspaces-briefed", "w.jsonl"),
      [user("2026-10-12T07:00:00Z", brief),
       call("2026-10-12T07:30:00Z", "command", f"echo \"done: report\" >> '{fm}/state/briefed.status'", "stop")])

db = sqlite3.connect(os.path.join(fm, "data", "beads", ".beads", "beads.db"))
db.executescript("create table issues(id text, created_at text, closed_at text, close_reason text, deleted_at text);"
                 "create table labels(issue_id text, label text);")
db.executemany("insert into issues values (?,?,?,?,null)", [
    ("fm-1", "2026-10-12T09:00:00.000000+00:00", "2026-10-12T11:00:00.000000+00:00", "done: wrote the audit in https://github.com/acme/vm/pull/7"),
    ("fm-2", "2026-10-12T09:30:00.000000+00:00", None, None),
    ("fm-3", "2026-10-12T06:00:00.000000+00:00", "2026-10-12T06:30:00.000000+00:00", "needs captain: which channel?"),
    ("fm-4", "2026-10-12T07:10:00.000000+00:00", "2026-10-12T07:20:00.000000+00:00", "done"),
    ("fm-5", "2026-10-12T10:00:00.000000+00:00", "2026-10-12T10:05:00.000000+00:00", "no mirror label"),
    ("fm-6", "2026-10-12T10:00:00.000000+00:00", "2026-10-12T10:10:00.000000+00:00", "duplicate of fm-1"),
    ("fm-7", "2026-10-12T10:00:00.000000+00:00", "2026-10-12T10:10:00.000000+00:00", ""),
    ("fm-8", "2026-10-12T10:00:00.000000+00:00", "2026-10-12T10:10:00.000000+00:00", "cancelled")])
db.executemany("insert into labels values (?,?)", [("fm-1", "mirror:chore"), ("fm-1", "chore"), ("fm-2", "mirror:pending"),
                                                   ("fm-3", "mirror:asks"), ("fm-4", "mirror:briefed"),
                                                   ("fm-6", "mirror:dup"), ("fm-7", "mirror:empty"), ("fm-8", "mirror:cancel")])
db.commit()
PY
  make_nm_db "$root/nm.sqlite"
  run_flow "$root" "$root/out" || fail "fm-flow-wait.py failed on the dispatch fixture: $(cat "$root/out.err")"
  got=$(python3 - "$root/out" <<'PY'
import csv, sys
for r in sorted(csv.DictReader(open(f"{sys.argv[1]}/tasks.csv")), key=lambda r: r["task"]):
    print(r["task"], r["source"], r["kind"], r["spawn"], r["end"] or "-", r["outcome"], r["touch_types"] or "-",
          "human_answer=" + r["wait_human_answer_h"], "worker_stall=" + r["wait_worker_stall_h"])
PY
)
  want='asks beads-crew scout 2026-10-12T06:00:00Z - closed-not-live - human_answer=0.0 worker_stall=0.0
briefed launch-brief scout 2026-10-12T07:00:00Z 2026-10-12T07:30:00Z live-proven - human_answer=0.0 worker_stall=0.0
cancel beads-crew scout 2026-10-12T10:00:00Z - closed-not-live - human_answer=0.0 worker_stall=0.0
chore beads-crew scout 2026-10-12T09:00:00Z 2026-10-12T11:00:00Z live-proven - human_answer=0.0 worker_stall=0.0
dup beads-crew scout 2026-10-12T10:00:00Z - closed-not-live - human_answer=0.0 worker_stall=0.0
empty beads-crew scout 2026-10-12T10:00:00Z - closed-not-live - human_answer=0.0 worker_stall=0.0
pending beads-crew scout 2026-10-12T09:30:00Z - in-flight - human_answer=0.0 worker_stall=0.0
swarm-a swarm scout 2026-10-12T08:00:05Z 2026-10-12T08:40:00Z live-proven direct:1 human_answer=0.0 worker_stall=0.0
swarm-b swarm scout 2026-10-12T21:00:05Z - in-flight - human_answer=0.0 worker_stall=0.0'
  assert_equals "$want" "$got" "swarm and beads-crew dispatches must be measured tasks beside the launch-brief ones"
  got=$(jq -c '.by_source | map_values(.measured)' "$root/out/summary.json")
  assert_equals '{"beads-crew":6,"launch-brief":1,"swarm":2}' "$got" "summary splits measured tasks by join"
  pass "a swarm root's session directory and a beads crew mirror bead each join their own task; a launch brief keeps its task"
}

test_ledger_and_transcript_classify_the_same
test_automation_rows_are_not_touches
test_brief_citing_another_tasks_status_joins_its_own_task
test_swarm_and_beads_crew_dispatches_are_measured
