#!/usr/bin/env python3
"""fm-flow-wait-analyze.py RUN_DIR - derive the readout figures not already in summary.json.

Reads tasks.csv, touches.csv, waits.csv, steers.csv from one bin/fm-flow-wait.py --out
directory and prints JSON: touch categories, tasks touched per category, zero-touch
counterfactuals (which touch categories, if removed, would flip how many live tasks to
zero-touch), touches per ship and scout, decision answers (no-mistakes ask-user gate
answers are the ones naming a run key nm-<ULID>), per-item wait distributions for
merge_queue, release, and ci, and per-day hours by class. Read-only; writes nothing.

Usage:
  bin/fm-flow-wait-analyze.py RUN_DIR > RUN_DIR/analysis.json
"""
import argparse, collections, csv, json, re, statistics, sys

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("run", metavar="RUN_DIR", help="a bin/fm-flow-wait.py --out directory")
run = ap.parse_args().run
T = {x["task"]: x for x in csv.DictReader(open(f"{run}/tasks.csv"))}
TO = list(csv.DictReader(open(f"{run}/touches.csv")))
W = list(csv.DictReader(open(f"{run}/waits.csv")))
S = list(csv.DictReader(open(f"{run}/steers.csv")))
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
            m = re.search(r"pull/(\d+)", w["ref"])
            k = m.group(1) if m else "paused:" + w["task"]
            d[k] += float(w["hours"])
            owner[k] = w["task"]
    v = sorted(d.values())
    if not v:
        out[f"{cls}_per_item_h"] = dict(n=0, median=None, p90=None, sum=0.0, top=[])
        continue
    out[f"{cls}_per_item_h"] = dict(n=len(v), median=round(statistics.median(v), 2), p90=round(v[int(0.9 * (len(v) - 1))], 2),
                                    sum=round(sum(v), 1), top=[(k, owner[k], round(x, 1)) for k, x in sorted(d.items(), key=lambda x: -x[1])[:10]])
dd = collections.defaultdict(collections.Counter)
for w in W:
    dd[w["start"][:10]][w["cls"]] += float(w["hours"])
out["hours_by_day_and_class"] = {d: {k: round(v, 1) for k, v in sorted(dd[d].items())} for d in sorted(dd)}
json.dump(out, sys.stdout, indent=1)
print()
