#!/usr/bin/env bash
# fm-attention-check.sh - the daily attention check: one line rating whether
# firstmate's own attention is the fleet's constraint, signal by signal.
#
# Usage:
#   fm-attention-check.sh [scan]    print the line now (on demand; writes nothing)
#   fm-attention-check.sh check     watcher hook: sample decisions, record the daily line
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
#   release-seq  inbox messages in the window that sequence a release by hand
#       ("next in line", "queued behind", "after ... deploys"). Informational:
#       amber when any, never part of the verdict.
#
# The verdict follows data/firstmate-bottleneck-plan section 5: RED when two or
# more of S1, S2, S3, S4, S8, S11 are red, AMBER when one is, GREEN otherwise.
#
# Blind spots are named on the line rather than guessed: when the home keeps a
# beads (br) crew queue at data/beads/.beads/beads.db and br is installed, the
# line reports its open and in-progress unit counts as not seen (one read-only
# br call bounded to FM_ATTENTION_BR_TIMEOUT seconds, default 5), because S8
# and S11 read only backlog rows, task records, and steering inboxes, and br
# crews have none of those.
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
# after 13:00Z each UTC day it computes the line and records it in
# state/.attention-check (reported=<date>, line=<line>). When the verdict is
# RED it first appends one durable `check` wake (key attention) and prints that
# wake reason; otherwise it prints nothing and the line waits in the record,
# which the fleet snapshot and bin/fm-fleet-view.sh show without a wake.
# A failed wake append is retried on the next run instead of being recorded.
# Those two records and that wake are the only writes.
#
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

usage() {
  cat <<'EOF'
Usage:
  fm-attention-check.sh [scan]   print the attention line now (writes nothing)
  fm-attention-check.sh check    watcher hook: sample decisions; at the first run
                                 after 13:00Z each day record the line, waking
                                 firstmate once when it is RED
  fm-attention-check.sh --help   print this help
EOF
}

die() { printf 'fm-attention-check: %s\n' "$1" >&2; exit "${2:-1}"; }

case "${1:-scan}" in
  scan|check) ;;
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

NOW=${FM_ATTENTION_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
NOW_EPOCH=$(fm_utc_iso_to_epoch "$NOW") || die "invalid FM_ATTENTION_NOW: $NOW" 2
WIN0=$((NOW_EPOCH - 86400))
iso_of() { jq -nr --argjson e "$1" '$e | todate'; }
WIN0_ISO=$(iso_of "$WIN0")
WIN_PREV_ISO=$(iso_of $((WIN0 - 86400)))
NOW_ISO=$(iso_of "$NOW_EPOCH")

mtime_of() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

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
    mtime=$(mtime_of "$f") || mtime=$NOW_EPOCH
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
    age=$((NOW_EPOCH - $(mtime_of "$marker")))
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

blind_spots() {
  local db counts
  db="$DATA/beads/.beads/beads.db"
  [ -f "$db" ] && command -v br >/dev/null 2>&1 || return 0
  counts=$(fm_run_timed "$BR_TIMEOUT" br --db "$db" --no-auto-import --no-auto-flush count --by-status --json 2>/dev/null) \
    && counts=$(printf '%s' "$counts" \
      | jq -er '[.groups[] | select(.group == "open" or .group == "in_progress") | "\(.count) \(.group)"] | join(", ")' 2>/dev/null) \
    || counts=unreadable
  printf 'not seen: br crew queue %s units (S8/S11 read no br crews)' "${counts:-0 open}"
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
  reds=$(printf '%s' "$RED_SIGNALS" | awk -F ',' '{ print NF }')
  VERDICT=GREEN
  [ "${reds:-0}" -lt 1 ] || VERDICT=AMBER
  [ "${reds:-0}" -lt 2 ] || VERDICT=RED
  blind=$(blind_spots)
  LINE="attention $(printf '%s' "$NOW_ISO" | cut -c6-10) $(printf '%s' "$NOW_ISO" | cut -c12-16)Z $VERDICT${RED_SIGNALS:+ ($RED_SIGNALS)}: $SEGMENTS${blind:+ | $blind}"
}

action_scan() {
  attention_line "$(merged_record)"
  printf '%s\n' "$LINE"
}

action_check() {
  local record today reason
  record=$(merged_record)
  write_atomic "$FIRST_SEEN" "$record" || die "could not write $FIRST_SEEN"
  today=${NOW_ISO%%T*}
  [ "$((10#$(printf '%s' "$NOW_ISO" | cut -c12-13)))" -ge "$DAILY_HOUR" ] || return 0
  if [ -f "$RECORD" ] && [ "$(head -n 1 "$RECORD")" = "$RECORD_SCHEMA" ] \
    && [ "$(sed -n 's/^reported=//p' "$RECORD" | head -n 1)" = "$today" ]; then
    return 0
  fi
  attention_line "$record"
  if [ "$VERDICT" = RED ]; then
    reason="check: attention: $LINE"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    fm_wake_append check attention "$reason" || die "could not queue the attention wake; it is retried next run"
    write_atomic "$RECORD" "$RECORD_SCHEMA"$'\n'"reported=$today"$'\n'"line=$LINE" || true
    printf '%s\n' "$reason"
    return 0
  fi
  write_atomic "$RECORD" "$RECORD_SCHEMA"$'\n'"reported=$today"$'\n'"line=$LINE" \
    || die "could not write $RECORD"
}

case "${1:-scan}" in
  scan) action_scan ;;
  check) action_check ;;
esac
