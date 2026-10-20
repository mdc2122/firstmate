#!/usr/bin/env python3
"""fm-flow-wait-analyze.py RUN_DIR - derive the readout figures not already in summary.json.

Reads tasks.csv, touches.csv, waits.csv, steers.csv, and summary.json from one
bin/fm-flow-wait.py --out directory and prints JSON: touch categories, tasks touched per
category, zero-touch counterfactuals (which touch categories, if removed, would flip how
many live tasks to zero-touch), touches per ship and scout, decision answers (no-mistakes
ask-user gate answers are the ones naming a run key nm-<ULID>), per-item wait
distributions and concentration for merge_queue, release, and ci, and per-day hours by
class. Rows with a non-empty excluded field are dropped, as in summary.json. touches.csv,
waits.csv, and steers.csv carry no home column, so task ids are assumed unique across the
accounted homes. Read-only; writes nothing.

It also prints the coverage caveats every weekly readout states:
  * denominators by kind/outcome/zero-touch and by home, and the zero-touch live ships
  * supervisor_transcript_gaps: each hole of at least --gap-min-hours in the --home main
    home's supervisor transcript coverage (summary.json coverage.supervisor_transcripts)
    that meets the window, with the settled tasks whose spawn..end span overlaps it,
    since supervisor touches inside a hole went unseen before the action ledger
  * ended_after_cap: tasks whose END came after now_cap, and the wait hours clipped off
  * merge_queue hours by kind and yolo posture
  * uncovered_rows: the backlog rows closed in the window with no worker transcript
    (summary.json coverage), classed by why: swarm, secondmate / beads crew, a launch brief
    before, inside, or after the window (from --sessions-dir), or no launch brief at all

Usage:
  bin/fm-flow-wait-analyze.py RUN_DIR [--home DIR] [--sessions-dir DIR] [--gap-min-hours H]
      > RUN_DIR/analysis.json
  --home defaults to $FM_HOME, else this script's checkout root, and must be the --home the
  run accounted; --sessions-dir defaults to ~/.omp/agent/sessions.
"""
import argparse, collections, csv, glob, importlib.util, json, os, re, statistics, sys

BIN = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("run", metavar="RUN_DIR", help="a bin/fm-flow-wait.py --out directory")
ap.add_argument("--home", default=os.environ.get("FM_HOME") or os.path.dirname(BIN),
                help="the firstmate home the run accounted (default: $FM_HOME, else this checkout)")
ap.add_argument("--sessions-dir", default=os.path.expanduser("~/.omp/agent/sessions"),
                help="omp session root (default: %(default)s)")
ap.add_argument("--gap-min-hours", type=float, default=1.0,
                help="shortest supervisor transcript hole reported (default: %(default)s)")
args = ap.parse_args()
run = args.run
# fm-flow-wait.py owns timestamp parsing and omp's session directory naming.
_spec = importlib.util.spec_from_file_location("fm_flow_wait", os.path.join(BIN, "fm-flow-wait.py"))
fw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fw)
fw.SESS = args.sessions_dir
T = {x["task"]: x for x in csv.DictReader(open(f"{run}/tasks.csv")) if not x["excluded"]}
ids = set(T)
TO = [x for x in csv.DictReader(open(f"{run}/touches.csv")) if x["task"] in ids]
W = [x for x in csv.DictReader(open(f"{run}/waits.csv")) if x["task"] in ids]
S = [x for x in csv.DictReader(open(f"{run}/steers.csv")) if x["task"] in ids]
SUMMARY = json.load(open(f"{run}/summary.json"))
since, until = SUMMARY["window"]
settled = [x for x in T.values() if x["outcome"] != "in-flight"]
live = [x for x in settled if x["outcome"] == "live-proven"]
by = collections.defaultdict(list)
for t in TO:
    by[t["task"]].append(t)


def cat(t):
    if t["type"] == "steer":
        m = re.match(r"\[([^/\]]+)/([^\]]+)\]", t["detail"])
        return "steer:" + (m.group(1) if m else "?")
    return t["type"]


out = {}
out["touch_categories_settled"] = collections.Counter(cat(t) for x in settled for t in by[x["task"]]).most_common()
tc = collections.Counter()
for x in settled:
    for k in {cat(t) for t in by[x["task"]]}:
        tc[k] += 1
out["tasks_touched_by_category_settled"] = tc.most_common()


def zt(remove):
    return sum(1 for x in live if all(cat(t) in remove for t in by[x["task"]]))


handoff = {"re-point", "steer:merge_or_release_routing", "steer:go_ahead_after_external_event"}
decide = {"steer:decision_answer", "answer"}
out["counterfactual_zero_touch_live"] = {
    "baseline": zt(set()),
    "minus_merge_release_handoffs": zt(handoff),
    "minus_handoffs_and_decision_answers": zt(handoff | decide),
    "minus_handoffs_decisions_relaunch": zt(handoff | decide | {"relaunch"}),
    "settled_denominator": len(settled),
}
for k in ("ship", "scout"):
    xs = [int(x["touches"]) for x in settled if x["kind"] == k]
    out[f"{k}_touches_per_task"] = dict(n=len(xs), median=statistics.median(xs) if xs else None,
                                        mean=round(sum(xs) / len(xs), 1) if xs else None)
da = [s for s in S if s["purpose"] == "decision_answer" and s["in_span"] == "True"]
NM_GATE = re.compile(r"\bnm-[0-7][0-9A-HJKMNP-TV-Z]{2}")   # a no-mistakes run id is a ULID
out["decision_answers"] = dict(total=len(da), no_mistakes_gate=len([s for s in da if NM_GATE.search(s["body"])]),
                               captain=len([s for s in da if s["answerer"] == "captain"]))
for cls in ("merge_queue", "release", "ci"):
    d = collections.defaultdict(float)
    owner = {}
    for w in W:
        if w["cls"] == cls:
            m = re.search(r"github\.com/([^/\s]+/[^/\s]+)/pull/(\d+)", w["ref"])
            k = f"{m.group(1)}#{m.group(2)}" if m else "paused:" + w["task"]
            d[k] += float(w["hours"])
            owner[k] = w["task"]
    v = sorted(d.values())
    if not v:
        out[f"{cls}_per_item_h"] = dict(n=0, median=None, p90=None, sum=0.0, top10_sum=0.0, ge5h_n=0, ge5h_sum=0.0, top=[])
        continue
    out[f"{cls}_per_item_h"] = dict(n=len(v), median=round(statistics.median(v), 2), p90=round(v[int(0.9 * (len(v) - 1))], 2),
                                    sum=round(sum(v), 1), top10_sum=round(sum(v[-10:]), 1),
                                    ge5h_n=sum(x >= 5 for x in v), ge5h_sum=round(sum(x for x in v if x >= 5), 1),
                                    top=[(k, owner[k], round(x, 1)) for k, x in sorted(d.items(), key=lambda x: -x[1])[:10]])
dd = collections.defaultdict(collections.Counter)
for w in W:
    dd[w["start"][:10]][w["cls"]] += float(w["hours"])
out["hours_by_day_and_class"] = {d: {k: round(v, 1) for k, v in sorted(dd[d].items())} for d in sorted(dd)}

# ---------------------------------------------------------------- coverage caveats
tasks = list(T.values())
out["by_kind_outcome_zero_touch"] = {"|".join(k): n for k, n in sorted(collections.Counter(
    (x["kind"], x["outcome"], x["zero_touch"]) for x in tasks).items())}
out["by_home"] = dict(collections.Counter(x["home"] for x in tasks))
out["zero_touch_live_ships"] = [(x["task"], x["prs"], x["end_how"]) for x in live
                                if x["zero_touch"] == "True" and x["kind"] == "ship"]

main_sessions = fw.session_dir(args.home)


def main_home_transcript(c):
    if "/" in c["file"]:
        return False   # an action ledger (state/supervisor-actions.jsonl), not a transcript
    if "dir" in c:
        return c["dir"] == os.path.basename(main_sessions)
    return os.path.exists(os.path.join(main_sessions, c["file"]))   # a summary from before coverage named its dir


gaps, reach = [], None
for first, last in sorted((c["first"], c["last"]) for c in SUMMARY["coverage"]["supervisor_transcripts"]
                          if main_home_transcript(c)):
    if (reach is not None and first > reach and first > since and reach < until
            and fw.ts(first) - fw.ts(reach) >= args.gap_min_hours * 3600):
        gaps.append((reach, first))
    reach = last if reach is None else max(reach, last)
out["supervisor_transcript_gaps"] = []
for start, end in gaps:
    ov = [x for x in settled if x["spawn"] < end and (x["end"] or "9") > start]
    out["supervisor_transcript_gaps"].append(dict(
        start=start, end=end, hours=round((fw.ts(end) - fw.ts(start)) / 3600, 1), settled=len(ov),
        zero_touch_any=sum(x["zero_touch"] == "True" for x in ov),
        zero_touch_live=[(x["task"], x["home"]) for x in ov if x["zero_touch"] == "True" and x["outcome"] == "live-proven"]))

cap = SUMMARY["now_cap"]
late = [x for x in tasks if x["end"] and x["end"] > cap]
out["ended_after_cap"] = dict(n=len(late), tail_h=round(sum((fw.ts(x["end"]) - fw.ts(cap)) / 3600 for x in late), 1),
                              zero_touch=sum(x["zero_touch"] == "True" for x in late))

yo = collections.Counter()
for x in tasks:
    yo[x["kind"] + "/yolo=" + (x["yolo"] or "-")] += float(x["wait_merge_queue_h"])
out["merge_queue_by_kind_yolo"] = {k: round(h, 1) for k, h in yo.items()}

# Uncovered backlog rows: classify each by why no worker transcript was measured.
miss = SUMMARY["coverage"]["backlog_rows_closed_in_window_without_worker_transcript"]
backlog = "".join(open(p, errors="replace").read() for p in
                  (os.path.join(args.home, "data", n) for n in ("done-archive.md", "backlog.md")) if os.path.exists(p))
launch = collections.defaultdict(list)   # row id -> launch-brief session dates naming its inbox
lo = fw.ts(since + "T00:00:00Z") - 14 * 86400
for f in glob.glob(os.path.join(args.sessions_dir, "*", "*.jsonl")) if miss else []:
    try:
        if os.path.getmtime(f) < lo:
            continue
        with open(f, errors="replace") as fh:
            head = fh.read(300000)
    except OSError:
        continue
    if "FIRSTMATE_OP: v1 launch-brief" not in head:
        continue
    for m in miss:
        if f"state/{m}.inbox" in head:
            launch[m].append(os.path.basename(f)[:10])
uncovered = {}
for m in miss:
    row = re.search(r"^- \[.\] " + re.escape(m) + r" - (.*)$", backlog, re.M)
    line = row.group(1) if row else ""
    if re.search(r"swarm|prime|grok", m + line, re.I):
        k = "swarm (no fm-spawn launch brief)"
    elif re.search(r"beads|secondmate|ab-beads|board-drain|supply", line, re.I) and m not in launch:
        k = "secondmate / beads crew"
    elif m in launch:
        d = max(launch[m])
        k = ("spawned before window" if d < since else "spawned on/after window end" if d >= until
             else "in-window launch brief, session-match miss")
    else:
        k = "no launch brief anywhere (firstmate-direct, captain call, or done by another task's worker)"
    uncovered.setdefault(k, []).append(m)
out["uncovered_rows"] = {k: dict(n=len(v), ids=v) for k, v in uncovered.items()}
out["uncovered_rows_total"] = len(miss)
json.dump(out, sys.stdout, indent=1)
print()
