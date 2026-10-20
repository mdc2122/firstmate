#!/usr/bin/env bash
# <root> <out> [extra args]
root=$1 out=$2; shift 2
python3 -c "import sqlite3,sys;c=sqlite3.connect(sys.argv[1]);c.executescript('create table if not exists repos(id text, upstream_url text);create table if not exists runs(id text, repo_id text, branch text, status text, pr_url text, created_at text, ci_ready_at text, parked_ms integer);')" "$root/nm.sqlite"
HOME="$root/home" FM_HOME="$root/home/fm" CLIPROXY_KEY='' python3 /Users/studio2/.no-mistakes/worktrees/662ae98237ac/01M5BPZA4HT62W3GFQNV5FQVD1/bin/fm-flow-wait.py \
  --since 2026-10-12 --until 2026-10-13 --home "$root/home/fm" --cache-dir "$root/cache" --out "$out" \
  --sessions-dir "$root/home/.omp/agent/sessions" --nm-db "$root/nm.sqlite" --release-queue "$root/none.jsonl" --no-github --no-flash "$@"
