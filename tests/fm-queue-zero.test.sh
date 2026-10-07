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

test_ready_and_unowned_rows_are_named_and_owned_rows_are_not() {
  local home out
  home=$(make_home local-classes)
  axi "$home" add ready-now "ready queued work" --kind ship
  axi "$home" add blocker-open "still open blocker"
  axi "$home" add waits-on "waits on an open blocker"
  axi "$home" block waits-on --by blocker-open
  axi "$home" add dated-only "held to a date with nobody on it"
  axi "$home" hold dated-only --reason "check back later" --until 2099-12-31
  axi "$home" add past-date "held until a date that passed"
  axi "$home" hold past-date --reason "waiting on x" --until 2026-09-30
  axi "$home" add captain-call "a captain decision"
  axi "$home" hold captain-call --reason "pick A or B" --kind captain
  axi "$home" add parked "held with no date"
  axi "$home" hold parked --reason "someday" --kind parked
  set_since "$home" blocker-open 2026-09-30
  set_since "$home" waits-on 2026-09-29
  set_since "$home" parked 2026-09-29
  set_since "$home" dated-only 2026-09-29
  set_since "$home" past-date 2026-09-29

  out=$(qz "$home" scan --local) || fail "scan failed: $out"
  assert_contains "$out" "queue ready ready-now" "a ready queued row was not named"
  assert_contains "$out" "queue ready past-date" "a hold whose --until date passed was not named as ready"
  assert_contains "$out" "queue ready blocker-open" "an unblocked unheld row was not named ready"
  assert_contains "$out" "queue unowned waits-on" "a row blocked only by an ownerless row was not named unowned"
  assert_contains "$out" "queue unowned parked" "an aged hold without an owner was not named"
  assert_contains "$out" "queue unowned dated-only" "a far date was accepted as an owner"
  assert_not_contains "$out" "captain-call" "a fresh captain call leaked out of Captain's Call into the queue rows"
  pass "ready rows and rows whose only owner is the supervisor are named, whatever their date"
}

# Invariant 2: a row is owned only by something that is running - a live
# worker, the beads crew, a registered secondmate, a condition watch, a genuine
# captain call, or a blocked-by edge to a row that is itself owned. A date or
# an "owner: firstmate" reason is not an owner.
test_unowned_row_flagged_and_each_running_owner_clears_it() {
  local home out id
  home=$(make_home owners)
  for id in bare by-firstmate by-mate by-unknown-mate by-watch by-worker dep-owned behind-owned dep-bare behind-bare; do
    axi "$home" add "$id" "row $id"
  done
  axi "$home" hold bare --reason "later" --until 2099-10-03
  axi "$home" hold by-firstmate --reason "owner: firstmate - after the release" --kind captain
  axi "$home" hold by-mate --reason "owner: sm-web - building it" --until 2099-10-03
  axi "$home" hold by-unknown-mate --reason "owner: sm-gone - building it" --until 2099-10-03
  axi "$home" hold by-watch --reason "fires when the deploy lands" --until 2099-10-03
  axi "$home" hold by-worker --reason "worker on it" --until 2099-10-03
  axi "$home" hold dep-owned --reason "owner: sm-web" --until 2099-10-03
  axi "$home" block behind-owned --by dep-owned
  axi "$home" hold dep-bare --reason "later" --until 2099-10-03
  axi "$home" block behind-bare --by dep-bare
  for id in bare by-firstmate by-mate by-unknown-mate by-watch by-worker dep-owned behind-owned dep-bare behind-bare; do
    set_since "$home" "$id" 2026-09-25
  done
  printf '%s\n' "- sm-web - web work (home: $home/sm-web; scope: web; projects: web; added 2026-09-01)" \
    > "$home/data/secondmates.md"
  mkdir -p "$home/state/procevent"
  printf 'adapter=when\n' > "$home/state/procevent/when-by-watch--deploy.source"
  printf 'kind=ship\n' > "$home/state/by-worker.meta"

  out=$(qz "$home" scan --local) || fail "scan failed: $out"
  for id in bare by-firstmate by-unknown-mate dep-bare behind-bare; do
    assert_contains "$out" "queue unowned $id " "row $id has no running owner but was not flagged unowned"
  done
  for id in by-mate by-watch by-worker dep-owned behind-owned; do
    assert_not_contains "$out" " $id " "row $id has a running owner but was flagged"
  done
  assert_contains "$out" "a date is not an owner" "the unowned detail did not say a date is not an answer"
  pass "a row whose only owner is the supervisor is flagged unowned; a worker, secondmate, watch, or owned blocker clears it"
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

# A genuine captain call (a captain hold whose reason does not begin "owner:")
# gets bin/fm-far-holds.sh's two days, aged from its hold-set stamp or a lapsed
# date, before it is named nocheck. An "owner:" captain hold is not a captain
# call at all: it is supervisor-owned work and is named unowned.
test_captain_calls_get_the_far_holds_window_and_owner_holds_do_not() {
  local home out tmp
  home=$(make_home nocheck)
  axi "$home" add owner-ask "firstmate work parked as a captain hold"
  axi "$home" hold owner-ask --reason "owner: firstmate - queued behind other work" --kind captain
  axi "$home" add fresh-call "a genuine captain call asked yesterday"
  axi "$home" hold fresh-call --reason "pick the vendor" --kind captain
  axi "$home" add old-call "a genuine captain call asked two days ago"
  axi "$home" hold old-call --reason "pick the region" --kind captain
  axi "$home" add restamped-call "an old row whose captain call was re-asked yesterday"
  axi "$home" hold restamped-call --reason "pick the name" --kind captain
  axi "$home" add lapsed-call "a genuine captain call whose date passed yesterday"
  axi "$home" hold lapsed-call --reason "pick the venue" --kind captain --until 2026-09-30
  axi "$home" add lapsed-old-call "a genuine captain call whose date passed two days ago"
  axi "$home" hold lapsed-old-call --reason "pick the date" --kind captain --until 2026-09-29
  axi "$home" add dated-owner "firstmate work dated as a captain hold"
  axi "$home" hold dated-owner --reason "owner: firstmate - re-ask on the date" --kind captain --until 2099-10-02
  set_since "$home" owner-ask 2026-09-30
  set_since "$home" fresh-call 2026-09-30
  set_since "$home" old-call 2026-09-29
  set_since "$home" restamped-call 2026-09-01
  set_since "$home" lapsed-call 2026-09-01
  set_since "$home" lapsed-old-call 2026-09-01
  set_since "$home" dated-owner 2026-09-30
  tmp=$(mktemp)
  awk '{ print } /^- \[ \] restamped-call - / { print "  Captain hold set: 2026-09-30T08:00:00Z" }' \
    "$home/data/backlog.md" > "$tmp" && mv "$tmp" "$home/data/backlog.md"
  out=$(qz "$home" scan --local) || fail "scan failed: $out"
  assert_contains "$out" "queue unowned owner-ask" "an owner: captain hold was treated as a captain call"
  assert_contains "$out" "queue unowned dated-owner" "a dated owner: captain hold was cleared by its date"
  assert_contains "$out" "queue nocheck old-call" "a genuine captain call two days old was not named"
  assert_not_contains "$out" "fresh-call" "a genuine captain call inside its two days was named"
  assert_not_contains "$out" "restamped-call" "a captain call was aged from its filing date, not its hold-set stamp"
  assert_contains "$out" "queue nocheck lapsed-old-call" "a genuine captain call two days past its date was not named"
  assert_not_contains "$out" "lapsed-call " "a genuine captain call inside two days past its date was named"
  out=$(FM_FAR_HOLDS_DAYS=3 qz "$home" scan --local) || fail "scan failed: $out"
  assert_not_contains "$out" "old-call" "a genuine captain call ignored the far-holds window"
  pass "genuine captain calls get the far-holds window; owner: captain holds are unowned work"
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

# --- alarms force an end ----------------------------------------------------

captain_hold() {  # <home> <args...>; prints stderr, returns the command's status
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_QUEUE_ZERO_NOW="${QZ_NOW:-$NOW}" \
    FM_CAPTAIN_HOLD_NOW="${QZ_NOW:-$NOW}" "$ROOT/bin/fm-captain-hold.sh" hold "$@" 3>&1 1>/dev/null 2>&3
}

hold_until() {  # <home> <id>
  sed -n "s/^- \[ \] $2 - .*(hold-until: \([0-9-]*\)).*/\1/p" "$1/data/backlog.md"
}

# Invariant 1: the first re-date passes; a second re-date with nothing new
# since is refused, naming the only answers, and leaves the date untouched.
test_second_redate_without_evidence_is_refused() {
  local home out rc
  home=$(make_home redate-refused)
  axi "$home" add follow "a follow-up nobody is on"
  captain_hold "$home" follow --reason "owner: firstmate - after the deploy" --until 2099-10-02 \
    || fail "the first hold was refused"
  captain_hold "$home" follow --reason "owner: firstmate - after the deploy" --until 2099-10-03 \
    || fail "the first re-date was refused"
  rc=0
  out=$(captain_hold "$home" follow --reason "owner: firstmate - after the deploy" --until 2099-10-04) || rc=$?
  [ "$rc" = 3 ] || fail "a second re-date without new evidence was not refused (exit $rc): $out"
  assert_contains "$out" "refused" "the refusal did not say so"
  assert_contains "$out" "start it" "the refusal did not name starting it"
  assert_contains "$out" "close it with a reason" "the refusal did not name closing it"
  assert_contains "$out" "captain's own decision" "the refusal did not name the captain hold"
  [ "$(hold_until "$home" follow)" = 2099-10-03 ] || fail "a refused re-date still moved the date: $(hold_until "$home" follow)"
  grep -F '"kind":"refused"' "$home/state/.queue-zero-redates.jsonl" >/dev/null \
    || fail "the refusal was not logged as a re-date without progress"

  # New evidence since the last hold - a status line - allows the next re-date.
  printf 'working: started on the follow-up\n' > "$home/state/follow.status"
  captain_hold "$home" follow --reason "owner: firstmate - after the deploy" --until 2099-10-04 \
    || fail "a re-date after a new status line was refused"
  [ "$(hold_until "$home" follow)" = 2099-10-04 ] || fail "the allowed re-date did not land"
  pass "a second re-date without new evidence is refused with the only answers; new evidence allows it"
}

test_captain_deferral_is_never_refused() {
  local home words
  home=$(make_home redate-captain)
  words="$home/words.txt"
  axi "$home" add tabled "work the captain tabled"
  captain_hold "$home" tabled --reason "owner: firstmate - later" --until 2099-10-02 || fail "first hold refused"
  captain_hold "$home" tabled --reason "owner: firstmate - later" --until 2099-10-03 || fail "first re-date refused"
  printf 'Not this week - bring it back on the 20th.\n' > "$words"
  captain_hold "$home" tabled --reason "captain tabled it" --until 2026-10-20 --captain-words-file "$words" \
    || fail "the captain's own deferral was refused"
  printf 'Push it to November.\n' > "$words"
  captain_hold "$home" tabled --reason "captain tabled it" --until 2026-11-01 --captain-words-file "$words" \
    || fail "a second captain deferral was refused"
  [ "$(hold_until "$home" tabled)" = 2026-11-01 ] || fail "the captain's deferral date did not land"
  pass "the captain's own deferral is never refused, however often it moves"
}

# A re-date made around the gate (a direct tasks-axi hold) is still caught by
# the fold, and the row is listed `redated` until something changes.
test_redate_around_the_gate_is_listed_redated() {
  local home out
  home=$(make_home redate-fold)
  axi "$home" add drift "a row re-dated by hand"
  axi "$home" hold drift --reason "later" --until 2099-10-02
  qz "$home" check >/dev/null || fail "first fold failed"
  axi "$home" hold drift --reason "later" --until 2099-10-03
  qz "$home" check >/dev/null || fail "second fold failed"
  axi "$home" hold drift --reason "later" --until 2099-10-04
  out=$(qz "$home" scan --local) || fail "scan failed: $out"
  assert_contains "$out" "queue redated drift" "a row re-dated twice without evidence was not listed redated"
  printf 'blocked: waiting on the vendor\n' > "$home/state/drift.status"
  axi "$home" hold drift --reason "later" --until 2099-10-05
  out=$(qz "$home" scan --local) || fail "scan failed: $out"
  assert_not_contains "$out" "queue redated drift" "a re-date with new evidence stayed listed redated"
  pass "a re-date around the gate is folded and listed redated until new evidence arrives"
}

# Each answer the alarm names ends a `redated` listing without another date:
# new evidence, a running owner (a watch, a secondmate), a genuine captain
# call, or closing it. A dated hand-off to a secondmate passes the gate.
test_redated_row_clears_on_each_answer() {
  local home out id
  home=$(make_home redate-exits)
  for id in by-status by-watch by-mate by-captain by-close; do
    axi "$home" add "$id" "row $id re-dated by hand"
    axi "$home" hold "$id" --reason "later" --until 2099-10-02
  done
  qz "$home" check >/dev/null || fail "first fold failed"
  for id in by-status by-watch by-mate by-captain by-close; do
    axi "$home" hold "$id" --reason "later" --until 2099-10-03
  done
  qz "$home" check >/dev/null || fail "second fold failed"
  for id in by-status by-watch by-mate by-captain by-close; do
    axi "$home" hold "$id" --reason "later" --until 2099-10-04
  done
  out=$(qz "$home" scan --local) || fail "scan failed: $out"
  for id in by-status by-watch by-mate by-captain by-close; do
    assert_contains "$out" "queue redated $id " "row $id re-dated twice without evidence was not listed redated"
  done

  printf 'working: picked it up\n' > "$home/state/by-status.status"
  mkdir -p "$home/state/procevent"
  printf 'adapter=when\n' > "$home/state/procevent/when-by-watch.source"
  printf '%s\n' "- sm-web - web work (home: $home/sm-web; scope: web; projects: web; added 2026-09-01)" \
    > "$home/data/secondmates.md"
  captain_hold "$home" by-mate --reason "owner: sm-web - building it" --until 2099-10-05 \
    || fail "a dated hand-off to a registered secondmate was refused"
  captain_hold "$home" by-captain --reason "pick the vendor" || fail "the captain hold failed"
  axi "$home" "done" by-close
  out=$(qz "$home" scan --local) || fail "scan failed: $out"
  for id in by-status by-watch by-mate by-captain by-close; do
    assert_not_contains "$out" "redated $id " "row $id stayed listed redated after an answer"
  done
  qz "$home" check >/dev/null || fail "fold after the answers failed"
  jq -e '[.rows[] | .strikes] | all(. == 0)' "$home/state/.queue-zero-holds.json" >/dev/null \
    || fail "the ledger kept strikes after the answers: $(cat "$home/state/.queue-zero-holds.json")"
  pass "a redated row clears on new evidence, a running owner, a captain call, or closing it"
}

# Invariant 3: the three numbers, per home.
test_load_reports_unowned_median_age_and_redates() {
  local home out
  home=$(make_home load)
  axi "$home" add old-bare "nobody on it"
  axi "$home" add new-bare "nobody on it either"
  axi "$home" add worked "a worker is on it"
  axi "$home" start worked
  printf 'kind=ship\n' > "$home/state/worked.meta"
  set_since "$home" old-bare 2026-09-21
  set_since "$home" new-bare 2026-10-01
  set_since "$home" worked 2026-09-27
  out=$(qz "$home" load) || fail "load failed: $out"
  printf '%s' "$out" | jq -e '.open == 3 and .unowned == 2 and (.unowned_ids | sort) == ["new-bare","old-bare"]
    and .unowned_over_day == 1 and .unowned_over_day_ids == ["old-bare"]
    and .median_open_age_days == 4 and .redates_no_progress == 0' >/dev/null \
    || fail "load numbers are wrong: $out"
  axi "$home" hold old-bare --reason "later" --until 2099-10-02
  qz "$home" check >/dev/null || fail "fold failed"
  axi "$home" hold old-bare --reason "later" --until 2099-10-03
  qz "$home" check >/dev/null || fail "fold failed"
  out=$(qz "$home" load) || fail "load failed: $out"
  printf '%s' "$out" | jq -e '.redates_no_progress == 1' >/dev/null \
    || fail "a re-date without progress was not counted: $out"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_QUEUE_ZERO_NOW=2026-10-03T12:00:01Z "$QZ" load) \
    || fail "load failed: $out"
  printf '%s' "$out" | jq -e '.redates_no_progress == 0' >/dev/null \
    || fail "a re-date older than 24 h was still counted: $out"
  pass "load reports unowned rows (and those over 24 h), median open age, and re-dates without progress"
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
  axi "$home" hold flappy --reason "named blocker" --until 2099-12-31
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
  assert_contains "$out" "approval approval:aaaaaaaa" "an old pending approval was not named"
  assert_contains "$out" "approval approval:bbbbbbbb" "a fresh pending approval was not named at the default age of 0"
  assert_not_contains "$out" "FIR-2 " "a backlog issue behind an open blocker was named"
  assert_not_contains "$out" "FIR-4 " "a blocked issue covered by live blocker work was named"
  assert_not_contains "$out" "FIR-6 " "a blocked issue with a dated next check was named"
  assert_not_contains "$out" "FIR-9 " "an in-progress issue with a live run was named"
  pass "the Paperclip sweep names stuck issues and stale approvals and leaves covered or dated work alone"
}

# The approval-age default is 0 (no built-in wait): every pending approval is
# listed on the next sweep. A home can still set a minute-granularity age in
# the home .env or the environment, with a malformed value falling back to 0.
test_approval_age_default_and_threshold() {
  local home out
  home=$(make_home approval-age)
  install_fake_paperclip "$home"
  paperclip_fixture "$home"
  # Fresh ask is 1 h old, old ask 10 h (NOW is 12:00Z).
  out=$(sweep "$home" scan) || fail "sweep scan failed: $out"
  assert_contains "$out" "approval approval:bbbbbbbb" "the default 0 age did not list a fresh approval"

  printf 'FM_PAPERCLIP_APPROVAL_AGE_MINUTES=240\n' >> "$home/.env"
  out=$(sweep "$home" scan) || fail "scan with a .env age failed"
  assert_not_contains "$out" "bbbbbbbb" "an approval younger than the .env age was named"
  assert_contains "$out" "approval approval:aaaaaaaa" "an approval older than the .env age was not named"
  out=$(qz "$home" scan) || fail "queue scan failed"
  assert_not_contains "$out" "bbbbbbbb" "queue-zero surfaced an approval below the .env age"

  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_PAPERCLIP_APPROVAL_AGE_MINUTES=0 \
    FM_QUEUE_ZERO_NOW="$NOW" "$SWEEP" scan) || fail "scan with an explicit env 0 failed"
  assert_contains "$out" "approval approval:bbbbbbbb" "an explicit environment 0 did not list every approval"

  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_PAPERCLIP_APPROVAL_AGE_MINUTES=09 \
    FM_QUEUE_ZERO_NOW="$NOW" "$SWEEP" scan) || fail "scan with a leading-zero age failed: $out"
  assert_contains "$out" "approval approval:bbbbbbbb" "a leading-zero age of 09 was not read as 9 minutes"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_PAPERCLIP_APPROVAL_AGE_MINUTES=0090 \
    FM_QUEUE_ZERO_NOW="$NOW" "$SWEEP" scan) || fail "scan with a leading-zero age failed: $out"
  assert_not_contains "$out" "bbbbbbbb" "a leading-zero age of 0090 was not read as 90 minutes"

  printf 'FM_PAPERCLIP_APPROVAL_AGE_MINUTES=soon\n' > "$home/.env"
  printf 'FM_PAPERCLIP_URL=http://paperclip.test\nFM_PAPERCLIP_KEY_FILE=%s\n' "$home/pc/key" >> "$home/.env"
  out=$(sweep "$home" scan) || fail "scan with a malformed age failed"
  assert_contains "$out" "approval approval:bbbbbbbb" "a malformed age did not fall back to listing every approval"
  pass "the approval age defaults to 0, reads whole minutes from the .env, and a malformed value falls back to 0"
}

# A newly appearing approval is a new queue-zero episode: its row key is new
# to the report record, so the next check wakes firstmate instead of waiting
# for the 24 h re-nag.
test_new_approval_is_a_new_queue_zero_episode() {
  local home out
  home=$(make_home approval-episode)
  install_fake_paperclip "$home"
  printf '[]' > "$home/pc/issues.json"
  printf '[]' > "$home/pc/approvals.json"
  out=$(qz "$home" check) || fail "empty check failed"
  [ -z "$out" ] || fail "an empty board woke firstmate: $out"

  printf '[{"id":"cccccccc-3","type":"request_board_approval","status":"pending","createdAt":"%s","payload":{"title":"new ask"}}]' \
    "$NOW.000Z" > "$home/pc/approvals.json"
  out=$(qz "$home" check) || fail "check after a new approval failed"
  assert_contains "$out" "check: queue-zero:" "a newly appearing approval did not start a new episode"
  assert_contains "$out" "paperclip approval approval:cccccccc" "the new approval was not named in the wake"
  grep -F $'\tcheck\tqueue-zero\t' "$home/state/.wake-queue" >/dev/null \
    || fail "the approval wake was printed but not durably queued"

  out=$(qz "$home" check) || fail "repeat check failed"
  [ -z "$out" ] || fail "an unchanged approval set woke again: $out"
  pass "a newly appearing approval is a new queue-zero episode that wakes firstmate on the next check"
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
# acknowledgment does not clear it and a newer marker supersedes an older one
# (within one comment, the last valid line wins); a passed newest date, a malformed line, or blockers that are all done does
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
  "blockedBy":[{"identifier":"FIR-111","status":"in_progress"}],"blockerAttention":{"state":"stalled"}},
 {"id":"m11","identifier":"FIR-243","title":"last line in one comment wins","status":"blocked",
  "blockedBy":[{"identifier":"FIR-112","status":"in_progress"}],"blockerAttention":{"state":"stalled"}}
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
  printf '%s' '[{"body":"Re-dated.\nfm-next-check: 2026-10-01T11:00:00Z owner=engineer\nfm-next-check: 2026-10-04T00:00:00Z owner=engineer"}]' > "$home/pc/comments-m11.json"
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
  assert_not_contains "$out" "FIR-243 " "an earlier past line beat the last future line in the same comment"
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

test_ready_and_unowned_rows_are_named_and_owned_rows_are_not
test_unowned_row_flagged_and_each_running_owner_clears_it
test_inflight_row_without_a_live_task_is_named_orphan
test_captain_calls_get_the_far_holds_window_and_owner_holds_do_not
test_empty_queue_is_silent_and_unpaired_state_is_silent
test_second_redate_without_evidence_is_refused
test_captain_deferral_is_never_refused
test_redate_around_the_gate_is_listed_redated
test_redated_row_clears_on_each_answer
test_load_reports_unowned_median_age_and_redates
test_check_wakes_once_per_episode_and_queues_durably
test_row_that_leaves_and_returns_is_a_new_episode
test_failed_append_does_not_suppress_the_episode
test_paperclip_scan_classifies_stuck_items
test_paperclip_blocked_comment_marker_dates_the_next_check
test_paperclip_comment_transport_failure_stops_comment_reads
test_paperclip_rows_join_the_queue_wake_and_failure_is_visible
test_paperclip_release_is_guarded
test_approval_age_default_and_threshold
test_new_approval_is_a_new_queue_zero_episode
