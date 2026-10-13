#!/usr/bin/env bash
# Behavior tests for bin/fm-prime-swarm.sh, driven through PATH fakes for
# prime-agent, orca, tasks-axi and ssh (no model tokens, no Orca app, no
# gateway). The fake orca renders a screen from what was pasted into it, so the
# launcher's confirmations (depth set, turn started) are exercised for real.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

LAUNCHER="$ROOT/bin/fm-prime-swarm.sh"
TMP_ROOT=$(fm_test_tmproot fm-prime-swarm)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
export TMUX_TMPDIR="$TMP_ROOT/tmux"
mkdir -p "$TMUX_TMPDIR"
unset TMUX
cleanup_tmux() { tmux kill-server >/dev/null 2>&1 || true; }
trap cleanup_tmux EXIT

FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cat > "$FAKEBIN/prime-agent" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "model list")
    printf 'provider          model                           context  max-out  thinking  images\n'
    printf 'omniroute-cursor  cursor-api/grok-4.7             200K     32K      no        no\n'
    printf 'omniroute-muse    muse-code/muse-wonder-full-1.0  1M       64K      yes       no\n'
    ;;
  "list "*) printf 'name id status age model messages clients\n' ;;
esac
exit 0
SH
# The fake terminal shows the Prime banner once created, "RLM max depth set"
# once a depth command was pasted, and a nonzero token count once the kickoff
# line was pasted. FAKE_ORCA_NO_DEPTH / FAKE_ORCA_NO_TURN suppress those.
cat > "$FAKEBIN/orca" <<'SH'
#!/usr/bin/env bash
dir=$FAKE_ORCA_DIR
mkdir -p "$dir"
printf 'orca %s\n' "$*" >> "$FAKE_LOG"
case "$1 $2" in
  "terminal create")
    while [ "$#" -gt 0 ]; do
      [ "$1" = --command ] && printf '%s\n' "$2" > "$dir/command"
      shift
    done
    printf '{"ok":true,"result":{"terminal":{"handle":"term_fake"}}}\n'
    ;;
  "terminal send")
    text=''
    while [ "$#" -gt 0 ]; do
      [ "$1" = --text ] && text=$2
      shift
    done
    printf '%s' "$text" >> "$dir/sent"
    printf '\n<send>\n' >> "$dir/sent"
    printf '{"ok":true}\n'
    ;;
  "terminal read")
    model=$(sed -n 's/.* --model \([^ ]*\) .*/\1/p' "$dir/command")
    printf ' prime agent v0\n model %s\n' "$model"
    if [ -z "${FAKE_ORCA_NO_DEPTH:-}" ]; then
      d=$(sed -n 's/.*\/rlm-max-depth \([0-9]*\).*/\1/p' "$dir/sent" 2>/dev/null | tail -1)
      [ -z "$d" ] || printf ' RLM max depth set: %s\n' "$d"
    fi
    if [ -z "${FAKE_ORCA_NO_TURN:-}" ] && grep -q 'kickoff.md' "$dir/sent" 2>/dev/null; then
      printf '%s · 12k (6%%)\n' "${model##*/}"
    else
      printf '%s · 0 (0%%)\n' "${model##*/}"
    fi
    ;;
esac
exit 0
SH
cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf 'tasks-axi %s\n' "$*" >> "$FAKE_LOG"
if [ "$1" = show ]; then
  [ -n "${FAKE_TASK_EXISTS:-}" ] && exit 0
  exit 1
fi
exit 0
SH
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'ssh %s\n' "$*" >> "$FAKE_LOG"
printf 'cursor-api/grok-4.7 calls=3 200:3 avg_ms=900\n'
SH
chmod +x "$FAKEBIN"/*
export PATH="$FAKEBIN:$PATH"
export FM_PRIME_START_TIMEOUT_S=5

# One fresh home per case: FM_HOME with data/ and state/, a models.json, a brief.
new_case() {  # <name>
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/home/data" "$CASE/home/state" "$CASE/cwd"
  : > "$CASE/home/data/backlog.md"
  cat > "$CASE/models.json" <<'JSON'
{"providers":{
 "omniroute-cursor":{"baseUrl":"http://gw/v1","models":[{"id":"cursor-api/grok-4.7"}]},
 "omniroute-muse":{"baseUrl":"http://gw/v1","headers":{"x-session-id":"old-key","x-keep":"1"},
   "models":[{"id":"muse-code/muse-wonder-full-1.0"}]}}}
JSON
  printf 'write evidence/hello.md\n' > "$CASE/brief.md"
  # Each case logs its own calls: an earlier case's sampler keeps running.
  LOG="$CASE/calls.log"
  export FM_HOME="$CASE/home" FM_PRIME_MODELS_JSON="$CASE/models.json" FAKE_ORCA_DIR="$CASE/orca" FAKE_LOG="$LOG"
  : > "$LOG"
}

launch() {  # <swarm-id> [args...]
  local id=$1
  shift
  (cd "$CASE/cwd" && "$LAUNCHER" "$id" --brief "$CASE/brief.md" --cwd "$CASE/cwd" "$@") \
    > "$CASE/out" 2> "$CASE/err"
}

# assert_regex <ERE> <file> <msg>: the file has a line matching the pattern.
assert_regex() {
  grep -E -- "$1" "$2" >/dev/null || fail "$3"
}

test_launch_pastes_bracketed_and_starts_sampler() {
  new_case happy
  # A report already in place lets the sampler stop after its first sample.
  mkdir -p "$CASE/home/data/s1"
  echo '# report' > "$CASE/home/data/s1/report.md"
  launch s1 --model omniroute-cursor --depth 1 --max-agents 2
  expect_code 0 $? "happy-path launch"
  assert_regex '^tab: term_fake$' "$CASE/out" "prints the tab handle"
  assert_regex '^backlog: s1$' "$CASE/out" "prints the backlog id"
  assert_regex '^kickoff: .*/data/s1/kickoff\.md$' "$CASE/out" "prints the kickoff path"
  assert_regex '^sampler: due-check: s1-sampler ' "$CASE/out" "prints the sampler job"
  assert_regex 'tasks-axi add s1 .* --kind scout --start --report data/s1/report\.md' "$LOG" "adds an In flight scout item"
  assert_grep 'thinking off' "$CASE/orca/command" "a non-thinking model launches at off"
  # Every pasted payload is wrapped in bracketed-paste markers, and the CR
  # that submits it is a separate send.
  local esc
  esc=$(printf '\033')
  assert_grep "${esc}[200~/rlm-max-depth 1${esc}[201~" "$CASE/orca/sent" "depth is pasted bracketed"
  assert_grep "${esc}[200~Use your read tool on $CASE/home/data/s1/kickoff.md and execute it fully now.${esc}[201~" \
    "$CASE/orca/sent" "kickoff line is pasted bracketed"
  assert_equals 2 "$(grep -c "^$(printf '\r')$" "$CASE/orca/sent")" "each paste is submitted by its own CR"
  assert_grep "Read $CASE/brief.md and execute it fully." "$CASE/home/data/s1/kickoff.md" "kickoff names the brief"
  assert_grep 'No A/B tests, trials, pilots or lotteries; actions only.' "$CASE/home/data/s1/kickoff.md" "kickoff carries the settled rule"
  assert_grep 'discover and choose your own threads of work from the brief' "$CASE/home/data/s1/kickoff.md" "kickoff leaves threads to the root"
  local i=0
  while [ ! -f "$CASE/home/data/s1/gateway-sampler.result" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  assert_regex '^result=ok exit=0' "$CASE/home/data/s1/gateway-sampler.result" "sampler stops cleanly once the report exists and nothing works"
  assert_grep 'cursor-api/grok-4.7 calls=3' "$CASE/home/data/s1/gateway-by-model.tsv" "sampler records the gateway row"
  pass "launch pastes bracketed, confirms depth and turn, starts the sampler"
}

test_unconfirmed_depth_stops_before_kickoff() {
  new_case nodepth
  FAKE_ORCA_NO_DEPTH=1 launch s2 --model omniroute-cursor --depth 2
  expect_code 1 $? "unconfirmed depth"
  assert_grep 'RLM max depth 2 not confirmed' "$CASE/err" "names the unconfirmed depth"
  assert_no_grep 'kickoff.md' "$CASE/orca/sent" "the kickoff is never sent"
  pass "an unconfirmed depth stops the launch before the kickoff"
}

test_turn_that_never_starts_fails() {
  new_case noturn
  FAKE_ORCA_NO_TURN=1 launch s3 --model omniroute-cursor
  expect_code 1 $? "turn never started"
  assert_grep 'did not start a turn within 5s' "$CASE/err" "names the start timeout"
  assert_no_grep 'sampler:' "$CASE/out" "no sampler is started"
  pass "a turn that never starts fails the launch"
}

test_refusals_have_no_side_effects() {
  new_case refuse
  launch s4 --model omniroute-cursor/cursor-api/nope
  expect_code 2 $? "unknown model"
  launch s4 --model omniroute-cursor --effort high
  expect_code 2 $? "effort on a non-thinking model"
  assert_grep 'does not support thinking' "$CASE/err" "names the thinking refusal"
  launch s4 --model omniroute-cursor --depth 6
  expect_code 2 $? "depth above 5"
  FAKE_TASK_EXISTS=1 launch s4 --model omniroute-cursor
  expect_code 2 $? "existing backlog id"
  assert_no_grep 'orca ' "$LOG" "no tab is created by any refusal"
  assert_no_grep 'tasks-axi add' "$LOG" "no backlog item is added by any refusal"
  pass "refusals create no tab and no backlog item"
}

test_muse_gets_a_fresh_session_key() {
  new_case muse
  launch s5 --model omniroute-muse --session-key relaunch-b
  expect_code 0 $? "muse launch"
  assert_equals relaunch-b "$(jq -r '.providers["omniroute-muse"].headers["x-session-id"]' "$CASE/models.json")" "uses the given session key"
  assert_equals 1 "$(jq -r '.providers["omniroute-muse"].headers["x-keep"]' "$CASE/models.json")" "keeps other headers"
  assert_equals old-key "$(jq -r '.providers["omniroute-muse"].headers["x-session-id"]' "$CASE/models.json.bak-s5")" "backs up the previous key"
  assert_grep 'thinking max' "$CASE/orca/command" "Muse defaults to max effort"
  assert_grep 'at most 6 agents' "$CASE/home/data/s5/kickoff.md" "Muse defaults to 6 agents"
  launch s6 --model omniroute-muse
  expect_code 0 $? "second muse launch"
  local key
  key=$(jq -r '.providers["omniroute-muse"].headers["x-session-id"]' "$CASE/models.json")
  assert_not_equals relaunch-b "$key" "a launch without --session-key mints a new key"
  assert_contains "$key" "s6" "the minted key names the swarm"
  pass "a Muse launch writes a fresh session key and keeps the rest of models.json"
}

test_dry_run_changes_nothing() {
  new_case dry
  local before
  before=$(cat "$CASE/models.json")
  launch s7 --model omniroute-muse --dry-run
  expect_code 0 $? "dry run"
  assert_equals "$before" "$(cat "$CASE/models.json")" "models.json untouched"
  assert_absent "$CASE/home/data/s7" "no swarm directory"
  assert_no_grep 'orca terminal' "$LOG" "no tab"
  assert_no_grep 'tasks-axi add' "$LOG" "no backlog item"
  assert_no_grep 'ssh ' "$LOG" "no gateway call"
  assert_grep 'terminal create --worktree path:' "$CASE/out" "prints the tab command"
  assert_grep 'x-session-id' "$CASE/out" "prints the session key change"
  assert_grep 'fm-durable-job.sh s7-sampler' "$CASE/out" "prints the sampler command"
  assert_grep "Read $CASE/brief.md and execute it fully." "$CASE/out" "prints the kickoff file"
  local body
  body="verify: data/s7/report.md exists with a Swarm method section and state/s7.status has a done line; brief $CASE/brief.md"
  assert_grep "--report data/s7/report.md --body $(printf %q "$body")" "$CASE/out" "prints the exact backlog body"
  assert_grep "+ orca terminal send --terminal <tab handle> --text \$'\\E[200~/rlm-max-depth 3\\E[201~' --json" \
    "$CASE/out" "prints the bracketed depth send"
  assert_grep "+ orca terminal send --terminal <tab handle> --text \$'\\E[200~Use your read tool on $CASE/home/data/s7/kickoff.md and execute it fully now.\\E[201~' --json" \
    "$CASE/out" "prints the bracketed kickoff send"
  assert_equals 2 "$(grep -cF "+ orca terminal send --terminal <tab handle> --text \$'\\r' --json" "$CASE/out")" "prints a separate CR send per paste"
  pass "--dry-run prints the launch and changes nothing"
}

test_launch_pastes_bracketed_and_starts_sampler
test_unconfirmed_depth_stops_before_kickoff
test_turn_that_never_starts_fails
test_refusals_have_no_side_effects
test_muse_gets_a_fresh_session_key
test_dry_run_changes_nothing
