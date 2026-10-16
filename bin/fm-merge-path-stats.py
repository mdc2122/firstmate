#!/usr/bin/env python3
"""fm-merge-path-stats.py - read-only per-stage timing of one repository's merge path.

Re-measures the merge path the 2026-10-15 merge-path audit measured for
mdc2122/viral-moment (no-mistakes -> PR checks -> merge line -> gitea-mq ->
merge -> release queue -> live), so each speed fix can be measured before and
after it lands with the same instrument.

Sources (all reads; nothing is mutated):
  - no-mistakes run ledger  ~/.no-mistakes/state.sqlite, opened mode=ro, rows
                            limited to --nm-repo-ids (the `repos` table maps
                            each id to a local clone path)
  - GitHub via gh-axi       --repo's merged PRs, issue timelines, head
                            check-runs, and --ci-workflow runs with their jobs
  - release queue ledger    <--repo-dir>/.runtime/release-queue/queue.jsonl
  - origin/main first-parent history of the local --repo-dir checkout
The only write is the --out directory.

Usage:
  bin/fm-merge-path-stats.py [--days 3] [--prs 45] [--repo OWNER/NAME]
      [--nm-repo-ids ID,ID,...] [--repo-dir ~/viral-moment]
      [--ci-workflow pytest-checks.yml] [--ci-job pytest] [--out DIR]
  --days bounds the no-mistakes rows and the CI workflow runs (created within
  the last N days); --prs bounds the GitHub stages to the N most recently
  merged PRs, whatever their age.

Output: writes pr_stage_table.csv (one row per merged PR, epoch seconds) and
stats.json into --out (default: ./out-<utc stamp>), and prints stats.json.
Every stage is {n, p50, p90, max, sum_h}: p50/p90/max in minutes, sum in hours.
  no_mistakes.<step>             completed pipeline step durations, plus the
                                 test agent's invocations and run statuses
  github.pr_head_pytest          PR-head `pytest` check-run duration
  github.green_to_armed          PR checks green -> auto_squash_enabled
  github.armed_to_enqueued       armed -> gitea-mq check started
  github.mq_merge_branch_test    gitea-mq/pytest check duration
  github.merge_to_next_arm_when_next_was_green
                                 merge-line handoff gap: a merge -> the next
                                 merged PR's arm, when that PR was already green
  ci.<runner>.<event|all>        successful --ci-job job duration per runner
                                 (GitHub-hosted runners collapse to
                                 github-hosted) and per triggering event
  release.merged_to_release_join merge -> first release ticket covering it joins
  release.merged_to_live         merge -> that release ticket done
"""
import argparse, base64, csv, json, os, re, sqlite3, statistics as st, subprocess, time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

DEFAULT_REPO = "mdc2122/viral-moment"
DEFAULT_NM_REPO_IDS = "ae52fb4b642d,2d76d4a089d6,bbf687ba63cf,8dbc1a12f9fb,41ad77d4595b"


def T(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() if s else None


def qs(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    n = len(xs)
    return dict(n=n, p50=round(st.median(xs) / 60, 1), p90=round(xs[int(0.9 * (n - 1))] / 60, 1),
                max=round(xs[-1] / 60, 1), sum_h=round(sum(xs) / 3600, 1))


def api(path, jq="."):
    """gh-axi prints TOON; transport JSON through base64 so it parses exactly."""
    p = subprocess.run(["gh-axi", "api", path, "--full", "--jq", f"({jq})|tojson|@base64"],
                       capture_output=True, text=True)
    m = re.search(r'body: "?([A-Za-z0-9+/=]+)"?', p.stdout)
    if not m:
        raise RuntimeError(f"gh-axi {path}: {p.stdout[:200]} {p.stderr[:200]}")
    return json.loads(base64.b64decode(m.group(1)))


def no_mistakes(days, nm_repo_ids):
    con = sqlite3.connect(f"file:{os.path.expanduser('~/.no-mistakes/state.sqlite')}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    since = int(time.time()) - days * 86400
    ids = ",".join("?" for _ in nm_repo_ids)
    out = {}
    for name in ("rebase", "review", "test", "document", "lint", "push", "pr", "ci"):
        rows = con.execute(
            f"select s.duration_ms from step_results s join runs r on r.id=s.run_id "
            f"where r.repo_id in ({ids}) and r.created_at>=? and s.step_name=? "
            f"and s.status='completed' and s.duration_ms>0", (*nm_repo_ids, since, name)).fetchall()
        out[name] = qs([r[0] / 1000 for r in rows])
    # test step split: agent "live evidence" time vs everything else
    agent = con.execute(
        f"select a.duration_ms from agent_invocations a join runs r on r.id=a.run_id "
        f"where r.repo_id in ({ids}) and r.created_at>=? and a.step_name='test' and a.purpose='test'",
        (*nm_repo_ids, since)).fetchall()
    out["test_agent_invocations"] = qs([r[0] / 1000 for r in agent])
    out["run_status"] = dict(con.execute(
        f"select status,count(*) from runs where repo_id in ({ids}) and created_at>=? group by status",
        (*nm_repo_ids, since)).fetchall())
    return out


def github(repo, n_prs):
    prs = []
    for page in (1, 2, 3):
        prs += api(f"/repos/{repo}/pulls?state=closed&per_page=50&page={page}&sort=updated&direction=desc",
                   "[.[]|{number,created_at,merged_at,head_sha:.head.sha,merge_commit_sha}]")
    merged = sorted([p for p in prs if p["merged_at"]], key=lambda p: p["merged_at"], reverse=True)[:n_prs]

    def one(p):
        n = p["number"]
        tl = api(f"/repos/{repo}/issues/{n}/timeline?per_page=100", "[.[]|{event,created_at}]")
        ck = api(f"/repos/{repo}/commits/{p['head_sha']}/check-runs?per_page=100",
                 "[.check_runs[]|{name,conclusion,started_at,completed_at}]")
        return n, tl, ck

    with ThreadPoolExecutor(8) as ex:
        got = {n: (tl, ck) for n, tl, ck in ex.map(one, merged)}
    rows = []
    for p in merged:
        tl, ck = got[p["number"]]
        by = lambda name: [c for c in ck if c["name"] == name]
        green = max([T(c["completed_at"]) for name in ("pytest", "PR must be raised via no-mistakes")
                     for c in by(name) if c["conclusion"] == "success" and c["completed_at"]] or [None])
        arms = [T(e["created_at"]) for e in tl if e["event"] == "auto_squash_enabled"]
        g = (by("gitea-mq") or [{}])[0]
        gp = (by("gitea-mq/pytest") or [{}])[0]
        pyt = (by("pytest") or [{}])[0]
        r = dict(pr=p["number"], created=T(p["created_at"]), green=green, armed=max(arms) if arms else None,
                 mq_start=T(g.get("started_at")), mq_done=T(g.get("completed_at")),
                 mqpy_start=T(gp.get("started_at")), mqpy_done=T(gp.get("completed_at")),
                 merged=T(p["merged_at"]), merge_commit=p["merge_commit_sha"],
                 pr_pytest=(T(pyt["completed_at"]) - T(pyt["started_at"])) if pyt.get("completed_at") else None)
        rows.append(r)
    stats = dict(
        created_to_green=qs([r["green"] - r["created"] for r in rows if r["green"]]),
        pr_head_pytest=qs([r["pr_pytest"] for r in rows]),
        green_to_armed=qs([max(0, r["armed"] - r["green"]) for r in rows if r["armed"] and r["green"]]),
        armed_to_enqueued=qs([r["mq_start"] - r["armed"] for r in rows if r["armed"] and r["mq_start"]]),
        mq_merge_branch_test=qs([r["mqpy_done"] - r["mqpy_start"] for r in rows if r["mqpy_start"] and r["mqpy_done"]]),
        green_to_merged=qs([r["merged"] - r["green"] for r in rows if r["green"]]),
    )
    order = sorted(rows, key=lambda r: r["merged"])
    stats["merge_to_next_merge_when_next_was_green"] = qs(
        [b["merged"] - a["merged"] for a, b in zip(order, order[1:]) if b["green"] and b["green"] < a["merged"]])
    stats["merge_to_next_arm_when_next_was_green"] = qs(
        [b["armed"] - a["merged"] for a, b in zip(order, order[1:])
         if b["green"] and b["green"] < a["merged"] and b["armed"] and b["armed"] >= a["merged"]])
    return rows, stats


def ci_runners(repo, days, workflow, job):
    """Successful `job` job duration per runner and triggering event, over `workflow` runs from the last N days."""
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - days * 86400))
    runs, page = [], 1
    while True:
        got = api(f"/repos/{repo}/actions/workflows/{workflow}/runs?status=completed&per_page=100"
                  f"&page={page}&created=%3E%3D{since}", "[.workflow_runs[]|{id,event}]")
        runs += got
        if len(got) < 100:
            break
        page += 1

    def jobs(run):
        return run["event"], api(f"/repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100",
                                 "[.jobs[]|{name,conclusion,runner_name,started_at,completed_at}]")

    with ThreadPoolExecutor(8) as ex:
        got = list(ex.map(jobs, runs))
    by = {}
    for event, js in got:
        for j in js:
            if j["name"] != job or j["conclusion"] != "success" or not j["started_at"] or not j["completed_at"]:
                continue
            runner = j["runner_name"] or "unknown"
            if runner.startswith("GitHub Actions"):
                runner = "github-hosted"
            d = T(j["completed_at"]) - T(j["started_at"])
            by.setdefault(runner, {}).setdefault(event, []).append(d)
            by[runner].setdefault("all", []).append(d)
    return {runner: {event: qs(ds) for event, ds in sorted(evs.items())} for runner, evs in sorted(by.items())}


def releases(rows, repo_dir):
    ev = [json.loads(l) for l in open(os.path.join(repo_dir, ".runtime/release-queue/queue.jsonl")) if l.strip()]
    main = subprocess.run(["git", "-C", repo_dir, "rev-list", "--first-parent", "origin/main", "--since=10 days ago"],
                          capture_output=True, text=True).stdout.split()
    idx = {s: i for i, s in enumerate(reversed(main))}
    tickets = {}
    for e in ev:
        tickets.setdefault(e["ticket"], []).append(e)
    rels = []
    for es in tickets.values():
        done = [e for e in es if e["event"] == "release" and e.get("result") == "done"]
        if not done:
            continue
        m = re.search(r"\(([0-9a-f]{8})", done[0].get("proof", ""))
        short = m.group(1) if m else es[0].get("detail", "")
        full = next((s for s in idx if s.startswith(short)), None)
        stp = {e["step"]: e["epoch"] for e in es if e["event"] == "step"}
        rels.append(dict(join=es[0]["epoch"], canary=stp.get("canary"), promote=stp.get("promote"),
                         deploy=stp.get("deploy"), done=done[0]["epoch"], sha=full))
    m2l, m2j = [], []
    for r in rows:
        if r["merge_commit"] not in idx:
            continue
        c = [x for x in rels if x["sha"] and idx[x["sha"]] >= idx[r["merge_commit"]] and x["done"] >= r["merged"]]
        if c:
            x = min(c, key=lambda x: x["done"])
            m2l.append(x["done"] - r["merged"])
            m2j.append(x["join"] - r["merged"])
    return dict(merged_to_live=qs(m2l), merged_to_release_join=qs(m2j),
                canary_to_promote=qs([x["promote"] - x["canary"] for x in rels if x["canary"] and x["promote"]]),
                deploy_to_done=qs([x["done"] - x["deploy"] for x in rels if x["deploy"]]))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, default=3,
                    help="window for no-mistakes rows and CI workflow runs (default: 3)")
    ap.add_argument("--prs", type=int, default=45, help="number of most recently merged PRs to measure (default: 45)")
    ap.add_argument("--repo", default=DEFAULT_REPO, help=f"GitHub OWNER/NAME (default: {DEFAULT_REPO})")
    ap.add_argument("--nm-repo-ids", default=DEFAULT_NM_REPO_IDS,
                    help="comma-separated no-mistakes repos.id values for --repo's clones "
                         f"(default: {DEFAULT_NM_REPO_IDS})")
    ap.add_argument("--repo-dir", default=os.path.expanduser("~/viral-moment"),
                    help="local checkout holding origin/main and the release queue ledger (default: ~/viral-moment)")
    ap.add_argument("--ci-workflow", default="pytest-checks.yml",
                    help="workflow file whose job durations are reported per runner (default: pytest-checks.yml)")
    ap.add_argument("--ci-job", default="pytest", help="job name inside --ci-workflow (default: pytest)")
    ap.add_argument("--out", default=f"out-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}",
                    help="output directory (default: ./out-<utc stamp>)")
    a = ap.parse_args()
    nm_repo_ids = [i for i in a.nm_repo_ids.split(",") if i]
    if not nm_repo_ids:
        ap.error("--nm-repo-ids must name at least one no-mistakes repo id")
    os.makedirs(a.out, exist_ok=True)
    nm = no_mistakes(a.days, nm_repo_ids)
    rows, gh = github(a.repo, a.prs)
    ci = ci_runners(a.repo, a.days, a.ci_workflow, a.ci_job)
    rel = releases(rows, a.repo_dir)
    stats = dict(no_mistakes=nm, github=gh, ci=ci, release=rel)
    with open(os.path.join(a.out, "pr_stage_table.csv"), "w") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]) if rows else [])
        w.writeheader()
        w.writerows(rows)
    json.dump(stats, open(os.path.join(a.out, "stats.json"), "w"), indent=1)
    print(json.dumps(stats, indent=1))


if __name__ == "__main__":
    main()
