#!/usr/bin/env python3
"""fm-flow-wait.py - read-only dispatch-to-live wait accounting for a firstmate home.

Measures, for every worker task dispatched in a window:
  * whether it went spawn -> live-and-proven with zero human touches, and
  * where its wall-clock waits went, by class:
      decision_park, human_answer, ci, merge_queue, release, worker_stall.

Deterministic joins own every number. DeepSeek Flash (optional) only labels the
PURPOSE of a steer text or the REASON of a paused line when no regex rule
matches; such rows carry classified_by=flash and never change whether a touch
counted.

SOURCES (all read-only; the only writes are --out and the two caches in --cache-dir):
  W  worker transcripts   <--sessions-dir>/*/*.jsonl (omp sessions, default
                          ~/.omp/agent/sessions): launch brief (spawn time, task id,
                          kind), every status append the worker made (tool-call
                          timestamp), every steering-inbox message body it read
                          (schema=fm-task-inbox.v1 at=...), doorbells, turn ends, relaunches.
                          Needed because state/<id>.status lines carry no timestamp.
  S  supervisor actions   the action ledger <home>/state/supervisor-actions.jsonl of --home and
                          of every local secondmate home registered in <home>/data/secondmates.md,
                          and the copy teardown archived of every retired one under
                          <home>/data/retired-secondmates/<id>/ (format: bin/fm-action-ledger-lib.sh): every fm-send / fm-control /
                          fm-pr-check / fm-pr-merge / fm-merge-line / fm-captain-hold invocation
                          with its time. A row whose origin is a firstmate script rather than
                          "direct" is automation, never a touch. Before a home's first ledger
                          row (the baseline window predates the ledger), the same calls come
                          from that home's supervisor transcripts: its omp session directory
                          (omp names it "-" + the cwd relative to ~, "/" -> "-"), which also
                          always supplies the fm-spawn / fm-teardown calls.
  L  live state           <home>/state/<id>.meta (in-flight set, yolo), steering-inbox records:
                          live under state/<id>.inbox/, archived by teardown under data/<id>/inbox/
                          (for a retired secondmate's tasks, under its retired-secondmates/<id>/data/).
  B  backlog              <home>/data/backlog.md + done-archive.md (kind, close state).
  N  no-mistakes ledger   --nm-db (default ~/.no-mistakes/state.sqlite, opened mode=ro):
                          runs by branch, pr_url, created_at, ci_ready_at, parked_ms.
  G  GitHub via gh-axi    PR created/merged/merge commit/head check-runs (cached).
  R  release ledger       --release-queue (default ~/viral-moment/.runtime/release-queue/
                          queue.jsonl) + first-parent origin/main of --release-repo-dir
                          (default <home>/projects/<name of --release-repo>); live = first
                          release done whose commit contains the merge commit.
                          --release-repo (default mdc2122/viral-moment) is the one repo with
                          a release ledger, and its owner is the fleet's own GitHub owner.

HUMAN TOUCH (applied uniformly, spawn < t <= end):
  steer        a firstmate- or captain-authored steering-inbox message delivered to the
               worker (worker-side record, union live inbox files, union supervisor-side
               fm-send calls). Script-originated templates are NOT touches: watcher
               behind-base rerun steer, pending-reply REPOST REQUIRED, CONFIG_REREAD,
               and the fm-control switch-model notice.
  answer       a steer that answers an open needs-decision/blocked (subset of steer), or a
               supervisor fm-captain-hold answer/release/complete on the task id.
  re-point     supervisor fm-pr-check, fm-pr-merge (non-dry-run), or fm-merge-line
               front/enqueue/remove/declare on the task or one of its PRs.
  relaunch     supervisor fm-control relaunch/exit/interrupt on the task, or a second
               launch-brief session for the task.
  direct       any other user message typed into the worker window.

END (live-and-proven):
  ship  every PR the task owns (one owner per PR: no-mistakes run on fm/<task> >
        the task's own `done: PR <url>` line > fm-pr-check / meta pr=) is merged and
        live: --release-repo = first release-queue `release done` whose commit has the
        merge commit on first-parent main; other repos of the fleet's owner = merged.
        A task whose only PRs are on third-party upstreams ends at its done: line
        (the merge is not the fleet's to make). Merged but not yet live = in-flight.
  scout last done: status line.
  outcome in-flight = task record (state/<id>.meta) still present or awaiting release;
  closed-not-live = record gone without reaching END.

WAIT CLASSES (per task, overlaps resolved by PRIORITY, clipped to [spawn, end] and window):
  decision_park  open needs-decision/blocked answered by a steer that names the captain's
                 decision; paused lines whose reason names the captain or a board approval;
                 supervisor fm-captain-hold hold..answer interval on the task id.
  human_answer   open needs-decision/blocked answered by a firstmate steer (or self-cleared /
                 still open); paused lines with no other reason; PLUS handoff_idle = the
                 worker's turn ended and the next event is a doorbell for a firstmate steer,
                 ranked below the machine queues and reported inside human_answer.
  release        PR merged -> live; paused lines whose reason is a deploy/release.
  merge_queue    PR green -> merged (green = earliest of the worker's own "done: PR <url>
                 ... green" line, no-mistakes ci_ready_at, head check-runs green); paused
                 lines whose reason is a merge/queue.
  ci             first no-mistakes run (or PR open) -> green; paused lines on CI.
  worker_stall   turn ended (stop/error/abort) and the gap >= IDLE_MIN_S ends in a relaunch,
                 a script-only steer, nothing, or any non-external event.
  Paused-line reasons come from PAUSE_RULES regexes; a reason no regex matches is labelled
  by Flash (ref "paused (flash): ..."); a Flash wait of external_other is not counted.
  Flash is surplus-dsv41-flash at $CLIPROXY_BASE (default http://100.69.240.64:8317) with
  $CLIPROXY_KEY; without the key, uncached rows stay unclassified.

AS-OF (reproducing a past readout):
  The sources keep growing and the live state moves on, so a rerun of an old window
  drifts. --as-of TIMESTAMP evaluates the window as it stood at that instant: transcript
  events, inbox messages, supervisor calls, no-mistakes runs, release tickets, and
  GitHub PR/check times later than it are dropped, and a task whose state/<id>.meta is
  gone counts as in flight when its last fm-teardown call is later than it. Run it with
  the cache from the readout being reproduced and --no-github.

Usage:
  bin/fm-flow-wait.py --since 2026-10-09 --until 2026-10-17 [--out DIR] [--home DIR]
      [--cache-dir DIR] [--as-of 2026-10-16T03:44:44Z] [--no-github] [--no-flash]
      [--flash-workers 16] [--sessions-dir DIR] [--nm-db FILE] [--release-repo OWNER/NAME]
      [--release-queue FILE] [--release-repo-dir DIR]
  --home defaults to $FM_HOME, else this script's checkout root; --cache-dir defaults to
  <home>/data/flow-wait-accounting and --out to <cache-dir>/out-<utc stamp>.
Writes tasks.csv, touches.csv, waits.csv, steers.csv, summary.json into --out and prints
the summary without its coverage and per-class top lists. Caches (gh_cache.json,
flash_cache.jsonl) live in --cache-dir; bin/fm-flow-wait-analyze.py derives the
counterfactuals and per-item distributions from one --out directory.

Weekly readout: run the last full week (e.g. --since 2026-10-16 --until 2026-10-23), then
bin/fm-flow-wait-analyze.py on its --out. The baseline is the 2026-10-09..2026-10-17
window as of 2026-10-16T03:44:44Z: zero-touch 20.1% (32 of 159 settled; ships 5 of 95),
merge_queue 293.4 h, release 213.3 h, ci 124.0 h.
"""
import argparse, base64, bisect, csv, glob, hashlib, json, os, re, sqlite3, subprocess, sys, time
import urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
CODE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Set from the command line in main(); the defaults reproduce the baseline readout.
SESS = os.path.join(HOME, ".omp/agent/sessions")
NM_DB = os.path.join(HOME, ".no-mistakes/state.sqlite")
RELEASE_QUEUE = os.path.join(HOME, "viral-moment/.runtime/release-queue/queue.jsonl")
VM_REPO = "mdc2122/viral-moment"
RELEASE_REPO_DIR = None
AS_OF = None   # epoch seconds; None = now

# Attribution priority (earlier wins an overlapping second). handoff_idle is the
# idle-until-firstmate-steer gap; it ranks below the machine queues so a green PR
# sitting in the merge path is merge_queue, and is reported inside human_answer.
PRIORITY = ["decision_park", "human_answer", "release", "merge_queue", "ci", "handoff_idle", "worker_stall"]
REPORT_CLASSES = ["decision_park", "human_answer", "ci", "merge_queue", "release", "worker_stall"]
IDLE_MIN_S = 180          # idle gaps shorter than this are ignored
DOORBELL_COLLAPSE_S = 1800
SCRIPT_TEMPLATES = [
    ("watcher-behind-rerun", re.compile(r"is green but GitHub refuses the merge because the branch is behind")),
    ("pending-reply-repost", re.compile(r"REPOST REQUIRED: previous marked request")),
    ("config-reread", re.compile(r"\bCONFIG_REREAD:")),
    ("model-switch-notice", re.compile(r"Your model was switched in place from \S+ to \S+")),
    ("resume-watch", re.compile(r"^Resume fact \(watch\): ")),
]


# ---------------------------------------------------------------- helpers
def ts(s):
    if s is None or s == "":
        return None
    if isinstance(s, (int, float)):
        return float(s) / (1000.0 if s > 1e11 else 1.0)
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def iso(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if t else ""


def h(sec):
    return round(sec / 3600.0, 2)


def text_of(content):
    if isinstance(content, str):
        return content
    return "\n".join(p.get("text", "") for p in content or [] if isinstance(p, dict) and p.get("type") == "text")


def strip_line_numbers(t):
    # the read tool prints "[path#TAG]" then "N:line"; normalise back to raw lines
    if re.search(r"^\s*\d+:schema=fm-task-inbox", t, re.M):
        t = re.sub(r"^\s*\d+:", "", t, flags=re.M)
    return t


# ---------------------------------------------------------------- status-line parsing
VERB_RE = re.compile(r"^\s*(working|done|needs-decision|blocked|paused|resolved|failed|note|progress)\b\s*(\[key=([^\]]+)\])?\s*:?\s*(.*)$", re.S)
PATH_RE = r"[\"']?(\S+?/state/([A-Za-z0-9._-]+)\.status)[\"']?"


def extract_status_appends(cmd):
    """Return [(task, line)] for every status append in one shell command."""
    out = []
    vars_ = dict(re.findall(r"\b([A-Za-z_]\w*)=[\"']?(\S+?\.status)[\"']?(?=[\s;&]|$)", cmd))

    def resolve(p):
        m = re.match(r"\$\{?([A-Za-z_]\w*)\}?$", p.strip("\"'"))
        if m and m.group(1) in vars_:
            p = vars_[m.group(1)]
        m = re.search(r"/state/([A-Za-z0-9._-]+)\.status$", p.strip("\"'"))
        return m.group(1) if m else None

    tgt = r"([^\s;&|)]+)"
    for m in re.finditer(r"echo\s+(?:-[en]+\s+)?([\"'])(.*?)(?<!\\)\1\s*(?:>>\s*" + tgt + r"|\|\s*tee\s+-a\s+" + tgt + ")", cmd, re.S):
        task = resolve(m.group(3) or m.group(4))
        if task:
            out.append((task, m.group(2).replace('\\"', '"')))
    for m in re.finditer(r"cat\s*>>\s*" + tgt + r"\s*<<-?\s*[\"']?(\w+)[\"']?\n(.*?)\n\2", cmd, re.S):
        task = resolve(m.group(1))
        if task:
            out.extend((task, ln) for ln in m.group(3).split("\n") if VERB_RE.match(ln))
    for m in re.finditer(r"printf\s+([\"'])(.*?)(?<!\\)\1[^>|]*?(?:>>\s*" + tgt + r"|\|\s*tee\s+-a\s+" + tgt + ")", cmd, re.S):
        task = resolve(m.group(3) or m.group(4))
        if task:
            out.append((task, m.group(2).replace("\\n", "")))
    return out


def parse_status(line):
    m = VERB_RE.match(line)
    if not m:
        return None, None, line
    return m.group(1), m.group(3), m.group(4).strip()


# ---------------------------------------------------------------- worker transcripts (W)
def seen(t):
    """True when an event at epoch t had happened by the --as-of instant."""
    return AS_OF is None or (t is not None and t <= AS_OF)


def session_dir(path):
    """omp's session directory for a cwd: "-" + the path relative to ~, "/" -> "-"."""
    rel = os.path.relpath(os.path.realpath(path), os.path.realpath(HOME))
    return os.path.join(SESS, "-" + rel.replace(os.sep, "-"))


def scan_workers(since_mtime):
    """One record per worker session that began with a launch brief."""
    sessions = []
    files = [f for f in glob.glob(os.path.join(SESS, "*/*.jsonl")) if os.path.getmtime(f) >= since_mtime]
    for f in files:
        rec = None
        events = []           # (t, kind, payload)
        try:
            fh = open(f, errors="replace")
        except OSError:
            continue
        with fh:
            for raw in fh:
                try:
                    d = json.loads(raw)
                except ValueError:
                    continue
                typ = d.get("type")
                t = ts(d.get("timestamp")) if d.get("timestamp") else None
                if t is not None and not seen(t):
                    continue   # happened after --as-of
                if typ == "message":
                    msg = d["message"]
                    role = msg.get("role")
                    if role == "user":
                        txt = text_of(msg.get("content"))
                        if "FIRSTMATE_OP: v1 launch-brief" in txt[:60]:
                            if rec is None:
                                # The task's own status log is the target of the brief's
                                # template append line (`echo "{state}: {one short line}" >>
                                # '<home>/state/<id>.status'`); the task text, rendered before
                                # it, can mention or append to another task's log.
                                m = (re.search(r"\"\{state\}: \{one short line\}\"\s*>>\s*['\"]?(/[^'\"\s]+?)/state/([A-Za-z0-9._-]+)\.status", txt)
                                     or re.search(r">>\s*['\"]?(/[^'\"\s]+?)/state/([A-Za-z0-9._-]+)\.status", txt)
                                     or re.search(r"(?<![^\s'\"=])(/\S+?)/state/([A-Za-z0-9._-]+)\.status", txt))
                                if not m:
                                    break
                                mode = re.search(r"Delivery contract: mode=(\S+)", txt)
                                rec = dict(file=f, task=m.group(2), home=m.group(1), spawn=t,
                                           kind="scout" if "This is a SCOUT task" in txt else ("ship" if mode else "other"),
                                           mode=mode.group(1) if mode else "",
                                           charter=bool(re.search(r"charter|kind=secondmate|You are a secondmate", txt[:4000], re.I)))
                            events.append((t, "launch", None))
                        elif txt.lstrip().startswith(": Firstmate instruction waiting"):
                            events.append((t, "doorbell", None))
                        else:
                            events.append((t, "user_other", txt[:400]))
                    elif role == "assistant":
                        stop = msg.get("stopReason")
                        for p in msg.get("content") or []:
                            if p.get("type") == "toolCall" and isinstance(p.get("arguments"), dict):
                                cmd = p["arguments"].get("command") or ""
                                if ".status" in cmd:
                                    for task, line in extract_status_appends(cmd):
                                        events.append((t, "status", (task, line)))
                        events.append((t, "turn_end" if stop in ("stop", "error", "aborted") else "assistant", stop))
                    elif role == "toolResult":
                        txt = text_of(msg.get("content"))
                        if "schema=fm-task-inbox.v1" in txt:
                            txt = strip_line_numbers(txt)
                            for m in re.finditer(r"schema=fm-task-inbox\.v1\nat=(\S+)\n((?:[a-z_]+=\S*\n)*)--\n(.*?)(?=\n?(?:==\s|schema=fm-task-inbox)|\Z)", txt, re.S):
                                events.append((t, "inbox", (ts(m.group(1)), m.group(2), m.group(3).strip())))
                        events.append((t, "tool_result", None))
                elif typ == "custom_message":
                    events.append((t, "async" if d.get("customType") in ("async-result", "launch-completion") else "custom", d.get("customType")))
        if rec:
            rec["events"] = [e for e in events if e[0] is not None]
            rec["end_ts"] = max((e[0] for e in rec["events"]), default=rec["spawn"])
            sessions.append(rec)
    return sessions


# ---------------------------------------------------------------- supervisor transcripts (S)
SUP_PATTERNS = [
    ("send", re.compile(r"bin/fm-send\.sh\s+(?:--fire-and-forget\s+\S+\s+)?([A-Za-z0-9._$-]+)")),
    ("control", re.compile(r"bin/fm-control\.sh\s+([A-Za-z0-9._$-]+)\s+(relaunch|exit|interrupt)\b")),
    ("pr_check", re.compile(r"bin/fm-pr-check\.sh\s+([A-Za-z0-9._$-]+)\s+(https://\S+?/pull/\d+)")),
    ("pr_merge", re.compile(r"bin/fm-pr-merge\.sh\s+([A-Za-z0-9._$-]+)\s+(https://\S+?/pull/\d+)([^\n;&|]*)")),
    ("merge_line", re.compile(r"bin/fm-merge-line\.sh\s+(front|enqueue|remove|declare)\s+(https://\S+?/pull/\d+)")),
    ("hold", re.compile(r"bin/fm-captain-hold\.sh\s+(hold|answer|complete|release)\s+([A-Za-z0-9._-]+)")),
    ("spawn", re.compile(r"bin/fm-spawn\.sh\s+([A-Za-z0-9._-]+)\s+(\S+)([^\n;&|]*)")),
    ("spawn_many", re.compile(r"bin/fm-spawn\.sh\s+((?:[A-Za-z0-9._-]+=\S*\s+)+)([^\n;&|]*)")),
    ("teardown", re.compile(r"bin/fm-teardown\.sh\s+(?:--?[a-z][\w-]*\s+)*([A-Za-z0-9._-]+)")),
]


def local_secondmate_homes(home):
    """Local secondmate homes registered in <home>/data/secondmates.md (remote ones carry host:)."""
    try:
        lines = open(os.path.join(home, "data", "secondmates.md"), errors="replace").read().splitlines()
    except OSError:
        return []
    return [m.group(1).strip() for m in (re.search(r"\(home: ([^;]+); scope: ", ln) for ln in lines) if m]


def retired_secondmate_homes(home):
    """{retired secondmate home path: its teardown archive dir} under <home>/data/retired-secondmates/."""
    out = {}
    for d in sorted(glob.glob(os.path.join(home, "data", "retired-secondmates", "*", ""))):
        try:
            path = open(os.path.join(d, "home"), errors="replace").read().strip()
        except OSError:
            continue
        if path:
            out[os.path.realpath(path)] = d.rstrip("/")
    return out


# Action ledger rows (bin/fm-action-ledger-lib.sh) -> the act shapes SUP_PATTERNS produce,
# so every touch and wait rule reads both sources identically. merge-line undeclare and
# the captain-hold intakes have no transcript pattern and stay out, as before.
LEDGER_KINDS = {"send", "control", "pr_check", "pr_merge", "merge_line", "hold"}


def ledger_act(row):
    verb, action, task, target = (row.get(k) or "" for k in ("verb", "action", "task", "target"))
    if verb == "send":
        return "send", (task or target,)
    if verb == "control" and action in ("relaunch", "exit", "interrupt"):
        return "control", (task, action)
    if verb == "pr-check":
        return "pr_check", (task, target)
    if verb == "pr-merge":
        return "pr_merge", (task, target, "")
    if verb == "merge-line" and action in ("front", "enqueue", "remove", "declare"):
        return "merge_line", (action, target)
    if verb == "captain-hold" and action in ("hold", "answer", "complete"):
        return "hold", (action, task)
    return None


def read_ledger(home, path):
    """(first row epoch or None, [direct-origin acts by --as-of], row count) for one home's ledger at <path>."""
    first, acts, n = None, [], 0
    try:
        fh = open(path, errors="replace")
    except OSError:
        return None, acts, n
    with fh:
        for raw in fh:
            try:
                row = json.loads(raw)
                t = float(row["epoch"])
            except (ValueError, KeyError, TypeError):
                continue
            n += 1
            first = t if first is None else min(first, t)
            if not seen(t) or row.get("origin") != "direct":
                continue
            act = ledger_act(row)
            if act:
                acts.append(dict(t=t, kind=act[0], groups=act[1], home=os.path.basename(home), file="supervisor-actions.jsonl"))
    return first, acts, n


def scan_supervisors(since_mtime, home, retired):
    """Supervisor actions by --as-of, plus every fm-teardown call after it (task -> times).
    Per home, the action ledger owns every verb it records from its first row on; that
    home's transcripts supply those verbs only before it, and fm-spawn / fm-teardown always."""
    acts = []
    coverage = []
    late_teardowns = defaultdict(list)
    homes = list(dict.fromkeys([os.path.realpath(p) for p in [home] + local_secondmate_homes(home)] + list(retired)))
    ledger_from = {}
    for h_ in homes:
        first, rows, n = read_ledger(h_, os.path.join(retired[h_] if h_ in retired else os.path.join(h_, "state"),
                                                      "supervisor-actions.jsonl"))
        acts.extend(rows)
        if n:
            ledger_from[session_dir(h_)] = first
            coverage.append(dict(dir=os.path.basename(h_), file="state/supervisor-actions.jsonl", first=iso(first),
                                 last=iso(max((a["t"] for a in rows), default=first)), rows=n))
    dirs = [d for d in dict.fromkeys(session_dir(p) for p in homes) if os.path.isdir(d)]
    for dpath in dirs:
        cutoff = ledger_from.get(dpath)
        for f in sorted(glob.glob(os.path.join(dpath, "*.jsonl"))):
            if os.path.getmtime(f) < since_mtime:
                continue
            first = last = None
            with open(f, errors="replace") as fh:
                for raw in fh:
                    if '"timestamp"' not in raw:
                        continue
                    try:
                        d = json.loads(raw)
                    except ValueError:
                        continue
                    t = ts(d.get("timestamp")) if isinstance(d.get("timestamp"), str) else None
                    late = t is not None and not seen(t)
                    if late and "fm-teardown.sh" not in raw:
                        continue
                    if t and not late:
                        first = first or t
                        last = t
                    if '"toolCall"' not in raw or d.get("type") != "message":
                        continue
                    for p in d["message"].get("content") or []:
                        if p.get("type") != "toolCall" or not isinstance(p.get("arguments"), dict):
                            continue
                        cmd = p["arguments"].get("command") or ""
                        if "bin/fm-" not in cmd:
                            continue
                        for kind, rx in SUP_PATTERNS:
                            for m in rx.finditer(cmd):
                                if kind == "teardown":
                                    if late:
                                        late_teardowns[m.group(1)].append(t)
                                elif late:
                                    continue
                                elif kind in LEDGER_KINDS and cutoff is not None and t is not None and t >= cutoff:
                                    continue   # the ledger owns this verb from its first row on
                                else:
                                    acts.append(dict(t=t, kind=kind, groups=m.groups(), home=os.path.basename(dpath), file=os.path.basename(f)))
            coverage.append(dict(dir=os.path.basename(dpath), file=os.path.basename(f), first=iso(first), last=iso(last)))
    return acts, coverage, late_teardowns


# ---------------------------------------------------------------- backlog (B) and live state (L)
def read_backlog(home):
    rows = {}
    for name in ("data/done-archive.md", "data/backlog.md"):
        p = os.path.join(home, name)
        if not os.path.exists(p):
            continue
        section = "archive" if "archive" in name else None
        for line in open(p, errors="replace"):
            if line.startswith("## "):
                if "backlog" in name:
                    section = line[3:].strip().lower()
                continue
            m = re.match(r"^- \[(.)\] (\S+) - (.*)$", line)
            if not m:
                continue
            rest = m.group(3)
            kind = re.search(r"\(kind: ([\w-]+)\)", rest)
            close = re.findall(r"\((done|merged|reported|since) (\d{4}-\d\d-\d\d)\)", rest)
            rows[m.group(2)] = dict(checked=m.group(1) == "x", section=section, kind=kind.group(1) if kind else "",
                                    close=close[-1] if close else None)
    return rows


def read_meta(path):
    out = {}
    try:
        for line in open(path):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                out[k] = v
    except OSError:
        pass
    return out


def live_inbox(home, task, retired):
    """Steering-inbox records still in state/ and those teardown archived into data/<id>/inbox/,
    including a retired secondmate home's archive."""
    msgs = {}
    dirs = [os.path.join(home, "state", f"{task}.inbox"), os.path.join(home, "data", task, "inbox")]
    if os.path.realpath(home) in retired:
        dirs.append(os.path.join(retired[os.path.realpath(home)], "data", task, "inbox"))
    for d in dirs:
        for p in glob.glob(os.path.join(d, "*.msg")) + glob.glob(os.path.join(d, "handled", "*.msg")):
            try:
                txt = open(p, errors="replace").read()
            except OSError:
                continue
            m = re.match(r"schema=fm-task-inbox\.v1\nat=(\S+)\n((?:[a-z_]+=\S*\n)*)--\n(.*)", txt, re.S)
            if m and seen(ts(m.group(1))):
                msgs[(m.group(1), m.group(3).strip())] = (ts(m.group(1)), m.group(2), m.group(3).strip())
    return list(msgs.values())


# ---------------------------------------------------------------- no-mistakes (N)
def nm_runs():
    con = sqlite3.connect(f"file:{NM_DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    rows = con.execute("select r.id, r.branch, r.status, r.pr_url, r.created_at, r.ci_ready_at, r.parked_ms, "
                       "p.upstream_url from runs r join repos p on p.id=r.repo_id").fetchall()
    runs = [dict(r) for r in rows if seen(ts(r["created_at"]))]
    for r in runs:
        if r["ci_ready_at"] and not seen(ts(r["ci_ready_at"])):
            r["ci_ready_at"] = None
    return runs


# ---------------------------------------------------------------- GitHub (G)
class GH:
    def __init__(self, cache_path, enabled):
        self.path = cache_path
        self.enabled = enabled
        self.cache = json.load(open(cache_path)) if os.path.exists(cache_path) else {}
        self.dirty = False
        self.fresh = set()

    def api(self, path, jq, final=lambda v: True):
        """Cached read; a cached value that is not final (open PR, pending checks, error)
        is re-fetched once per run when online."""
        key = path + "|" + jq
        if key in self.cache and (not self.enabled or key in self.fresh or final(self.cache[key])):
            return self.cache[key]
        if not self.enabled:
            return None
        p = subprocess.run(["gh-axi", "api", path, "--full", "--jq", f"({jq})|tojson|@base64"], capture_output=True, text=True)
        m = re.search(r'body: "?([A-Za-z0-9+/=]+)"?', p.stdout)
        val = json.loads(base64.b64decode(m.group(1))) if m else {"error": (p.stdout + p.stderr)[:300]}
        self.cache[key] = val
        self.fresh.add(key)
        self.dirty = True
        return val

    def pr(self, url):
        m = re.match(r"https://github\.com/([^/]+/[^/]+)/pull/(\d+)", url)
        if not m:
            return None
        repo, n = m.group(1), m.group(2)
        pr = self.api(f"/repos/{repo}/pulls/{n}", "{created_at,merged_at,merge_commit_sha,state,head:.head.sha}",
                      final=lambda v: "error" not in v and v.get("state") == "closed")
        if not pr or "error" in pr or not seen(ts(pr["created_at"])):
            return None
        merged_at = pr["merged_at"] if pr["merged_at"] and seen(ts(pr["merged_at"])) else None
        ck = self.api(f"/repos/{repo}/commits/{pr['head']}/check-runs?per_page=100",
                      "[.check_runs[]|{name,conclusion,completed_at}]",
                      final=lambda v: isinstance(v, list) and all(c.get("completed_at") for c in v)) or []
        if isinstance(ck, dict):
            ck = []
        ck = [c for c in ck if not c.get("completed_at") or seen(ts(c["completed_at"]))]
        ok = [ts(c["completed_at"]) for c in ck if c.get("conclusion") in ("success", "skipped", "neutral") and c.get("completed_at")]
        bad = [c for c in ck if c.get("conclusion") in ("failure", "timed_out", "cancelled")]
        return dict(repo=repo, number=int(n), created=ts(pr["created_at"]), merged=ts(merged_at),
                    merge_commit=pr["merge_commit_sha"] if merged_at else None,
                    state="open" if pr["merged_at"] and not merged_at else pr["state"],
                    head_green=max(ok) if ok and not bad else None)

    def save(self):
        if self.dirty:
            tmp = self.path + ".tmp"
            json.dump(self.cache, open(tmp, "w"))
            os.replace(tmp, self.path)


# ---------------------------------------------------------------- releases (R)
def releases(home):
    if not os.path.exists(RELEASE_QUEUE):
        print(f"warning: release queue {RELEASE_QUEUE} missing; every merged {VM_REPO} ship stays in-flight", file=sys.stderr)
        return [], {}
    repo_dir = RELEASE_REPO_DIR or os.path.join(home, "projects", VM_REPO.split("/")[1])
    since = "30 days ago" if AS_OF is None else iso(AS_OF - 30 * 86400)
    rl = subprocess.run(["git", "-C", repo_dir, "rev-list", "--first-parent", "origin/main", f"--since={since}"],
                        capture_output=True, text=True)
    main = rl.stdout.split()
    if rl.returncode or not main:
        print(f"warning: no first-parent origin/main commits in {repo_dir} since {since} ({rl.stderr.strip() or 'empty'}); "
              f"every merged {VM_REPO} ship stays in-flight", file=sys.stderr)
    idx = {s: i for i, s in enumerate(reversed(main))}
    tickets = defaultdict(list)
    for line in open(RELEASE_QUEUE):
        if line.strip():
            e = json.loads(line)
            if seen(e["epoch"]):
                tickets[e["ticket"]].append(e)
    rels = []
    for es in tickets.values():
        done = [e for e in es if e["event"] == "release" and e.get("result") == "done"]
        if not done:
            continue
        m = re.search(r"\(([0-9a-f]{8})", done[0].get("proof", "")) or re.match(r"([0-9a-f]{8})", str(es[0].get("detail", "")))
        short = m.group(1) if m else ""
        full = next((s for s in idx if short and s.startswith(short)), None)
        if full:
            rels.append(dict(done=done[0]["epoch"], join=es[0]["epoch"], idx=idx[full], sha=full, ticket=es[0]["ticket"]))
    rels.sort(key=lambda r: r["done"])
    return rels, idx


def live_time(pr, rels, idx):
    if not pr or not pr.get("merged"):
        return None, "unmerged"
    if pr["repo"] != VM_REPO:
        return pr["merged"], "merged (no release ledger for repo)"
    i = idx.get(pr["merge_commit"])
    if i is None:
        return None, "merge commit not on first-parent main"
    for r in rels:
        if r["idx"] >= i and r["done"] >= pr["merged"]:
            return r["done"], f"release {r['ticket']} {r['sha'][:8]}"
    return None, "merged, not yet live"


# ---------------------------------------------------------------- Flash classification
STEER_RULES = [
    ("decision_answer", re.compile(r"^\s*(?:Decision|Decisions)\b|\bDecision\b.{0,40}\bkey\b|\[key=|key=\S+.*\b(step|answer|action)\b|^Answered \[key=|\banswered\b.{0,20}\bkey\b", re.I | re.S)),
    ("go_ahead_after_external_event", re.compile(r"\b(is live|now live|went live|flipped to prod|merged .{0,40}(live|deploy)|GO:)\b", re.I)),
    ("merge_or_release_routing", re.compile(r"\b(merge poll|merge line|re-?arm|rerun (the )?pipeline|behind (its )?base|fm-pr-check)\b", re.I)),
    ("admin_maintenance", re.compile(r"\b(Stow cascade|Firstmate was updated|firstmate was updated|restart your agent)\b", re.I)),
    ("new_work", re.compile(r"\b(New routed work|new (task|row|work)|also (take|own)|queue after|next row)\b", re.I)),
]
CAPTAIN_RE = re.compile(r"\b(captain(?:'s)? (?:decision|ruled|approved|answered|chose|says|direction|call|word|ruling|answer)|Captain direction|Correction from the captain|approved by the captain|Captain \d{4}-\d\d-\d\d)\b", re.I)
PAUSE_RULES = [
    ("decision_park", re.compile(r"\b(captain|board approval|paperclip approval)\b", re.I)),
    ("release", re.compile(r"\b(deploy|release|live|prod-\d|flip|promot)", re.I)),
    ("merge_queue", re.compile(r"\b(merge|merged|queue|auto-?merge|armed|line head|green.{0,20}wait)", re.I)),
    ("ci", re.compile(r"\b(CI|checks?|pytest|pipeline|validation|no-mistakes)\b", re.I)),
    ("external_other", re.compile(r"\b(quota|rate.?limit|reset|until \d|credits?|upstream)\b", re.I)),
]
FLASH_URL = (os.environ.get("CLIPROXY_BASE") or "http://100.69.240.64:8317").rstrip("/") + "/v1/chat/completions"


class Flash:
    def __init__(self, cache_path, enabled, workers):
        self.path = cache_path
        self.enabled = enabled and bool(os.environ.get("CLIPROXY_KEY"))
        self.workers = workers
        self.cache = {}
        if os.path.exists(cache_path):
            for line in open(cache_path):
                try:
                    r = json.loads(line)
                    self.cache[r["key"]] = r
                except ValueError:
                    pass

    def _call(self, prompt):
        body = json.dumps(dict(model="surplus-dsv41-flash", max_tokens=600, temperature=0,
                               response_format={"type": "json_object"},
                               messages=[{"role": "user", "content": prompt}])).encode()
        req = urllib.request.Request(FLASH_URL, body, {"Authorization": "Bearer " + os.environ["CLIPROXY_KEY"],
                                                       "Content-Type": "application/json"})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=90) as r:
                    out = json.load(r)
                return json.loads(out["choices"][0]["message"]["content"])
            except Exception as e:  # network or parse failure: retry, then give up visibly
                err = str(e)
                time.sleep(2 * (attempt + 1))
        return {"error": err}

    def classify(self, items):
        """items: [(key, prompt)] -> {key: result}; results are appended to the cache file."""
        todo = [(k, p) for k, p in items if k not in self.cache]
        if todo and self.enabled:
            with ThreadPoolExecutor(self.workers) as ex, open(self.path, "a") as out:
                for (k, p), res in zip(todo, ex.map(lambda kp: self._call(kp[1]), todo)):
                    rec = dict(key=k, result=res, model="surplus-dsv41-flash", at=iso(time.time()))
                    self.cache[k] = rec
                    out.write(json.dumps(rec) + "\n")
        return {k: self.cache[k]["result"] for k, _ in items if k in self.cache}


def steer_prompt(body):
    return ("You label one instruction that a supervisor agent (firstmate) sent to an autonomous coding worker. "
            "Return JSON {\"purpose\": one of [decision_answer, go_ahead_after_external_event, correction_or_scope_change, "
            "unblock_information, merge_or_release_routing, new_work, admin_maintenance, status_request, other], "
            "\"answerer\": one of [captain, firstmate] (captain only if the text says the captain decided or directed it), "
            "\"reason\": short}.\n\nINSTRUCTION:\n" + body[:3000])


def pause_prompt(line):
    return ("A coding worker paused itself with this status line. Classify what it is waiting for. Return JSON "
            "{\"wait\": one of [release, merge_queue, ci, decision_park, human_answer, external_other], \"reason\": short}. "
            "release = a deploy/production release; merge_queue = a PR merge; ci = checks/validation; decision_park = a captain "
            "decision; human_answer = an answer or go-ahead from the supervisor; external_other = quota, third party, time.\n\nLINE:\n" + line[:1500])


def key_of(prefix, s):
    return prefix + ":" + hashlib.sha256(s.encode()).hexdigest()[:20]


# ---------------------------------------------------------------- interval attribution
def attribute(intervals, lo, hi):
    """intervals: [(start, end, cls, ref)] -> {cls: seconds}, [(start,end,cls,ref) final non-overlapping]."""
    pts = sorted({lo, hi} | {max(lo, min(hi, s)) for s, e, c, r in intervals} | {max(lo, min(hi, e)) for s, e, c, r in intervals})
    out = Counter()
    pieces = []
    for a, b in zip(pts, pts[1:]):
        if b <= a:
            continue
        cover = [(PRIORITY.index(c), c, r) for s, e, c, r in intervals if s <= a and e >= b]
        if not cover:
            continue
        _, c, r = min(cover)
        out[c] += b - a
        if pieces and pieces[-1][2] == c and pieces[-1][3] == r and abs(pieces[-1][1] - a) < 1e-6:
            pieces[-1] = (pieces[-1][0], b, c, r)
        else:
            pieces.append((a, b, c, r))
    return out, pieces


# ---------------------------------------------------------------- main build
def build(args):
    since, until = ts(args.since + "T00:00:00Z"), ts(args.until + "T00:00:00Z")
    now = min(AS_OF if AS_OF is not None else time.time(), until)
    scan_from = since - 3 * 86400
    print("scanning worker transcripts ...", file=sys.stderr)
    sessions = scan_workers(scan_from)
    print(f"  {len(sessions)} launch-brief sessions", file=sys.stderr)
    print("scanning supervisor transcripts ...", file=sys.stderr)
    retired = retired_secondmate_homes(args.home)
    acts, sup_cov, late_teardowns = scan_supervisors(scan_from, args.home, retired)
    backlog = read_backlog(args.home)
    runs = nm_runs()
    gh = GH(os.path.join(args.cache_dir, "gh_cache.json"), not args.no_github)
    flash = Flash(os.path.join(args.cache_dir, "flash_cache.jsonl"), not args.no_flash, args.flash_workers)
    rels, idx = releases(args.home)

    # group sessions into tasks (home, task)
    tasks = {}
    for s in sorted(sessions, key=lambda s: s["spawn"]):
        k = (s["home"], s["task"])
        t = tasks.setdefault(k, dict(task=s["task"], home=s["home"], spawn=s["spawn"], kind=s["kind"], mode=s["mode"],
                                     charter=s["charter"], sessions=[]))
        t["sessions"].append(s)
        if s["kind"] == "ship":
            t["kind"], t["mode"] = "ship", s["mode"]

    # supervisor actions indexed by task id and PR url
    sup_by_task = defaultdict(list)
    sup_by_url = defaultdict(list)
    spawn_yolo = {}
    unresolved_targets = Counter()
    for a in acts:
        g = a["groups"]
        if a["kind"] == "spawn":
            y = re.search(r"--yolo\s+(on|off)", g[2])
            if y:
                spawn_yolo[g[0]] = y.group(1)
            continue
        if a["kind"] == "spawn_many":   # fm-spawn.sh id=repo id=repo ... --yolo on|off
            y = re.search(r"--yolo\s+(on|off)", g[1])
            if y:
                spawn_yolo.update((tok.split("=", 1)[0], y.group(1)) for tok in g[0].split())
            continue
        if a["kind"] == "merge_line":
            sup_by_url[g[1]].append(a)
            continue
        tid = g[1] if a["kind"] == "hold" else g[0]
        if "$" in tid:
            unresolved_targets[a["kind"]] += 1
            continue
        sup_by_task[tid].append(a)
        if a["kind"] in ("pr_check", "pr_merge"):
            sup_by_url[g[1]].append(dict(a, task=tid))

    # One owner per PR. Claim strength: 3 = no-mistakes run on branch fm/<task>,
    # 2 = the task's own `done: PR <url>` line, 1 = supervisor fm-pr-check or meta pr=.
    # Highest strength wins; ties go to the earliest claim. A PR merely mentioned
    # (waiting on another task's PR) is never claimed.
    claims = defaultdict(list)
    for (home, tid), t in tasks.items():
        for r in runs:
            if r["pr_url"] and r["branch"] in (f"fm/{tid}", tid):
                claims[r["pr_url"]].append((3, r["created_at"], (home, tid)))
        for s in t["sessions"]:
            for e in s["events"]:
                if e[1] == "status" and e[2][0] == tid:
                    verb, _, note = parse_status(e[2][1])
                    m = re.match(r"PR (https://github\.com/[^\s/]+/[^\s/]+/pull/\d+)", note or "")
                    if verb == "done" and m:
                        claims[m.group(1)].append((2, e[0], (home, tid)))
        for a in sup_by_task.get(tid, []):
            if a["kind"] == "pr_check":
                claims[a["groups"][1]].append((1, a["t"], (home, tid)))
        meta_pr = read_meta(os.path.join(home, "state", f"{tid}.meta")).get("pr")
        if meta_pr:
            claims[meta_pr].append((1, t["spawn"], (home, tid)))
    pr_owner = {}
    for u, cs in claims.items():
        u2 = u.rstrip(".,;)")
        best = max(cs, key=lambda c: (c[0], -c[1]))
        pr_owner[u2] = best[2]

    task_rows, touch_rows, wait_rows, steer_rows = [], [], [], []
    flash_items = []
    pending = []   # (task record, prepared data) for second pass after flash
    unresolved_prs = defaultdict(list)

    for (home, tid), t in tasks.items():
        if not (since <= t["spawn"] < until):
            continue
        bl = backlog.get(tid, {})
        excluded = ""
        if t["charter"] or bl.get("kind") in ("program", "secondmate"):
            excluded = "standing crew / secondmate charter"
        meta = read_meta(os.path.join(home, "state", f"{tid}.meta"))
        # at --as-of, a record removed since then still existed if its teardown came later
        in_flight = bool(meta) or bool(late_teardowns.get(tid))
        yolo = meta.get("yolo") or spawn_yolo.get(tid, "")

        # merged event stream across sessions
        ev = sorted((e for s in t["sessions"] for e in s["events"]), key=lambda e: e[0])
        status = [(e[0],) + parse_status(e[2][1]) + (e[2][1],) for e in ev if e[1] == "status" and e[2][0] == tid]
        # steers: worker-side inbox reads (dedupe by at), live inbox, doorbell-only
        steers = {}
        for e in ev:
            if e[1] == "inbox" and e[2][0]:
                at, hdr, body = e[2]
                cur = steers.get(round(at))
                if cur is None or len(body) > len(cur["body"]):
                    steers[round(at)] = dict(at=at, body=body, ff="fire-and-forget" in hdr, src="worker-transcript")
        for at, hdr, body in live_inbox(home, tid, retired):
            if at and round(at) not in steers:
                steers[round(at)] = dict(at=at, body=body, ff="fire-and-forget" in hdr, src="live-inbox")
        steer_ats = sorted(s["at"] for s in steers.values())
        last_bell = None
        for e in ev:
            if e[1] != "doorbell":
                continue
            i = bisect.bisect_right(steer_ats, e[0] + 5)
            matched = i > 0 and e[0] - steer_ats[i - 1] < DOORBELL_COLLAPSE_S
            if not matched and (last_bell is None or e[0] - last_bell > DOORBELL_COLLAPSE_S):
                steers[round(e[0])] = dict(at=e[0], body="", ff=False, src="doorbell-only")
            last_bell = e[0]
        # supervisor-side sends with no worker-side record within 10 min
        for a in sup_by_task.get(tid, []):
            if a["kind"] == "send" and not any(abs(s["at"] - a["t"]) < 600 for s in steers.values()):
                steers[round(a["t"])] = dict(at=a["t"], body="", ff=False, src="supervisor-fm-send")

        # PRs of this task: only PRs this task owns (see pr_owner) so a PR named in
        # several tasks' status lines is counted once
        urls = {u for u, o in pr_owner.items() if o == (home, tid)}
        prs = {}
        for u in sorted(urls):
            p = gh.pr(u)
            if not p:
                unresolved_prs[tid].append(u)
            else:
                rr = [r for r in runs if r["pr_url"] == u]
                p["nm_start"] = min((r["created_at"] for r in rr), default=None)
                # earliest green signal: the worker's own "done: PR <url> ... green" line,
                # no-mistakes ci_ready_at (overwritten on every rerun), or head check-runs
                said_green = [st[0] for st in status if st[1] == "done" and u in st[3] and re.search(r"green|checks pass", st[3], re.I)]
                cands = said_green + [r["ci_ready_at"] for r in rr if r["ci_ready_at"]] + ([p["head_green"]] if p["head_green"] else [])
                cands = [c for c in cands if c and (not p.get("merged") or c <= p["merged"])]
                p["green"] = min(cands) if cands else None
                p["nm_parked_s"] = sum((r["parked_ms"] or 0) for r in rr) / 1000.0
                p["live"], p["live_how"] = live_time(p, rels, idx)
                prs[u] = p

        # end (live-and-proven)
        done_lines = [st for st in status if st[1] == "done"]
        end, end_how = None, ""
        own = {u: p for u, p in prs.items() if p["repo"].split("/")[0] == VM_REPO.split("/")[0]}
        if t["kind"] == "ship" and prs and not own and done_lines:
            # upstream contribution: the fleet's deliverable is the PR; merge is a third party's call
            end, end_how = done_lines[-1][0], "done: upstream PR opened (merge not ours)"
        elif t["kind"] == "ship" and prs:
            prs = own
            merged = [p for p in prs.values() if p.get("merged")]
            open_ = [p for p in prs.values() if not p.get("merged") and p.get("state") == "open"]
            if merged and not open_ and all(p["live"] for p in merged):
                last = max(merged, key=lambda p: p["live"])
                end, end_how = last["live"], last["live_how"]
            elif merged and not in_flight and all(p["live"] for p in merged):
                last = max(merged, key=lambda p: p["live"])
                end, end_how = last["live"], last["live_how"] + " (other PRs closed unmerged)"
        elif done_lines and not (t["kind"] == "ship" and prs):
            end, end_how = done_lines[-1][0], "done: status line"
        awaiting_live = any(p.get("merged") and not p.get("live") for p in prs.values()) if t["kind"] == "ship" else False
        if end is None and (in_flight or awaiting_live):
            outcome = "in-flight"   # still working, or merged and waiting for a release
        elif end is None:
            outcome = "closed-not-live"
        else:
            outcome = "live-proven"
        horizon = end or (now if outcome == "in-flight" else max(e[0] for e in ev))

        pending.append(dict(t=t, tid=tid, home=home, bl=bl, excluded=excluded, in_flight=in_flight, yolo=yolo,
                            ev=ev, status=status, steers=sorted(steers.values(), key=lambda s: s["at"]), prs=prs,
                            end=end, end_how=end_how, outcome=outcome, horizon=horizon))
        for s in steers.values():
            if s["body"] and t["spawn"] < s["at"] <= horizon and not any(rx.search(s["body"]) for _, rx in SCRIPT_TEMPLATES):
                if not any(rx.search(s["body"]) for _, rx in STEER_RULES):
                    flash_items.append((key_of("steer", s["body"]), steer_prompt(s["body"])))
        for st in status:
            if st[1] == "paused" and not any(rx.search(st[3]) for _, rx in PAUSE_RULES):
                flash_items.append((key_of("pause", st[4]), pause_prompt(st[4])))

    if unresolved_prs:
        print(f"warning: {sum(map(len, unresolved_prs.values()))} owned PR(s) of {len(unresolved_prs)} task(s) did not resolve "
              "(gh error, uncached under --no-github, or created after --as-of); see summary coverage.owned_prs_unresolved",
              file=sys.stderr)
    print(f"flash: {len(set(k for k, _ in flash_items))} ambiguous records", file=sys.stderr)
    fl = flash.classify(list(dict(flash_items).items()))
    gh.save()

    for P in pending:
        t, tid, ev, status = P["t"], P["tid"], P["ev"], P["status"]
        spawn, horizon = t["spawn"], P["horizon"]
        touches = []

        def add_touch(at, typ, detail, src, classified_by="rule"):
            if spawn < at <= horizon:
                touches.append(dict(task=tid, at=iso(at), t=at, type=typ, detail=detail[:240], source=src, classified_by=classified_by))

        # steers
        for s in P["steers"]:
            body = s["body"]
            tmpl = next((name for name, rx in SCRIPT_TEMPLATES if body and rx.search(body)), None)
            purpose, answerer, cby = "", "firstmate", "rule"
            if tmpl:
                purpose, cby = "script:" + tmpl, "rule"
            elif body:
                purpose = next((n for n, rx in STEER_RULES if rx.search(body)), "")
                if CAPTAIN_RE.search(body):
                    answerer = "captain"
                if not purpose:
                    r = fl.get(key_of("steer", body))
                    if r and "purpose" in r:
                        purpose, cby = r["purpose"], "flash"
                        if r.get("answerer") == "captain":
                            answerer = "captain"
                    else:
                        purpose = "unclassified"
            else:
                purpose = "body-not-captured"
            s.update(purpose=purpose, answerer=answerer, classified_by=cby, script=bool(tmpl))
            steer_rows.append(dict(task=tid, at=iso(s["at"]), source=s["src"], script_template=tmpl or "",
                                   purpose=purpose, answerer=answerer, classified_by=cby,
                                   in_span=spawn < s["at"] <= horizon, body=body[:300].replace("\n", " ")))
            if not tmpl:
                add_touch(s["at"], "steer", f"[{purpose}/{answerer}] {body[:200]}", s["src"], cby)

        # supervisor-side re-points, answers, relaunches
        urls = set(P["prs"])
        for a in sup_by_task.get(tid, []):
            g = a["groups"]
            if a["kind"] == "control":
                add_touch(a["t"], "relaunch", f"fm-control {g[1]}", "supervisor")
            elif a["kind"] == "pr_check":
                add_touch(a["t"], "re-point", f"fm-pr-check {g[1]}", "supervisor")
            elif a["kind"] == "pr_merge" and "--dry-run" not in g[2] and "--help" not in g[2]:
                add_touch(a["t"], "re-point", f"fm-pr-merge {g[1]}", "supervisor")
            elif a["kind"] == "hold" and g[0] in ("answer", "release", "complete"):
                add_touch(a["t"], "answer", f"fm-captain-hold {g[0]}", "supervisor")
        for u in urls:
            for a in sup_by_url.get(u, []):
                if a["kind"] == "merge_line":
                    add_touch(a["t"], "re-point", f"fm-merge-line {a['groups'][0]} {u}", "supervisor")
        launches = [e[0] for e in ev if e[1] == "launch"]
        for lt in launches[1:]:
            add_touch(lt, "relaunch", "new launch-brief session", "worker-transcript")
        for e in ev:
            if e[1] == "user_other":
                add_touch(e[0], "direct", e[2] or "", "worker-transcript")
        # dedupe identical (type, detail-prefix) within 5 minutes (retried calls)
        touches.sort(key=lambda x: x["t"])
        dedup = []
        for x in touches:
            if dedup and any(y["type"] == x["type"] and y["detail"][:60] == x["detail"][:60] and x["t"] - y["t"] < 300 for y in dedup[-4:]):
                continue
            dedup.append(x)
        touches = dedup
        touch_rows.extend({k: v for k, v in x.items() if k != "t"} for x in touches)

        # ---- wait intervals
        iv = []
        human_steers = [s for s in P["steers"] if not s.get("script")]
        # open decisions / blockers
        open_dec = None
        for st in status + [(horizon, "END", None, "", "")]:
            t0, verb = st[0], st[1]
            if open_dec and (verb in ("resolved", "working", "done", "END", "needs-decision", "blocked", "paused", "failed")):
                close = t0
                ans = next((s for s in human_steers if open_dec[0] < s["at"] <= close + 120), None)
                if ans:
                    close = min(close, ans["at"]) if ans["at"] > open_dec[0] else close
                    cls = "decision_park" if ans.get("answerer") == "captain" else "human_answer"
                    iv.append((open_dec[0], ans["at"], cls, f"{open_dec[1]} -> steer {iso(ans['at'])}"))
                elif verb != "END" or not P["in_flight"]:
                    r = next((cls for cls, rx in PAUSE_RULES if rx.search(open_dec[2])), None)
                    iv.append((open_dec[0], close, r if r in PRIORITY else "human_answer", f"{open_dec[1]} self-cleared"))
                else:
                    iv.append((open_dec[0], close, "human_answer", f"{open_dec[1]} still open"))
                open_dec = None
            if verb in ("needs-decision", "blocked"):
                open_dec = (t0, verb, st[3])
        # paused lines
        for i, st in enumerate(status):
            if st[1] != "paused":
                continue
            nxt = [x[0] for x in status[i + 1:]] + [s["at"] for s in human_steers if s["at"] > st[0]] + [horizon]
            close = min(nxt)
            cls = next((c for c, rx in PAUSE_RULES if rx.search(st[3])), None)
            cby = "rule"
            if not cls:
                r = fl.get(key_of("pause", st[4]))
                cls, cby = (r.get("wait"), "flash") if r and r.get("wait") else ("human_answer", "default")
            if cls in PRIORITY:
                iv.append((st[0], close, cls, f"paused ({cby}): {st[3][:80]}"))
            else:
                iv.append((st[0], close, "__external", f"paused ({cby}): {st[3][:80]}"))
        # PR-derived intervals
        for u, p in P["prs"].items():
            start = p.get("nm_start") or p.get("created")
            if start and p.get("green"):
                iv.append((start, p["green"], "ci", f"{u} validation+checks"))
            if p.get("green") and p.get("merged"):
                iv.append((p["green"], p["merged"], "merge_queue", f"{u} green->merged"))
            elif p.get("green") and p.get("state") == "open":
                iv.append((p["green"], horizon, "merge_queue", f"{u} green, still open"))
            if p.get("merged") and p.get("live") and p["repo"] == VM_REPO:
                iv.append((p["merged"], p["live"], "release", f"{u} merged->{p['live_how']}"))
            elif p.get("merged") and not p.get("live") and p["repo"] == VM_REPO:
                iv.append((p["merged"], horizon, "release", f"{u} merged, not yet live"))
        # captain-hold intervals on the task id itself
        holds = sorted((a["t"], a["groups"][0]) for a in sup_by_task.get(tid, []) if a["kind"] == "hold")
        hs = None
        for at, verb in holds:
            if verb == "hold" and hs is None:
                hs = at
            elif verb in ("answer", "release", "complete") and hs is not None:
                iv.append((hs, at, "decision_park", "captain hold"))
                hs = None
        # idle gaps
        for a, b in zip(ev, ev[1:]):
            if a[1] != "turn_end" or b[0] - a[0] < IDLE_MIN_S:
                continue
            nxt_kind = b[1]
            if nxt_kind == "doorbell":
                st = next((s for s in human_steers if a[0] < s["at"] <= b[0] + 5), None)
                cls = "handoff_idle" if st else "worker_stall"
                iv.append((a[0], b[0], cls, "idle until firstmate steer (handoff)" if st else "idle until script steer"))
            elif nxt_kind == "launch":
                iv.append((a[0], b[0], "worker_stall", "idle until relaunch"))
            elif nxt_kind == "async":
                continue   # background compute finished: not a wait
            else:
                iv.append((a[0], b[0], "worker_stall", f"idle until {nxt_kind}" + (" (error stop)" if a[2] == "error" else "")))
        # tail: last event to horizon with no resume
        last = ev[-1]
        if last[0] < horizon - IDLE_MIN_S:
            iv.append((last[0], horizon, "worker_stall", "no worker activity to end of span"))
        iv = [x for x in iv if x[1] > x[0] and x[2] in PRIORITY]
        lo, hi = max(spawn, since), min(horizon, now)
        by_cls, pieces = attribute(iv, lo, hi) if hi > lo else (Counter(), [])
        for a, b, c, r in pieces:
            wait_rows.append(dict(task=tid, cls=c, start=iso(a), end=iso(b), hours=h(b - a), ref=r))

        n_touch = len(touches)
        task_rows.append(dict(
            task=tid, home="primary" if os.path.realpath(P["home"]) == os.path.realpath(args.home) else "secondmate:" + P["home"],
            kind=t["kind"], mode=t["mode"], yolo=P["yolo"], backlog_kind=P["bl"].get("kind", ""), excluded=P["excluded"],
            spawn=iso(spawn), end=iso(P["end"]), end_how=P["end_how"], outcome=P["outcome"], in_flight=P["in_flight"],
            span_h=h(horizon - spawn), sessions=len(t["sessions"]), prs=" ".join(sorted(P["prs"])),
            touches=n_touch, touch_types=" ".join(f"{k}:{v}" for k, v in sorted(Counter(x["type"] for x in touches).items())),
            first_touch=touches[0]["at"] if touches else "",
            first_touch_detail=touches[0]["detail"][:140] if touches else "",
            zero_touch=n_touch == 0,
            **{f"wait_{c}_h": h(by_cls.get(c, 0) + (by_cls.get("handoff_idle", 0) if c == "human_answer" else 0)) for c in REPORT_CLASSES},
            wait_handoff_idle_h=h(by_cls.get("handoff_idle", 0)),
            nm_parked_h=h(sum(p.get("nm_parked_s", 0) for p in P["prs"].values())),
        ))

    # ---- summary
    measured = [r for r in task_rows if not r["excluded"]]
    settled = [r for r in measured if r["outcome"] != "in-flight"]
    live = [r for r in settled if r["outcome"] == "live-proven"]
    zt_live = [r for r in live if r["zero_touch"]]
    inflight = [r for r in measured if r["outcome"] == "in-flight"]

    def share(a, b):
        return round(100.0 * len(a) / len(b), 1) if b else None

    cls_tot = {c: round(sum(r[f"wait_{c}_h"] for r in measured), 1) for c in REPORT_CLASSES}
    cls_tot["of_which_handoff_idle"] = round(sum(r["wait_handoff_idle_h"] for r in measured), 1)
    top = {}
    for c in REPORT_CLASSES + ["handoff_idle"]:
        top[c] = sorted(({"task": r["task"], "hours": r[f"wait_{c}_h"]} for r in measured if r[f"wait_{c}_h"] > 0),
                        key=lambda x: -x["hours"])[:8]
    sup_ranges = sorted((c["first"], c["last"], c["file"]) for c in sup_cov if c["first"])
    summary = dict(
        window=[args.since, args.until], generated=iso(time.time()), now_cap=iso(now),
        tasks_spawned=len(task_rows), excluded=len(task_rows) - len(measured), measured=len(measured),
        settled=len(settled), live_proven=len(live), closed_not_live=len(settled) - len(live), in_flight=len(inflight),
        zero_touch_live=len(zt_live),
        zero_touch_share_of_settled_pct=share(zt_live, settled),
        zero_touch_share_of_live_pct=share(zt_live, live),
        in_flight_untouched_so_far=len([r for r in inflight if r["zero_touch"]]),
        upper_bound_if_all_untouched_inflight_land_pct=share(zt_live + [r for r in inflight if r["zero_touch"]], measured),
        by_kind={k: dict(settled=len([r for r in settled if r["kind"] == k]),
                         zero_touch_live=len([r for r in zt_live if r["kind"] == k]),
                         live=len([r for r in live if r["kind"] == k]))
                 for k in sorted({r["kind"] for r in measured})},
        touches_total=len([x for x in touch_rows if x["task"] in {r["task"] for r in measured}]),
        touches_by_type=dict(Counter(x["type"] for x in touch_rows if x["task"] in {r["task"] for r in measured})),
        steer_purposes=dict(Counter(s["purpose"] for s in steer_rows if s["in_span"] and not s["script_template"])),
        steer_answerers=dict(Counter(s["answerer"] for s in steer_rows if s["in_span"] and not s["script_template"])),
        script_steers_excluded=len([s for s in steer_rows if s["script_template"] and s["in_span"]]),
        flash_classified_rows=dict(steers=len([s for s in steer_rows if s["classified_by"] == "flash"]),
                                   pauses=len([w for w in wait_rows if "(flash)" in w["ref"]])),
        wait_hours_by_class=cls_tot,
        wait_hours_by_class_live_tasks={c: round(sum(r[f"wait_{c}_h"] for r in live), 1) for c in REPORT_CLASSES},
        top_tasks_by_class=top,
        coverage=dict(
            supervisor_transcripts=[dict(first=a, last=b, file=f) for a, b, f in sup_ranges],
            supervisor_unresolved_variable_targets=dict(unresolved_targets),
            backlog_rows_closed_in_window_without_worker_transcript=sorted(
                k for k, v in backlog.items() if v.get("close") and v["close"][0] in ("done", "merged", "reported")
                and args.since <= v["close"][1] < args.until and v.get("kind") in ("ship", "scout")
                and not any(k == r["task"] for r in task_rows)),
            owned_prs_unresolved=dict(sorted(unresolved_prs.items())),
            gh_cache_entries=len(gh.cache), releases_indexed=len(rels)),
    )
    return task_rows, touch_rows, wait_rows, steer_rows, summary


def write_csv(path, rows):
    if not rows:
        open(path, "w").close()
        return
    keys = list(rows[0].keys())
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)


def main():
    global SESS, NM_DB, RELEASE_QUEUE, VM_REPO, RELEASE_REPO_DIR, AS_OF
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", required=True, help="YYYY-MM-DD (UTC, inclusive) spawn window start")
    ap.add_argument("--until", required=True, help="YYYY-MM-DD (UTC, exclusive) spawn window end")
    ap.add_argument("--home", default=os.environ.get("FM_HOME") or CODE_ROOT,
                    help="firstmate home to account (default: $FM_HOME, else this checkout)")
    ap.add_argument("--out", default=None, help="output directory (default: <cache-dir>/out-<utc stamp>)")
    ap.add_argument("--cache-dir", default=None, help="gh/flash cache directory (default: <home>/data/flow-wait-accounting)")
    ap.add_argument("--as-of", default=None, help="ISO-8601 UTC instant to evaluate the window at (default: now)")
    ap.add_argument("--no-github", action="store_true", help="use only cached GitHub responses")
    ap.add_argument("--no-flash", action="store_true", help="skip Flash; ambiguous rows stay unclassified")
    ap.add_argument("--flash-workers", type=int, default=16)
    ap.add_argument("--sessions-dir", default=SESS, help="omp session root (default: %(default)s)")
    ap.add_argument("--nm-db", default=NM_DB, help="no-mistakes state database (default: %(default)s)")
    ap.add_argument("--release-repo", default=VM_REPO, help="OWNER/NAME of the repo with a release ledger (default: %(default)s)")
    ap.add_argument("--release-queue", default=RELEASE_QUEUE, help="release queue ledger (default: %(default)s)")
    ap.add_argument("--release-repo-dir", default=None, help="checkout of --release-repo (default: <home>/projects/<name>)")
    args = ap.parse_args()
    SESS, NM_DB, RELEASE_QUEUE, VM_REPO = args.sessions_dir, args.nm_db, args.release_queue, args.release_repo
    RELEASE_REPO_DIR = args.release_repo_dir
    AS_OF = ts(args.as_of) if args.as_of else None
    args.cache_dir = args.cache_dir or os.path.join(args.home, "data", "flow-wait-accounting")
    os.makedirs(args.cache_dir, exist_ok=True)
    out = args.out or os.path.join(args.cache_dir, "out-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    os.makedirs(out, exist_ok=True)
    tasks, touches, waits, steers, summary = build(args)
    write_csv(os.path.join(out, "tasks.csv"), tasks)
    write_csv(os.path.join(out, "touches.csv"), touches)
    write_csv(os.path.join(out, "waits.csv"), waits)
    write_csv(os.path.join(out, "steers.csv"), steers)
    json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in summary.items() if k not in ("coverage", "top_tasks_by_class")}, indent=1))
    print("wrote", out)


if __name__ == "__main__":
    main()
