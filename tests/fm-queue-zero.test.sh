#!/usr/bin/env bash
# Tests for queue inbox zero: bin/fm-queue-zero.sh (which queued rows must leave
# the queue now, and one wake per episode) and bin/fm-paperclip-sweep.sh (which
# Paperclip issues and approvals are stuck, and the guarded release).
#
# The incident: ready queued rows sat in Charted Next for one to two days, an
# in-flight backlog row with no live task stayed a silent "(main-inventory)"
# warning, and Paperclip issues stayed blocked behind blockers that had
# already finished. Each case below drives one of those shapes through the
# public command and asserts the row is named (or, for work that is genuinely
# waiting with a date, that it is not).
#
# Paperclip is faked by a `curl` on PATH that answers from fixture files, so no
# case ever reaches a real board.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QZ="$ROOT/bin/fm-queue-zero.sh"
SWEEP="$ROOT/bin/fm-paperclip-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-queue-zero)
NOW=2026-10-01T12:00:00Z

if ! command -v tasks-axi >/dev/null 2>&1; then
  echo "skip: tasks-axi not found; queue-zero cases not run"
  exit 0
fi

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/fakebin"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

axi() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  tasks-axi "$@" --file "$home/data/backlog.md" >/dev/null || fail "tasks-axi $* failed"
}

# Rewrite every (since ...) date so the age arithmetic is pinned to NOW.
set_since() {  # <home> <id> <date>
  local home=$1 id=$2 date=$3 tmp
  tmp=$(mktemp)
  awk -v id="$id" -v d="$date" '
    $0 ~ "^- \\[[ xX]\\] " id " - " { sub(/\(since [0-9-]+\)/, "(since " d ")") }
    { print }' "$home/data/backlog.md" > "$tmp" && mv "$tmp" "$home/data/backlog.md"
}

qz() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_QUEUE_ZERO_NOW="$NOW" "$QZ" "$@"
}

sweep() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_QUEUE_ZERO_NOW="$NOW" "$SWEEP" "$@"
}

# A fake Paperclip: GET answers come from $home/pc/<route>.json (an issue's
# comments, newest first, from comments-<id>.json, else none); PATCH bodies are
# appended to $home/pc/patches.log. The key arrives on stdin (-H @-).
install_fake_paperclip() {  # <home>
  local home=$1
  mkdir -p "$home/pc"
  printf 'test-key\n' > "$home/pc/key"
  chmod 600 "$home/pc/key"
  printf 'FM_PAPERCLIP_URL=http://paperclip.test\nFM_PAPERCLIP_KEY_FILE=%s\n' "$home/pc/key" > "$home/.env"
  printf '{"companyIds":["co1"]}' > "$home/pc/me.json"
  printf '[]' > "$home/pc/issues.json"
  printf '[]' > "$home/pc/approvals.json"
  cat > "$home/fakebin/curl" <<SH
#!/usr/bin/env bash
pc="$home/pc"
method=GET data= url=
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) method=\$2; shift ;;
    --data) data=\$2; shift ;;
    -H|-m|-w) shift ;;
    http*) url=\$1 ;;
  esac
  shift
done
grep -q 'Bearer test-key' || { printf 'denied\n401'; exit 0; }
path=\${url#http://paperclip.test/api}
case "\$method \$path" in
  "GET /cli-auth/me") body=\$(cat "\$pc/me.json") ;;
  "GET /companies/co1/issues?"*) body=\$(cat "\$pc/issues.json") ;;
  "GET /companies/co1/approvals?"*) body=\$(cat "\$pc/approvals.json") ;;
  "GET /issues/"*"/comments?"*) [ ! -f "\$pc/comments-down" ] || { printf '%s\n' "\$path" >> "\$pc/comments.log"; printf 'curl: (28) Operation timed out'; exit 28; }; f="\$pc/comments-\${path#/issues/}"; f="\${f%%/comments\?*}.json"; body=\$(cat "\$f" 2>/dev/null || printf '[]') ;;
  "GET /issues/"*) f="\$pc/issue-\${path#/issues/}.json"; [ -f "\$f" ] || { printf 'missing\n404'; exit 0; }; body=\$(cat "\$f") ;;
  "PATCH /issues/"*) printf '%s %s\n' "\${path#/issues/}" "\$data" >> "\$pc/patches.log"; body='{}' ;;
  *) printf 'unknown\n404'; exit 0 ;;
esac
printf '%s\n200' "\$body"
SH
  chmod +x "$home/fakebin/curl"
}

# --- local queue -------------------------------------------------------------

test_ready_and_undated_rows_are_named_and_dated_holds_are_not() {
  local home out
  home=$(make_home local-classes)
  axi "$home" add ready-now "ready queued work" --kind ship
  axi "$home" add blocker-open "still open blocker"
  axi "$home" add waits-on "waits on an open blocker"
  axi "$home" block waits-on --by blocker-open
  axi "$home" add watch-only "Watch Paperclip FIR-9 to merge"
  axi "$home" hold watch-only --reason "FIR-9 owned by the viral-moment engineer" --until 2026-10-03
  axi "$home" add past-date "held until a date that passed"
  axi "$home" hold past-date --reason "waiting on x" --until 2026-09-30
  axi "$home" add captain-call "a captain decision"
  axi "$home" hold captain-call --reason "pick A or B" --kind captain
  axi "$home" add parked "held with no date"
  axi "$home" hold parked --reason "someday" --kind parked
  set_since "$home" blocker-open 2026-09-30
  set_since "$home" waits-on 2026-09-29
  set_since "$home" parked 2026-09-29

  out=$(qz "$home" scan --local) || fail "scan failed: $out"
  assert_contains "$out" "queue ready ready-now" "a ready queued row was not named"
  assert_contains "$out" "queue ready past-date" "a hold whose --until date passed was not named as ready"
  assert_contains "$out" "queue undated waits-on" "an aged blocked row without a date was not named"
  assert_contains "$out" "queue undated parked" "an aged hold without a date was not named"
  assert_contains "$out" "queue ready blocker-open" "an unblocked unheld row was not named ready"
  assert_not_contains "$out" "watch-only" "a watch row held with an owner and a future date was named"
  assert_not_contains "$out" "captain-call" "a captain hold leaked out of Captain's Call into the queue rows"
  pass "ready, past-date, and undated rows are named; dated holds and captain holds are not"
}

test_inflight_row_without_a_live_task_is_named_orphan() {
  local home out
  home=$(make_home orphan)
  axi "$home" add lost-work "in flight but nobody is on it"
  axi "$home" start lost-work
  axi "$home" add live-work "in flight with a live task"
  axi "$home" start live-work
  printf 'kind=ship\n' > "$home/state/live-work.meta"
  out=$(qz "$home" scan --local) || fail "scan failed: $out"
  assert_contains "$out" "queue orphan lost-work" "an in-flight row with no task record was not named"
  assert_not_contains "$out" "live-work" "an in-flight row with a live task record was named"
  pass "an in-flight backlog row with no live task is named instead of left as a silent warning"
}

test_empty_queue_is_silent_and_unpaired_state_is_silent() {
  local home out
  home=$(make_home empty)
  out=$(qz "$home" scan --local) || fail "scan failed"
  [ -z "$out" ] || fail "an empty queue printed rows: $out"
  axi "$home" add ready-now "ready queued work"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$TMP_ROOT/elsewhere" \
    FM_QUEUE_ZERO_NOW="$NOW" "$QZ" check) || fail "unpaired check failed"
  [ -z "$out" ] || fail "a state override without its data directory still reported: $out"
  pass "an empty queue and an unpaired state override stay silent"
}

# --- one wake per episode ---------------------------------------------------

test_check_wakes_once_per_episode_and_queues_durably() {
  local home out
  home=$(make_home episode)
  axi "$home" add ready-a "first ready row"
  out=$(qz "$home" check) || fail "first check failed"
  assert_contains "$out" "check: queue-zero:" "the first sighting did not wake"
  assert_contains "$out" "queue ready ready-a" "the wake did not name its row"
  grep -F $'\tcheck\tqueue-zero\t' "$home/state/.wake-queue" >/dev/null \
    || fail "the wake was printed but not durably queued"

  out=$(qz "$home" check) || fail "repeat check failed"
  [ -z "$out" ] || fail "an unchanged row set woke again inside the renag window: $out"

  axi "$home" add ready-b "second ready row"
  out=$(qz "$home" check) || fail "check after a new row failed"
  assert_contains "$out" "queue ready ready-a" "a new episode did not re-name the still-open row"
  assert_contains "$out" "queue ready ready-b" "a newly ready row did not wake"

  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_QUEUE_ZERO_NOW=2026-10-02T13:00:00Z "$QZ" check) \
    || fail "renag check failed"
  assert_contains "$out" "check: queue-zero:" "an unchanged set past the renag window did not wake again"
  pass "check wakes once per episode, names its rows, queues durably, and re-nags only after the window"
}

test_row_that_leaves_and_returns_is_a_new_episode() {
  local home out
  home=$(make_home leave-return)
  axi "$home" add flappy "row that gets held then due again"
  out=$(qz "$home" check) || fail "first check failed"
  assert_contains "$out" "flappy" "first sighting did not wake"
  axi "$home" hold flappy --reason "named blocker" --until 2026-10-05
  out=$(qz "$home" check) || fail "check while held failed"
  [ -z "$out" ] || fail "a dated hold still woke: $out"
  axi "$home" unhold flappy
  out=$(qz "$home" check) || fail "check after unhold failed"
  assert_contains "$out" "flappy" "a row that returned to the queue was suppressed as already reported"
  pass "a row that leaves the queue and returns wakes again"
}

test_failed_append_does_not_suppress_the_episode() {
  local home out
  home=$(make_home append-fail)
  axi "$home" add ready-a "ready row"
  mkdir "$home/state/.wake-queue"   # a directory: the append cannot write
  if out=$(qz "$home" check 2>&1); then fail "check succeeded although its wake could not be queued: $out"; fi
  assert_not_contains "$out" "check: queue-zero:" "a wake that was never queued was still printed"
  rmdir "$home/state/.wake-queue"
  out=$(qz "$home" check) || fail "retry check failed"
  assert_contains "$out" "queue ready ready-a" "a failed append suppressed the episode instead of retrying it"
  pass "a wake that could not be queued is retried, never recorded as reported"
}

# --- Paperclip --------------------------------------------------------------

paperclip_fixture() {  # <home>
  local home=$1
  cat > "$home/pc/issues.json" <<'JSON'
[
 {"id":"u1","identifier":"FIR-1","title":"release me","status":"backlog",
  "blockedBy":[{"identifier":"FIR-90","status":"done"}]},
 {"id":"u2","identifier":"FIR-2","title":"still waiting","status":"backlog",
  "blockedBy":[{"identifier":"FIR-91","status":"in_progress"}]},
 {"id":"u3","identifier":"FIR-3","title":"stale edge","status":"blocked",
  "blockedBy":[{"identifier":"FIR-92","status":"done"}]},
 {"id":"u4","identifier":"FIR-4","title":"covered","status":"blocked",
  "blockedBy":[{"identifier":"FIR-93","status":"in_progress"}],"blockerAttention":{"state":"covered"}},
 {"id":"u5","identifier":"FIR-5","title":"stalled","status":"blocked",
  "blockedBy":[{"identifier":"FIR-94","status":"in_review"}],"blockerAttention":{"state":"stalled"}},
 {"id":"u6","identifier":"FIR-6","title":"dated","status":"blocked",
  "blockedBy":[{"identifier":"FIR-95","status":"in_review"}],"blockerAttention":{"state":"stalled"},
  "monitorNextCheckAt":"2026-10-02T00:00:00.000Z"},
 {"id":"u7","identifier":"FIR-7","title":"nobody owns it","status":"backlog","blockedBy":[]},
 {"id":"u8","identifier":"FIR-8","title":"orphaned run","status":"in_progress","blockedBy":[],
  "executionRunId":null,"lastActivityAt":"2026-09-30T00:00:00.000Z"},
 {"id":"u9","identifier":"FIR-9","title":"live run","status":"in_progress","blockedBy":[],
  "executionRunId":"r1","lastActivityAt":"2026-09-30T00:00:00.000Z"},
 {"id":"u10","identifier":"FIR-10","title":"legacy execution","status":"in_review","blockedBy":[],
  "activeRecoveryAction":{"status":"active","cause":"legacy_execution_requires_reconciliation","nextAction":"inspect run"}}
]
JSON
  cat > "$home/pc/approvals.json" <<'JSON'
[
 {"id":"aaaaaaaa-1","type":"request_board_approval","status":"pending","createdAt":"2026-10-01T02:00:00.000Z","payload":{"title":"old ask"}},
 {"id":"bbbbbbbb-2","type":"request_board_approval","status":"pending","createdAt":"2026-10-01T11:00:00.000Z","payload":{"title":"fresh ask"}}
]
JSON
}

test_paperclip_scan_classifies_stuck_items() {
  local home out
  home=$(make_home pc-scan)
  install_fake_paperclip "$home"
  paperclip_fixture "$home"
  out=$(sweep "$home" scan) || fail "sweep scan failed: $out"
  assert_contains "$out" "release FIR-1" "a backlog issue whose blockers are all done was not offered for release"
  assert_contains "$out" "stale-edge FIR-3" "a blocked issue behind a done blocker was not named"
  assert_contains "$out" "stalled FIR-5" "a blocked issue with no live blocker work and no date was not named"
  assert_contains "$out" "no-blocker FIR-7" "a backlog issue with no blocker and no date was not named"
  assert_contains "$out" "orphaned-execution FIR-8" "an in-progress issue with no run and no recent activity was not named"
  assert_contains "$out" "recovery FIR-10" "an issue with an active recovery action was not named"
  assert_contains "$out" "approval approval:aaaaaaaa" "a pending approval past the age threshold was not named"
  assert_not_contains "$out" "FIR-2 " "a backlog issue behind an open blocker was named"
  assert_not_contains "$out" "FIR-4 " "a blocked issue covered by live blocker work was named"
  assert_not_contains "$out" "FIR-6 " "a blocked issue with a dated next check was named"
  assert_not_contains "$out" "FIR-9 " "an in-progress issue with a live run was named"
  assert_not_contains "$out" "bbbbbbbb" "a fresh approval was named before its threshold"
  pass "the Paperclip sweep names stuck issues and stale approvals and leaves covered or dated work alone"
}

test_paperclip_rows_join_the_queue_wake_and_failure_is_visible() {
  local home out
  home=$(make_home pc-join)
  install_fake_paperclip "$home"
  paperclip_fixture "$home"
  out=$(qz "$home" check) || fail "check failed"
  assert_contains "$out" "paperclip release FIR-1" "a Paperclip row did not reach the queue-zero wake"
  out=$(qz "$home" scan --local) || fail "local scan failed"
  assert_not_contains "$out" "paperclip" "--local still read Paperclip"
  rm "$home/fakebin/curl"
  printf '#!/usr/bin/env bash\nprintf "curl: (7) Failed to connect"; exit 7\n' > "$home/fakebin/curl"
  chmod +x "$home/fakebin/curl"
  out=$(sweep "$home" scan) || fail "a failing board read made the scan itself fail"
  assert_contains "$out" "error paperclip" "an unreadable board was reported as silence"
  rm "$home/.env"
  out=$(qz "$home" scan) || fail "unconfigured scan failed"
  assert_not_contains "$out" "paperclip" "an unconfigured home still read Paperclip"
  pass "Paperclip rows join the one wake, an unreadable board is an error row, and unconfigured homes skip it"
}

# Paperclip refuses a monitor on a blocked issue, so its owner dates the next
# check with an `fm-next-check:` line in an issue comment. The sweep reads the
# comments newest-first and honors the newest valid marker, so a later
# acknowledgment does not clear it and a newer marker supersedes an older one;
# a passed newest date, a malformed line, or blockers that are all done does
# list the issue again.
test_paperclip_blocked_comment_marker_dates_the_next_check() {
  local home out
  home=$(make_home pc-marker)
  install_fake_paperclip "$home"
  cat > "$home/pc/issues.json" <<'JSON'
[
 {"id":"m1","identifier":"FIR-18","title":"marker then ack","status":"blocked",
  "blockedBy":[{"identifier":"FIR-104","status":"in_progress"}],"blockerAttention":{"state":"needs_attention"},
  "monitorNextCheckAt":null},
 {"id":"m2","identifier":"FIR-20","title":"past dated","status":"blocked",
  "blockedBy":[{"identifier":"FIR-133","status":"in_review"}],"blockerAttention":{"state":"needs_attention"}},
 {"id":"m3","identifier":"FIR-13","title":"malformed marker","status":"blocked",
  "blockedBy":[{"identifier":"FIR-105","status":"in_progress"}],"blockerAttention":{"state":"stalled"}},
 {"id":"m4","identifier":"FIR-91","title":"no owner named","status":"blocked","blockedBy":[]},
 {"id":"m5","identifier":"FIR-57","title":"marker not on its own line","status":"blocked",
  "blockedBy":[{"identifier":"FIR-106","status":"in_review"}],"blockerAttention":{"state":"stalled"}},
 {"id":"m6","identifier":"FIR-58","title":"time without seconds","status":"blocked",
  "blockedBy":[{"identifier":"FIR-107","status":"in_progress"}],"blockerAttention":{"state":"stalled"}},
 {"id":"m7","identifier":"FIR-89","title":"leading space","status":"blocked",
  "blockedBy":[{"identifier":"FIR-108","status":"in_progress"}],"blockerAttention":{"state":"stalled"}},
 {"id":"m8","identifier":"FIR-134","title":"dated but blockers done","status":"blocked",
  "blockedBy":[{"identifier":"FIR-109","status":"done"}],"blockerAttention":{"state":"needs_attention"}},
 {"id":"m9","identifier":"FIR-241","title":"newer past marker wins","status":"blocked",
  "blockedBy":[{"identifier":"FIR-110","status":"in_progress"}],"blockerAttention":{"state":"stalled"}},
 {"id":"m10","identifier":"FIR-242","title":"newer future marker wins","status":"blocked",
  "blockedBy":[{"identifier":"FIR-111","status":"in_progress"}],"blockerAttention":{"state":"stalled"}}
]
JSON
  printf '%s' '[{"body":"Acknowledged, tracking it."},{"body":"Both blockers are healthy waits.\n\nfm-next-check: 2026-10-01T18:00:00Z owner=coordinator"}]' > "$home/pc/comments-m1.json"
  printf '%s' '[{"body":"fm-next-check: 2026-10-01T11:59:59Z owner=engineer"}]' > "$home/pc/comments-m2.json"
  printf '%s' '[{"body":"fm-next-check: tomorrow morning owner=engineer"}]' > "$home/pc/comments-m3.json"
  printf '%s' '[{"body":"fm-next-check: 2026-10-03T00:00:00Z"}]' > "$home/pc/comments-m4.json"
  printf '%s' '[{"body":"I will set fm-next-check: 2026-10-03T00:00:00Z owner=engineer later"}]' > "$home/pc/comments-m5.json"
  printf '%s' '[{"body":"fm-next-check: 2026-10-03T00:00Z owner=engineer"}]' > "$home/pc/comments-m6.json"
  printf '%s' '[{"body":" fm-next-check: 2026-10-03T00:00:00Z owner=engineer"}]' > "$home/pc/comments-m7.json"
  printf '%s' '[{"body":"Seen, releasing soon."},{"body":"fm-next-check: 2026-10-03T00:00:00Z owner=coordinator"}]' > "$home/pc/comments-m8.json"
  printf '%s' '[{"body":"fm-next-check: 2026-10-01T11:00:00Z owner=engineer"},{"body":"fm-next-check: 2026-10-05T00:00:00Z owner=engineer"}]' > "$home/pc/comments-m9.json"
  printf '%s' '[{"body":"fm-next-check: 2026-10-02T00:00:00Z owner=engineer"},{"body":"fm-next-check: 2026-09-30T00:00:00Z owner=engineer"}]' > "$home/pc/comments-m10.json"
  out=$(sweep "$home" scan) || fail "sweep scan failed: $out"
  assert_not_contains "$out" "FIR-18 " "a blocked issue whose comment dates a future check with an owner was named despite a later acknowledgment"
  assert_contains "$out" "stalled FIR-20" "a blocked issue whose comment-dated check has passed was not named again"
  assert_contains "$out" "stalled FIR-13" "a blocked issue with a malformed date marker was hidden"
  assert_contains "$out" "no-blocker FIR-91" "a date marker naming no owner hid the issue"
  assert_contains "$out" "stalled FIR-57" "a marker that does not start its line hid the issue"
  assert_contains "$out" "stalled FIR-58" "a marker time without seconds hid the issue"
  assert_contains "$out" "stalled FIR-89" "a marker with a leading space hid the issue"
  assert_contains "$out" "stale-edge FIR-134" "a future marker hid a blocked issue whose blockers are all done"
  assert_contains "$out" "stalled FIR-241" "an older future marker beat the newest past marker"
  assert_not_contains "$out" "FIR-242 " "an older past marker beat the newest future marker"
  FM_QUEUE_ZERO_NOW=2026-10-01T18:00:01Z PATH="$home/fakebin:$PATH" FM_HOME="$home" "$SWEEP" scan > "$home/later.out" \
    || fail "later sweep scan failed"
  assert_contains "$(cat "$home/later.out")" "stalled FIR-18" "a comment-dated blocked issue was not named once its date passed"
  pass "the newest valid fm-next-check comment marker with an owner hides a blocked issue through later acknowledgments until the date passes; malformed markers and stale edges do not"
}

# A board that stops answering after the issue list must not stretch the scan
# by one curl timeout per blocked issue: the first transport failure ends the
# comment reads, and every unread issue stays listed.
test_paperclip_comment_transport_failure_stops_comment_reads() {
  local home out
  home=$(make_home pc-comments-down)
  install_fake_paperclip "$home"
  cat > "$home/pc/issues.json" <<'JSON'
[
 {"id":"d1","identifier":"FIR-201","title":"one","status":"blocked",
  "blockedBy":[{"identifier":"FIR-301","status":"in_progress"}],"blockerAttention":{"state":"stalled"}},
 {"id":"d2","identifier":"FIR-202","title":"two","status":"blocked",
  "blockedBy":[{"identifier":"FIR-302","status":"in_progress"}],"blockerAttention":{"state":"stalled"}},
 {"id":"d3","identifier":"FIR-203","title":"three","status":"blocked","blockedBy":[]}
]
JSON
  : > "$home/pc/comments-down"
  out=$(sweep "$home" scan) || fail "sweep scan failed: $out"
  [ "$(wc -l < "$home/pc/comments.log" | tr -d ' ')" = 1 ] \
    || fail "comment reads continued after a transport failure: $(cat "$home/pc/comments.log")"
  assert_contains "$out" "stalled FIR-201" "an unread blocked issue was hidden"
  assert_contains "$out" "stalled FIR-202" "an unread blocked issue was hidden"
  assert_contains "$out" "no-blocker FIR-203" "an unread blocked issue was hidden"
  assert_not_contains "$out" "error paperclip" "a comment transport failure became a board error"
  pass "the first comment transport failure stops the comment reads and unread issues stay listed"
}

test_paperclip_release_is_guarded() {
  local home out
  home=$(make_home pc-release)
  install_fake_paperclip "$home"
  printf '%s' '{"id":"u1","identifier":"FIR-1","status":"backlog","blockedBy":[{"identifier":"FIR-90","status":"done"}]}' \
    > "$home/pc/issue-FIR-1.json"
  printf '%s' '{"id":"u2","identifier":"FIR-2","status":"backlog","blockedBy":[{"identifier":"FIR-91","status":"in_progress"}]}' \
    > "$home/pc/issue-FIR-2.json"
  printf '%s' '{"id":"u7","identifier":"FIR-7","status":"backlog","blockedBy":[]}' > "$home/pc/issue-FIR-7.json"
  printf '%s' '{"id":"u9","identifier":"FIR-9","status":"in_progress","blockedBy":[{"identifier":"FIR-90","status":"done"}]}' \
    > "$home/pc/issue-FIR-9.json"
  out=$(sweep "$home" release FIR-1) || fail "a valid release failed: $out"
  assert_contains "$out" "released FIR-1" "a valid release did not report success"
  grep -F 'u1 {"status":"todo"' "$home/pc/patches.log" >/dev/null \
    || fail "the release did not PATCH the issue to todo: $(cat "$home/pc/patches.log")"
  for ref in FIR-2 FIR-7 FIR-9; do
    if out=$(sweep "$home" release "$ref"); then fail "release of $ref should have been refused: $out"; fi
    assert_contains "$out" "refused $ref" "release of $ref was not refused"
  done
  [ "$(wc -l < "$home/pc/patches.log" | tr -d ' ')" = 1 ] \
    || fail "a refused release still sent a PATCH: $(cat "$home/pc/patches.log")"
  pass "release moves only backlog or blocked issues whose every blocker is done"
}

test_ready_and_undated_rows_are_named_and_dated_holds_are_not
test_inflight_row_without_a_live_task_is_named_orphan
test_empty_queue_is_silent_and_unpaired_state_is_silent
test_check_wakes_once_per_episode_and_queues_durably
test_row_that_leaves_and_returns_is_a_new_episode
test_failed_append_does_not_suppress_the_episode
test_paperclip_scan_classifies_stuck_items
test_paperclip_blocked_comment_marker_dates_the_next_check
test_paperclip_comment_transport_failure_stops_comment_reads
test_paperclip_rows_join_the_queue_wake_and_failure_is_visible
test_paperclip_release_is_guarded
