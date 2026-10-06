#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - the portable regression for the omp (Oh My Pi)
# adapter: detection, session-lock identity, tmux liveness classification, the
# spawn launch line and worker posture overlay, pre-launch model validation, the
# per-task busy-state extension, the extension supervision model and ownership
# proof, and the two tracked primary extensions driven over a fake omp API.
#
# omp's identity, launch, and lifecycle checks are HARNESS-DEPENDENT: their
# verdicts come from what the vendor emits (a process name, a settings schema,
# an extension event). This suite pins the LOGIC with real processes, a fake
# omp binary, and a plain Node host, so CI enforces it with no omp installed;
# FM_OMP_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh is the live guard that
# catches vendor drift against a real omp. Neither replaces the other.
#
# The load-bearing contracts:
#   1. omp's identity is anchored in every vendor shape - the natively-named
#      process `omp` (a Bun-compiled binary, 18.1.11), bun running the launcher
#      script (comm bun, argv `bun .../bin/omp`, 18.1.22), or bun running its
#      `@oh-my-pi/pi-coding-agent/dist/cli.js` package entry (18.4.4, after
#      /restart) but never an `__omp_worker_*` helper - plus the OMPCODE=1
#      marker omp sets for its children; ompd/comp never identify.
#   2. FM_OMP_HARNESS=omp is a precedence override that needs a real omp
#      ancestor: it beats an inherited CLAUDECODE under omp and is inert when it
#      leaks into a worker whose ancestry holds no omp.
#   3. Every omp launch clears foreign markers, carries the tracked posture
#      overlay, --auto-approve, --cwd, and (for a crewmate) one -e pointing at
#      state/<id>.omp-ext.ts; a secondmate launch names no -e at all.
#   4. A <provider>/<id> model is validated only when `omp models --json` lists
#      that provider; an unlisted provider passes through with a notice.
#   5. Busy state: agent_start is busy, agent_end with willContinue stays busy,
#      a plain agent_end is idle, turn_end is a notification only.
#   6. The turn-end guard extension compels one continuation on exit 2 and
#      stands down when the payload already carries stop_hook_active.
#   7. The watch extension arms through fm_watch_arm_omp, delivers every
#      actionable close as one follow-up at once, and shows the model a note
#      instead of an acknowledged stale wake for a torn-down terminal only.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
export NODE_NO_WARNINGS=1

# A process whose kernel-recorded identity is the bare name `omp`: a SYMLINK to
# the system shell, never a copy (a copied platform binary fails macOS code
# signing). macOS reports the symlink name through `ps -o comm=`, which is the
# exact signal under test. Every `-c` body below ends in a no-op so bash does
# not exec-optimize the single command away and replace the named process.
make_named_shells() {  # <dir> -> echoes <bindir>
  local dir=$1 name
  mkdir -p "$dir"
  for name in omp ompd comp; do
    ln -sf /bin/bash "$dir/$name"
  done
  printf '%s' "$dir"
}

# --- 1. Detection --------------------------------------------------------------

test_detection_anchored_name_and_marker_precedence() {
  local bin out fakebin
  bin=$(make_named_shells "$TMP_ROOT/named")
  # Every env list below also drops OMPCODE: the suite may itself run under
  # omp, and a leaked marker would decide the verdict instead of the evidence
  # under test.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u OMPCODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "a process named omp must detect as omp, got '$out'"
  for decoy in ompd comp; do
    # Pinned with a foreign marker rather than cleared markers: the suite may
    # run under omp, whose own args-strength ancestry would otherwise satisfy
    # a bare `!= omp` above the decoy. A comm-layer false positive would still
    # beat the marker, so the anchoring stays guarded.
    # shellcheck disable=SC2016 # the quoted body expands inside the named shell
    out=$(env -u OMPCODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 \
      "$bin/$decoy" -c '"$1"; :' _ "$HARNESS")
    [ "$out" = claude ] || fail "'$decoy' merely contains omp and must not detect as omp, got '$out'"
  done
  # The marker beats an inherited CLAUDECODE only under a real omp ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u OMPCODE -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "FM_OMP_HARNESS under an omp ancestor must outrank an inherited CLAUDECODE, got '$out'"
  # ...and is inert when it leaks into a worker with no omp ancestor. Ancestry
  # is blinded so the "no omp ancestor" condition holds even when the suite
  # itself runs under omp.
  fakebin=$(fm_fakebin "$TMP_ROOT/blind")
  fm_fake_blind_ancestry "$fakebin"
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u OMPCODE -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    PATH="$fakebin:$PATH" bash -c '"$1"; :' _ "$HARNESS")
  [ "$out" = claude ] || fail "a leaked FM_OMP_HARNESS without an omp ancestor must not relabel a claude worker, got '$out'"
  pass "fm-harness: omp detects by its anchored name; the marker is a precedence override that needs real omp ancestry"
}

test_lock_identity_and_liveness_classification() {
  fm_harness_process_matches omp '' || fail "session-lock identity must accept the exact omp name"
  fm_harness_process_matches /usr/local/bin/omp 'omp --cwd /x' || fail "session-lock identity must accept an omp path"
  ! fm_harness_process_matches ompd '' || fail "session-lock identity must not accept ompd"
  ! fm_harness_process_matches comp '' || fail "session-lock identity must not accept comp"
  fm_harness_process_matches bun 'bun /Users/x/.bun/bin/omp' || fail "session-lock identity must accept bun running the omp launcher"
  fm_harness_process_matches bun 'bun /x/omp --config y --cwd /z' || fail "session-lock identity must accept the launcher with trailing arguments"
  ! fm_harness_process_matches bun 'bun run build' || fail "session-lock identity must not accept a bare bun"
  ! fm_harness_process_matches bun 'bun /x/ompd' || fail "session-lock identity must not accept bun running ompd"
  ! fm_harness_process_matches bun 'bun /x/comp' || fail "session-lock identity must not accept bun running comp"
  ! fm_harness_process_matches bun 'bun server.js --config /x/omp' || fail "session-lock identity must not accept an omp mention in a later flag value"
  local entry=/Users/x/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js
  fm_harness_process_matches bun "/Users/x/.bun/bin/bun $entry --resume 01a0" || fail "session-lock identity must accept bun running the omp package entry (resumed session)"
  fm_harness_process_matches bun "bun $entry" || fail "session-lock identity must accept the bare omp package entry"
  ! fm_harness_process_matches bun "bun $entry __omp_worker_daemon_broker" || fail "session-lock identity must not accept omp's daemon-broker helper"
  ! fm_harness_process_matches bun "bun $entry __omp_worker_text_predict" || fail "session-lock identity must not accept omp's text-predict helper"
  ! fm_harness_process_matches bun 'bun /x/other-pkg/dist/cli.js' || fail "session-lock identity must not accept an unrelated package cli.js"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  [ "$(fm_agent_process_classify_name omp)" = agent ] || fail "tmux liveness must classify omp as an agent"
  [ "$(fm_agent_process_classify_name /opt/omp/bin/omp)" = agent ] || fail "tmux liveness must classify an omp path as an agent"
  [ "$(fm_agent_process_classify_name ompd)" != agent ] || fail "tmux liveness must not classify ompd as an agent"
  [ "$(fm_agent_process_classify_name comp)" != agent ] || fail "tmux liveness must not classify comp as an agent"
  # shellcheck source=bin/fm-agent-process-lib.sh
  . "$ROOT/bin/fm-agent-process-lib.sh"
  [ "$(fm_agent_process_classify bun bun 'bun /Users/x/.bun/bin/omp')" = agent ] || fail "liveness must classify bun running the omp launcher as an agent"
  [ "$(fm_agent_process_classify bun bun 'bun run build')" = other ] || fail "liveness must not classify a bare bun as an agent"
  [ "$(fm_agent_process_classify bun bun 'bun /x/ompd')" = other ] || fail "liveness must not classify bun running ompd as an agent"
  [ "$(fm_agent_process_classify bun bun "bun $entry --resume 01a0")" = agent ] || fail "liveness must classify bun running the omp package entry as an agent"
  [ "$(fm_agent_process_classify bun bun "bun $entry")" = agent ] || fail "liveness must classify the bare omp package entry as an agent"
  [ "$(fm_agent_process_classify bun bun "bun $entry __omp_worker_daemon_broker")" = other ] || fail "liveness must not classify omp's daemon-broker helper as an agent"
  [ "$(fm_agent_process_classify bun bun "bun $entry __omp_worker_text_predict")" = other ] || fail "liveness must not classify omp's text-predict helper as an agent"
  [ "$(fm_agent_process_classify bun bun 'bun /x/other-pkg/dist/cli.js')" = other ] || fail "liveness must not classify an unrelated package cli.js as an agent"
  pass "session lock and shared liveness: omp is anchored in the binary, launcher, and package-entry shapes, decoys and helpers stay out"
}

# A bun launcher running a script: a `bun` symlink to the system shell plus a
# script file, reproducing `bun .../bin/omp` (comm bun, argv carrying the
# launcher path). The script body ends in a no-op for the same
# exec-optimization reason make_named_shells documents.
make_bun_launcher() {  # <dir> <script-name> -> echoes <dir>
  local dir=$1 script=$2
  mkdir -p "$dir"
  ln -sf /bin/bash "$dir/bun"
  cat > "$dir/$script" <<SH
"$HARNESS"
:
SH
  printf '%s' "$dir"
}

test_detection_bun_launcher_shape() {
  local dir out
  dir="$TMP_ROOT/bun-omp"
  make_bun_launcher "$dir" omp >/dev/null
  out=$(env -u CLAUDECODE -u OMPCODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    "$dir/bun" "$dir/omp")
  [ "$out" = omp ] || fail "bun running the omp launcher must detect as omp, got '$out'"
  # Trailing launcher arguments change nothing.
  out=$(env -u CLAUDECODE -u OMPCODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    "$dir/bun" "$dir/omp" --config x --cwd /z)
  [ "$out" = omp ] || fail "launcher arguments must not change the verdict, got '$out'"
  pass "fm-harness: bun running the omp launcher detects as omp"
}

# A fake ps modeling one bun process at pid 100 under init, for the
# deterministic argv-shape cases a real process cannot pin: a decoy script
# under a live omp launcher would inherit real omp ancestry above it.
bun_shape_bin() {  # <dir> <comm> <args> -> echoes the fakebin
  local dir=$1 comm=$2 args=$3 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
pid=
prev=
for a in "\$@"; do
  [ "\$prev" = -p ] && pid=\$a
  prev=\$a
done
case "\$*" in
  *'comm='*) if [ "\$pid" = 100 ]; then printf '%s\n' "$comm"; else printf 'init\n'; fi ;;
  *'args='*) if [ "\$pid" = 100 ]; then printf '%s\n' "$args"; else printf 'init\n'; fi ;;
  *'ppid='*) printf '1\n' ;;
  *) printf '\n' ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

bun_shape_verdict() {  # <fakebin> -> the ancestry verdict for pid 100
  env -u CLAUDECODE -u OMPCODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    PATH="$1:$PATH" "$HARNESS" ancestry 100
}

test_detection_bun_launcher_ancestry_shapes() {
  local fakebin out decoy entry=/Users/x/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js
  fakebin=$(bun_shape_bin "$TMP_ROOT/ps-bun-omp" bun "bun /Users/x/.bun/bin/omp")
  out=$(bun_shape_verdict "$fakebin")
  [ "$out" = "args omp" ] || fail "bun+omp argv must read 'args omp', got '$out'"
  fakebin=$(bun_shape_bin "$TMP_ROOT/ps-bun-flags" bun "bun /x/omp --config y --cwd /z")
  out=$(bun_shape_verdict "$fakebin")
  [ "$out" = "args omp" ] || fail "trailing launcher arguments must keep 'args omp', got '$out'"
  fakebin=$(bun_shape_bin "$TMP_ROOT/ps-bun-entry" bun "/Users/x/.bun/bin/bun $entry --resume 01a0")
  out=$(bun_shape_verdict "$fakebin")
  [ "$out" = "args omp" ] || fail "bun running the omp package entry must read 'args omp', got '$out'"
  for decoy in __omp_worker_daemon_broker __omp_worker_text_predict; do
    fakebin=$(bun_shape_bin "$TMP_ROOT/ps-bun-$decoy" bun "/Users/x/.bun/bin/bun $entry $decoy")
    out=$(bun_shape_verdict "$fakebin")
    [ -z "$out" ] || fail "omp's $decoy helper must read no verdict, got '$out'"
  done
  for decoy in ompd comp; do
    fakebin=$(bun_shape_bin "$TMP_ROOT/ps-bun-$decoy" bun "bun /x/$decoy")
    out=$(bun_shape_verdict "$fakebin")
    [ -z "$out" ] || fail "bun running $decoy must read no verdict, got '$out'"
  done
  fakebin=$(bun_shape_bin "$TMP_ROOT/ps-bun-bare" bun "bun run build")
  out=$(bun_shape_verdict "$fakebin")
  [ -z "$out" ] || fail "a bare bun must read no verdict, got '$out'"
  fakebin=$(bun_shape_bin "$TMP_ROOT/ps-bun-flagmention" bun "bun server.js --config /x/omp")
  out=$(bun_shape_verdict "$fakebin")
  [ -z "$out" ] || fail "an omp mention in a later flag value must read no verdict, got '$out'"
  pass "fm-harness ancestry: the bun argv rule accepts the launcher and package entry and rejects helpers, decoys, bare runs, and flag mentions"
}

test_detection_ompcode_marker() {
  local out
  # shellcheck disable=SC2016 # the quoted body expands inside the child shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS OMPCODE=1 \
    bash -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "OMPCODE=1 must identify omp, got '$out'"
  # shellcheck disable=SC2016 # the quoted body expands inside the child shell
  out=$(env -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS OMPCODE=1 CLAUDECODE=1 \
    bash -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "OMPCODE=1 must outrank an inherited CLAUDECODE, got '$out'"
  # shellcheck disable=SC2016 # the quoted body expands inside the child shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS OMPCODE=1 GEMINI_CLI=1 \
    bash -c '"$1"; :' _ "$HARNESS")
  [ "$out" = gemini ] || fail "a harness's own marker must outrank a leaked OMPCODE, got '$out'"
  pass "fm-harness: OMPCODE=1 identifies omp, outranks CLAUDECODE, and yields to another harness's own marker"
}

test_detection_leaked_ompcode_yields_to_structural_ancestry() {
  local dir out
  dir="$TMP_ROOT/named-claude"
  mkdir -p "$dir"
  ln -sf /bin/bash "$dir/claude"
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS OMPCODE=1 CLAUDECODE=1 \
    "$dir/claude" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = claude ] || fail "a leaked OMPCODE must not relabel a claude worker, got '$out'"
  pass "fm-harness: a structural claude ancestor outranks a leaked OMPCODE"
}

test_lock_acquires_from_bun_launcher_ancestry() {
  local home fakebin out
  home="$TMP_ROOT/lock-bun-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-bun-fake")
  mkdir -p "$home/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'bun'; exit 0 ;;
  *"args="*) printf '%s\n' 'bun /Users/x/.bun/bin/omp'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" \
    || fail "fm-lock did not acquire from bun-launcher ancestry"
  case "$(cat "$home/state/.lock")" in
    ''|*[!0-9]*) fail "fm-lock did not record the bun-launcher harness ancestor" ;;
  esac
  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" \
    "fm-lock did not recognize the bun launcher as a live holder"
  home="$TMP_ROOT/lock-bun-bare-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-bun-bare-fake")
  mkdir -p "$home/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'bun'; exit 0 ;;
  *"args="*) printf '%s\n' 'bun run build'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  if FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1; then
    fail "fm-lock acquired from a bare bun with no omp launcher above it"
  fi
  pass "fm-lock acquires from bun-launcher ancestry, recognizes the live holder, and refuses a bare bun"
}

# --- 2. Launch ---------------------------------------------------------------

# A fake omp that answers `models --json` with a two-provider catalog and exits
# 0 for everything else (the launch itself is only recorded by the fake tmux).
make_fake_omp() {  # <fakebin>
  cat > "$1/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  models)
    printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6-astra","selector":"openai-codex/gpt-6-astra"},{"provider":"ollama","id":"qwen3:8b","selector":"ollama/qwen3:8b"}]}'
    ;;
esac
exit 0
SH
  chmod +x "$1/omp"
}

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  make_fake_omp "$fakebin"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_scout_spawn() {  # <home> <wt> <fakebin> <launch-log> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --scout
}

test_spawn_launch_line_and_worker_wiring() {
  local rec id=omp-launch-q1 out status launch state
  rec=$(make_spawn_case launch omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-astra --effort medium)
  status=$?
  expect_code 0 "$status" "omp scout spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=omp" "spawn did not report the omp harness"
  state="$HOME_DIR/state"
  assert_grep "harness=omp" "$state/$id.meta" "meta missing harness=omp"
  assert_grep "model=openai-codex/gpt-6-astra" "$state/$id.meta" "meta missing the pinned model"
  assert_grep "effort=medium" "$state/$id.meta" "meta missing the pinned effort"
  assert_present "$state/$id.omp-ext.ts" "omp spawn did not write the per-task extension"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '$FAKEBIN_DIR/omp'" \
    "omp launch did not clear foreign markers and establish its own at the launch boundary"
  assert_contains "$launch" "--config '$ROOT/.omp/fm-worker-overlay.yml' --auto-approve --cwd '$WT_DIR'" \
    "omp launch did not carry the tracked posture overlay, --auto-approve, and the pinned working directory"
  assert_contains "$launch" "--model 'openai-codex/gpt-6-astra' --thinking 'medium' -e '$state/$id.omp-ext.ts'" \
    "omp launch did not pass the model, thinking level, and the state-resident worker extension"
  assert_contains "$launch" "encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md'" "omp launch lost the canonical typed launch-brief envelope"
  case "$launch" in
    *"-e '$state/$id.omp-ext.ts' \"\$("*) ;;
    *) fail "omp launch must keep exactly one positional brief after the extension flag: $launch" ;;
  esac
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy fm-spawn" ] \
    || fail "omp spawn must seed the busy-state contract"
  pass "fm-spawn: the omp launch line clears markers, pins posture, and wires the state-resident extension"
}

test_spawn_model_validation_scoped_to_listed_providers() {
  local rec id out status
  rec=$(make_spawn_case model-refused omp omp-model-refused-q2)
  read_case_record "$rec"
  id=omp-model-refused-q2
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-nope)
  status=$?
  expect_code 1 "$status" "a model absent from a listed provider must refuse"
  assert_contains "$out" "is not listed by 'omp models --json' although provider 'openai-codex' is" "refusal did not name the listing evidence"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"

  rec=$(make_spawn_case model-bridge omp omp-model-bridge-q3)
  read_case_record "$rec"
  id=omp-model-bridge-q3
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model claude-bridge/claude-opus-4-8)
  status=$?
  expect_code 0 "$status" "an extension-registered provider must pass through: $out"
  assert_contains "$out" "notice: omp provider 'claude-bridge' is not in 'omp models --json'" "pass-through did not state its reason"
  assert_contains "$(cat "$LAUNCH_LOG")" "--model 'claude-bridge/claude-opus-4-8'" "pass-through model did not reach the launch line"

  rec=$(make_spawn_case model-fuzzy omp omp-model-fuzzy-q4)
  read_case_record "$rec"
  id=omp-model-fuzzy-q4
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model astra)
  status=$?
  expect_code 0 "$status" "a bare fuzzy pattern is omp's own matcher's job: $out"
  pass "fm-spawn: omp model validation is scoped to providers the listing can prove"
}

test_secondmate_launch_relies_on_discovery() {
  # A seeded secondmate home, launched for real through fm-spawn on omp: the
  # launch must carry the posture overlay and pin --cwd to the home, and must
  # name NO -e, because omp auto-discovers the home's tracked .omp/extensions
  # and a file named both ways loads twice.
  local world home fakebin launchlog out status launch
  world="$TMP_ROOT/secondmate"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_omp "$fakebin"
  launchlog="$world/launch.log"
  : > "$launchlog"
  # FM_BACKEND=tmux pins the fake tmux even where the developer shell carries a
  # live Herdr environment; without it auto-detection would spawn a real pane.
  out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" sm "$home" omp --secondmate 2>&1)
  status=$?
  expect_code 0 "$status" "omp secondmate spawn should succeed: $out"
  assert_grep "harness=omp" "$world/home/state/sm.meta" "secondmate meta missing harness=omp"
  launch=$(cat "$launchlog")
  case "$launch" in
    *" -e "*) fail "an omp secondmate launch must name no -e: omp auto-discovers .omp/extensions and a file named both ways loads twice: $launch" ;;
  esac
  assert_contains "$launch" "--config '$ROOT/.omp/fm-worker-overlay.yml' --auto-approve --cwd '$home'" "secondmate launch lost the posture overlay or the pinned home directory: $launch"
  assert_contains "$launch" "FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '$fakebin/omp'" "secondmate launch lost the omp marker or executable"
  assert_contains "$launch" "FM_SUPERVISION_MODEL=extension" "an omp secondmate must run the extension supervision model"
  assert_absent "$world/home/state/sm.omp-ext.ts" "a secondmate must not receive a per-task worker extension"
  pass "fm-spawn: a real omp secondmate launch relies on auto-discovery while crewmates load one -e"
}

test_secondmate_config_pinned_model_is_validated() {
  # The same seeded secondmate home, but the harness and model come from the
  # primary's config/secondmate-harness rather than the command line: the
  # durable pin lands on MODEL after the harness case arm, so an unlisted id
  # under a listed provider must still be refused before endpoint creation.
  local world home fakebin launchlog out status
  world="$TMP_ROOT/secondmate-config-model"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  printf 'omp openai-codex/gpt-nope\n' > "$world/home/config/secondmate-harness"
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_omp "$fakebin"
  launchlog="$world/launch.log"
  : > "$launchlog"
  out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" sm "$home" --secondmate 2>&1)
  status=$?
  expect_code 1 "$status" "a config-pinned unlisted omp model must refuse the secondmate spawn: $out"
  assert_contains "$out" "omp model 'openai-codex/gpt-nope' is not listed by 'omp models --json' although provider 'openai-codex' is" \
    "the refusal did not name the config-pinned model under its listed provider: $out"
  assert_absent "$world/home/state/sm.meta" "a refused secondmate spawn must publish no sm.meta"
  [ ! -s "$launchlog" ] || fail "a refused secondmate spawn must record no launch: $(cat "$launchlog")"
  pass "fm-spawn: the config/secondmate-harness model pin is validated against the omp catalog before launch"
}

# --- 3. Busy state -------------------------------------------------------------

drive_omp_ext() {  # <ext-path> <mode>
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
// ctx.isIdle() reads false at a natural TUI agent_end on omp; the extension
// must go idle on a plain agent_end regardless of it.
const ctx = { isIdle: () => false, agent: { kind: "main", id: "Main", name: "main", depth: 0 } };
// omp rebinds the factory into subagent sessions; their handlers see kind "sub".
const subCtx = { isIdle: () => false, agent: { kind: "sub", id: "0-Task", name: "task", depth: 1, parentId: "Main" } };
switch (process.env.MODE) {
  case "handlers": console.log(Object.keys(handlers).sort().join(" ")); break;
  case "agent-start": await handlers["agent_start"]({ type: "agent_start" }, ctx); break;
  case "end-continuing": await handlers["agent_end"]({ type: "agent_end", willContinue: true }, ctx); break;
  case "end-final": await handlers["agent_end"]({ type: "agent_end" }, ctx); break;
  case "turn-end": await handlers["turn_end"]({ type: "turn_end", turnIndex: 0 }, ctx); break;
  case "sub-end-final": await handlers["agent_end"]({ type: "agent_end" }, subCtx); break;
  case "sub-turn-end": await handlers["turn_end"]({ type: "turn_end", turnIndex: 0 }, subCtx); break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (process.env.MODE === "turn-end" || process.env.MODE === "sub-turn-end" || process.env.MODE === "sub-end-final") {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
}

test_busy_extension_lifecycle() {
  local rec id=omp-busy-q5 out state ext
  rec=$(make_spawn_case busy omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  assert_present "$ext" "omp spawn did not write the per-task extension"
  out=$(drive_omp_ext "$ext" handlers) || fail "handler listing failed: $out"
  case " $out " in
    *" agent_settled "*) fail "the omp extension must not listen for agent_settled (omp has no such event)" ;;
  esac
  for handler in agent_start agent_end turn_end; do
    case " $out " in
      *" $handler "*) ;;
      *) fail "the omp extension must register $handler, got '$out'" ;;
    esac
  done

  rm -f "$state/$id.turn-ended"
  out=$(drive_omp_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge"

  out=$(drive_omp_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "agent_start must classify 'busy omp-ext'"

  # A subagent the worker spawned finishing its own run must not record the
  # task idle or ring the turn-end marker while main is still waiting on it.
  rm -f "$state/$id.turn-ended"
  out=$(drive_omp_ext "$ext" sub-end-final) || fail "subagent agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "a subagent's agent_end must not record the worker idle"
  out=$(drive_omp_ext "$ext" sub-turn-end) || fail "subagent turn_end drive failed: $out"
  [ ! -e "$state/$id.turn-ended" ] || fail "a subagent's turn_end must not ring the worker's turn-end marker"

  out=$(drive_omp_ext "$ext" end-continuing) || fail "continuing agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "agent_end with willContinue must stay busy (a session_stop continuation is coming)"

  out=$(drive_omp_ext "$ext" end-final) || fail "final agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "idle omp-ext" ] || fail "a plain agent_end must classify 'idle omp-ext'"

  # A record from another harness's writer is never trusted for omp.
  fm_busy_source_trusted omp pi-ext && fail "omp must not trust the Pi extension's records"
  fm_busy_source_trusted omp omp-ext || fail "omp must trust its own extension's records"
  pass "omp extension: agent_start busy, willContinue stays busy, plain agent_end idle, turn_end a notification"
}

# --- 4. Control, composer, supervision model -----------------------------------

test_control_composer_and_model_tables() {
  [ "$(fm_control_exit_command omp)" = /quit ] || fail "omp exit command must be /quit"
  [ "$(fm_control_interrupt_key omp)" = Escape ] || fail "omp interrupt key must be Escape"
  [ "$(fm_control_interrupt_repeat omp)" = 1 ] || fail "omp interrupts on a single press"
  [ -z "$(fm_control_interrupt_clear_key omp)" ] || fail "omp leaves its composer empty and needs no clear key"
  [ "$(fm_control_harness_wiring_paths omp /wt /st id1)" = "/st/id1.omp-ext.ts" ] || fail "omp wiring path must be the state-resident extension"
  printf 'Working…\n' | fm_busy_lines_match omp || fail "omp busy regex must match the TUI ellipsis form"
  printf 'Working...\n' | fm_busy_lines_match omp && fail "omp busy regex must not match the three-dot form no supervised pane renders"
  printf ' ⠧ 11s  · gpt-6-astra\n' | fm_busy_lines_match omp || fail "omp busy regex must match the braille spinner plus elapsed cell"
  printf ' ⣾ 3s  · gpt-6-astra\n' | fm_busy_lines_match omp || fail "omp busy regex must match the status-set spinner frames, not only the activity set"
  printf ' 󰵗  · gpt-6-astra · 36.7%%/41K\n' | fm_busy_lines_match omp && fail "an idle omp status row must not read busy"
  printf 'esc to interrupt\n' | fm_busy_lines_match omp && fail "omp must not borrow Claude's footer"
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named-model")
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_SUPERVISION_MODEL \
    "$bin/omp" -c '. "$1"; fm_supervision_model' _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$out" = extension ] || fail "an omp primary must run the extension supervision model, got '$out'"
  pass "control, composer, and supervision-model tables carry omp's verified values"
}

# --- 5. Ownership proof --------------------------------------------------------

# Stand up the durable evidence a live omp session leaves behind: both tracked
# extensions under the case root and one marker per extension recording that
# build plus the session pid in state/.lock.
record_omp_session() {  # <root> <home> <session-pid> [omit] [drift]
  local root=$1 home=$2 session_pid=$3 omit=${4:-} drift=${5:-} pair source marker version
  mkdir -p "$root/.omp/extensions" "$home/state"
  for pair in \
    "fm-primary-omp-watch.ts:.omp-watch-extension-loaded:watch" \
    "fm-primary-turnend-guard.ts:.omp-turnend-extension-loaded:turnend"; do
    source=${pair%%:*}
    marker=${pair#*:}; marker=${marker%%:*}
    printf '// %s\n' "${pair##*:}" > "$root/.omp/extensions/$source"
    [ "$omit" = "${pair##*:}" ] && continue
    if [ "$drift" = "${pair##*:}" ]; then
      version="sha256:0000000000000000000000000000000000000000000000000000000000000000"
    else
      version=$(bash -c '. "$1"; fm_pi_extension_version "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$root/.omp/extensions/$source") || return 1
    fi
    printf '%s\n%s\n' "$version" "$session_pid" > "$home/state/$marker"
  done
  printf '%s\n' "$session_pid" > "$home/state/.lock"
}

owns() {  # <root> <home>
  bash -c '. "$1"; fm_omp_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$2/state" "$1"
}

test_ownership_proof_is_omp_keyed() {
  local root home pid
  sleep 60 &
  pid=$!
  root="$TMP_ROOT/own/root"; home="$TMP_ROOT/own/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the omp session"
  owns "$root" "$home" || fail "a live session that loaded both omp extensions must own supervision"
  bash -c '. "$1"; fm_pi_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root" \
    && fail "omp markers must never satisfy the Pi proof"
  bash -c '. "$1"; fm_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root" \
    || fail "the shared extension proof must accept the omp pair"

  root="$TMP_ROOT/own-drift/root"; home="$TMP_ROOT/own-drift/home"
  record_omp_session "$root" "$home" "$pid" "" watch || fail "could not record the drifted session"
  owns "$root" "$home" && fail "a session that loaded an older watch build must not own supervision"
  root="$TMP_ROOT/own-omit/root"; home="$TMP_ROOT/own-omit/home"
  record_omp_session "$root" "$home" "$pid" turnend || fail "could not record the partial session"
  owns "$root" "$home" && fail "a session missing the turn-end guard extension must not own supervision"
  root="$TMP_ROOT/own-dead/root"; home="$TMP_ROOT/own-dead/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the dead session"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  owns "$root" "$home" && fail "a dead session must not own supervision"

  # The pull-guard verdict tolerates the extension's own hand-off only with the proof.
  sleep 60 &
  pid=$!
  root="$TMP_ROOT/own-verdict/root"; home="$TMP_ROOT/own-verdict/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the verdict session"
  touch "$home/state/.last-watcher-beat"
  local verdict
  verdict=$(FM_SUPERVISION_MODEL=extension FM_HOME="$home" bash -c '
    . "$1"; fm_watcher_supervision_verdict "$2" "$3" 999 "$4" "$5"; printf "%s %s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root/bin/fm-watch.sh" "$home" "$root")
  [ "${verdict%% *}" = true ] || fail "an unheld lock with a fresh beacon and the omp proof must be healthy, got '$verdict'"
  rm -f "$home/state/.omp-turnend-extension-loaded"
  verdict=$(FM_SUPERVISION_MODEL=extension FM_HOME="$home" bash -c '
    . "$1"; fm_watcher_supervision_verdict "$2" "$3" 999 "$4" "$5"; printf "%s %s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root/bin/fm-watch.sh" "$home" "$root")
  [ "$verdict" = "false no-watcher" ] || fail "without the proof the same hand-off must alarm as no-watcher, got '$verdict'"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "fm-wake-lib: the omp ownership proof is keyed on its own extensions and gates the hand-off tolerance"
}

# --- 6. The tracked primary extensions over a fake omp API ----------------------

install_omp_extension_fixture() {  # <repo>
  local repo=$1
  mkdir -p "$repo/.omp/extensions" "$repo/.pi/extensions/lib" "$repo/bin" "$repo/node_modules/typebox"
  cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$repo/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
  chmod +x "$repo/bin/fm-operational-input.sh"
  printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/typebox/package.json"
  printf 'export const Type = { Object(p) { return { type: "object", properties: p }; } };\n' > "$repo/node_modules/typebox/index.js"
}

test_turnend_guard_extension_compels_one_continuation() {
  local repo home out status
  repo="$TMP_ROOT/guard/repo"; home="$TMP_ROOT/guard/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat); printf '%s\n' "$payload" >> "${FM_GUARD_LOG:?}"
case "$payload" in *'"stop_hook_active":true'*) exit 0 ;; esac
printf 'guard says: repair with fm_watch_arm_omp\n' >&2; exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-watch-arm.sh*'&'*) printf 'fm watcher-arm seatbelt: blocked\n' >&2; exit 2 ;; esac; exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-cd-pretool-check.sh"
  # shellcheck disable=SC2016 # $2 expands in the generated script
  printf '#!/usr/bin/env bash\nprintf "OMP DIGEST source=%%s\\n" "$2"\n' > "$repo/bin/fm-sessionstart-run.sh"
  chmod +x "$repo/bin/"*.sh
  out=$(FM_GUARD_LOG="$TMP_ROOT/guard/guard.log" FM_HOME="$home" EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, existsSync } from "node:fs";
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
for (const name of ["session_start", "before_agent_start", "session_compact", "session_shutdown", "tool_call", "session_stop"]) {
  if (!handlers.has(name)) throw new Error(`${name} handler was not registered`);
}
if (handlers.has("agent_settled")) throw new Error("omp guard must not listen for agent_settled");
const ctx = { sessionManager: { getSessionId: () => "s1" } };
handlers.get("session_start")({ type: "session_start" }, ctx);
const first = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!first?.message?.content?.includes("FIRSTMATE_OP: v1 session-start: OMP DIGEST source=startup")) throw new Error(`first start did not deliver a startup digest: ${JSON.stringify(first)}`);
if (first.message.display !== false || first.message.customType !== "firstmate-sessionstart-nudge") throw new Error("digest message lost its persistent shape");
// A later in-process session_start is a replacement and maps to clear.
handlers.get("session_start")({ type: "session_start" }, ctx);
const second = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!second?.message?.content?.includes("source=clear")) throw new Error(`in-process replacement did not map to clear: ${JSON.stringify(second)}`);
const allowed = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "ls" } }, {});
if (allowed.block) throw new Error("an ordinary command was blocked");
const blocked = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "bin/fm-watch-arm.sh &" } }, {});
if (blocked.block !== true || !blocked.reason.includes("seatbelt")) throw new Error(`backgrounded arm was not blocked: ${JSON.stringify(blocked)}`);
const r1 = await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: false }, {});
if (r1?.continue !== true) throw new Error(`guard exit 2 did not compel a continuation: ${JSON.stringify(r1)}`);
if (!r1.additionalContext.startsWith("⁣FIRSTMATE_OP: v1 turn-end-guard: ")) throw new Error(`continuation context is not typed operational input: ${r1.additionalContext}`);
if (!r1.additionalContext.includes("TURN WOULD END BLIND") || !r1.additionalContext.includes("repair with fm_watch_arm_omp")) throw new Error("continuation dropped the guard text");
const r2 = await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: true }, {});
if (r2 !== undefined) throw new Error(`the flagged second stop must stand down, got ${JSON.stringify(r2)}`);
const payloads = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n");
if (payloads.join("|") !== '{"stop_hook_active":false}|{"stop_hook_active":true}') throw new Error(`guard payloads were ${payloads.join("|")}`);
if (!existsSync(`${process.env.FM_HOME}/state/.omp-turnend-extension-loaded`)) throw new Error("loaded marker was not written");
await handlers.get("session_shutdown")({}, {});
EOF
)
  status=$?
  expect_code 0 "$status" "omp turn-end guard extension contract: $out"
  [ -z "$out" ] || fail "omp guard extension test printed output: $out"
  pass ".omp turn-end guard: digest delivery, seatbelt block, one compelled continuation, flagged stop stands down"
}

test_watch_extension_arms_and_delivers() {
  local repo home out status
  repo="$TMP_ROOT/watch/repo"; home="$TMP_ROOT/watch/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # The first arm child closes with one actionable reason; every successor
  # stays up, so exactly one wake exists to consume.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
if [ ! -e "${FM_HOME:?}/state/.e2e-fired" ]; then
  : > "$FM_HOME/state/.e2e-fired"
  sleep 1
  printf 'signal: omp-e2e done\n'
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, existsSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; let command = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand(n, o) { if (n === "fm-watch-arm-omp") command = o.handler; },
  registerTool(t) { tool = t; },
  // omp sendUserMessage returns synchronously, not a promise.
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
if (!tool || tool.name !== "fm_watch_arm_omp") throw new Error("fm_watch_arm_omp was not registered");
if (!command) throw new Error("/fm-watch-arm-omp was not registered");
if (tool.parameters?.type !== "object") throw new Error("tool parameters must be an empty object schema");
const result = await tool.execute();
if (!/^watcher: started omp extension arm child 1;/.test(result.content[0].text)) throw new Error(`unexpected arm result: ${result.content[0].text}`);
const marker = readFileSync(`${process.env.FM_HOME}/state/.omp-watch-extension-loaded`, "utf8").split("\n");
if (marker[1] !== String(process.pid)) throw new Error("loaded marker must record the session pid");
const again = await tool.execute();
if (!/^watcher: unchanged - omp extension already owns an arm child/.test(again.content[0].text)) throw new Error(`redundant arm was not an ownership no-op: ${again.content[0].text}`);
await new Promise((r) => setTimeout(r, 2500));
if (sent.length !== 1) throw new Error(`expected one follow-up wake, saw ${sent.length}: ${JSON.stringify(sent)}`);
if (!sent[0].m.startsWith("⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: omp-e2e done")) throw new Error(`unexpected wake text: ${sent[0].m}`);
if (sent[0].o?.deliverAs !== "followUp") throw new Error("wake must be delivered as a follow-up");
// The wake is consumed when omp starts the next run with that exact prompt.
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
await handlers.get("session_shutdown")({}, {});
if (existsSync(`${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`)) throw new Error("a consumed wake must not ride the replacement handoff");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension contract: $out"
  [ -z "$out" ] || fail "omp watch extension test printed output: $out"
  pass ".omp watch extension: fm_watch_arm_omp arms once, repeats as a no-op, and delivers an actionable close as one follow-up"
}

test_watch_extension_helper_session_leaves_owner_live() {
  local repo home out status
  repo="$TMP_ROOT/watch-helper/repo"; home="$TMP_ROOT/watch-helper/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.EXT).href);
// omp binds the factory once per session in one process: the owner, then an
// in-process task subagent, then (after the owner ends) a replacement.
function bind() {
  const s = { handlers: new Map(), tool: null };
  mod.default({
    on(e, h) { s.handlers.set(e, h); },
    registerCommand() {},
    registerTool(t) { s.tool = t; },
    sendUserMessage() {},
  });
  return s;
}
const arm = async (s) => (await s.tool.execute()).content[0].text;
const owner = bind();
await owner.handlers.get("session_start")({}, {});
let text = await arm(owner);
if (!/^watcher: unchanged - omp extension already owns an arm child/.test(text)) throw new Error(`owner session_start did not arm: ${text}`);
const helper = bind();
await helper.handlers.get("session_start")({}, {});
text = await arm(owner);
if (!/^watcher: unchanged - omp extension already owns an arm child/.test(text)) throw new Error(`a helper session_start displaced the owner: ${text}`);
text = await arm(helper);
if (!/^watcher: unchanged - another live omp session in this process owns the watcher$/.test(text)) throw new Error(`a helper session must stay inert without claiming to shut down: ${text}`);
await helper.handlers.get("session_shutdown")({}, {});
text = await arm(owner);
if (!/^watcher: unchanged - omp extension already owns an arm child/.test(text)) throw new Error(`a helper session_shutdown stopped the owner: ${text}`);
// A genuine replacement still hands off once the owner shuts down.
await owner.handlers.get("session_shutdown")({}, {});
if (!/^watcher: not armed - omp session is shutting down$/.test(await arm(owner))) throw new Error("the retired owner kept the watcher");
const replacement = bind();
await replacement.handlers.get("session_start")({}, {});
text = await arm(replacement);
if (!/^watcher: unchanged - omp extension already owns an arm child/.test(text)) throw new Error(`the replacement did not take over: ${text}`);
// The diagnostic log records the start and stop of every session with its role.
const log = readFileSync(`${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-generations.log`, "utf8")
  .trim().split("\n").map((line) => line.replace(/^\S+ pid=\d+ /, ""));
const expected = [
  "instance=1/1 gen=1 load owner",
  "instance=1/1 gen=1 session_start owner",
  "instance=2/2 gen=2 load inert",
  "instance=2/2 gen=2 session_start inert",
  "instance=2/2 gen=2 session_shutdown inert",
  "instance=1/2 gen=1 session_shutdown owner",
  "instance=3/3 gen=3 load owner",
  "instance=3/3 gen=3 session_start owner",
];
if (JSON.stringify(log) !== JSON.stringify(expected)) throw new Error(`session log mismatch:\n${log.join("\n")}`);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension helper-session contract: $out"
  [ -z "$out" ] || fail "omp watch helper-session test printed output: $out"
  pass ".omp watch extension: an in-process helper session's start and shutdown leave the owner armed and are logged as inert; a genuine replacement still takes over"
}

# The omp primary on 2026-10-05: a nested omp the session ran from its own
# home (fm-spawn's `omp models --json` probe at every omp dispatch) auto-loaded
# both tracked extensions, walked up to the lock-owning session, and rewrote
# both loaded-build markers with its own short-lived pid. That broke
# fm_omp_extension_owns_supervision, so every ordinary watcher hand-off read
# as "WATCHER DOWN". A descendant of the lock owner must leave the session's
# markers alone, while the lock owner itself still records them.
test_nested_omp_process_keeps_the_session_markers() {
  local repo home out
  repo="$TMP_ROOT/nested-markers/repo"; home="$TMP_ROOT/nested-markers/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # shellcheck disable=SC2016 # expanded by the inner bash, which stands in for the session
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" REPO="$repo" LIB="$ROOT/bin/fm-wake-lib.sh" bash -c '
    . "$LIB"
    state=$FM_HOME/state
    printf "%s\n" "$$" > "$state/.lock"
    for pair in fm-primary-omp-watch.ts:.omp-watch-extension-loaded fm-primary-turnend-guard.ts:.omp-turnend-extension-loaded; do
      printf "%s\n%s\n" "$(fm_pi_extension_version "$REPO/.omp/extensions/${pair%%:*}")" "$$" > "$state/${pair#*:}"
    done
    fm_omp_extension_owns_supervision "$state" "$REPO" || { echo "fixture proof did not hold"; exit 1; }
    # A nested process under the session loads both extensions, as omp does.
    node --input-type=module -e "
      const { pathToFileURL } = await import(\"node:url\");
      const pi = { on() {}, registerCommand() {}, registerTool() {}, sendUserMessage() {} };
      for (const f of [\"fm-primary-omp-watch.ts\", \"fm-primary-turnend-guard.ts\"]) {
        (await import(pathToFileURL(process.env.REPO + \"/.omp/extensions/\" + f).href)).default(pi);
      }
      process.exit(0);
    " || { echo "nested load failed"; exit 1; }
    fm_omp_extension_owns_supervision "$state" "$REPO" && echo nested-kept || echo "nested-clobbered: $(sed -n 2p "$state/.omp-watch-extension-loaded") $(sed -n 2p "$state/.omp-turnend-extension-loaded") lock=$$"
  ' 2>&1)
  [ "$out" = nested-kept ] || fail "a nested omp process under the lock owner must not rewrite the session's markers: $out"
  pass ".omp extensions: a nested omp process under the lock-owning session leaves its loaded-build markers and ownership proof intact"
}

# A nested omp under the session also fires session_start and exposes
# fm_watch_arm_omp; through an ancestor walk either one would start
# fm-watch-arm.sh --restart, replacing the session's watcher with one parented
# to the short-lived nested process. Only the lock-holding process may arm.
test_nested_omp_process_never_arms() {
  local repo home out launches
  repo="$TMP_ROOT/nested-arm/repo"; home="$TMP_ROOT/nested-arm/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PPID" >> "${FM_HOME:?}/state/.arm-launches"
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # shellcheck disable=SC2016 # expanded by the inner bash, which stands in for the session
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" bash -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    node --input-type=module -e "
      const { pathToFileURL } = await import(\"node:url\");
      const { readFileSync } = await import(\"node:fs\");
      const lockPid = readFileSync(process.env.FM_HOME + \"/state/.lock\", \"utf8\").trim();
      if (lockPid === String(process.pid)) { console.log(\"not nested: node holds the lock pid \" + lockPid); process.exit(1); }
      const handlers = new Map(); let tool = null;
      const pi = { on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool(t) { tool = t; }, sendUserMessage() {} };
      (await import(pathToFileURL(process.env.EXT).href)).default(pi);
      await handlers.get(\"session_start\")({}, {});
      console.log((await tool.execute()).content[0].text);
      await handlers.get(\"session_shutdown\")({}, {});
      process.exit(0);
    " || exit 1
    exit 0
  ' 2>&1)
  [ "$out" = "watcher: read-only - session lock is held by another firstmate session" ] \
    || fail "a nested omp process under the lock owner must refuse to arm: $out"
  [ ! -e "$home/state/.arm-launches" ] || fail "a nested omp process started an arm child: $(cat "$home/state/.arm-launches")"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool() {}, sendUserMessage() {} };
(await import(pathToFileURL(process.env.EXT).href)).default(pi);
await handlers.get("session_start")({}, {});
for (let i = 0; i < 150 && !existsSync(`${process.env.FM_HOME}/state/.arm-launches`); i += 1) await new Promise((r) => setTimeout(r, 20));
const launches = readFileSync(`${process.env.FM_HOME}/state/.arm-launches`, "utf8").trim().split("\n");
if (launches.length !== 1 || launches[0] !== String(process.pid)) throw new Error(`the lock owner did not arm exactly once: ${launches}`);
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  [ -z "$out" ] || fail "the lock-owning omp process did not arm on session_start: $out"
  launches=$(wc -l < "$home/state/.arm-launches" | tr -d ' ')
  [ "$launches" = 1 ] || fail "expected one arm launch from the lock owner, saw $launches"
  pass ".omp watch extension: a nested omp process under the lock-owning session never starts an arm child, while the lock owner arms"
}

# One restart round of the replacement-handoff replay contract against the real
# extension: session 1 receives one actionable close per <wakes> entry, each
# after its watcher queued the durable row under the shared pending recovery
# generation (as bin/fm-watch.sh does), never consumes the follow-ups, and shuts
# down, persisting the handoff. <ack-through> is the highest sequence the
# handling turn acknowledged before the restart (0 for none); like
# fm-wake-drain.sh --ack-through it removes those rows and leaves the generation
# pending while any row remains. Sessions 2 and 3 are fresh processes (a
# reboot); each prints how many times each wake was re-delivered ("A,B") and
# consumes what it got, so session 3 proves a replay happens at most once.
run_omp_restart_replay() {  # <dir> <ack-through> <wakes: "seq:label ...">
  local dir=$1 ack=$2 wakes=$3 repo home wake planned=0
  repo="$dir/repo"; home="$dir/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  printf 'pending:downtime:gen-G\n' > "$home/state/.watcher-down"
  : > "$home/state/.e2e-plan"
  for wake in $wakes; do
    printf '%s\t%s\n' "${wake%%:*}" "${wake#*:}" >> "$home/state/.e2e-plan"
    planned=$((planned + 1))
  done
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
# The extension's synchronous handling-delivery confirmation must not consume
# the next planned close meant for the successor arm.
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-G\n' "$$"
plan="${FM_HOME:?}/state/.e2e-plan"
next=$(head -n 1 "$plan")
if [ -n "$next" ]; then
  tail -n +2 "$plan" > "$plan.tmp" && mv "$plan.tmp" "$plan"
  sleep 1
  seq=${next%%$'\t'*}; label=${next#*$'\t'}
  printf '%s\n' "$seq" > "$FM_HOME/state/.wake-queue.seq"
  printf '1700000000\t%s\tsignal\treplay.%s\tsignal: omp-replay %s done\n' "$seq" "$label" "$label" >> "$FM_HOME/state/.wake-queue"
  printf 'signal: omp-replay %s done\n' "$label"
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  cat > "$dir/session.mjs" <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); const sent = [];
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default({
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(m) { sent.push(m); return undefined; },
});
await handlers.get("session_start")({}, {});
// Wait until EXPECT wakes arrived (a slow host must not drop a late re-arm),
// or WAIT_MS elapsed when asserting that nothing more arrives.
const delivered = () => sent.filter((m) => /signal: omp-replay [AB] done/.test(m));
const deadline = Date.now() + Number(process.env.WAIT_MS);
while (Date.now() < deadline && !(Number(process.env.EXPECT) > 0 && delivered().length >= Number(process.env.EXPECT))) {
  await new Promise((r) => setTimeout(r, 50));
}
const wakes = delivered();
if (process.env.CONSUME === "1") {
  for (const m of wakes) await handlers.get("before_agent_start")({ prompt: m }, {});
}
await handlers.get("session_shutdown")({}, {});
const count = (label) => wakes.filter((m) => m.includes(`omp-replay ${label} done`)).length;
process.stdout.write(`${count("A")},${count("B")}`);
process.exit(0);
EOF
  omp_replay_session() {  # <consume> <wait-ms> [expected-wakes]
    FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 \
      FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
      EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" CONSUME="$1" WAIT_MS="$2" EXPECT="${3:-0}" node "$dir/session.mjs" 2>&1
  }
  OMP_REPLAY_FIRST=$(omp_replay_session 0 30000 "$planned")
  OMP_REPLAY_HANDOFF=absent
  [ -e "$home/state/extensions/omp-primary-watch/session-replacement-actionable.json" ] && OMP_REPLAY_HANDOFF=present
  awk -F '\t' -v cutoff="$ack" '$2 > cutoff' "$home/state/.wake-queue" > "$home/state/.wake-queue.ack"
  mv "$home/state/.wake-queue.ack" "$home/state/.wake-queue"
  [ -s "$home/state/.wake-queue" ] || printf 'acked:downtime:gen-G\n' > "$home/state/.watcher-down"
  OMP_REPLAY_SECOND=$(omp_replay_session 1 1500)
  OMP_REPLAY_THIRD=$(omp_replay_session 1 1500)
  OMP_REPLAY_LEFTOVER=absent
  [ -e "$home/state/extensions/omp-primary-watch/session-replacement-actionable.json" ] && OMP_REPLAY_LEFTOVER=present
}

test_watch_extension_restart_skips_acknowledged_handoff() {
  run_omp_restart_replay "$TMP_ROOT/watch-replay-acked" 7 "7:A"
  [ "$OMP_REPLAY_FIRST" = 1,0 ] || fail "session 1 must deliver the close once before the restart, got '$OMP_REPLAY_FIRST'"
  [ "$OMP_REPLAY_HANDOFF" = present ] || fail "an unconsumed close must ride the replacement handoff across shutdown"
  [ "$OMP_REPLAY_SECOND" = 0,0 ] || fail "a close whose queued wake was acknowledged before the restart must not be replayed, saw '$OMP_REPLAY_SECOND'"
  [ "$OMP_REPLAY_THIRD" = 0,0 ] || fail "an acknowledged close must stay unreplayed on a later restart, saw '$OMP_REPLAY_THIRD'"
  [ "$OMP_REPLAY_LEFTOVER" = absent ] || fail "a skipped acknowledged close must be retired from the handoff file"
  pass ".omp watch extension: after a restart, a handed-off close whose queued wake was already acknowledged is not replayed"
}

test_watch_extension_restart_replays_unacknowledged_handoff_once() {
  run_omp_restart_replay "$TMP_ROOT/watch-replay-unacked" 0 "7:A"
  [ "$OMP_REPLAY_FIRST" = 1,0 ] || fail "session 1 must deliver the close once before the restart, got '$OMP_REPLAY_FIRST'"
  [ "$OMP_REPLAY_HANDOFF" = present ] || fail "an unconsumed close must ride the replacement handoff across shutdown"
  [ "$OMP_REPLAY_SECOND" = 1,0 ] || fail "a close whose queued wake is still unacknowledged must be replayed exactly once after the restart, saw '$OMP_REPLAY_SECOND'"
  [ "$OMP_REPLAY_THIRD" = 0,0 ] || fail "a replayed and consumed close must not be replayed again, saw '$OMP_REPLAY_THIRD'"
  [ "$OMP_REPLAY_LEFTOVER" = absent ] || fail "a consumed replay must be retired from the handoff file"
  pass ".omp watch extension: after a restart, a handed-off close whose queued wake is still unacknowledged is replayed exactly once"
}

test_watch_extension_restart_decides_replay_per_wake_within_one_generation() {
  run_omp_restart_replay "$TMP_ROOT/watch-replay-shared-generation" 7 "7:A 8:B"
  [ "$OMP_REPLAY_FIRST" = 1,1 ] || fail "session 1 must deliver both closes once before the restart, got '$OMP_REPLAY_FIRST'"
  [ "$OMP_REPLAY_HANDOFF" = present ] || fail "unconsumed closes must ride the replacement handoff across shutdown"
  [ "$OMP_REPLAY_SECOND" = 0,1 ] || fail "after --ack-through 7 under a still-pending shared generation, only the close for row 8 may replay, saw '$OMP_REPLAY_SECOND'"
  [ "$OMP_REPLAY_THIRD" = 0,0 ] || fail "neither close may replay again on a later restart, saw '$OMP_REPLAY_THIRD'"
  [ "$OMP_REPLAY_LEFTOVER" = absent ] || fail "both closes must be retired from the handoff file"
  pass ".omp watch extension: closes sharing one pending recovery generation replay per wake, so acknowledging row 7 replays only row 8"
}

# An arm fixture that closes each row of state/.e2e-plan in turn
# (<seq>\t<reason>), appending its wake row first like the real watcher, and
# waits for the next row once the plan is empty.
write_omp_plan_arm_fixture() {  # <repo>
  cat > "$1/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-H\n' "$$"
plan="${FM_HOME:?}/state/.e2e-plan"
for _ in $(seq 300); do [ -s "$plan" ] && break; sleep 0.1; done
next=$(head -n 1 "$plan")
[ -n "$next" ] || exit 0
tail -n +2 "$plan" > "$plan.tmp" && mv "$plan.tmp" "$plan"
sleep 0.3
seq=${next%%$'\t'*}; reason=${next#*$'\t'}
printf '%s\n' "$seq" > "$FM_HOME/state/.wake-queue.seq"
printf '1700000000\t%s\tstale\tkey%s\t%s\n' "$seq" "$seq" "$reason" >> "$FM_HOME/state/.wake-queue"
printf '%s\n' "$reason"
SH
  chmod +x "$1/bin/fm-watch-arm.sh"
}

# The 2026-10-05 ghost-wake shape: a main turn ended in a provider error, so
# omp parked wake A unconsumed. A later close B must still reach omp at once as
# a follow-up, because each new follow-up is what retries omp's parked drain.
test_watch_extension_sends_wake_while_earlier_one_is_parked() {
  local dir repo home out status
  dir="$TMP_ROOT/watch-parked"; repo="$dir/repo"; home="$dir/home"
  install_omp_extension_fixture "$repo"
  write_omp_plan_arm_fixture "$repo"
  mkdir -p "$home/state"
  printf '7\tcheck: omp-parked A ready\n8\tcheck: omp-parked B ready\n' > "$home/state/.e2e-plan"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 \
    FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); const sent = [];
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default({
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(m, options) { sent.push({ m, deliverAs: options?.deliverAs }); return undefined; },
});
await handlers.get("session_start")({}, {});
const deadline = Date.now() + 20000;
while (Date.now() < deadline && sent.length < 2) await new Promise((r) => setTimeout(r, 50));
await handlers.get("session_shutdown")({}, {});
if (sent.length !== 2 || !sent[0].m.includes("omp-parked A") || !sent[1].m.includes("omp-parked B")) {
  throw new Error(`B must reach omp while A is still parked, saw ${JSON.stringify(sent.map((s) => s.m.match(/omp-parked \w/)?.[0] ?? s.m))}`);
}
if (sent.some((s) => s.deliverAs !== "followUp")) throw new Error(`every wake must be a followUp: ${JSON.stringify(sent.map((s) => s.deliverAs))}`);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp parked-wake delivery: $out"
  [ -z "$out" ] || fail "omp parked-wake delivery test printed output: $out"
  pass ".omp watch extension: a close arriving while an earlier follow-up is parked unconsumed is sent to omp at once"
}

# The 2026-10-05 ghost wakes: omp hands main a stale wake for a terminal torn
# down meanwhile. The context event before the LLM call shows the model a
# no-action note only for that stale wake once main acknowledged its row; the
# same torn-down stale wake with its row still queued, a live terminal's stale
# wake, an unrecorded task's signal wake (a torn-down task's final word), and
# a check wake all reach the model unchanged, and no consumed record rides a
# replacement handoff.
test_watch_extension_context_drops_superseded_wakes() {
  local dir repo home out status
  dir="$TMP_ROOT/watch-superseded"; repo="$dir/repo"; home="$dir/home"
  install_omp_extension_fixture "$repo"
  write_omp_plan_arm_fixture "$repo"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/live.meta" "window=fm-live" "endpoint_task_id=live" "terminal=term_live" "backend=orca" "kind=ship"
  printf '7\tstale: term_gone (idle 300s, possible wedge, escalation 6)\n8\tstale: term_gone (idle 360s, possible wedge, escalation 7)\n9\tstale: term_live (idle 300s, possible wedge, escalation 1)\n10\tsignal: %s/state/ghost.status\n11\tcheck: omp-superseded C ready\n' \
    "$home" > "$home/state/.e2e-plan"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 \
    FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const handlers = new Map(); const sent = [];
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default({
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(m) { sent.push(m); return undefined; },
});
await handlers.get("session_start")({}, {});
const deadline = Date.now() + 20000;
while (Date.now() < deadline && sent.length < 5) await new Promise((r) => setTimeout(r, 50));
if (sent.length !== 5) throw new Error(`expected five wakes sent, saw ${sent.length}`);
// The drain in main acknowledged every row except 8 before omp handed the wakes over.
const rows = readFileSync(`${state}/.wake-queue`, "utf8").split("\n").filter(Boolean);
writeFileSync(`${state}/.wake-queue`, rows.filter((row) => row.split("\t")[1] === "8").map((row) => `${row}\n`).join(""));
const text = (message) => message.content.map((part) => part.text).join("\n");
const userMessage = (m, timestamp) => ({ role: "user", content: [{ type: "text", text: m }], timestamp });
const history = () => [userMessage("captain: status?", 100), ...sent.map((m, index) => userMessage(m, 101 + index))];
// omp hands the torn-down stale wake to an idle main (before_agent_start, then
// its user message_start) and the rest to a streaming main (user message_start).
for (const message of history()) {
  if (message.timestamp === 101) await handlers.get("before_agent_start")({ prompt: sent[0] }, {});
  await handlers.get("message_start")({ message }, {});
}
for (const pass of [1, 2]) {
  const result = await handlers.get("context")({ type: "context", messages: history() }, {});
  const seen = result?.messages?.map(text) ?? [];
  if (seen[0] !== "captain: status?") throw new Error(`pass ${pass}: a non-wake message changed: ${seen[0]}`);
  if (!/watcher: superseded wake dropped \(no state\/<id>\.meta records term_gone; wake row 7 already acknowledged\): stale: term_gone \(idle 300s.* - no action needed; do not run the drain for it\./.test(seen[1]) || seen[1].includes("FIRSTMATE WATCHER WAKE")) {
    throw new Error(`pass ${pass}: the acknowledged torn-down stale wake reached the model: ${seen[1]}`);
  }
  for (const [index, label] of [[2, "queued torn-down stale"], [3, "live stale"], [4, "unrecorded signal"], [5, "check"]]) {
    if (seen[index] !== sent[index - 1]) throw new Error(`pass ${pass}: the ${label} wake was changed: ${seen[index]}`);
  }
}
const triage = readFileSync(`${state}/.watch-triage.log`, "utf8").split("\n").filter(Boolean);
if (triage.length !== 1 || !triage[0].includes("stale: term_gone (idle 300s")) throw new Error(`only the acknowledged torn-down stale wake may be dropped: ${triage.join("\n")}`);
await handlers.get("session_shutdown")({}, {});
const handoff = `${state}/extensions/omp-primary-watch/session-replacement-actionable.json`;
if (existsSync(handoff)) throw new Error(`dropped and consumed wakes must not ride the replacement handoff: ${readFileSync(handoff, "utf8")}`);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp superseded-wake context: $out"
  [ -z "$out" ] || fail "omp superseded-wake context test printed output: $out"
  pass ".omp watch extension: the context event replaces only an acknowledged stale wake for a torn-down terminal and passes every other wake unchanged"
}

# The watcher repeats one stale wake text for an endpoint. A drop
# is bound to the one message omp handed over (its timestamp), so a later wake
# with identical text stays live in context and pending until its own
# consumption, riding the replacement handoff if the session ends first.
test_watch_extension_drop_binds_one_message_of_repeated_text() {
  local dir repo home out status
  dir="$TMP_ROOT/watch-twin"; repo="$dir/repo"; home="$dir/home"
  install_omp_extension_fixture "$repo"
  write_omp_plan_arm_fixture "$repo"
  mkdir -p "$home/state"
  printf '7\tstale: term_twin\n8\tstale: term_twin\n' > "$home/state/.e2e-plan"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 \
    FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const handlers = new Map(); const sent = [];
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default({
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(m) { sent.push(m); return undefined; },
});
await handlers.get("session_start")({}, {});
const deadline = Date.now() + 20000;
while (Date.now() < deadline && sent.length < 2) await new Promise((r) => setTimeout(r, 50));
if (sent.length !== 2 || sent[0] !== sent[1]) throw new Error(`expected two identical wakes, saw ${sent.length}`);
// Main acknowledged row 7 before omp handed its wake over.
const rows = readFileSync(`${state}/.wake-queue`, "utf8").split("\n").filter(Boolean);
writeFileSync(`${state}/.wake-queue`, rows.filter((row) => row.split("\t")[1] !== "7").map((row) => `${row}\n`).join(""));
const userMessage = (timestamp) => ({ role: "user", content: [{ type: "text", text: sent[0] }], timestamp });
await handlers.get("message_start")({ message: userMessage(1) }, {});
const result = await handlers.get("context")({ type: "context", messages: [userMessage(1), userMessage(2)] }, {});
const seen = (result?.messages ?? []).map((message) => message.content.map((part) => part.text).join("\n"));
if (!/watcher: superseded wake dropped \(no state\/<id>\.meta records term_twin; wake row 7 already acknowledged\)/.test(seen[0] ?? "")) throw new Error(`the acknowledged wake reached the model: ${seen[0]}`);
if (seen[1] !== sent[1]) throw new Error(`the later identical wake was rewritten: ${seen[1]}`);
await handlers.get("session_shutdown")({}, {});
const handoff = `${state}/extensions/omp-primary-watch/session-replacement-actionable.json`;
const pending = existsSync(handoff) ? JSON.parse(readFileSync(handoff, "utf8")).pending : [];
if (pending.length !== 1 || pending[0].wakeQueueSeq !== 8) throw new Error(`only the wake for row 8 may stay pending: ${JSON.stringify(pending)}`);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp repeated-text drop: $out"
  [ -z "$out" ] || fail "omp repeated-text drop test printed output: $out"
  pass ".omp watch extension: a dropped wake rewrites only its own message, and a later identical wake stays live and pending"
}

test_detection_anchored_name_and_marker_precedence
test_lock_identity_and_liveness_classification
test_detection_bun_launcher_shape
test_detection_bun_launcher_ancestry_shapes
test_detection_ompcode_marker
test_detection_leaked_ompcode_yields_to_structural_ancestry
test_lock_acquires_from_bun_launcher_ancestry
test_spawn_launch_line_and_worker_wiring
test_spawn_model_validation_scoped_to_listed_providers
test_secondmate_launch_relies_on_discovery
test_secondmate_config_pinned_model_is_validated
test_busy_extension_lifecycle
test_control_composer_and_model_tables
test_ownership_proof_is_omp_keyed
test_turnend_guard_extension_compels_one_continuation
test_watch_extension_arms_and_delivers
test_watch_extension_helper_session_leaves_owner_live
test_nested_omp_process_keeps_the_session_markers
test_nested_omp_process_never_arms
test_watch_extension_restart_skips_acknowledged_handoff
test_watch_extension_restart_replays_unacknowledged_handoff_once
test_watch_extension_restart_decides_replay_per_wake_within_one_generation
test_watch_extension_sends_wake_while_earlier_one_is_parked
test_watch_extension_context_drops_superseded_wakes
test_watch_extension_drop_binds_one_message_of_repeated_text
