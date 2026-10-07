#!/usr/bin/env bash
# fm-attention-check.sh - the daily attention check: one line rating whether
# firstmate's own attention is the fleet's constraint, signal by signal.
#
# Usage:
#   fm-attention-check.sh [scan]    print the line now (on demand; writes nothing)
#   fm-attention-check.sh check     watcher hook: sample decisions, record the daily line
#   fm-attention-check.sh act reallocate|drain "<what was done>"
#                                   record the same-day action a binding line owes
#   fm-attention-check.sh --help
#
# Every signal looks at the trailing 24 hours ending now and is rated green,
# amber, or red. Red means past the "firstmate is the constraint" threshold;
# amber means present but under it; green means absent.
#
#   S1  decisions waiting over 30 min: keyed needs-decision/blocked decisions
#       (the bin/fm-classify-lib.sh fold of every state/*.status) first seen in
#       the window or still open; the count that waited over 30 min, the
#       worker-hours those waited, and the longest wait. Red at 5 or more over
#       30 min, or any over 2 h.
#   S2  three or more decisions open at once: total minutes in the window with
#       at least three open. Red over 30 min.
#   S3  green PRs that cannot merge: state/*.pr-green-blocked episodes (the
#       watcher's record; its first-seen epoch is the age). Red when any is
#       older than 30 min.
#   S4  merged but not live, per project under projects/ that has prod-* tags:
#       the age of the oldest origin/main first-parent commit that is not an
#       ancestor of the newest prod-* tag, and how many of the window's
#       first-parent merges took over 2 h to reach their first prod-* tag (or
#       are still not live). Red when the oldest unreleased commit is over 4 h
#       old or over a quarter of the window's merges took over 2 h. It reads
#       the local clone as the last fleet sync left it and never fetches. A
#       prod-* tag's release time is its tagger date, so a lightweight prod-*
#       tag has no known release time: it is never a release or the newest tag,
#       and the line names how many were ignored.
#   S8  ownerless in-flight work: In-flight backlog rows whose task's recorded
#       endpoint has a state/.endpoint-gone-* marker older than 12 h, excluding
#       a task whose latest status is a `paused: ... until <time>` wait that is
#       still in the future and a row whose backlog `hold-until` date is still
#       ahead (an owned, dated wait). Red when any.
#   S11 attention on the constraint: the share of steering-inbox messages
#       (state/*.inbox, by their at= stamp) sent to constraint tasks, meaning
#       backlog rows whose `verify:` line names the ballot, review, repair, or
#       finishing. Red when under 40% in this window and in the 24 h before it;
#       amber when only this window is under 40%. Messages to tasks already
#       torn down left with their inbox and are not counted.
#       When data/backlog.md exists but cannot be read, S8 and S11 are rated
#       unknown, say so, and never count toward the verdict.
#   S12 supervisor load, per home - this home, then every local registered
#       secondmate home (data/secondmates.md) - from that home's own
#       `bin/fm-queue-zero.sh load`, which owns ownership and the re-date
#       ledger: "<home> unowned <n> (<n> >24h), median age <d>d, re-dates
#       without progress <n>". unowned counts open rows whose only owner is
#       the supervisor (target 0); median age is the median filed age of open
#       rows; re-dates without progress counts hold dates moved (or refused)
#       with no new evidence in the window. Red when any home has a row
#       unowned for 24 h or more; amber when any home has an unowned row or a
#       re-date without progress; unknown (not counted) when a home's load
#       cannot be read.
#   release-seq  inbox messages in the window that sequence a release by hand
#       ("next in line", "queued behind", "after ... deploys"). Informational:
#       amber when any, never part of the verdict.
#   class-e  fleet-pins Class E applications in the window, read from the
#       fleet-pins agent's log (FM_ATTENTION_CLASS_E_LOG, default
#       ~/.fleet-backup/pins/class-e.log; mdc2122/firstmate-fleet-backup
#       pins/README.md owns the format): a line counts when its second
#       tab-separated field is exactly `class-e` and its first, a UTC
#       YYYY-MM-DDTHH:MM:SSZ stamp, falls in the window, with the count split
#       by its health= value. Informational: amber when any application did not
#       pass health, never part of the verdict; absent when the log is absent.
#
# The verdict follows data/firstmate-bottleneck-plan section 5: RED when two or
# more of S1, S2, S3, S4, S8, S11, S12 are red, AMBER when one is, GREEN
# otherwise.
#
# Blind spots and the shadow-queue cross-check are named on the line rather
# than guessed. When br is installed, every beads (br) crew queue this home can
# read - its own at data/beads/.beads/beads.db and each local secondmate home's
# (data/secondmates.md) at the same relative path - gets one read-only
# `br list` call bounded to FM_ATTENTION_BR_TIMEOUT seconds (default 5), never
# a write. The STANDING RULE it watches: br never holds the only copy of
# captain-sequenced or dated work, so every br item that is not closed (open,
# in progress, blocked, deferred, or any other live status) carries a
# `mirror:<row-id>` label naming an open backlog row in its own home or in its
# parent home, or is closed. This home's queue is matched against this home's
# backlog and its parent's - itself in the primary home, the local home named
# by .fm-secondmate-parent in a secondmate home - and each local secondmate's
# queue against that secondmate's backlog and this home's. The informational
# `br-xcheck` segment reports "<home> <n>/<total> br-only (<ids>)" per queue,
# amber when any item has no row and unknown when a queue or its own backlog
# cannot be read. When only the parent backlog cannot be read (a remote parent
# route, say), the queue is still matched against its own backlog and the part
# ends ", parent not checked", rated at least unknown, so only an item
# mirroring a parent row can be a false br-only there. It never moves the
# verdict. This home's own queue is also named as "not seen" with its per-status
# counts, because S8 and S11 read only backlog rows, task records, and steering
# inboxes, and br crews have none.
#
# Status lines carry no timestamps, so decision ages come from sampling.
# `check` folds the open decision set on every run and keeps one record,
# state/.attention-first-seen, of each key's first-seen epoch and the epoch it
# was first seen closed (rows closed over 48 h ago are pruned). A key whose
# opening line is the newest line of its status log takes that log's mtime as
# its first-seen time; any other new key takes the sample time. Ages are exact
# to one sampling interval, and a decision opened and closed between two
# samples is never seen. Until the record covers the whole window the line says
# "sampled since". `scan` merges a sample in memory and writes nothing.
#
# `check` is the watcher's hook (bin/fm-watch.sh runs it every
# FM_ATTENTION_CHECK_INTERVAL seconds, default 600). On its first run at or
# after 13:00Z each UTC day (one window) it computes the line and records it in
# state/.attention-check (reported=<date>, line=<line>). The line is BINDING
# when the verdict is RED or S11 is red (under 40% in two consecutive windows):
# the record then also carries bound=<why>, and check first appends one durable
# `check` wake (key attention) naming the owed action and prints that wake
# reason. Once a window is recorded no later run that day wakes again, so a
# binding wake fires at most once per window. Otherwise it prints nothing and
# the line waits in the record, which the fleet snapshot and
# bin/fm-fleet-view.sh show without a wake. A failed wake append is retried on
# the next run instead of being recorded.
#
# The turn that handles a binding wake acts the same day - reallocates
# non-constraint steers toward the constraint, or drains the open decisions -
# and records it with `act reallocate|drain "<what was done>"`, which appends
# action=<utc> <kind> <note> to that day's record. act refuses when no line is
# recorded for today or today's line is not binding, so an action is always
# against the window's own binding line.
# The first-seen record, the daily record, that wake, and act's action lines
# are the only writes.
# FM_ATTENTION_NOW (UTC ISO-8601) pins the clock for tests.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
FIRST_SEEN="$STATE/.attention-first-seen"
FIRST_SEEN_SCHEMA=fm-attention-first-seen-v1
RECORD="$STATE/.attention-check"
RECORD_SCHEMA=fm-attention-check-v1
DAILY_HOUR=13
CONSTRAINT_RE='(^|[^a-z])(ballot|review|repair|finish)'
RELEASE_RE='next in line|queued behind|after [^.]{1,80} deploys'
BR_TIMEOUT=${FM_ATTENTION_BR_TIMEOUT:-5}
case "$BR_TIMEOUT" in ''|*[!0-9]*|0) BR_TIMEOUT=5 ;; esac
CLASS_E_LOG=${FM_ATTENTION_CLASS_E_LOG:-${HOME:-}/.fleet-backup/pins/class-e.log}

usage() {
  cat <<'EOF'
Usage:
  fm-attention-check.sh [scan]   print the attention line now (writes nothing)
  fm-attention-check.sh check    watcher hook: sample decisions; at the first run
                                 after 13:00Z each day record the line, waking
                                 firstmate once when it is binding (RED, or S11 red)
  fm-attention-check.sh act reallocate|drain "<what was done>"
                                 record today's action against a binding line
  fm-attention-check.sh --help   print this help
EOF
}

die() { printf 'fm-attention-check: %s\n' "$1" >&2; exit "${2:-1}"; }

case "${1:-scan}" in
  scan|check|act) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || die "jq not found"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"

NOW=${FM_ATTENTION_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
NOW_EPOCH=$(fm_utc_iso_to_epoch "$NOW") || die "invalid FM_ATTENTION_NOW: $NOW" 2
WIN0=$((NOW_EPOCH - 86400))
iso_of() { jq -nr --argjson e "$1" '$e | todate'; }
WIN0_ISO=$(iso_of "$WIN0")
WIN_PREV_ISO=$(iso_of $((WIN0 - 86400)))
NOW_ISO=$(iso_of "$NOW_EPOCH")

age_text() {  # <seconds>
  if [ "$1" -ge 7200 ]; then
    printf '%sh' $(($1 / 3600))
  else
    printf '%sm' $(($1 / 60))
  fi
}

write_atomic() {  # <path> <content>
  local tmp
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$1.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$2" > "$tmp" || ! mv -f -- "$tmp" "$1"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# --- S1/S2: decision sampling -----------------------------------------------

# One "<task>\t<key>\t<estimated-first-seen>" line per decision open now.
current_open() {
  local f task open last last_key mtime est key
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    task=${f##*/}
    task=${task%.status}
    open=$(status_open_decisions "$f")
    [ -n "$open" ] || continue
    last=$(last_status_line "$f")
    last_key=
    case "$(status_line_verb "$last")" in
      needs-decision|blocked) last_key=$(_fm_decision_key "$last") || last_key= ;;
    esac
    mtime=$(_fm_status_file_mtime "$f") || mtime=$NOW_EPOCH
    while IFS=$'\t' read -r key _; do
      [ -n "$key" ] || continue
      est=$NOW_EPOCH
      if [ "$key" = "$last_key" ] && [ "$mtime" -le "$NOW_EPOCH" ]; then
        est=$mtime
      fi
      printf '%s\t%s\t%s\n' "$task" "$key" "$est"
    done <<EOF
$open
EOF
  done
}

# The stored record merged with the current open set: rows
# "<task>\t<key>\t<first-seen>\t<closed-or-empty>" after a since= header.
merged_record() {
  local prev_body='' since=$NOW_EPOCH
  if [ -f "$FIRST_SEEN" ] && [ "$(head -n 1 "$FIRST_SEEN")" = "$FIRST_SEEN_SCHEMA" ]; then
    since=$(sed -n 's/^since=//p' "$FIRST_SEEN" | head -n 1)
    case "$since" in ''|*[!0-9]*) since=$NOW_EPOCH ;; esac
    prev_body=$(grep -v -e '^fm-attention' -e '^since=' "$FIRST_SEEN" || true)
  fi
  printf '%s\nsince=%s\n' "$FIRST_SEEN_SCHEMA" "$since"
  awk -F '\t' -v now="$NOW_EPOCH" -v keep=$((NOW_EPOCH - 172800)) '
    FILENAME == ARGV[1] { if (NF >= 3) cur[$1 "\t" $2] = $3; next }
    NF >= 3 {
      id = $1 "\t" $2
      closed = $4
      if (closed == "") {
        if (id in cur) { open[id] = 1; print id "\t" $3 "\t"; next }
        closed = now
      }
      if (closed + 0 >= keep) print id "\t" $3 "\t" closed
    }
    END {
      for (id in cur) if (!(id in open)) print id "\t" cur[id] "\t"
    }' <(current_open) <(printf '%s\n' "$prev_body")
}

# "<since> <s1-count> <s1-tail-seconds> <s1-max-seconds> <s2-seconds>"
decision_metrics() {  # <record-text>
  printf '%s\n' "$1" | awk -F '\t' -v now="$NOW_EPOCH" -v w0="$WIN0" '
    /^since=/ { since = substr($0, 7) + 0; next }
    NF < 3 { next }
    {
      first = $3 + 0; end = ($4 == "") ? now : $4 + 0
      if (first >= w0 || $4 == "") {
        wait = end - first
        if (wait > maxw) maxw = wait
        if (wait > 1800) { n++; tail += wait }
      }
      s = (first < w0) ? w0 : first
      if (end > s) { t[++k] = s; d[k] = 1; t[++k] = end; d[k] = -1 }
    }
    END {
      # Insertion sort by time, closing before opening at the same instant.
      for (i = 2; i <= k; i++) {
        tv = t[i]; dv = d[i]; j = i - 1
        while (j >= 1 && (t[j] > tv || (t[j] == tv && d[j] > dv))) { t[j + 1] = t[j]; d[j + 1] = d[j]; j-- }
        t[j + 1] = tv; d[j + 1] = dv
      }
      c = 0; last = 0; three = 0
      for (i = 1; i <= k; i++) {
        if (c >= 3) three += t[i] - last
        c += d[i]; last = t[i]
      }
      printf "%d %d %d %d %d\n", since, n, tail, maxw, three
    }'
}

# --- backlog view -------------------------------------------------------------

# Empty when data/backlog.md exists but could not be read.
BACKLOG_JSON=
load_backlog() {
  if [ ! -e "$DATA/backlog.md" ]; then
    BACKLOG_JSON='{"backlog":{"records":[]},"tasks":[]}'
    return 0
  fi
  BACKLOG_JSON=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input 2>/dev/null) \
    && printf '%s' "$BACKLOG_JSON" | jq -e '.backlog.records | type == "array"' >/dev/null 2>&1 \
    || BACKLOG_JSON=
}

# --- line assembly ------------------------------------------------------------

RED_SIGNALS=
SEGMENTS=
add_segment() {  # <signal> <rating> <text> [info]
  SEGMENTS="${SEGMENTS}${SEGMENTS:+ | }$1 $3 [$2]"
  if [ "$2" = red ] && [ "${4:-}" != info ]; then
    RED_SIGNALS="${RED_SIGNALS}${RED_SIGNALS:+,}$1"
  fi
}

names_capped() {  # <newline-separated items> -> "a, b, c +N"
  printf '%s\n' "$1" | sed '/^$/d' | awk '{ if (NR <= 3) out = out (NR > 1 ? ", " : "") $0; n = NR }
    END { if (n > 3) out = out " +" (n - 3); printf "%s", out }'
}

signal_decisions() {  # <record-text>
  local since n tail maxw three rating note=''
  read -r since n tail maxw three <<EOF
$(decision_metrics "$1")
EOF
  [ "$since" -le "$WIN0" ] || note="; sampled since $(iso_of "$since" | cut -c12-16)Z"
  rating=green
  [ "$n" -eq 0 ] || rating=amber
  if [ "$n" -ge 5 ] || [ "$maxw" -gt 7200 ]; then rating=red; fi
  add_segment S1 "$rating" "decisions>30m $n ($(awk -v s="$tail" 'BEGIN { printf "%.1f", s / 3600 }') wh, max $(age_text "$maxw")$note)"
  rating=green
  [ "$three" -eq 0 ] || rating=amber
  [ "$three" -le 1800 ] || rating=red
  add_segment S2 "$rating" ">=3 open $((three / 60))m"
}

signal_green_blocked() {
  local f url first age n=0 over=0 listed='' rating
  for f in "$STATE"/*.pr-green-blocked; do
    [ -f "$f" ] || continue
    read -r url _ first _ < "$f" || true
    case "$first" in ''|*[!0-9]*) continue ;; esac
    n=$((n + 1))
    age=$((NOW_EPOCH - first))
    if [ "$age" -gt 1800 ]; then
      over=$((over + 1))
      listed="$listed${url#https://github.com/} $(age_text "$age")"$'\n'
    fi
  done
  rating=green
  [ "$n" -eq 0 ] || rating=amber
  [ "$over" -eq 0 ] || rating=red
  add_segment S3 "$rating" "green>30m $over${listed:+ ($(names_capped "$listed"))}"
}

# One "<project> <oldest-unreleased-seconds> <unreleased-over-2h> <merges> <merges-over-2h> <newest-tag> <lightweight-tags>"
# line per prod-tagged project; the five measures are "-" when no prod-* tag
# has a tagger date.
merged_not_live_rows() {
  local repo name main newest refs tags light sha ct oldest unrel_over merges slow lag t tt
  for repo in "$PROJECTS"/*/; do
    repo=${repo%/}
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
    refs=$(git -C "$repo" for-each-ref --sort=taggerdate \
      --format='%(refname:short) %(taggerdate:unix)' 'refs/tags/prod-*' 2>/dev/null)
    [ -n "$refs" ] || continue
    name=${repo##*/}
    light=$(printf '%s\n' "$refs" | awk 'NF == 1 { n++ } END { print n + 0 }')
    # Only tags that existed at NOW count, so a pinned clock replays that moment.
    tags=$(printf '%s\n' "$refs" | awk -v now="$NOW_EPOCH" 'NF >= 2 && $2 + 0 <= now')
    if [ -z "$tags" ]; then
      [ "$light" -eq 0 ] || printf '%s - - - - - %s\n' "$name" "$light"
      continue
    fi
    main=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || main=origin/main
    git -C "$repo" rev-parse -q --verify "$main^{commit}" >/dev/null 2>&1 || continue
    newest=$(printf '%s\n' "$tags" | tail -n 1 | cut -d' ' -f1)
    oldest=0
    unrel_over=0
    while read -r sha ct; do
      [ -n "$sha" ] && [ "$ct" -le "$NOW_EPOCH" ] || continue
      lag=$((NOW_EPOCH - ct))
      [ "$lag" -le "$oldest" ] || oldest=$lag
      [ "$lag" -le 7200 ] || unrel_over=$((unrel_over + 1))
    done <<EOF
$(git -C "$repo" log --first-parent --format='%H %ct' "$main" "^$newest" 2>/dev/null)
EOF
    merges=0
    slow=0
    while read -r sha ct; do
      [ -n "$sha" ] || continue
      [ "$ct" -ge "$WIN0" ] && [ "$ct" -le "$NOW_EPOCH" ] || continue
      merges=$((merges + 1))
      lag=$((NOW_EPOCH - ct))
      while read -r t tt; do
        [ -n "$t" ] && [ "$tt" -ge $((ct - 60)) ] || continue
        if git -C "$repo" merge-base --is-ancestor "$sha" "$t" 2>/dev/null; then
          lag=$((tt - ct))
          break
        fi
      done <<TAGS
$tags
TAGS
      [ "$lag" -le 7200 ] || slow=$((slow + 1))
    done <<EOF
$(git -C "$repo" log --first-parent --format='%H %ct' --since="$WIN0_ISO" "$main" 2>/dev/null)
EOF
    printf '%s %s %s %s %s %s %s\n' "$name" "$oldest" "$unrel_over" "$merges" "$slow" "$newest" "$light"
  done
}

signal_merged_not_live() {
  local rows='' rating=unknown parts='' name oldest unrel_over merges slow newest light r ignored
  command -v git >/dev/null 2>&1 && rows=$(merged_not_live_rows)
  if [ -z "$rows" ]; then
    add_segment S4 green "unreleased n/a (no prod-tagged project)"
    return 0
  fi
  while read -r name oldest unrel_over merges slow newest light; do
    [ -n "$name" ] || continue
    ignored=
    [ "$light" -eq 0 ] || ignored="; $light lightweight prod tag(s) ignored, no release time"
    if [ "$oldest" = - ]; then
      parts="$parts${parts:+; }$name unknown (only lightweight prod tags, no release time)"
      continue
    fi
    r=green
    if [ "$unrel_over" -gt 0 ] || [ "$slow" -gt 0 ]; then r=amber; fi
    if [ "$oldest" -gt 14400 ] || [ $((slow * 4)) -gt "$merges" ]; then r=red; fi
    case "$r:$rating" in red:*|amber:green|amber:unknown|green:unknown) rating=$r ;; esac
    if [ "$oldest" -eq 0 ]; then
      parts="$parts${parts:+; }$name 0 ($newest = main; $slow/$merges >2h$ignored)"
    else
      parts="$parts${parts:+; }$name oldest $(age_text "$oldest"), $unrel_over >2h ($slow/$merges >2h$ignored)"
    fi
  done <<EOF
$rows
EOF
  add_segment S4 "$rating" "unreleased $parts"
}

signal_ownerless() {
  local ids task_id meta target marker age last wait_until over=0 gone=0 listed='' rating
  # A row held with a hold-until date still ahead is a dated wait, like a
  # future `paused: ... until` status, and is not ownerless.
  if [ -z "$BACKLOG_JSON" ] || ! ids=$(printf '%s' "$BACKLOG_JSON" | jq -r --arg today "${NOW_ISO%%T*}" '
    .backlog.records[] | select(.structured == true and .state == "in_flight")
    | select((.hold_until // "") <= $today) | .id' 2>/dev/null); then
    add_segment S8 unknown "ownerless in-flight unknown (backlog unreadable)"
    return 0
  fi
  while IFS= read -r task_id; do
    [ -n "$task_id" ] || continue
    meta="$STATE/$task_id.meta"
    [ -f "$meta" ] || continue
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    marker="$STATE/.endpoint-gone-$(window_key "$target")"
    [ -f "$marker" ] || continue
    last=$(last_status_line "$STATE/$task_id.status")
    if wait_until=$(status_paused_until "$last") && [ "$wait_until" -gt "$NOW_EPOCH" ]; then
      continue
    fi
    gone=$((gone + 1))
    age=$((NOW_EPOCH - $(_fm_status_file_mtime "$marker")))
    if [ "$age" -gt 43200 ]; then
      over=$((over + 1))
      listed="$listed$task_id $(age_text "$age")"$'\n'
    fi
  done <<EOF
$ids
EOF
  rating=green
  [ "$gone" -eq 0 ] || rating=amber
  [ "$over" -eq 0 ] || rating=red
  add_segment S8 "$rating" "ownerless in-flight $over${listed:+ ($(names_capped "$listed"))}"
}

# "<task>\t<at>\t<path>" for every steering-inbox message stamped in the last 48 h.
inbox_messages() {
  local f at task
  for f in "$STATE"/*.inbox/*.msg "$STATE"/*.inbox/handled/*.msg; do
    [ -f "$f" ] || continue
    at=$(sed -n '/^at=/{s/^at=//p;q;}' "$f")
    [[ "$at" > "$WIN_PREV_ISO" ]] && [[ ! "$at" > "$NOW_ISO" ]] || continue
    task=${f#"$STATE"/}
    task=${task%%.inbox/*}
    printf '%s\t%s\t%s\n' "$task" "$at" "$f"
  done
}

signal_steering() {
  local msgs constraint
  msgs=$(inbox_messages)
  if [ -z "$BACKLOG_JSON" ] || ! constraint=$(printf '%s' "$BACKLOG_JSON" | jq -r --arg re "$CONSTRAINT_RE" '
    .backlog.records[] | select(.structured == true)
    | select((.body_lines // []) | map(select(startswith("verify:"))) | (.[0] // "") | ascii_downcase | test($re))
    | .id' 2>/dev/null); then
    add_segment S11 unknown "constraint steers unknown (backlog unreadable)"
  else
    steering_share "$msgs" "$constraint"
  fi
  release_steers "$msgs"
}

steering_share() {  # <msgs> <constraint-ids>
  local msgs=$1 constraint=$2 share prev rating detail on n pon pn
  read -r on n pon pn <<EOF
$(printf '%s\n' "$msgs" | awk -F '\t' -v w0="$WIN0_ISO" '
    FILENAME == ARGV[1] { if ($0 != "") c[$0] = 1; next }
    NF >= 3 { if ($2 > w0) { n++; if ($1 in c) on++ } else { pn++; if ($1 in c) pon++ } }
    END { printf "%d %d %d %d\n", on, n, pon, pn }' <(printf '%s\n' "$constraint") -)
EOF
  if [ "$n" -eq 0 ]; then
    rating=green
    detail="n/a (0 steers)"
  else
    share=$((on * 100 / n))
    detail="$share% ($on/$n"
    rating=green
    [ "$share" -ge 40 ] || rating=amber
    if [ "$pn" -gt 0 ]; then
      prev=$((pon * 100 / pn))
      detail="$detail; prior 24h $prev%"
      if [ "$rating" = amber ] && [ "$prev" -lt 40 ]; then rating=red; fi
    fi
    detail="$detail)"
  fi
  add_segment S11 "$rating" "constraint steers $detail"
}

release_steers() {  # <msgs>
  local msgs=$1 release=0 at path rating
  while IFS=$'\t' read -r _ at path; do
    [ -n "$path" ] && [[ "$at" > "$WIN0_ISO" ]] || continue
    if sed '1,/^--$/d' "$path" | grep -qiE "$RELEASE_RE"; then
      release=$((release + 1))
    fi
  done <<EOF
$msgs
EOF
  rating=green
  [ "$release" -eq 0 ] || rating=amber
  add_segment release-seq "$rating" "steers $release (info)" info
}

# One bounded read-only br call: every item of <db> that is not closed or
# tombstoned, as [{id,status,refs}], refs being the backlog row ids the item
# names through its `mirror:<row-id>` labels. Fails when br does.
br_items() {  # <db>
  local out
  out=$(fm_run_timed "$BR_TIMEOUT" br --db "$1" --no-auto-import --no-auto-flush \
    list --json -s all --limit 0 2>/dev/null) || return 1
  printf '%s' "$out" | jq -ce '.issues
    | map(select(.status != "closed" and .status != "tombstone") | {id, status,
        refs:[.labels[]? | select(startswith("mirror:")) | ltrimstr("mirror:")]})' 2>/dev/null
}

# "<n-br-only> <total> <ids>" for <items> against the open rows of
# <backlog-json> and of this (parent) home's <parent-backlog-json>.
br_only() {  # <items-json> <backlog-json> <parent-backlog-json>
  jq -nr --argjson items "$1" --argjson backlog "$2" --argjson parent "$3" '
    [$backlog, $parent | .backlog.records[] | select(.structured == true and .state != "done") | .id] as $rows
    | [$items[] | select(any(.refs[]; . as $r | $rows | index($r)) | not) | .id] as $only
    | "\($only | length) \($items | length) \($only | join(","))"'
}

# The shadow-queue cross-check, one part per br crew queue this home can read:
# its own at data/beads/.beads/beads.db, and each local registered secondmate's
# (data/secondmates.md) at <home>/data/beads/.beads/beads.db, each matched
# against its own home's backlog and its parent's. Read-only throughout.
BR_NOT_SEEN=
signal_br_shadow() {
  local parts='' rating=green label db home items backlog parent note n total ids line
  command -v br >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r label home; do
    [ -n "$home" ] || continue
    db="$home/data/beads/.beads/beads.db"
    [ -f "$db" ] || continue
    if ! items=$(br_items "$db"); then
      [ "$label" != home ] || BR_NOT_SEEN=unreadable
      parts="$parts${parts:+; }$label br unreadable"
      [ "$rating" = amber ] || rating=unknown
      continue
    fi
    if [ "$label" = home ]; then
      BR_NOT_SEEN=$(printf '%s' "$items" | jq -r '
        group_by(.status) | map("\(length) \(.[0].status)")
        | if length == 0 then "0 open" else join(", ") end')
      backlog=$BACKLOG_JSON
      parent=$(parent_backlog) || parent=
    else
      backlog=$(home_backlog "$home") || backlog=
      parent=$BACKLOG_JSON
    fi
    note=
    if [ -z "$parent" ]; then
      parent=$backlog
      note=', parent not checked'
      [ "$rating" = amber ] || rating=unknown
    fi
    if [ -z "$backlog" ] || ! line=$(br_only "$items" "$backlog" "$parent"); then
      parts="$parts${parts:+; }$label backlog unreadable"
      [ "$rating" = amber ] || rating=unknown
      continue
    fi
    read -r n total ids <<EOF
$line
EOF
    [ "$n" -eq 0 ] || rating=amber
    parts="$parts${parts:+; }$label $n/$total br-only${ids:+ ($(names_capped "$(printf '%s' "$ids" | tr ',' '\n')"))}$note"
  done <<EOF
$(br_queue_homes)
EOF
  [ -z "$parts" ] || add_segment br-xcheck "$rating" "$parts (info)" info
}

# Another home's backlog, read through its own snapshot.
home_backlog() {  # <home>
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$1" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input 2>/dev/null
}

# This home's parent backlog: its own in the primary home; in a secondmate home,
# the local parent home its .fm-secondmate-parent binding names. Fails when a
# secondmate home's parent is remote or unreadable.
parent_backlog() {
  [ -f "$FM_HOME/.fm-secondmate-home" ] || { printf '%s' "$BACKLOG_JSON"; return 0; }
  fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" \
    && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] && [ -d "$FM_SECONDMATE_PARENT_HOME" ] || return 1
  home_backlog "$FM_SECONDMATE_PARENT_HOME"
}

# "<label>\t<home>": this home, then every local registered secondmate home.
br_queue_homes() {
  local line
  printf 'home\t%s\n' "$FM_HOME"
  [ -f "$DATA/secondmates.md" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" 2>/dev/null || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] && [ -d "$SECONDMATE_REGISTRY_HOME" ] || continue
    printf '%s\t%s\n' "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME"
  done < "$DATA/secondmates.md"
}

blind_spots() {
  [ -n "$BR_NOT_SEEN" ] || return 0
  printf 'not seen: br crew queue %s units (S8/S11 read no br crews)' "$BR_NOT_SEEN"
}

# "<label>\t<home>" per home whose load S12 reads: this home under its own
# (possibly overridden) state and data, then each local registered secondmate
# home through its own FM_HOME.
load_homes() {
  local line
  printf 'home\t%s\n' "$FM_HOME"
  [ -f "$DATA/secondmates.md" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" 2>/dev/null || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] && [ -d "$SECONDMATE_REGISTRY_HOME" ] || continue
    printf '%s\t%s\n' "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME"
  done < "$DATA/secondmates.md"
}

signal_load() {
  local parts='' rating=green label home load n day median redates ids
  while IFS=$'\t' read -r label home; do
    [ -n "$home" ] || continue
    if [ "$label" = home ]; then
      load=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_QUEUE_ZERO_NOW="$NOW_ISO" \
        "$SCRIPT_DIR/fm-queue-zero.sh" load 2>/dev/null) || load=
    else
      load=$(env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$home" FM_QUEUE_ZERO_NOW="$NOW_ISO" \
        "$SCRIPT_DIR/fm-queue-zero.sh" load 2>/dev/null) || load=
    fi
    if [ -z "$load" ] || ! read -r n day median redates ids <<EOF
$(printf '%s' "$load" | jq -r '"\(.unowned) \(.unowned_over_day) \(.median_open_age_days // "-") \(.redates_no_progress) \(.unowned_ids | join(","))"' 2>/dev/null)
EOF
    then
      parts="$parts${parts:+; }$label load unknown"
      [ "$rating" != green ] || rating=unknown
      continue
    fi
    case "$n" in ''|*[!0-9]*) n=x ;; esac
    case "$day" in ''|*[!0-9]*) n=x ;; esac
    case "$redates" in ''|*[!0-9]*) n=x ;; esac
    if [ "$n" = x ]; then
      parts="$parts${parts:+; }$label load unknown"
      [ "$rating" != green ] || rating=unknown
      continue
    fi
    [ "$day" -eq 0 ] || rating=red
    if [ "$rating" != red ] && { [ "$n" -gt 0 ] || [ "$redates" -gt 0 ]; }; then rating=amber; fi
    parts="$parts${parts:+; }$label unowned $n ($day >24h${ids:+: $(names_capped "$(printf '%s' "$ids" | tr ',' '\n')")}), median age ${median}d, re-dates without progress $redates"
  done <<EOF
$(load_homes)
EOF
  add_segment S12 "$rating" "load $parts"
}

# Class E applications in the window, split by health; nothing when the log is
# absent or unreadable.
signal_class_e() {
  local out n health rating
  [ -f "$CLASS_E_LOG" ] && [ -r "$CLASS_E_LOG" ] || return 0
  out=$(awk -F '\t' -v w0="$WIN0_ISO" -v now="$NOW_ISO" '
    $2 == "class-e" && $1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ && $1 >= w0 && $1 <= now {
      n++; h = "?"
      for (i = 3; i <= NF; i++) if (index($i, "health=") == 1) h = substr($i, 8)
      c[h]++
    }
    END {
      printf "%d", n
      for (h in c) printf " %s=%d", h, c[h]
      printf "\n"
    }' "$CLASS_E_LOG" 2>/dev/null) || return 0
  read -r n health <<EOF
$out
EOF
  health=$(printf '%s\n' "$health" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')
  rating=green
  case " $health " in *" fail-"*|*" ?="*) rating=amber ;; esac
  add_segment class-e "$rating" "applied $n${health:+ ($health)} (info)" info
}

VERDICT=
attention_line() {  # <record-text>
  local reds blind
  load_backlog
  signal_decisions "$1"
  signal_green_blocked
  signal_merged_not_live
  signal_ownerless
  signal_steering
  signal_load
  reds=$(printf '%s' "$RED_SIGNALS" | awk -F ',' '{ print NF }')
  VERDICT=GREEN
  [ "${reds:-0}" -lt 1 ] || VERDICT=AMBER
  [ "${reds:-0}" -lt 2 ] || VERDICT=RED
  signal_br_shadow
  signal_class_e
  blind=$(blind_spots)
  LINE="attention $(printf '%s' "$NOW_ISO" | cut -c6-10) $(printf '%s' "$NOW_ISO" | cut -c12-16)Z $VERDICT${RED_SIGNALS:+ ($RED_SIGNALS)}: $SEGMENTS${blind:+ | $blind}"
}

action_scan() {
  attention_line "$(merged_record)"
  printf '%s\n' "$LINE"
}

# The binding trigger: a RED verdict, or S11 red on its own (S11 is red only
# when the constraint share was under 40% in this window and the one before).
binding_reason() {
  if [ "$VERDICT" = RED ]; then
    printf 'RED verdict'
  elif case ",$RED_SIGNALS," in *,S11,*) true ;; *) false ;; esac; then
    printf 'S11 red two windows running'
  fi
}

record_today() {  # -> 0 when the record is today's, with its body in RECORD_BODY
  RECORD_BODY=
  [ -f "$RECORD" ] && [ "$(head -n 1 "$RECORD")" = "$RECORD_SCHEMA" ] || return 1
  RECORD_BODY=$(cat "$RECORD")
  [ "$(printf '%s\n' "$RECORD_BODY" | sed -n 's/^reported=//p' | head -n 1)" = "${NOW_ISO%%T*}" ]
}

action_check() {
  local record today reason bound
  record=$(merged_record)
  write_atomic "$FIRST_SEEN" "$record" || die "could not write $FIRST_SEEN"
  today=${NOW_ISO%%T*}
  [ "$((10#$(printf '%s' "$NOW_ISO" | cut -c12-13)))" -ge "$DAILY_HOUR" ] || return 0
  ! record_today || return 0
  attention_line "$record"
  bound=$(binding_reason)
  if [ -n "$bound" ]; then
    reason="check: attention: BINDING ($bound) - act on it this turn: reallocate non-constraint steers toward the constraint or drain the open decisions, then record it with bin/fm-attention-check.sh act reallocate|drain \"<what was done>\"; $LINE"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    fm_wake_append check attention "$reason" || die "could not queue the attention wake; it is retried next run"
    write_atomic "$RECORD" "$RECORD_SCHEMA"$'\n'"reported=$today"$'\n'"line=$LINE"$'\n'"bound=$bound" || true
    printf '%s\n' "$reason"
    return 0
  fi
  write_atomic "$RECORD" "$RECORD_SCHEMA"$'\n'"reported=$today"$'\n'"line=$LINE" \
    || die "could not write $RECORD"
}

action_act() {  # <reallocate|drain> <note>
  local kind=${1:-} note=${2:-}
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  case "$kind" in reallocate|drain) ;; *) die "act kind must be reallocate or drain: $kind" 2 ;; esac
  note=$(printf '%s' "$note" | tr '\n\t' '  ' | sed 's/^ *//; s/ *$//')
  [ -n "$note" ] || die "act needs a note naming what was done" 2
  record_today || die "no attention line is recorded for ${NOW_ISO%%T*}; nothing to act against" 1
  printf '%s\n' "$RECORD_BODY" | grep -q '^bound=' \
    || die "today's attention line is not binding; no action is owed" 1
  write_atomic "$RECORD" "$RECORD_BODY"$'\n'"action=$NOW_ISO $kind $note" || die "could not write $RECORD"
  printf 'attention action recorded %s: %s %s\n' "$NOW_ISO" "$kind" "$note"
}

case "${1:-scan}" in
  scan) action_scan ;;
  check) action_check ;;
  act) shift; action_act "$@" ;;
esac
