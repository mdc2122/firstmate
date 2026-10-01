#!/usr/bin/env bash
# fm-paperclip-sweep.sh - Paperclip inbox zero: find board issues and approvals
# that are stuck without an owner acting on them.
#
# Usage:
#   fm-paperclip-sweep.sh configured
#   fm-paperclip-sweep.sh scan [--json]
#   fm-paperclip-sweep.sh release <issue> [<issue>...]
#   fm-paperclip-sweep.sh --help
#
# `configured` exits 0 when this home's environment or gitignored .env names a
# Paperclip instance (FM_PAPERCLIP_URL plus a readable FM_PAPERCLIP_KEY_FILE),
# and 1 otherwise. docs/configuration.md "Paperclip sweep" owns that schema.
#
# `scan` is read-only. It makes its GET calls through Paperclip's supported
# board API: company discovery when FM_PAPERCLIP_COMPANY is unset, the
# open-issue list with includeBlockedBy, the pending-approval list, and the
# latest comment of each blocked issue with no dated monitor. It prints one
# row per item that needs action:
#
#   release             a backlog issue with at least one blocker, every one done
#   stale-edge          a blocked issue whose every blocker is done
#   no-blocker          a backlog or blocked issue with no blocker, no unblock
#                       owner, and no dated next check
#   stalled             a blocked issue Paperclip does not report as covered by
#                       live blocker work, with no dated next check
#   orphaned-execution  an in_progress issue with no execution run, no dated
#                       next check, and no activity for FM_PAPERCLIP_STALE_HOURS
#   recovery            an open issue carrying an active or escalated recovery
#                       action (orphaned or inspect-only executions)
#   approval            a pending approval older than FM_PAPERCLIP_APPROVAL_AGE_HOURS
#
# A "dated next check" is the issue's monitor (monitorNextCheckAt) still in the
# future. Paperclip refuses a monitor on a blocked issue (HTTP 422) and its
# unblockDescriptor carries no date, so a blocked issue's owner records one as
# a line of the issue's latest comment:
#
#   fm-next-check: <ISO-8601 UTC, e.g. 2026-10-02T09:00:00Z> owner=<name>
#
# The line must start the comment line, the time must end in Z (seconds are
# optional), and owner= must name someone. A blocked issue whose latest
# comment carries such a line with a future time is treated as dated and not
# listed; once the time passes, or when a newer comment lacks the line, or the
# line is malformed, it is listed again. A backlog issue with an open blocker
# is not listed: it is released by the `release` row the moment its blockers
# are done. A blocked issue that Paperclip's own blockerAttention reports as
# covered is waiting on live work.
# The scan prints nothing when nothing needs action, and prints one `error`
# row instead of silence when the instance cannot be read.
#
# `release` is the one mutation, run by firstmate on a `release` or
# `stale-edge` row: it re-reads each named issue, refuses unless it is backlog
# or blocked with at least one blocker and every blocker done, then sends
# PATCH /api/issues/<id> {"status":"todo"} with a comment naming the blockers.
#
# The board key is passed to curl on stdin, never on its command line.
# FM_QUEUE_ZERO_NOW (UTC ISO-8601) pins the clock for tests.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
ENV_FILE="$FM_HOME/.env"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"  # fmx_env_get: the shared .env reader

usage() {
  cat <<'EOF'
Usage:
  fm-paperclip-sweep.sh configured            exit 0 when this home names a Paperclip instance
  fm-paperclip-sweep.sh scan [--json]         list stuck issues and stale approvals (read-only)
  fm-paperclip-sweep.sh release <issue>...    move done-blocker issues to todo (guarded)
  fm-paperclip-sweep.sh --help                print this help

Configuration (environment wins over <FM_HOME>/.env): FM_PAPERCLIP_URL,
FM_PAPERCLIP_KEY_FILE, optional FM_PAPERCLIP_COMPANY. See docs/configuration.md
"Paperclip sweep".
EOF
}

die() { printf 'fm-paperclip-sweep: %s\n' "$1" >&2; exit "${2:-1}"; }

config_get() {  # <key>: environment first, then the home .env
  local key=$1 val
  val=${!key:-}
  [ -n "$val" ] || val=$(fmx_env_get "$key" "$ENV_FILE")
  printf '%s' "$val"
}

PC_URL=$(config_get FM_PAPERCLIP_URL)
PC_URL=${PC_URL%/}
PC_KEY_FILE=$(config_get FM_PAPERCLIP_KEY_FILE)
case "$PC_KEY_FILE" in \~/*) PC_KEY_FILE="$HOME/${PC_KEY_FILE:2}" ;; esac
PC_COMPANY=$(config_get FM_PAPERCLIP_COMPANY)
CURL_SECS=${FM_PAPERCLIP_CURL_SECS:-8}
case "$CURL_SECS" in ''|*[!0-9]*|0) CURL_SECS=8 ;; esac

hours_setting() {  # <name> <default>
  local v=${!1:-$2}
  case "$v" in ''|*[!0-9]*|0) v=$2 ;; esac
  printf '%s' "$v"
}
APPROVAL_AGE_HOURS=$(hours_setting FM_PAPERCLIP_APPROVAL_AGE_HOURS 4)
STALE_HOURS=$(hours_setting FM_PAPERCLIP_STALE_HOURS 6)

NOW=${FM_QUEUE_ZERO_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

configured() {
  [ -n "$PC_URL" ] && [ -n "$PC_KEY_FILE" ] && [ -r "$PC_KEY_FILE" ]
}

# api <method> <path> [<json-body>]: one bounded call. On a 2xx status the
# response body is left in API_BODY; otherwise API_ERROR names the failure.
# Both are globals rather than stdout so a failure reason survives the call.
api() {
  local method=$1 path=$2 body=${3:-} key out code
  API_BODY=
  key=$(head -n 1 "$PC_KEY_FILE" 2>/dev/null | tr -d '[:space:]')
  [ -n "$key" ] || { API_ERROR="board key file is empty"; return 1; }
  if [ -n "$body" ]; then
    out=$(printf 'Authorization: Bearer %s\n' "$key" \
      | curl -sS -m "$CURL_SECS" -X "$method" -H @- -H 'Content-Type: application/json' \
          --data "$body" -w '\n%{http_code}' "$PC_URL/api$path" 2>&1) \
      || { API_ERROR="$method $path failed: $(printf '%s' "$out" | head -n 1)"; return 1; }
  else
    out=$(printf 'Authorization: Bearer %s\n' "$key" \
      | curl -sS -m "$CURL_SECS" -X "$method" -H @- -w '\n%{http_code}' "$PC_URL/api$path" 2>&1) \
      || { API_ERROR="$method $path failed: $(printf '%s' "$out" | head -n 1)"; return 1; }
  fi
  code=${out##*$'\n'}
  case "$code" in
    2[0-9][0-9]) API_BODY=${out%$'\n'*} ;;
    *) API_ERROR="$method $path returned HTTP $code"; return 1 ;;
  esac
}

resolve_company() {
  [ -z "$PC_COMPANY" ] || return 0
  api GET /cli-auth/me || return 1
  PC_COMPANY=$(printf '%s' "$API_BODY" | jq -r 'if (.companyIds | length) == 1 then .companyIds[0] else empty end' 2>/dev/null)
  [ -n "$PC_COMPANY" ] || { API_ERROR="the board key sees zero or several companies; set FM_PAPERCLIP_COMPANY"; return 1; }
}

# Shared jq definitions: timestamp parsing and the issue's dated monitor.
# shellcheck disable=SC2016  # jq program text, not shell expansions.
DEFS='
  def ts: if . == null then null
          else (tostring | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) end;
  def dated_next: ((.monitorNextCheckAt | ts) as $t | $t != null and $t > $now);
'

# The classifier, over the open-issue list, the pending-approval list, and
# $latest (blocked issue id -> latest comment body). Rows: {class, ref, title, detail}.
# shellcheck disable=SC2016  # jq program text, not shell expansions.
CLASSIFY='
  def marker_next:
    ([($latest[.id] // "") | split("\n")[]
      | capture("^[ \\t]*fm-next-check:[ \\t]*(?<t>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\\.[0-9]+)?)?Z)[ \\t]+owner=[^ \\t\\r]+")
      | .t
      | if test("T[0-9]{2}:[0-9]{2}Z$") then sub("Z$"; ":00Z") else . end
      | ts] | last) as $t
    | $t != null and $t > $now;
  def refs($l): ($l | map(.identifier // .id) | join(","));
  def short: tostring | gsub("\\s+"; " ") | if length > 70 then .[:69] + "…" else . end;
  ($issues | map(
     . as $i
     | (.blockedBy // []) as $bb
     | ([$bb[] | select(.status != "done")]) as $open
     | {ref:(.identifier // .id), title:(.title // "" | short)} as $row
     | if .status == "backlog" then
         if ($bb | length) > 0 and ($open | length) == 0 then
           $row + {class:"release", detail:("blockers done: " + refs($bb))}
         elif ($open | length) > 0 or dated_next then empty
         else $row + {class:"no-blocker", detail:"backlog with no blocker and no dated next check"} end
       elif .status == "blocked" then
         if dated_next or marker_next then empty
         elif ($bb | length) > 0 and ($open | length) == 0 then
           $row + {class:"stale-edge", detail:("blocked but blockers done: " + refs($bb))}
         elif (.blockerAttention.state // null) == "covered" then empty
         elif ($bb | length) == 0 and .unblockDescriptor == null then
           $row + {class:"no-blocker", detail:"blocked with no blocker, no unblock owner, and no dated next check"}
         else $row + {class:"stalled",
                      detail:("blocker attention " + (.blockerAttention.state // "unknown")
                              + (if ($open | length) > 0 then "; waiting on " + refs($open) else "" end)
                              + "; no dated next check")} end
       elif .status == "in_progress" and .executionRunId == null and (dated_next | not)
            and (((.lastActivityAt // .updatedAt) | ts) // 0) < ($now - $stale_secs) then
         $row + {class:"orphaned-execution", detail:"in progress with no run, no dated next check, and no recent activity"}
       else empty end)
   + [ $issues[]
       | select(.activeRecoveryAction != null
                and ((.activeRecoveryAction.status // "active") == "active"
                     or .activeRecoveryAction.status == "escalated"))
       | {class:"recovery", ref:(.identifier // .id), title:(.title // "" | short),
          detail:("recovery " + (.activeRecoveryAction.cause // "unknown") + ": "
                  + (.activeRecoveryAction.nextAction // "-") | short)} ])
  + [ $approvals[]
      | select(.status == "pending")
      | select(((.createdAt | ts) // $now) <= ($now - $approval_secs))
      | {class:"approval", ref:("approval:" + (.id | tostring | .[:8])),
         title:((.payload.title // .payload.name // .type // "") | short),
         detail:("pending since " + (.createdAt | tostring))} ]
'

# scan_rows: leave the classified rows in SCAN_ROWS, or set API_ERROR. The
# responses go to jq through private files, because an issue list can outgrow
# a command-line argument. A failed comment read leaves that issue unmarked,
# so it is listed as it would be without a marker.
scan_rows() {
  local now_epoch tmp id rc=0
  SCAN_ROWS=
  configured || { API_ERROR="not configured"; return 1; }
  resolve_company || return 1
  now_epoch=$(jq -nr --arg now "$NOW" '$now | fromdateiso8601' 2>/dev/null) \
    || { API_ERROR="invalid FM_QUEUE_ZERO_NOW"; return 1; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-paperclip-sweep.XXXXXX") || { API_ERROR="no temporary directory"; return 1; }
  : > "$tmp/latest.ndjson"
  if ! api GET "/companies/$PC_COMPANY/issues?status=backlog,blocked,todo,in_progress,in_review&limit=1000&includeBlockedBy=true" \
    || ! printf '%s' "$API_BODY" > "$tmp/issues.json" \
    || ! api GET "/companies/$PC_COMPANY/approvals?status=pending" \
    || ! printf '%s' "$API_BODY" > "$tmp/approvals.json"; then
    rc=1
  elif ! jq -r --argjson now "$now_epoch" \
      "$DEFS .[] | select(.status == \"blocked\" and (dated_next | not)) | .id | strings" \
      "$tmp/issues.json" > "$tmp/blocked-ids" 2>/dev/null; then
    API_ERROR="unexpected response shape"
    rc=1
  else
    while IFS= read -r id; do
      api GET "/issues/$id/comments?order=desc&limit=1" || continue
      printf '%s' "$API_BODY" \
        | jq -c --arg id "$id" '{key:$id, value:(if type == "array" then (.[0].body // "") else "" end | tostring)}' \
          >> "$tmp/latest.ndjson" 2>/dev/null
    done < "$tmp/blocked-ids"
    API_ERROR=
    if ! SCAN_ROWS=$(jq -nc --slurpfile i "$tmp/issues.json" --slurpfile a "$tmp/approvals.json" \
        --slurpfile l "$tmp/latest.ndjson" \
        --argjson now "$now_epoch" \
        --argjson stale_secs "$((STALE_HOURS * 3600))" \
        --argjson approval_secs "$((APPROVAL_AGE_HOURS * 3600))" \
        "\$i[0] as \$issues | \$a[0] as \$approvals | (\$l | from_entries) as \$latest | $DEFS $CLASSIFY" 2>/dev/null); then
      API_ERROR="unexpected response shape"
      rc=1
    fi
  fi
  rm -rf -- "$tmp"
  return "$rc"
}

action_scan() {
  API_ERROR=
  if ! scan_rows; then
    SCAN_ROWS=$(jq -nc --arg d "$API_ERROR" '[{class:"error",ref:"paperclip",title:"Paperclip sweep could not read the board",detail:$d}]')
  fi
  if [ "${1:-}" = --json ]; then
    printf '%s\n' "$SCAN_ROWS"
  else
    printf '%s\n' "$SCAN_ROWS" | jq -r '.[] | "\(.class) \(.ref) - \(.title) [\(.detail)]"'
  fi
}

action_release() {
  local ref detail id status failed=0 body
  [ "$#" -gt 0 ] || die "release needs at least one issue identifier" 2
  configured || die "Paperclip is not configured for this home (docs/configuration.md \"Paperclip sweep\")" 2
  for ref in "$@"; do
    API_ERROR=
    if ! api GET "/issues/$ref"; then
      printf 'refused %s: %s\n' "$ref" "$API_ERROR"; failed=1; continue
    fi
    detail=$API_BODY
    status=$(printf '%s' "$detail" | jq -r '.status // ""')
    id=$(printf '%s' "$detail" | jq -r '.id // ""')
    case "$status" in
      backlog|blocked) ;;
      *) printf 'refused %s: status is %s, not backlog or blocked\n' "$ref" "$status"; failed=1; continue ;;
    esac
    if ! printf '%s' "$detail" | jq -e '((.blockedBy // []) | length) > 0 and all((.blockedBy // [])[]; .status == "done")' >/dev/null; then
      printf 'refused %s: it has no blocker, or a blocker is not done\n' "$ref"; failed=1; continue
    fi
    body=$(printf '%s' "$detail" | jq -c '{status:"todo",
      comment:("Released by firstmate: every blocker is done (" + ((.blockedBy // []) | map(.identifier // .id) | join(", ")) + ").")}')
    if api PATCH "/issues/$id" "$body"; then
      printf 'released %s\n' "$ref"
    else
      printf 'refused %s: %s\n' "$ref" "$API_ERROR"; failed=1
    fi
  done
  return "$failed"
}

command -v jq >/dev/null 2>&1 || die "jq not found"
case "${1:-}" in
  configured) configured ;;
  scan) shift; action_scan "$@" ;;
  release) shift; command -v curl >/dev/null 2>&1 || die "curl not found"; action_release "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
