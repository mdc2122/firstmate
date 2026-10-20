#!/usr/bin/env python3
"""fm-merge-path-window-stats.py - read-only merge-path timing over one absolute time window.

A time-windowed slice of bin/fm-merge-path-stats.py. That harness bounds CI
rows by --days and GitHub rows by --prs, so it cannot isolate the period after
one speed fix landed. This tool imports the harness's own functions (api, qs,
T, github, releases) unchanged and restricts every stage to [--since, --until],
so a re-measure uses the same instrument, sliced in time.

Extra over the harness:
  - CI job AND test-step duration per runner and triggering event (a
    gitea-mq/* head branch counts as merge_branch)
  - each merged PR's auto-merge arm classified from the supervisor action
    ledger (format: bin/fm-action-ledger-lib.sh): watcher (the nearest
    pr-merge row has origin fm-watch.sh), hand (any other origin), or
    unledgered (no pr-merge row from 60 s before to 5 s after the arm)
  - merge-to-next-arm cycles split by that arm class
  - PR-hours inside the window by state, covering PRs merged in the window,
    PRs merged after it, and the merge line's still-open entries

Sources (all reads; nothing is mutated):
  - GitHub via gh-axi       --repo's merged PRs, issue timelines, head
                            check-runs, open merge-line PRs, and pytest-checks.yml
                            runs with their jobs and steps
  - action ledger           --actions (default <home>/state/supervisor-actions.jsonl)
  - merge-line record       --merge-line (default <home>/state/merge-lines/
                            github@github.com@<OWNER>%2F<NAME>; format:
                            bin/fm-merge-line.sh); point it at a snapshot when
                            the live line has moved on since --until
  - release queue ledger    <--repo-dir>/.runtime/release-queue/queue.jsonl
  - origin/main first-parent history of the local --repo-dir checkout
<home> is --home, default $FM_HOME, else this script's checkout root.
The only write is the --out directory.

Usage:
  bin/fm-merge-path-window-stats.py --since ISO --until ISO --out DIR
      [--ci-since ISO] [--prs 60] [--repo OWNER/NAME] [--repo-dir ~/<NAME>]
      [--home DIR] [--actions FILE] [--merge-line FILE]
  ISO is a UTC timestamp such as 2026-10-16T10:02:23Z. --ci-since moves only
  the CI window's start (default --since). --prs bounds the GitHub stages to
  the N most recently merged PRs, so it must reach back past --since.

Output: writes window_stats.json, window_pr_table.csv (one row per PR merged
in the window, epoch seconds), ci_jobs.csv, open_line_entries.json, and
release_tickets.json into --out, and prints window_stats.json without its
cycles list. Every stage is {n, p50, p90, max, sum_h}: p50/p90/max in
minutes, sum in hours.
  ci.<runner>.<event|all>.{job,test_step}
                                 successful pytest job and "Run full test
                                 suite" step durations
  github.<stage>                 the harness's GitHub stages over PRs merged
                                 in the window, plus
                                 merge_to_next_arm_when_next_was_green[<class>]
                                 and arm_class_counts
  release.*                      the harness's release stages, with
                                 canary_to_promote and deploy_to_done over
                                 tickets joined in the window, plus
                                 advance_lane (release-advance tickets joined
                                 in the window)
  pr_hours_in_window.<state>     {h, share}: green_unarmed_queue_busy,
                                 green_unarmed_queue_idle, armed_not_enqueued,
                                 in_queue, merged_not_joined, joined_not_live;
                                 every interval clipped to the window
  queue_wall                     window hours and hours gitea-mq held an entry
"""
import argparse, csv, importlib.util, json, os, subprocess, time
from concurrent.futures import ThreadPoolExecutor

CODE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "fm_merge_path_stats", os.path.join(CODE_ROOT, "bin", "fm-merge-path-stats.py"))
H = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(H)
api, qs, T = H.api, H.qs, H.T

ARM_CLASSES = ("watcher", "hand", "unledgered")
PR_HOUR_STATES = ("green_unarmed_queue_busy", "green_unarmed_queue_idle", "armed_not_enqueued",
                  "in_queue", "merged_not_joined", "joined_not_live")
ARM_LEDGER_BEFORE_S, ARM_LEDGER_AFTER_S = 60, 5


def clip(start, end, w0, w1):
    """Seconds of [start, end] that fall inside the window [w0, w1]."""
    return max(0.0, min(end, w1) - max(start, w0))


def merge_intervals(intervals):
    out = []
    for s, e in sorted(intervals):
        if out and s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return out


def overlap(start, end, merged):
    """Seconds of [start, end] covered by the disjoint `merged` intervals."""
    return sum(max(0.0, min(end, be) - max(start, bs)) for bs, be in merged)


def arm_class(repo, pr, armed, merges):
    """Classify --repo PR `pr`'s auto-merge arm at epoch `armed` against the ledger's pr-merge rows."""
    if not armed:
        return None
    tail = f"github.com/{repo}/pull/{pr}"
    near = [x for x in merges if x["target"].endswith(tail)
            and armed - ARM_LEDGER_BEFORE_S <= x["epoch"] <= armed + ARM_LEDGER_AFTER_S]
    if not near:
        return "unledgered"
    return "watcher" if max(near, key=lambda x: x["epoch"])["origin"] == "fm-watch.sh" else "hand"


def ledger_merges(path):
    with open(path) as f:
        acts = [json.loads(l) for l in f if l.strip()]
    return [x for x in acts if x.get("verb") == "pr-merge" and x.get("action") == "merge"]


def cycles(rows, w0, w1):
    """Consecutive merges (rows sorted by merged) whose both ends fall in the window."""
    out = []
    for prev, nxt in zip(rows, rows[1:]):
        if not (w0 <= prev["merged"] <= w1) or nxt["merged"] > w1:
            continue
        out.append(dict(prev=prev["pr"], nxt=nxt["pr"], prev_merged=prev["merged"], nxt_green=nxt["green"],
                        nxt_armed=nxt["armed"], nxt_arm_class=nxt["arm_class"],
                        next_was_green=bool(nxt["green"] and nxt["green"] < prev["merged"]),
                        merge_to_next_arm=(nxt["armed"] - prev["merged"]) if nxt["armed"] else None,
                        merge_to_next_merge=nxt["merged"] - prev["merged"]))
    return out


def pr_hours(prs, busy, w0, w1):
    """Per-PR seconds in each PR_HOUR_STATES state inside [w0, w1].

    `prs` rows carry green, armed, mq_start, merged (None while open at --until),
    and optionally mq_done, joined, and live; `busy` is the merged gitea-mq-occupied intervals.
    """
    per_pr = {}
    for r in prs:
        if not r["green"]:
            continue
        mine = per_pr.setdefault(r["pr"], {k: 0.0 for k in PR_HOUR_STATES})
        mine["open_at_until"] = r.get("merged") is None
        s, e = max(r["green"], w0), min(r["armed"] or r.get("merged") or w1, w1)
        if e > s:
            b = overlap(s, e, busy)
            mine["green_unarmed_queue_busy"] += b
            mine["green_unarmed_queue_idle"] += (e - s) - b
        if r["armed"]:
            mine["armed_not_enqueued"] += clip(r["armed"], r["mq_start"] or r.get("merged") or w1, w0, w1)
        if r["mq_start"]:
            mine["in_queue"] += clip(r["mq_start"], r.get("merged") or r.get("mq_done") or w1, w0, w1)
        if r.get("merged"):
            mine["merged_not_joined"] += clip(r["merged"], r.get("joined") or w1, w0, w1)
            if r.get("joined"):
                mine["joined_not_live"] += clip(r["joined"], r.get("live") or w1, w0, w1)
    return per_pr


def busy_intervals(rows, open_rows, w0, w1):
    """Merged intervals gitea-mq held an entry: merged PRs until their merge, open ones until the check ended."""
    busy = [(r["mq_start"], r["merged"]) for r in rows
            if r["mq_start"] and r["merged"] and r["merged"] >= w0 and r["mq_start"] <= w1]
    busy += [(r["mq_start"], r["mq_done"] or w1) for r in open_rows
             if r["mq_start"] and r["mq_start"] <= w1 and (r["mq_done"] or w1) >= w0]
    return merge_intervals(busy)


def ticket_stages(tickets):
    """Release stages over finished tickets (rows carry join, canary, promote, deploy, done)."""
    done = [x for x in tickets if x["done"]]
    return dict(join_to_done=qs([x["done"] - x["join"] for x in done]),
                canary_to_promote=qs([x["promote"] - x["canary"] for x in done if x["canary"] and x["promote"]]),
                deploy_to_done=qs([x["done"] - x["deploy"] for x in done if x["deploy"]]))


def ci_window(repo, ci0, w1):
    since_s = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ci0))
    runs, page = [], 1
    while True:
        got = api(f"/repos/{repo}/actions/workflows/pytest-checks.yml/runs?status=completed&per_page=100"
                  f"&page={page}&created=%3E%3D{since_s}", "[.workflow_runs[]|{id,event,head_branch,created_at}]")
        runs += got
        if len(got) < 100:
            break
        page += 1
    runs = [r for r in runs if T(r["created_at"]) <= w1]

    def jobs(run):
        return run, api(f"/repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100",
                        "[.jobs[]|{name,conclusion,runner_name,labels,started_at,completed_at,"
                        "steps:[.steps[]|{name,started_at,completed_at}]}]")

    with ThreadPoolExecutor(8) as ex:
        got = list(ex.map(jobs, runs))
    ci_rows = []
    for run, js in got:
        for j in js:
            if j["name"] != "pytest" or j["conclusion"] != "success" or not j["completed_at"]:
                continue
            step = next((s for s in j["steps"] if s["name"].startswith("Run full test suite")), None)
            kind = "merge_branch" if run["head_branch"].startswith("gitea-mq/") else run["event"]
            ci_rows.append(dict(run=run["id"], created=run["created_at"], kind=kind, branch=run["head_branch"],
                                runner=(j["runner_name"] or "unknown").replace("GitHub Actions", "github-hosted"),
                                labels=",".join(j["labels"]),
                                job_s=T(j["completed_at"]) - T(j["started_at"]),
                                test_s=(T(step["completed_at"]) - T(step["started_at"]))
                                if step and step["completed_at"] else None))
    by = {}
    for r in ci_rows:
        for key in (r["kind"], "all"):
            d = by.setdefault(r["runner"], {}).setdefault(key, {"job": [], "test": []})
            d["job"].append(r["job_s"])
            d["test"].append(r["test_s"])
    ci = {rn: {k: dict(job=qs(v["job"]), test_step=qs(v["test"])) for k, v in sorted(ks.items())}
          for rn, ks in sorted(by.items())}
    return ci_rows, ci


def release_window(win, repo_dir, w0, w1):
    rel = H.releases(win, repo_dir)
    with open(os.path.join(repo_dir, ".runtime/release-queue/queue.jsonl")) as f:
        ev = [json.loads(l) for l in f if l.strip()]
    tickets = {}
    for e in ev:
        tickets.setdefault(e["ticket"], []).append(e)
    rel_rows = []
    for t, es in tickets.items():
        j = es[0]
        if j.get("event") != "join" or not (w0 - 3600 <= j["epoch"] <= w1):
            continue
        done = next((e for e in es if e["event"] == "release" and e.get("result") == "done"), None)
        stp = {}
        for e in es:
            if e["event"] == "step":
                stp.setdefault(e["step"], e["epoch"])
        rel_rows.append(dict(ticket=t, owner=j.get("owner"), sha=j.get("detail"), join=j["epoch"],
                             canary=stp.get("canary"), promote=stp.get("promote"), deploy=stp.get("deploy"),
                             done=done["epoch"] if done else None))
    inw = [x for x in rel_rows if x["join"] >= w0 and x["done"]]
    stages = ticket_stages(inw)
    rel["canary_to_promote"], rel["deploy_to_done"] = stages["canary_to_promote"], stages["deploy_to_done"]
    adv = [x for x in inw if x["owner"] == "release-advance"]
    rel["advance_lane"] = dict(tickets=len(adv), **ticket_stages(adv))
    # per-PR merged -> join / live through the first finished release carrying its merge commit
    main_shas = subprocess.run(["git", "-C", repo_dir, "rev-list", "--first-parent", "origin/main",
                                "--since=10 days ago"], capture_output=True, text=True).stdout.split()
    idx = {s: i for i, s in enumerate(reversed(main_shas))}

    def pos(short):
        return next((idx[s] for s in idx if s.startswith(short)), -1)

    at = {x["ticket"]: pos(x["sha"]) for x in rel_rows if x["done"] and x["sha"]}
    for r in win:
        mine = idx.get(r["merge_commit"], 10**9)
        c = [x for x in rel_rows if x["ticket"] in at and at[x["ticket"]] >= mine and x["done"] >= r["merged"]]
        x = min(c, key=lambda x: x["done"]) if c else None
        r["release_ticket"] = x["ticket"] if x else None
        r["joined"] = x["join"] if x else None
        r["live"] = x["done"] if x else None
    return rel, rel_rows


def open_line_entries(repo, merge_line):
    with open(merge_line) as f:
        urls = [l.split()[0] for l in f if l.startswith("https://")]

    def one(url):
        n = int(url.rsplit("/", 1)[1])
        p = api(f"/repos/{repo}/pulls/{n}", "{number,state,merged_at,head_sha:.head.sha,auto:(.auto_merge!=null)}")
        if p["state"] != "open":
            return None
        ck = api(f"/repos/{repo}/commits/{p['head_sha']}/check-runs?per_page=100",
                 "[.check_runs[]|{name,conclusion,started_at,completed_at}]")
        need = ("pytest", "PR must be raised via no-mistakes")
        ok = {nm: [T(c["completed_at"]) for c in ck if c["name"] == nm and c["conclusion"] == "success"]
              for nm in need}
        bad = [c for c in ck if c["conclusion"] == "failure"]
        green = max(max(v) for v in ok.values()) if all(ok.values()) and not bad else None
        tl = api(f"/repos/{repo}/issues/{n}/timeline?per_page=100", "[.[]|{event,created_at}]")
        arms = [T(e["created_at"]) for e in tl if e["event"] == "auto_squash_enabled"]
        g = next((c for c in ck if c["name"] == "gitea-mq"), {})
        return dict(pr=n, green=green, armed=max(arms) if arms and p["auto"] else None,
                    mq_start=T(g.get("started_at")), mq_done=T(g.get("completed_at")), merged=None, red=bool(bad))

    with ThreadPoolExecutor(6) as ex:
        return [x for x in ex.map(one, urls) if x]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", required=True, help="window start, UTC ISO timestamp")
    ap.add_argument("--until", required=True, help="window end, UTC ISO timestamp")
    ap.add_argument("--ci-since", help="CI window start (default: --since)")
    ap.add_argument("--prs", type=int, default=60,
                    help="number of most recently merged PRs to read; must reach back past --since (default: 60)")
    ap.add_argument("--repo", default=H.DEFAULT_REPO, help=f"GitHub OWNER/NAME (default: {H.DEFAULT_REPO})")
    ap.add_argument("--repo-dir",
                    help="local checkout holding origin/main and the release queue ledger (default: ~/<NAME>)")
    ap.add_argument("--home", default=os.environ.get("FM_HOME") or CODE_ROOT,
                    help="firstmate home whose state/ holds the ledger and merge line "
                         "(default: $FM_HOME, else this checkout)")
    ap.add_argument("--actions", help="supervisor action ledger (default: <home>/state/supervisor-actions.jsonl)")
    ap.add_argument("--merge-line",
                    help="merge-line record (default: <home>/state/merge-lines/github@github.com@<OWNER>%%2F<NAME>)")
    ap.add_argument("--out", required=True, help="output directory")
    a = ap.parse_args()
    w0, w1 = T(a.since), T(a.until)
    if w1 <= w0:
        ap.error("--until must be later than --since")
    ci0 = T(a.ci_since) if a.ci_since else w0
    repo_dir = a.repo_dir or os.path.expanduser("~/" + a.repo.rsplit("/", 1)[-1])
    actions = a.actions or os.path.join(a.home, "state", "supervisor-actions.jsonl")
    merge_line = a.merge_line or os.path.join(a.home, "state", "merge-lines",
                                              "github@github.com@" + a.repo.replace("/", "%2F"))
    rows, _ = H.github(a.repo, a.prs)
    rows = sorted(rows, key=lambda r: r["merged"])
    if not rows or rows[0]["merged"] > w0:
        ap.error(f"the {len(rows)} merged PRs read do not reach back to --since; raise --prs, or the window "
                 "lies beyond the harness's 150-closed-PR fetch")
    os.makedirs(a.out, exist_ok=True)

    ci_rows, ci = ci_window(a.repo, ci0, w1)
    with open(os.path.join(a.out, "ci_jobs.csv"), "w") as f:
        w = csv.DictWriter(f, fieldnames=list(ci_rows[0]) if ci_rows else ["run"])
        w.writeheader()
        w.writerows(sorted(ci_rows, key=lambda r: r["created"]))

    win = [r for r in rows if w0 <= r["merged"] <= w1]
    merges = ledger_merges(actions)
    for r in rows:
        r["arm_class"] = arm_class(a.repo, r["pr"], r["armed"], merges)
    gh = dict(
        pr_head_pytest=qs([r["pr_pytest"] for r in win]),
        green_to_armed=qs([max(0, r["armed"] - r["green"]) for r in win if r["armed"] and r["green"]]),
        armed_to_enqueued=qs([r["mq_start"] - r["armed"] for r in win if r["armed"] and r["mq_start"]]),
        mq_merge_branch_test=qs([r["mqpy_done"] - r["mqpy_start"] for r in win if r["mqpy_start"] and r["mqpy_done"]]),
        mq_enqueued_to_merged=qs([r["merged"] - r["mq_start"] for r in win if r["mq_start"]]),
    )
    cyc = cycles(rows, w0, w1)
    qual = [c for c in cyc if c["next_was_green"] and c["merge_to_next_arm"] is not None
            and c["merge_to_next_arm"] >= 0]
    gh["merge_to_next_merge_when_next_was_green"] = qs([c["merge_to_next_merge"] for c in cyc if c["next_was_green"]])
    gh["merge_to_next_arm_when_next_was_green"] = qs([c["merge_to_next_arm"] for c in qual])
    for cls in ARM_CLASSES:
        gh[f"merge_to_next_arm_when_next_was_green[{cls}]"] = qs(
            [c["merge_to_next_arm"] for c in qual if c["nxt_arm_class"] == cls])
    gh["arm_class_counts"] = {cls: sum(1 for r in win if r["arm_class"] == cls) for cls in ARM_CLASSES}

    rel, rel_rows = release_window(win, repo_dir, w0, w1)

    open_rows = open_line_entries(a.repo, merge_line)
    busy_m = busy_intervals(rows, open_rows, w0, w1)
    late = [dict(r, merged=None) for r in rows if r["merged"] > w1]
    per_pr = pr_hours(win + late + open_rows, busy_m, w0, w1)
    hours = {k: sum(d[k] for d in per_pr.values()) for k in PR_HOUR_STATES}
    tot = sum(hours.values())
    pr_hours_out = {k: dict(h=round(v / 3600, 2), share=round(v / tot, 3) if tot else None) for k, v in hours.items()}
    pr_hours_out["total_h"] = round(tot / 3600, 2)
    per_pr_h = {pr: {k: (round(v / 3600, 3) if isinstance(v, float) else v) for k, v in d.items()}
                for pr, d in per_pr.items()}

    stats = dict(window=dict(since=a.since, until=a.until,
                             ci_since=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ci0)),
                             merged_prs=[r["pr"] for r in win], open_line_entries=[r["pr"] for r in open_rows]),
                 ci=ci, github=gh, release=rel, pr_hours_in_window=pr_hours_out,
                 queue_wall=dict(window_h=round((w1 - w0) / 3600, 2),
                                 busy_h=round(overlap(w0, w1, busy_m) / 3600, 2)),
                 per_pr_hours=per_pr_h, cycles=cyc)
    with open(os.path.join(a.out, "window_pr_table.csv"), "w") as f:
        keys = ["pr", "arm_class", "green", "armed", "mq_start", "mqpy_start", "mqpy_done", "merged",
                "release_ticket", "joined", "live", "pr_pytest", "merge_commit"]
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        w.writerows(win)
    with open(os.path.join(a.out, "open_line_entries.json"), "w") as f:
        json.dump(open_rows, f, indent=1)
    with open(os.path.join(a.out, "release_tickets.json"), "w") as f:
        json.dump(rel_rows, f, indent=1)
    with open(os.path.join(a.out, "window_stats.json"), "w") as f:
        json.dump(stats, f, indent=1)
    print(json.dumps({k: v for k, v in stats.items() if k != "cycles"}, indent=1))


if __name__ == "__main__":
    main()
