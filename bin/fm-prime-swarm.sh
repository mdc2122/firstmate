#!/usr/bin/env bash
# fm-prime-swarm.sh - launch one Prime Agent swarm in one command. Mechanics only.
#
# Usage:
#   fm-prime-swarm.sh <swarm-id> --brief <path> --model <provider>[/<model-id>]
#                     [--effort <level>] [--depth <n>] [--max-agents <n>]
#                     [--cwd <worktree>] [--title <backlog title>]
#                     [--session-key <key>] [--dry-run]
#   fm-prime-swarm.sh --help
#
# The script owns no mission, channel rule, north star, or study content: the
# swarm's own brief file supplies all of that. It does, in order:
#
#  1. Model and effort. --model names a provider in ~/.prime/agent/models.json
#     (omniroute-cursor or omniroute-muse) and optionally one of its model ids;
#     the id defaults to cursor-api/grok-4.7 for Cursor and
#     muse-code/muse-wonder-full-1.0 for Muse. A model missing from models.json
#     or from `prime-agent model list` is refused, dry run included. Defaults:
#     --effort max for Muse, high otherwise, off for a model whose catalog
#     thinking column is not "yes" (any other effort is refused); --depth
#     3; --max-agents 12, or 6 for Muse. OmniRoute pins each x-session-id to ONE
#     Muse account for life (one account ran out of quota after ~6 minutes at 8
#     concurrent max-effort agents on 2026-10-12, then refused every call as
#     "session owner unavailable"), so a Muse launch writes a fresh x-session-id
#     into the provider's headers, or the --session-key given, so a relaunch can
#     land on another account. The previous models.json is kept beside it as
#     models.json.bak-<swarm-id>.
#  2. Directories: $FM_HOME/data/<swarm-id>/{sessions,evidence,wt}.
#  3. Backlog item: bin/fm-tasks-axi.sh add <swarm-id> "<title>" --kind scout
#     --start --report data/<swarm-id>/report.md, body opening with a verify
#     line naming the report and the brief. Refuses if the id already exists.
#  4. Orca tab in --cwd (default: the current directory) running prime-agent on
#     the chosen provider, model and thinking level, sessions under
#     data/<swarm-id>/sessions; prints the terminal handle.
#  5. RLM depth: sends `/rlm-max-depth <n>` by bracketed paste and requires the
#     tab to show "RLM max depth set: <n>".
#  6. Kickoff: writes data/<swarm-id>/kickoff.md (the fixed mechanics header
#     below plus "Read <brief> and execute it fully.") and sends one line naming
#     it, by bracketed paste only (ESC[200~ ... ESC[201~, then a separate CR):
#     Prime's composer drops doubled characters from typed text
#     (PrimeIntellect-ai/prime-agent#3250). Requires the tab's token count to
#     leave 0 within 120 s.
#  7. Gateway sampler: bin/fm-durable-job.sh <swarm-id>-sampler, every 30 s
#     reading studio1's OmniRoute call_logs READ-ONLY over ssh (calls, status
#     histogram and mean duration per requested model of this provider) into
#     data/<swarm-id>/gateway-by-model.tsv; stops once report.md exists and no
#     prime agent is working, 12 h cap.
#  8. Prints the tab handle, backlog id, sampler job, and kickoff path.
#
# --dry-run prints every command and file it would run or write, and changes
# nothing. Any failed step stops the launch loudly (exit 1); a refusal of bad
# input exits 2.
#
# Safety: never closes a Prime tab (closing one stopped every agent in both
# swarms on 2026-10-12); stop a swarm with `prime-agent stop <agent-id>`.
# Read-only on studio1 (no OmniRoute config change or restart). Never touches
# a production checkout. Writes only under data/<swarm-id>/, the backlog item,
# the Muse provider header in ~/.prime/agent/models.json, and the sampler job.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MODELS_JSON="${FM_PRIME_MODELS_JSON:-$HOME/.prime/agent/models.json}"
PRIME="${FM_PRIME_AGENT:-prime-agent}"
ORCA="${FM_PRIME_ORCA:-orca}"
GATEWAY_HOST="${FM_PRIME_GATEWAY_HOST:-studio1}"
# Relative to the gateway user's home: ssh runs the remote command there.
GATEWAY_DB="${FM_PRIME_GATEWAY_DB:-.omniroute/storage.sqlite}"
START_TIMEOUT_S="${FM_PRIME_START_TIMEOUT_S:-120}"

die() { printf 'fm-prime-swarm: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$0"; }
note() { printf 'fm-prime-swarm: %s\n' "$*"; }

ID='' BRIEF='' MODEL_ARG='' EFFORT='' DEPTH=3 MAX_AGENTS='' CWD="$PWD" TITLE='' SESSION_KEY='' DRY=0
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "$#" -ge 1 ] || { usage >&2; exit 2; }
ID=$1; shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --brief) BRIEF=${2:-}; shift 2 ;;
    --model) MODEL_ARG=${2:-}; shift 2 ;;
    --effort) EFFORT=${2:-}; shift 2 ;;
    --depth) DEPTH=${2:-}; shift 2 ;;
    --max-agents) MAX_AGENTS=${2:-}; shift 2 ;;
    --cwd) CWD=${2:-}; shift 2 ;;
    --title) TITLE=${2:-}; shift 2 ;;
    --session-key) SESSION_KEY=${2:-}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

# --- input refusals -----------------------------------------------------------
case "$ID" in ''|-*|*[!A-Za-z0-9_-]*) die "invalid swarm id '$ID' (allowed: A-Z a-z 0-9 _ -)" 2 ;; esac
[ -n "$BRIEF" ] || die "--brief is required" 2
[ -f "$BRIEF" ] || die "brief not found: $BRIEF" 2
BRIEF=$(cd "$(dirname "$BRIEF")" && pwd -P)/$(basename "$BRIEF")
[ -n "$MODEL_ARG" ] || die "--model <provider>[/<model-id>] is required" 2
PROVIDER=${MODEL_ARG%%/*}
MODEL=''
case "$MODEL_ARG" in */*) MODEL=${MODEL_ARG#*/} ;; esac
if [ -z "$MODEL" ]; then
  case "$PROVIDER" in
    omniroute-cursor) MODEL=cursor-api/grok-4.7 ;;
    omniroute-muse) MODEL=muse-code/muse-wonder-full-1.0 ;;
    *) die "--model needs a model id for provider $PROVIDER" 2 ;;
  esac
fi
case "$DEPTH" in ''|*[!0-9]*) die "--depth must be a whole number: $DEPTH" 2 ;; esac
if [ "$DEPTH" -lt 1 ] || [ "$DEPTH" -gt 5 ]; then die "--depth must be 1..5 (never above 5): $DEPTH" 2; fi
[ -d "$CWD" ] || die "--cwd is not a directory: $CWD" 2
CWD=$(cd "$CWD" && pwd -P)
[ -f "$MODELS_JSON" ] || die "models.json not found: $MODELS_JSON" 2
jq -e --arg p "$PROVIDER" --arg m "$MODEL" \
  '.providers[$p].models // [] | map(.id) | index($m) != null' "$MODELS_JSON" >/dev/null 2>&1 \
  || die "unknown model $PROVIDER/$MODEL in $MODELS_JSON" 2
# Read-only, so the dry run checks it too. Its thinking column says whether the
# model takes an effort at all: Prime silently runs a non-thinking model at off.
THINKS=$("$PRIME" model list "$MODEL" 2>/dev/null | awk -v p="$PROVIDER" -v m="$MODEL" '$1 == p && $2 == m { print $5; exit }')
[ -n "$THINKS" ] || die "prime-agent model list does not show $PROVIDER/$MODEL" 2
# The gateway logs this provider's calls under the model id's own prefix
# (cursor-api/..., muse-code/...), which is what the sampler groups by.
GATEWAY_FAMILY=${MODEL%%/*}
MUSE=0
[ "$PROVIDER" = omniroute-muse ] && MUSE=1
if [ -z "$EFFORT" ]; then
  if [ "$THINKS" != yes ]; then EFFORT=off
  elif [ "$MUSE" -eq 1 ]; then EFFORT=max
  else EFFORT=high; fi
fi
case "$EFFORT" in off|minimal|low|medium|high|xhigh|max) : ;; *) die "invalid --effort: $EFFORT" 2 ;; esac
if [ "$THINKS" != yes ] && [ "$EFFORT" != off ]; then
  die "$PROVIDER/$MODEL does not support thinking; --effort must be off" 2
fi
if [ -z "$MAX_AGENTS" ]; then
  if [ "$MUSE" -eq 1 ]; then MAX_AGENTS=6; else MAX_AGENTS=12; fi
fi
case "$MAX_AGENTS" in ''|*[!0-9]*|0) die "--max-agents must be a positive whole number: $MAX_AGENTS" 2 ;; esac
[ -n "$TITLE" ] || TITLE="Prime swarm $ID ($MODEL, $EFFORT)"
if [ "$MUSE" -eq 1 ] && [ -z "$SESSION_KEY" ]; then
  SESSION_KEY="fm-prime-$ID-$(date -u +%Y%m%dT%H%M%SZ)"
fi
[ -z "$SESSION_KEY" ] || case "$SESSION_KEY" in *[!A-Za-z0-9._-]*) die "invalid --session-key: $SESSION_KEY" 2 ;; esac

SWARM="$DATA/$ID"
REPORT="$SWARM/report.md"
KICKOFF="$SWARM/kickoff.md"
SAMPLER="$SWARM/gateway-sampler.sh"
STATUS_FILE="$STATE/$ID.status"
[ -e "$SWARM/kickoff.md" ] && die "swarm $ID already has a kickoff at $KICKOFF; pick a new id" 2
# Read-only, so the dry run refuses an existing id too.
if FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" show "$ID" >/dev/null 2>&1; then
  die "backlog item $ID already exists; pick a new swarm id" 2
fi

# --- files the launch writes (built in memory first, shown by --dry-run) -------
# Heredocs live in functions: bash 3.2 mis-parses a heredoc inside $( ) that
# holds an apostrophe or unbalanced parenthesis.
kickoff_text() {
  cat <<EOF
# Prime swarm kickoff: $ID (mechanics; the mission is in the brief)

Model and effort: you are the root on $PROVIDER/$MODEL at thinking "$EFFORT"; spawn every child with model "$MODEL" and thinking "$EFFORT". RLM max depth $DEPTH.
Concurrency: at most $MAX_AGENTS agents at once, root included.

Prepend this rule verbatim to every child prompt, with that child's own evidence file path:
"Rule: every reply you send must contain at least one tool call until your evidence file is written. Never reply with only a plan or status sentence. Your final step is writing <evidence file path>; only after it exists may you reply without a tool call."

Child evidence files go under $SWARM/evidence/. Supervise with a retry loop: after rlm.collect, re-spawn any thread whose evidence file is missing or under 3 KB as <thread>-r2, -r3 ... up to 4 attempts in all. Log every retry as one JSON line {"ts","event":"child_retry","thread","attempt","reason"} and every non-200 / 429 / quota or rate-limit reply as one JSON line, both to $SWARM/rate-limits.jsonl. On a quota exhausted / session owner unavailable reply: stop spawning, write report.md from what exists, record the stop and reset times, and end.

Write report.md progressively at $REPORT. It must contain a "Swarm method" section: model, effort, children spawned, depth used, attempts per thread, early stops, peak concurrency, limit replies, and seconds per model call where measurable.
Write only under $SWARM/. When done, append one line \`done: <one-line conclusion>\` to $STATUS_FILE.

Read $BRIEF and execute it fully.
EOF
}
KICKOFF_TEXT=$(kickoff_text)
sampler_text() {
  printf '#!/bin/bash\n'
  printf '# Gateway sampler for swarm %s, written by fm-prime-swarm.sh.\n' "$ID"
  printf 'GATEWAY_HOST=%q GATEWAY_DB=%q FAMILY=%q\n' "$GATEWAY_HOST" "$GATEWAY_DB" "$GATEWAY_FAMILY"
  printf 'OUT=%q REPORT=%q PRIME=%q\n' "$SWARM/gateway-by-model.tsv" "$REPORT" "$PRIME"
  cat <<'EOF'
# Every 30 s: the last 60 s of the gateway's OmniRoute call_logs for this
# swarm's provider family, per requested model: calls, status histogram, mean
# duration (ms). Read-only (sqlite3 -readonly, SQL on stdin). Stops once the
# report exists and no prime agent is working; 12 h cap.
END=$(( $(date +%s) + 43200 ))
while [ "$(date +%s)" -lt "$END" ]; do
  SINCE=$(date -u -v-60S +%Y-%m-%dT%H:%M:%S)
  ROW=$(printf "select group_concat(m || ' calls=' || n || ' ' || st || ' avg_ms=' || av, ' | ') from (select requested_model m, sum(c) n, group_concat(status || ':' || c) st, cast(sum(d) / sum(c) as int) av from (select requested_model, status, count(*) c, sum(duration) d from call_logs where timestamp >= '%s' and requested_model like '%s/%%' group by 1, 2) group by 1);\n" "$SINCE" "$FAMILY" \
    | ssh -o ConnectTimeout=5 -o BatchMode=yes "$GATEWAY_HOST" "sqlite3 -readonly '$GATEWAY_DB'" 2>&1 | tr '\n' ' ')
  KIDS=$("$PRIME" list 2>/dev/null | grep -c working)
  printf '%s\t%s\tworking_agents=%s\n' "$(date -u +%FT%TZ)" "$ROW" "$KIDS" >> "$OUT"
  if [ -s "$REPORT" ] && [ "$KIDS" = 0 ]; then break; fi
  sleep 30
done
echo "sampler done $(date -u +%FT%TZ)"
EOF
}
SAMPLER_TEXT=$(sampler_text)
PASTE_LINE="Use your read tool on $KICKOFF and execute it fully now."
PRIME_CMD="$PRIME --cwd $CWD --provider $PROVIDER --model $MODEL --thinking $EFFORT --session-dir $SWARM/sessions"

if [ "$DRY" -eq 1 ]; then
  note "DRY RUN - nothing will be changed"
  printf 'swarm=%s provider=%s model=%s effort=%s depth=%s max_agents=%s cwd=%s\n' \
    "$ID" "$PROVIDER" "$MODEL" "$EFFORT" "$DEPTH" "$MAX_AGENTS" "$CWD"
  [ -z "$SESSION_KEY" ] || printf 'models.json: set providers.%s.headers["x-session-id"]=%s (backup %s.bak-%s)\n' \
    "$PROVIDER" "$SESSION_KEY" "$MODELS_JSON" "$ID"
  printf 'mkdir -p %s/{sessions,evidence,wt}\n' "$SWARM"
  printf '+ %s/fm-tasks-axi.sh add %s %q --kind scout --start --report data/%s/report.md --body <verify line>\n' \
    "$SCRIPT_DIR" "$ID" "$TITLE" "$ID"
  printf '+ %s terminal create --worktree path:%s --title %s --command %q --json\n' "$ORCA" "$CWD" "$ID" "$PRIME_CMD"
  printf '+ paste /rlm-max-depth %s ; expect "RLM max depth set: %s"\n' "$DEPTH" "$DEPTH"
  printf -- '--- %s ---\n%s\n--- end ---\n' "$KICKOFF" "$KICKOFF_TEXT"
  printf '+ paste %q ; expect token count > 0 within %ss\n' "$PASTE_LINE" "$START_TIMEOUT_S"
  printf -- '--- %s ---\n%s\n--- end ---\n' "$SAMPLER" "$SAMPLER_TEXT"
  printf '+ %s/fm-durable-job.sh %s-sampler %s/gateway-sampler.result -- %s\n' "$SCRIPT_DIR" "$ID" "$SWARM" "$SAMPLER"
  exit 0
fi

# --- 1. session key (Muse) ----------------------------------------------------
if [ -n "$SESSION_KEY" ]; then
  cp -p "$MODELS_JSON" "$MODELS_JSON.bak-$ID" || die "could not back up $MODELS_JSON"
  tmp=$(mktemp "$MODELS_JSON.XXXXXX") || die "could not stage $MODELS_JSON"
  if ! jq --arg p "$PROVIDER" --arg k "$SESSION_KEY" \
    '.providers[$p].headers = ((.providers[$p].headers // {}) + {"x-session-id": $k})' \
    "$MODELS_JSON" > "$tmp"; then
    rm -f "$tmp"
    die "could not set the session key"
  fi
  mv -f "$tmp" "$MODELS_JSON" || die "could not replace $MODELS_JSON"
  note "session key $SESSION_KEY (previous models.json at $MODELS_JSON.bak-$ID)"
fi

# --- 2. directories -----------------------------------------------------------
mkdir -p "$SWARM/sessions" "$SWARM/evidence" "$SWARM/wt" "$STATE" || die "could not create $SWARM"

# --- 3. backlog item ----------------------------------------------------------
FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" add "$ID" "$TITLE" --kind scout --start \
  --report "data/$ID/report.md" \
  --body "verify: data/$ID/report.md exists with a Swarm method section and state/$ID.status has a done line; brief $BRIEF" \
  >/dev/null || die "could not add backlog item $ID"
note "backlog item $ID added (In flight)"

# --- 4. Orca tab --------------------------------------------------------------
out=$("$ORCA" terminal create --worktree "path:$CWD" --title "$ID" --command "$PRIME_CMD" --json) \
  || die "orca terminal create failed for $ID"
TERM_HANDLE=$(printf '%s' "$out" | jq -r '.result.terminal.handle // empty')
[ -n "$TERM_HANDLE" ] || die "orca terminal create returned no handle: $out"
note "tab $TERM_HANDLE"

screen() { "$ORCA" terminal read --terminal "$TERM_HANDLE" --screen 2>/dev/null; }
paste() {  # bracketed paste of one line, then a separate CR
  "$ORCA" terminal send --terminal "$TERM_HANDLE" --text "$(printf '\033[200~%s\033[201~' "$1")" --json >/dev/null \
    || die "could not paste into $TERM_HANDLE"
  sleep 0.5
  "$ORCA" terminal send --terminal "$TERM_HANDLE" --text "$(printf '\r')" --json >/dev/null \
    || die "could not submit in $TERM_HANDLE"
}

waited=0
until screen | grep -qF "model $MODEL"; do
  [ "$waited" -lt 60 ] || die "prime-agent did not start in $TERM_HANDLE within 60s"
  sleep 1; waited=$((waited + 1))
done

# --- 5. RLM depth -------------------------------------------------------------
paste "/rlm-max-depth $DEPTH"
waited=0
until screen | grep -qF "RLM max depth set: $DEPTH"; do
  [ "$waited" -lt 15 ] || die "RLM max depth $DEPTH not confirmed in $TERM_HANDLE"
  sleep 1; waited=$((waited + 1))
done
note "RLM max depth set: $DEPTH"

# --- 6. kickoff ---------------------------------------------------------------
printf '%s\n' "$KICKOFF_TEXT" > "$KICKOFF" || die "could not write $KICKOFF"
paste "$PASTE_LINE"
waited=0
until screen | grep -qE "${MODEL##*/} · [1-9][0-9.]*[kKmM]? "; do
  [ "$waited" -lt "$START_TIMEOUT_S" ] \
    || die "the agent in $TERM_HANDLE did not start a turn within ${START_TIMEOUT_S}s (token count still 0)"
  sleep 5; waited=$((waited + 5))
done
note "turn started"

# --- 7. gateway sampler -------------------------------------------------------
printf '%s\n' "$SAMPLER_TEXT" > "$SAMPLER" || die "could not write $SAMPLER"
chmod +x "$SAMPLER" || die "could not make $SAMPLER executable"
SAMPLER_LINE=$(cd "$SWARM" && "$SCRIPT_DIR/fm-durable-job.sh" "$ID-sampler" gateway-sampler.result -- "$SAMPLER") \
  || die "could not start the gateway sampler"

# --- 8. summary ---------------------------------------------------------------
printf 'tab: %s\nbacklog: %s\nsampler: %s\nkickoff: %s\n' "$TERM_HANDLE" "$ID" "$SAMPLER_LINE" "$KICKOFF"
