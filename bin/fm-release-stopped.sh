#!/usr/bin/env bash
# fm-release-stopped.sh - release-stopped alarm: wake firstmate once per
# episode when a registered project's release advance has failed or refused to
# start FM_RELEASE_STOPPED_AFTER (default 2) times in a row, so merged work
# does not sit hours behind a stopped release with nobody told.
#
# Usage:
#   fm-release-stopped.sh scan
#   fm-release-stopped.sh check
#   fm-release-stopped.sh --help
#
# THE SIGNAL: a project's release queue ledger, the JSON Lines file its
# release chain appends one object to per release event (for example
# <checkout>/.runtime/release-queue/queue.jsonl). It is the smallest reliable
# release-failure signal available to firstmate: it is local, written by the
# release chain itself at the moment of each attempt's outcome, needs no
# network or forge call, and is the same ledger bin/fm-flow-wait.py already
# reads for merged-to-live timing. Which ledger belongs to which repository is
# config/release-ledgers, whose schema docs/configuration.md "Release-stopped
# alarm" owns; a home without that file checks nothing.
#
# An attempt outcome is a ledger line whose `event` is `release` and whose
# `result` is a non-empty string: `done` is a release that reached live, and
# every other result (failed, refused, error, ...) is a release that failed
# or refused to start. Every other line is context only. The failing step is
# that line's `step`, else the `step` of the latest earlier `step` event of
# the same `ticket`, else `release`. The error text is the first non-empty of
# its `error`, `reason`, `detail`, or `proof`, whitespace-folded and cut to
# FM_RELEASE_STOPPED_ERROR_CHARS (default 300). Only the last
# FM_RELEASE_LEDGER_LINES (default 2000) lines are read, and a line that is
# not a JSON object is skipped.
#
# AN EPISODE is a run of consecutive failed outcomes since the last `done`,
# named by its first failure's `epoch` and `ticket`. Once that run reaches
# FM_RELEASE_STOPPED_AFTER outcomes, `check` first appends one durable `check`
# wake (key "release-stopped <repository-url>") naming the repository, the
# failing step, and the error text of the latest failure, then records the
# episode in state/release-stopped/<slug> and prints the reason; further
# failures in the same run stay silent. A `done` outcome ends the episode and
# removes its record, so the next run of failures is a new episode. When the
# window read holds no `done` at all, a recorded episode is kept, so a long
# run of failures sliding past the window does not re-alarm. A configured
# ledger that cannot be read is its own episode (named `unreadable`), woken
# once and cleared when it reads again. The record is written only after the
# wake is durably queued, so a failed append is retried rather than
# suppressed.
#
# `scan` is read-only and prints one line per configured repository:
# "<repository-url> ok|failing <n>|unreadable [step <step>: <error>]".
#
# `check` follows the watcher's custom-check output contract: it prints one
# line when firstmate should wake and nothing otherwise. bin/fm-watch.sh runs
# it on every poll cycle while config/release-ledgers exists (release_stopped
# tick), so a second consecutive failure wakes within one watcher cycle.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
LEDGERS="$CONFIG/release-ledgers"
RECORDS="$STATE/release-stopped"

usage() {
  cat <<'EOF'
Usage:
  fm-release-stopped.sh scan      show each configured repository's current release run
  fm-release-stopped.sh check     watcher hook: one wake line per new release-stopped episode
  fm-release-stopped.sh --help    print this help

Repositories and their release queue ledgers come from config/release-ledgers
(schema: docs/configuration.md "Release-stopped alarm").
EOF
}

die() { printf 'fm-release-stopped: %s\n' "$1" >&2; exit "${2:-1}"; }

whole_setting() {  # <name> <default>
  local v=${!1:-$2}
  case "$v" in ''|*[!0-9]*|0) v=$2 ;; esac
  printf '%s' "$v"
}
AFTER=$(whole_setting FM_RELEASE_STOPPED_AFTER 2)
LINES=$(whole_setting FM_RELEASE_LEDGER_LINES 2000)
ERROR_CHARS=$(whole_setting FM_RELEASE_STOPPED_ERROR_CHARS 300)

# ledgers: "<repository-url><TAB><ledger-path>" per valid config line.
ledgers() {
  [ -f "$LEDGERS" ] || return 0
  awk '/^[[:space:]]*(#|$)/ { next } NF == 2 { print $1 "\t" $2 }' "$LEDGERS"
}

# run_of <ledger>: one JSON object describing the trailing failure run, or
# nothing when the ledger cannot be read.
run_of() {
  local ledger=$1 tail_out
  [ -f "$ledger" ] && [ -r "$ledger" ] || return 1
  tail_out=$(tail -n "$LINES" -- "$ledger") || return 1
  printf '%s\n' "$tail_out" | jq -R -c -s --argjson max "$ERROR_CHARS" '
    [ split("\n")[] | select(length > 0) | (try fromjson catch null) | select(type == "object") ] as $ev
    | reduce range(0; $ev | length) as $i ({run: [], seen_done: false, steps: {}};
        $ev[$i] as $e
        | if $e.event == "step" and ($e.step | type) == "string"
          then .steps[($e.ticket // "" | tostring)] = $e.step
          elif $e.event == "release" and ($e.result | type) == "string" and $e.result != ""
          then if $e.result == "done"
            then .run = [] | .seen_done = true
            else .run += [{
              id: "\($e.epoch // "")/\($e.ticket // "")",
              step: ($e.step // .steps[($e.ticket // "" | tostring)] // "release" | tostring),
              error: ([$e.error, $e.reason, $e.detail, $e.proof]
                | map(select(. != null) | tostring | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" "))
                | map(select(. != "")) | first // "(no error text)"
                | if length > $max then .[:$max - 1] + "…" else . end)}]
            end
          else . end)
    | {count: (.run | length), seen_done, id: (.run[0].id // ""),
       step: (.run[-1].step // ""), error: (.run[-1].error // "")}'
}

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

action_scan() {
  local repo ledger run
  while IFS=$'\t' read -r repo ledger; do
    if ! run=$(run_of "$ledger") || [ -z "$run" ]; then
      printf '%s unreadable %s\n' "$repo" "$ledger"
      continue
    fi
    printf '%s' "$run" | jq -r --arg repo "$repo" \
      'if .count == 0 then "\($repo) ok" else "\($repo) failing \(.count) step \(.step): \(.error)" end'
  done < <(ledgers)
}

action_check() {
  local repo ledger run record prev episode count seen_done text reasons='' n=0 reason
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  mkdir -p "$RECORDS" || die "could not create $RECORDS"
  while IFS=$'\t' read -r repo ledger; do
    record="$RECORDS/$(slug "$repo")"
    prev=
    [ ! -f "$record" ] || [ -L "$record" ] || prev=$(head -n 1 "$record")
    if ! run=$(run_of "$ledger") || [ -z "$run" ]; then
      episode=unreadable
      text="release ledger $ledger cannot be read, so its release failures are not being watched"
    else
      count=$(printf '%s' "$run" | jq -r '.count')
      seen_done=$(printf '%s' "$run" | jq -r '.seen_done')
      if [ "$count" -lt "$AFTER" ]; then
        rm -f -- "$record"
        continue
      fi
      episode=$(printf '%s' "$run" | jq -r '.id')
      # Without a done in the window the run may have slid past its start.
      if [ "$seen_done" != true ] && [ -n "$prev" ] && [ "$prev" != unreadable ]; then
        continue
      fi
      text=$(printf '%s' "$run" | jq -r '"release stopped after \(.count) consecutive failed or refused release attempts; step \(.step): \(.error)"')
    fi
    [ "$prev" != "$episode" ] || continue
    reason="release-stopped $repo: $text"
    fm_wake_append check "release-stopped $repo" "check: $reason" \
      || die "could not queue the release-stopped wake for $repo; it is retried next cycle"
    printf '%s\n' "$episode" > "$record.tmp" && mv -f -- "$record.tmp" "$record" || true
    reasons="${reasons:+$reasons; }$reason"
    n=$((n + 1))
  done < <(ledgers)
  [ "$n" -gt 0 ] || return 0
  printf 'check: %s\n' "$reasons"
}

case "${1:-}" in
  scan) command -v jq >/dev/null 2>&1 || die "jq not found"; action_scan ;;
  check) command -v jq >/dev/null 2>&1 || die "jq not found"; action_check ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
