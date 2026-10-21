#!/usr/bin/env bash
# tests/fm-stranded-draft-delivery.test.sh - a composer holding only a stranded
# operational draft must not starve the steering doorbell.
#
# The 2026-10-16 failure mode: a harness typed a watcher wake into its composer
# but never submitted it, so the composer read `pending` forever and every later
# steer skipped with it while the pane sat idle. The ring now submits that
# machine-issued draft with exactly one Enter and reports the RECOVERED attempt.
#
# What these cases pin, in the RING's own contract:
#   1. A recoverable operational draft is submitted with exactly one Enter and
#      returns 4 WHEN the submit freed the composer.
#   2. A submit that leaves the composer still holding text recovered nothing:
#      it is NOT reported as 4, and the doorbell is never typed into that
#      still-pending composer (rc 1, the ordinary skip).
#   3. The legacy watcher carrier, in the single-line form real composer
#      extraction produces, is refused (rc 1, no keystroke).
#   4. Human-authored pending text is never typed into (rc 1, no keystroke).
#   5. Text that merely RESEMBLES an operational draft is refused the same way.
#   6. A composer reading pending whose content cannot be read at all (content
#      extraction fails) is refused rather than guessed at.
#
# Case 2 is the regression this file exists for: the original suite stubbed
# `fm_backend_composer_state` to return the same `pending` verdict before AND
# after the Enter, so the post-submit check could never observe the composer
# being freed, and a harness whose Enter did NOT free the composer was reported
# as a recovered success.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INBOX_LIB="$ROOT/bin/fm-task-inbox-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-stranded-draft-delivery)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# A composer holding `text`, rendered so the real tmux classifier can read it.
composer_capture() {  # <dir> <text> -> echoes a capture path reading `pending`
  local dir=$1 text=$2
  printf 'transcript line\n╭──────────────╮\n│ %s │\n╰──────────────╯\n' "$text" > "$dir/capture"
  printf '%s\n' "$dir/capture"
}

# Drive fm_task_inbox_ring with stubbed backend primitives. `post` is the
# composer verdict reported AFTER the Enter is sent, which is the whole point:
# the pre-submit verdict is always `pending` here.
ring_with_stubs() {  # <name> <cstate-before> <post-cstate> <content> [content-rc]
  local name=$1 before=$2 post=$3 content=$4 content_rc=${5:-0} dir state rec log out
  dir="$TMP_ROOT/$name"; mkdir -p "$dir/state/t1.inbox/handled"
  state="$dir/state"
  printf 'schema=fm-task-inbox.v1\n--\nplease continue\n' > "$state/t1.inbox/001.msg"
  rec="$state/t1.inbox/001.msg"
  log="$dir/send.log"; : > "$log"
  FM_STATE_OVERRIDE="$state" FM_SEND_LOG="$log" \
  RING_BEFORE="$before" RING_POST="$post" RING_CONTENT="$content" RING_CONTENT_RC="$content_rc" \
    bash -c '
      . "$1"
      SENT=0
      fm_backend_agent_state() { printf "alive\n"; }
      fm_backend_composer_state() {
        if [ "$SENT" = 1 ]; then printf "%s\n" "$RING_POST"; else printf "%s\n" "$RING_BEFORE"; fi
      }
      fm_backend_composer_content() {
        [ "$RING_CONTENT_RC" = 0 ] || return "$RING_CONTENT_RC"
        printf "%s" "$RING_CONTENT"
      }
      fm_backend_send_key() { printf "KEY %s\n" "$3" >> "$FM_SEND_LOG"; SENT=1; }
      fm_backend_send_text_submit() { printf "TEXT %s\n" "$3" >> "$FM_SEND_LOG"; printf "empty\n"; }
      fm_task_inbox_ring tmux sess:fm-t1 "$2" fm-t1
      printf "rc=%s\n" "$?"
    ' _ "$INBOX_LIB" "$rec" > "$dir/out" 2>&1 || true
  printf '%s\n' "$dir"
}

repo_root_check() {
  local dir
  for dir in "$@"; do
    [ -f "$dir/out" ] || fail "the ring produced no output for $dir"
  done
}

test_recoverable_draft_returns_4_when_the_composer_is_freed() {
  local dir out
  dir=$(ring_with_stubs ring-freed pending empty \
    "$(printf '⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: sess:fm-t1')")
  out=$(cat "$dir/out")
  printf '%s' "$out" | grep -q 'rc=4' \
    || fail "a submitted draft that freed the composer must return 4: $out"
  # EXACT keystroke pin: the recovery submits with Enter, never a typed
  # doorbell and never any other special key.
  [ "$(cat "$dir/send.log")" = 'KEY Enter' ] \
    || fail "the recovery must submit exactly Enter and nothing else: $(cat "$dir/send.log")"
  pass "stranded draft: a submitted operational draft that freed the composer returns 4 with exactly Enter"
}

test_submit_that_does_not_free_the_composer_is_not_recovered() {
  # The regression this file exists for. Enter was sent, the draft is still
  # sitting there: nothing was recovered, so the ring must NOT claim 4.
  local dir out
  dir=$(ring_with_stubs ring-still-pending pending pending \
    "$(printf '⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: sess:fm-t1')")
  out=$(cat "$dir/out")
  printf '%s' "$out" | grep -q 'rc=4' \
    && fail "a submit that did not free the composer must not be reported as recovered: $out"
  # The composer still provably holds text, so it keeps the ordinary skip:
  # the doorbell must never be appended to it and submitted.
  printf '%s' "$out" | grep -q 'rc=1' \
    || fail "a still-pending composer after the submit must skip with 1: $out"
  [ "$(cat "$dir/send.log")" = 'KEY Enter' ] \
    || fail "the doorbell was typed into a still-pending composer: $(cat "$dir/send.log")"
  pass "stranded draft: a submit that left the composer pending skips without typing the doorbell"
}

test_an_unproven_post_submit_state_never_receives_the_doorbell() {
  # After Enter, a failed capture or an ambiguous screen must not be read as
  # "composer free". The pre-fix code fell through both case arms and typed
  # the doorbell into a composer that may still hold the stranded draft.
  local dir out verdict
  for verdict in unknown pending-unproven; do
    dir=$(ring_with_stubs "ring-post-$verdict" pending "$verdict" \
      "$(printf '⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: sess:fm-t1')")
    out=$(cat "$dir/out")
    printf '%s' "$out" | grep -q 'rc=1' \
      || fail "post-submit state $verdict must skip with 1: $out"
    [ "$(cat "$dir/send.log")" = 'KEY Enter' ] \
      || fail "the doorbell was typed after post-submit state $verdict: $(cat "$dir/send.log")"
  done
  pass "stranded draft: unknown and pending-unproven after Enter skip without the doorbell"
}

test_draft_rendered_without_its_mark_is_recovered() {
  # Real pi (and tmux at column 0) draws a typed draft WITHOUT its zero-width
  # U+2063 mark, so the composer screen holds only the visible header.
  local dir out
  dir=$(ring_with_stubs ring-unmarked pending empty \
    'FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: sess:fm-t1')
  out=$(cat "$dir/out")
  printf '%s' "$out" | grep -q 'rc=4' \
    || fail "a draft drawn without its mark must still be recovered with 4: $out"
  [ "$(cat "$dir/send.log")" = 'KEY Enter' ] \
    || fail "the recovery must submit exactly Enter and nothing else: $(cat "$dir/send.log")"
  pass "stranded draft: a draft the screen drew without its U+2063 mark is recovered the same way"
}

test_legacy_carrier_is_refused() {
  local dir out
  # Composer extraction joins rows with single spaces, so the legacy carrier
  # reaches the ring in this single-line form. Legacy carriers are not typed
  # by any current producer and are never submitted.
  dir=$(ring_with_stubs ring-legacy pending empty \
    'FIRSTMATE WATCHER WAKE: stale: sess:fm-t1 Run bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.')
  out=$(cat "$dir/out")
  printf '%s' "$out" | grep -q 'rc=1' \
    || fail "a legacy carrier in the composer must be refused with 1: $out"
  [ ! -s "$dir/send.log" ] \
    || fail "a legacy carrier was typed into: $(cat "$dir/send.log")"
  pass "stranded draft: the legacy watcher carrier is refused, never submitted"
}

test_human_pending_text_is_never_touched() {
  local dir out
  dir=$(ring_with_stubs ring-human pending empty 'hold on, let me think about this')
  out=$(cat "$dir/out")
  printf '%s' "$out" | grep -q 'rc=1' \
    || fail "human pending text must still skip the ring with 1: $out"
  [ ! -s "$dir/send.log" ] \
    || fail "human pending text was typed into: $(cat "$dir/send.log")"
  pass "stranded draft: human-authored pending text is never submitted or clobbered"
}

test_near_miss_text_is_refused() {
  # Independence: text that merely RESEMBLES a draft must not be submitted.
  # Only the operational-input contract's own classification authorizes a
  # keystroke, so a line naming FIRSTMATE_OP as prose is refused.
  local dir out
  dir=$(ring_with_stubs ring-near-miss pending empty \
    'so I asked FIRSTMATE_OP: v1 watcher to do it but nothing happened')
  out=$(cat "$dir/out")
  printf '%s' "$out" | grep -q 'rc=1' \
    || fail "a near-miss operational-looking message must be refused with 1: $out"
  [ ! -s "$dir/send.log" ] \
    || fail "a near-miss message was typed into: $(cat "$dir/send.log")"
  pass "stranded draft: text that merely resembles an operational draft is refused, never submitted"
}

test_unreadable_composer_content_is_refused() {
  local dir out
  dir=$(ring_with_stubs ring-unreadable pending empty 'ignored' 1)
  out=$(cat "$dir/out")
  printf '%s' "$out" | grep -q 'rc=1' \
    || fail "an unreadable composer must be refused with 1: $out"
  [ ! -s "$dir/send.log" ] \
    || fail "an unreadable composer was typed into: $(cat "$dir/send.log")"
  pass "stranded draft: an unreadable composer is refused rather than guessed at"
}

test_recoverable_draft_returns_4_when_the_composer_is_freed
test_an_unproven_post_submit_state_never_receives_the_doorbell
test_submit_that_does_not_free_the_composer_is_not_recovered
test_draft_rendered_without_its_mark_is_recovered
test_legacy_carrier_is_refused
test_human_pending_text_is_never_touched
test_near_miss_text_is_refused
test_unreadable_composer_content_is_refused
