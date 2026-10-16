#!/usr/bin/env python3
"""Builds a disposable sandbox: fake HOME with no-mistakes state.sqlite, a viral-moment-like
git checkout with origin/main + release queue ledger, and GitHub API fixture JSON served by a
fake gh-axi. Times are relative to now so the --since windows apply. Expected values (minutes):
  pr_head_pytest 12; handoff gap n=1 9.0; merged_to_live [40,35,40]; merged_to_release_join [5,5,20]
  ci strix/pull_request 12, n100/push 24, github-hosted/pull_request 25"""
import json, os, sqlite3, subprocess, sys, time
from datetime import datetime, timezone
root = sys.argv[1]; os.makedirs(root, exist_ok=True)
now = int(time.time()); B = now - 5 * 3600   # base: 5h ago
iso = lambda m: datetime.fromtimestamp(B + m * 60, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
home = os.path.join(root, "home"); os.makedirs(home + "/.no-mistakes", exist_ok=True)
db = sqlite3.connect(home + "/.no-mistakes/state.sqlite")
db.executescript("""create table repos(id text primary key, path text);
create table runs(id text primary key, repo_id text, created_at integer, status text);
create table step_results(run_id text, step_name text, status text, duration_ms integer);
create table agent_invocations(run_id text, step_name text, purpose text, duration_ms integer);""")
db.execute("insert into repos values('vm1','/x'),('other','/y')")
for rid, repo, age, status in [("r1","vm1",3600,"completed"),("r2","vm1",7200,"failed"),
                               ("r3","other",3600,"completed"),("r4","vm1",10*86400,"completed")]:
    db.execute("insert into runs values(?,?,?,?)", (rid, repo, now-age, status))
for rid, step, st, ms in [("r1","review","completed",120000),("r2","review","completed",240000),
                          ("r1","test","completed",600000),("r2","test","failed",900000),
                          ("r3","review","completed",9999000),("r4","review","completed",8888000),
                          ("r1","push","completed",0)]:
    db.execute("insert into step_results values(?,?,?,?)", (rid, step, st, ms))
db.execute("insert into agent_invocations values('r1','test','test',480000)")
db.execute("insert into agent_invocations values('r3','test','test',7777000)")
db.commit(); db.close()
# git: bare origin + checkout, three first-parent merge commits on main
repo = os.path.join(root, "vm"); origin = os.path.join(root, "origin.git")
g = lambda *a, env=None: subprocess.run(["git", *a], check=True, capture_output=True, text=True, env=env).stdout.strip()
g("init", "-q", "--bare", "-b", "main", origin); g("clone", "-q", origin, repo)
shas = []
for i, m in enumerate([95, 115, 160]):   # PR1 merged +95m, PR2 +115m, PR3 +160m
    open(os.path.join(repo, f"f{i}"), "w").write(str(i))
    g("-C", repo, "add", "."); env = dict(os.environ, GIT_COMMITTER_DATE=iso(m), GIT_AUTHOR_DATE=iso(m))
    g("-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", f"pr{i+1}", env=env)
    shas.append(g("-C", repo, "rev-parse", "HEAD"))
g("-C", repo, "push", "-q", "origin", "main"); g("-C", repo, "fetch", "-q")
q = os.path.join(repo, ".runtime/release-queue"); os.makedirs(q)
ev = []
for t, sha, join, done in [("A", shas[0], 100, 135), ("B", shas[1], 120, 150), ("C", shas[2], 180, 200)]:
    ev += [dict(ticket=t, event="join", epoch=B+join*60, detail=sha[:8]),
           dict(ticket=t, event="step", step="canary", epoch=B+(join+2)*60),
           dict(ticket=t, event="step", step="promote", epoch=B+(join+10)*60),
           dict(ticket=t, event="step", step="deploy", epoch=B+(join+12)*60),
           dict(ticket=t, event="release", result="done", epoch=B+done*60, proof=f"live ({sha[:8]}) ok")]
ev.append(dict(ticket="Z", event="join", epoch=B+60, detail="deadbeef"))   # never finished
open(q + "/queue.jsonl", "w").write("\n".join(json.dumps(e) for e in ev) + "\n")
# GitHub fixtures keyed by API path (query string stripped)
R = "/repos/acme/vm"; F = {}
def pr(n, c, merged, sha, msha):
    return dict(number=n, created_at=iso(c), merged_at=merged and iso(merged), head=dict(sha=sha), merge_commit_sha=msha)
F[R+"/pulls"] = [pr(1,0,95,"h1",shas[0]), pr(2,1,115,"h2",shas[1]), pr(3,60,160,"h3",shas[2]), pr(4,2,None,"h4",None)]
F[R+"/issues/1/timeline"] = [dict(event="auto_squash_enabled", created_at=iso(20))]
F[R+"/issues/2/timeline"] = [dict(event="labeled", created_at=iso(5)), dict(event="auto_squash_enabled", created_at=iso(104))]
F[R+"/issues/3/timeline"] = [dict(event="auto_squash_enabled", created_at=iso(131))]
def ck(ps, pe, nm, mq, mqp):
    c = [dict(name="pytest", conclusion="success", started_at=iso(ps), completed_at=iso(pe)),
         dict(name="PR must be raised via no-mistakes", conclusion="success", started_at=iso(nm-1), completed_at=iso(nm))]
    if mq: c.append(dict(name="gitea-mq", conclusion="success", started_at=iso(mq), completed_at=iso(mq+10)))
    if mqp: c.append(dict(name="gitea-mq/pytest", conclusion="success", started_at=iso(mqp[0]), completed_at=iso(mqp[1])))
    return dict(check_runs=c)
F[R+"/commits/h1/check-runs"] = ck(5, 17, 18, 21, (22, 32))
F[R+"/commits/h2/check-runs"] = ck(6, 18, 20, 105, (106, 112))
F[R+"/commits/h3/check-runs"] = ck(65, 77, 130, 132, None)
F[R+"/actions/workflows/pytest-checks.yml/runs"] = dict(workflow_runs=[dict(id=11, event="pull_request"), dict(id=12, event="push"), dict(id=13, event="pull_request")])
J = lambda name, concl, runner, s, e: dict(name=name, conclusion=concl, runner_name=runner, started_at=iso(s), completed_at=iso(e))
F[R+"/actions/runs/11/jobs"] = dict(jobs=[J("pytest","success","strix",0,12), J("lint","success","strix",0,1)])
F[R+"/actions/runs/12/jobs"] = dict(jobs=[J("pytest","success","n100",0,24), J("pytest","failure","n100",0,3)])
F[R+"/actions/runs/13/jobs"] = dict(jobs=[J("pytest","success","GitHub Actions 3",0,25)])
os.makedirs(root + "/gh", exist_ok=True); json.dump(F, open(root + "/gh/fixtures.json", "w"), indent=1)
print(json.dumps(dict(shas=shas)))
