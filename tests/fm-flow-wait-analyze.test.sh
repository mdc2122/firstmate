#!/usr/bin/env bash
# Tests the coverage caveats bin/fm-flow-wait-analyze.py derives from one
# bin/fm-flow-wait.py --out directory, its home's backlog, and its omp session
# root: the main-home supervisor transcript gaps and the settled tasks they
# overlap, the tail clipped off by now_cap, merge_queue item concentration and
# its split by kind and yolo, and the uncovered backlog-row breakdown.
#
# The fixture window is 2026-10-09..2026-10-15 with now_cap 2026-10-15T00:00Z.
# The main home's transcripts leave one 24 h hole (10-10T00 -> 10-11T00) and one
# 30 min hole below the 1 h floor; a secondmate transcript spanning the big hole
# and the action ledger must not close it. The same summary without the
# per-transcript dir field (a run from before it was recorded) must find the
# same hole from the transcript files present in the main home's session dir.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || fail "python3 is required by bin/fm-flow-wait-analyze.py"
TMP_ROOT=$(fm_test_tmproot fm-flow-wait-analyze-tests)
ANALYZE="$ROOT/bin/fm-flow-wait-analyze.py"

# make_run <root> <with-dir: 1|0>: the run dir <root>/out, the home <root>/fm, and
# the session root <root>/sessions (the home's own session dir is <root>/sessions/-fm
# because the test runs with HOME=<root>).
make_run() {
  python3 - "$1" "$2" <<'PY'
import csv, json, os, sys
root, with_dir = sys.argv[1], sys.argv[2] == "1"
out, fm, sess = (os.path.join(root, d) for d in ("out", "fm", "sessions"))
for d in (out, os.path.join(fm, "data"), os.path.join(sess, "-fm"), os.path.join(sess, "-mate"), os.path.join(sess, "-w")):
    os.makedirs(d, exist_ok=True)

COLS = ["task", "home", "kind", "mode", "yolo", "excluded", "spawn", "end", "end_how", "outcome", "prs",
        "touches", "zero_touch", "wait_merge_queue_h"]

def task(name, kind, spawn, end, outcome, zt, yolo="", mq="0.0", excluded="", home="primary", prs="", how=""):
    return dict(task=name, home=home, kind=kind, mode="", yolo=yolo, excluded=excluded, spawn=spawn, end=end,
                end_how=how, outcome=outcome, prs=prs, touches="0" if zt == "True" else "1", zero_touch=zt,
                wait_merge_queue_h=mq)

d = lambda day, h=0: f"2026-10-{day:02d}T{h:02d}:00:00Z"
tasks = [
    task("span-live", "scout", d(9, 20), d(11, 6), "live-proven", "True", home="secondmate:/m"),
    task("span-touched", "ship", d(10, 6), d(10, 12), "live-proven", "False", yolo="on", mq="6.0",
         prs="https://github.com/o/r/pull/1"),
    task("span-closed", "scout", d(10, 3), "", "closed-not-live", "True"),
    task("inflight", "ship", d(10, 1), "", "in-flight", "True"),
    task("before-gap", "ship", d(9, 1), d(9, 23), "live-proven", "True", yolo="off", mq="1.0",
         prs="https://github.com/o/r/pull/2", how="merged"),
    task("late-a", "ship", d(12), d(15, 6), "live-proven", "False", mq="2.0"),
    task("late-b", "scout", d(13), d(15, 3), "live-proven", "True"),
    task("dropped", "scout", d(10, 2), d(10, 4), "live-proven", "True", excluded="standing crew"),
]
with open(os.path.join(out, "tasks.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=COLS)
    w.writeheader()
    w.writerows(tasks)
waits = [
    ("span-touched", "merge_queue", "3.0", "https://github.com/o/r/pull/1 green->merged"),
    ("span-touched", "merge_queue", "3.0", "https://github.com/o/r/pull/1 green, still open"),
    ("before-gap", "merge_queue", "1.0", "https://github.com/o/r/pull/2 green->merged"),
    ("late-a", "merge_queue", "2.0", "paused (rule): holding for the merge line"),
    ("late-a", "ci", "4.0", "https://github.com/o/r/pull/3 validation+checks"),
    ("dropped", "merge_queue", "9.0", "https://github.com/o/r/pull/4 green->merged"),
]
with open(os.path.join(out, "waits.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["task", "cls", "start", "end", "hours", "ref"])
    w.writerows([(t, c, d(12), d(12), h, ref) for t, c, h, ref in waits])
for name, cols in (("touches.csv", "task,at,type,detail,source,classified_by"),
                   ("steers.csv", "task,at,source,script_template,purpose,answerer,classified_by,in_span,body")):
    open(os.path.join(out, name), "w").write(cols + "\n")

def cov(first, last, file, dir_):
    c = dict(first=first, last=last, file=file)
    if with_dir:
        c["dir"] = dir_
    return c

transcripts = [
    cov(d(8), d(10), "a.jsonl", "-fm"),
    cov(d(9, 12), d(9, 18), "b.jsonl", "-fm"),
    cov(d(11), "2026-10-12T12:00:00Z", "c.jsonl", "-fm"),
    cov("2026-10-12T12:30:00Z", d(16), "d.jsonl", "-fm"),
    cov(d(9), d(14), "mate.jsonl", "-mate"),
    cov(d(10, 1), d(10, 2), "state/supervisor-actions.jsonl", "fm"),
]
for c in transcripts:
    if "/" not in c["file"]:
        open(os.path.join(sess, "-mate" if c["file"] == "mate.jsonl" else "-fm", c["file"]), "w").write("{}\n")
miss = ["prime-swarm-plan", "beads-row", "before-row", "after-row", "inwin-row", "direct-row"]
json.dump(dict(window=["2026-10-09", "2026-10-15"], now_cap=d(15),
               coverage=dict(supervisor_transcripts=transcripts,
                             backlog_rows_closed_in_window_without_worker_transcript=miss)),
          open(os.path.join(out, "summary.json"), "w"))
open(os.path.join(fm, "data", "done-archive.md"), "w").write(
    "## Archived 2026-10-14\n"
    "- [x] beads-row - Fix the flake the beads crew found (kind: ship) (done 2026-10-12)\n"
    "- [x] prime-swarm-plan - Plan the next run (kind: scout) (reported 2026-10-11)\n")
open(os.path.join(fm, "data", "backlog.md"), "w").write(
    "## Done\n- [x] direct-row - Captain call recorded directly (kind: ship) (done 2026-10-13)\n")
brief = "\u2063FIRSTMATE_OP: v1 launch-brief: inbox is {}/state/{}.inbox\n"
for stamp, row in (("2026-10-01", "before-row"), ("2026-10-15", "after-row"), ("2026-10-10", "inwin-row")):
    open(os.path.join(sess, "-w", f"{stamp}T00-00-00-000Z_x.jsonl"), "w").write(json.dumps(brief.format(fm, row)) + "\n")
# A session naming a row's inbox without a launch brief must not count as one.
open(os.path.join(sess, "-w", "2026-10-11T00-00-00-000Z_y.jsonl"), "w").write(f"see {fm}/state/direct-row.inbox\n")
PY
}

# caveats <root>: the coverage-caveat figures the analyze script printed, one per line.
caveats() {
  HOME="$1" python3 "$ANALYZE" "$1/out" --home "$1/fm" --sessions-dir "$1/sessions" >"$1/analysis.json" 2>"$1/err" \
    || fail "fm-flow-wait-analyze.py failed: $(cat "$1/err")"
  python3 - "$1/analysis.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
for k in ("supervisor_transcript_gaps", "ended_after_cap", "merge_queue_by_kind_yolo", "by_home",
          "zero_touch_live_ships", "uncovered_rows", "uncovered_rows_total"):
    print(k, json.dumps(a[k], sort_keys=True))
mq = a["merge_queue_per_item_h"]
print("merge_queue_items", json.dumps({k: mq[k] for k in ("n", "sum", "top10_sum", "ge5h_n", "ge5h_sum")}, sort_keys=True))
PY
}

test_breakdowns() {
  local run="$TMP_ROOT/dir" got want
  mkdir -p "$run"
  make_run "$run" 1
  got=$(caveats "$run")
  want='supervisor_transcript_gaps [{"end": "2026-10-11T00:00:00Z", "hours": 24.0, "settled": 3, "start": "2026-10-10T00:00:00Z", "zero_touch_any": 2, "zero_touch_live": [["span-live", "secondmate:/m"]]}]
ended_after_cap {"n": 2, "tail_h": 9.0, "zero_touch": 1}
merge_queue_by_kind_yolo {"scout/yolo=-": 0.0, "ship/yolo=-": 2.0, "ship/yolo=off": 1.0, "ship/yolo=on": 6.0}
by_home {"primary": 6, "secondmate:/m": 1}
zero_touch_live_ships [["before-gap", "https://github.com/o/r/pull/2", "merged"]]
uncovered_rows {"in-window launch brief, session-match miss": {"ids": ["inwin-row"], "n": 1}, "no launch brief anywhere (firstmate-direct, captain call, or done by another task'"'"'s worker)": {"ids": ["direct-row"], "n": 1}, "secondmate / beads crew": {"ids": ["beads-row"], "n": 1}, "spawned before window": {"ids": ["before-row"], "n": 1}, "spawned on/after window end": {"ids": ["after-row"], "n": 1}, "swarm (no fm-spawn launch brief)": {"ids": ["prime-swarm-plan"], "n": 1}}
uncovered_rows_total 6
merge_queue_items {"ge5h_n": 1, "ge5h_sum": 6.0, "n": 3, "sum": 9.0, "top10_sum": 9.0}'
  assert_equals "$want" "$got" "coverage caveats on the fixture run"
  pass "gap overlap, cap-clipped tail, merge_queue concentration, and uncovered rows are derived from one run"
}

test_summary_without_transcript_dirs_finds_the_same_gap() {
  local with="$TMP_ROOT/dir" without="$TMP_ROOT/nodir" got want
  mkdir -p "$without"
  make_run "$without" 0
  want=$(caveats "$with" | grep '^supervisor_transcript_gaps ')
  got=$(caveats "$without" | grep '^supervisor_transcript_gaps ')
  assert_equals "$want" "$got" "a summary without transcript dirs must place the gap from the main home's session files"
  pass "a summary recorded before transcript dirs finds the main-home gap from the session files"
}

test_breakdowns
test_summary_without_transcript_dirs_finds_the_same_gap
