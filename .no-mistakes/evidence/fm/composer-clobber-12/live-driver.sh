#!/usr/bin/env bash
# Live validation lab: the proof-gated muse post-interrupt composer clear.
#
# Drives the REAL product (bin/fm-send.sh --key Escape, bin/fm-control.sh
# interrupt) against a REAL muse 1.3.0 TUI running under a REAL tmux server on
# an isolated socket, using muse's credential-free echo provider (the same
# live-guard pattern as tests/fm-muse-signals-live-e2e.test.sh). The firstmate
# home under the lab carries the same state records fm-spawn writes
# (state/<id>.meta + state/<id>.muse-session), so target resolution, session-log
# binding, busy classification, composer extraction, key delivery, and the
# restored-prompt verdict all run for real. A tmux wrapper on PATH logs every
# send-keys the product delivers (Escape / C-u) while still exec'ing the real
# tmux server, so key delivery is real AND observable; the lab's own typing
# goes through the real binary directly and never enters that log.
set -u

ROOT=/Users/Morley/.no-mistakes/worktrees/62b3bc0be3e5/01M2MJEBHN3K1Y9N0136SVCEWA
EV=/Users/Morley/.no-mistakes/evidence/01M2MJEBHN3K1Y9N0136SVCEWA
REAL_TMUX=$(command -v tmux)
MUSE_BIN=/Users/Morley/.local/bin/muse
ECHO_DELAY=8000

mkdir -p "$EV"
LAB=$(mktemp -d "${TMPDIR%/}/fm-clear-live.XXXXXX")
SOCKET=fmclear-$$
SESSION=fmlive
ID=museclear
WINDOW=fm-$ID
TARGET=$SESSION:$WINDOW
RESULTS=$EV/results.txt
KEYLOG=$LAB/send-keys.log

mkdir -p "$LAB/config" "$LAB/data" "$LAB/home/state" "$LAB/home/data" "$LAB/bin" "$LAB/ws"
git -C "$LAB/ws" init -q
WS=$(cd "$LAB/ws" && pwd -P)

: > "$KEYLOG"
: > "$RESULTS"

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

# --- tmux wrapper: log the product's send-keys, exec the real server ---------
cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = send-keys ]; then
  printf '%s | tmux %s\n' "\$(date +%H:%M:%S)" "\$*" >> "$KEYLOG"
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/bin/tmux"

# --- firstmate home wiring (the records fm-spawn owns) -----------------------
write_binding() {
  cat > "$LAB/home/state/$ID.muse-session" <<EOF2
sessions_root=$LAB/data/muse/sessions
workspace_root=$WS
binding_id=lab.$$.1
EOF2
}
cat > "$LAB/home/state/$ID.meta" <<EOF2
window=$TARGET
backend=tmux
harness=muse
kind=ship
project=live-proof
worktree=$WS
endpoint_task_id=$ID
EOF2
write_binding

# --- product libraries (observation helpers only) -----------------------------
. "$ROOT/bin/fm-busy-lib.sh"
. "$ROOT/bin/fm-tmux-lib.sh"

# --- helpers -------------------------------------------------------------------
SESSION_LOG=
run_state() { fm_busy_muse_run_state "$SESSION_LOG" 2>/dev/null || printf unsettled; }
composer_state() { PATH="$LAB/bin:$PATH" fm_tmux_composer_state "$TARGET"; }
composer_content() { PATH="$LAB/bin:$PATH" fm_tmux_composer_content "$TARGET" 2>/dev/null || printf '(unreadable)'; }
cancel_count() { grep -c '"terminal":"cancelled"' "$SESSION_LOG" 2>/dev/null || true; }
mark() { printf '\n===== MARKER %s =====\n' "$1" >> "$KEYLOG"; }
log_slice() { sed -n "/^===== MARKER $1/,\$p" "$KEYLOG"; }
esc_in() { [ "$(log_slice "$1" | grep -c -- "send-keys -t $TARGET Escape\$")" -gt 0 ] && echo 1 || echo 0; }
cu_in() { [ "$(log_slice "$1" | grep -c -- "send-keys -t $TARGET C-u\$")" -gt 0 ] && echo 1 || echo 0; }

wait_run() { # <want> <max-secs>
  local want=$1 max=$2 i=0 got
  while [ "$i" -lt $((max * 10)) ]; do
    got=$(run_state)
    [ "$got" = "$want" ] && return 0
    i=$((i + 1)); sleep 0.1
  done
  echo "    (wait_run $want timed out; last=$(run_state))" >&2
  return 1
}
wait_composer() { # <want> <max-secs>
  local want=$1 max=$2 i=0 got
  while [ "$i" -lt $((max * 10)) ]; do
    got=$(composer_state)
    [ "$got" = "$want" ] && return 0
    i=$((i + 1)); sleep 0.1
  done
  echo "    (wait_composer $want timed out; last=$(composer_state))" >&2
  return 1
}
type_literal() { "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "$1"; }
press() { "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" "$1"; }
submit_prompt() { # <text>
  type_literal "$1"
  sleep 0.3
  press Enter
}
start_run() { # <prompt> - submit and wait until the run is in flight
  local tries=0
  while [ "$tries" -lt 3 ]; do
    wait_run settled 25 || true
    press C-u
    sleep 0.4
    submit_prompt "$1"
    wait_run busy 8 && return 0
    tries=$((tries + 1))
  done
  return 1
}
reset_composer() { press C-u; sleep 0.4; }
capture_pane() { # <name>
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -80 > "$EV/pane-$1.txt"
  "$REAL_TMUX" -L "$SOCKET" capture-pane -e -p -t "$TARGET" -S -80 > "$EV/pane-$1.ansi"
}

FAILURES=0
check() { # <scenario> <description> <ok: 1 pass, 0 fail> <detail>
  if [ "$3" = 1 ]; then
    printf 'ok - %s: %s\n' "$1" "$2" >> "$RESULTS"
  else
    printf 'not ok - %s: %s (%s)\n' "$1" "$2" "$4" >> "$RESULTS"
    FAILURES=$((FAILURES + 1))
  fi
}
has() { # <haystack> <needle> -> 1|0
  case "$1" in *"$2"*) echo 1 ;; *) echo 0 ;; esac
}

run_fmsend_escape() { # <tag>
  PATH="$LAB/bin:$PATH" \
  FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$ROOT" FM_GATE_REFUSE_BYPASS=1 \
    "$ROOT/bin/fm-send.sh" "$ID" --key Escape >"$EV/$1.out" 2>&1
}
run_fmcontrol_interrupt() { # <tag>
  PATH="$LAB/bin:$PATH" \
  FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$ROOT" FM_GATE_REFUSE_BYPASS=1 \
    "$ROOT/bin/fm-control.sh" "$ID" interrupt >"$EV/$1.out" 2>&1
}

# scenario driver: one retry when the echo turn races the interrupt
# records the cancel-count delta under $EV/<tag>.cancel for later assertions
drive() { # <tag> <prompt> <pre-act-shell> <act-shell>
  local tag=$1 prompt=$2 pre=$3 act=$4 before after rc=0 attempt=0 ok=0
  while [ "$attempt" -lt 2 ] && [ "$ok" = 0 ]; do
    attempt=$((attempt + 1))
    before=$(cancel_count)
    mark "$tag-attempt$attempt"
    if ! start_run "$prompt"; then
      echo "    (start_run failed for $tag)" >&2
      printf '0 0' > "$EV/$tag.cancel"
      return 1
    fi
    sleep 0.5
    [ -z "$pre" ] || eval "$pre"
    eval "$act"
    rc=$?
    after=$(cancel_count)
    [ "$after" -gt "$before" ] && ok=1
    [ "$ok" = 1 ] || echo "    (interrupt raced the echo turn for $tag attempt $attempt; retrying)" >&2
  done
  printf '%s %s' "$before" "$after" > "$EV/$tag.cancel"
  return "$rc"
}
cancel_proved() { # <tag> -> 1|0  (did the session log gain a cancelled run)
  local after=0
  read -r _ after < "$EV/$1.cancel" 2>/dev/null || true
  [ "${after:-0}" -gt 0 ] && echo 1 || echo 0
}

# --- launch real muse ----------------------------------------------------------
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -x 200 -y 50 -c "$WS"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$WINDOW" -c "$WS" -- \
  env XDG_CONFIG_HOME="$LAB/config" XDG_DATA_HOME="$LAB/data" \
  MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on \
  "$MUSE_BIN" --provider echo --echo-delay-ms "$ECHO_DELAY" --yolo \
  "live proof alpha: describe this repository in one line"

for i in $(seq 1 150); do
  SESSION_LOG=$(fm_busy_muse_matching_logs "$LAB/data/muse/sessions" "$WS" 2>/dev/null | head -1)
  [ -n "$SESSION_LOG" ] && break
  sleep 0.2
done
if [ -z "$SESSION_LOG" ]; then
  printf 'FATAL: real muse produced no workspace-bound session.jsonl\n' | tee -a "$RESULTS"
  exit 1
fi
printf 'lab: socket=%s target=%s\nmuse: %s\ntmux: %s\nworkspace: %s\nsession log: %s\n\n' \
  "$SOCKET" "$TARGET" "$("$MUSE_BIN" --version | head -1)" "$("$REAL_TMUX" -V)" "$WS" "$SESSION_LOG" >> "$RESULTS"

# ===============================================================================
# A1: fm-send --key Escape clears a PROVEN restored prompt
# ===============================================================================
tag=A1-fmsend-restored-cleared
rc=0
drive "$tag" "live proof alpha again: describe this repository in one line" \
  "" "run_fmsend_escape $tag" || rc=$?
sleep 0.5
out=$(cat "$EV/$tag.out")
check "$tag" "exit 0" "$([ $rc -eq 0 ] && echo 1 || echo 0)" "rc=$rc out=$out"
check "$tag" "Escape was delivered to the real pane" "$(esc_in "$tag-attempt")" "delivery log slice had no Escape"
check "$tag" "C-u clear fired (verdict was restored)" "$(cu_in "$tag-attempt")" "delivery log slice had no C-u"
check "$tag" "no skip warning" "$([ "$(has "$out" 'left untouched')" = 0 ] && echo 1 || echo 0)" "unexpected skip warning: $out"
check "$tag" "composer is empty after the clear" "$([ "$(composer_state)" = empty ] && echo 1 || echo 0)" "state=$(composer_state)"
check "$tag" "the session log records the cancelled run" "$(cancel_proved "$tag")" "no cancelled terminal event"
capture_pane "$tag"

# ===============================================================================
# A2: fm-send --key Escape PRESERVES fresh typed input
# ===============================================================================
reset_composer
tag=A2-fmsend-fresh-preserved
rc=0
drive "$tag" "live proof bravo: summarize the changes" \
  "type_literal 'URGENT captain note: keep this text'" \
  "run_fmsend_escape $tag" || rc=$?
sleep 0.5
out=$(cat "$EV/$tag.out")
content=$(composer_content)
check "$tag" "exit 0 (interrupt delivered, clear skipped)" "$([ $rc -eq 0 ] && echo 1 || echo 0)" "rc=$rc out=$out"
check "$tag" "Escape was delivered" "$(esc_in "$tag-attempt")" "delivery log slice had no Escape"
check "$tag" "NO C-u was sent" "$([ "$(cu_in "$tag-attempt")" = 0 ] && echo 1 || echo 0)" "C-u appeared in delivery log"
check "$tag" "warned the composer was left untouched" "$(has "$out" 'left untouched')" "warning missing: $out"
check "$tag" "fresh captain text still in composer" "$(has "$content" 'URGENT captain note')" "content=[$content]"
check "$tag" "composer classifies pending" "$([ "$(composer_state)" = pending ] && echo 1 || echo 0)" "state=$(composer_state)"
check "$tag" "the session log records the cancelled run" "$(cancel_proved "$tag")" "no cancelled terminal event"
capture_pane "$tag"
reset_composer

# ===============================================================================
# A3: fm-send --key Escape skips the clear when the restore is unprovable
# ===============================================================================
tag=A3-fmsend-unprovable-skip
mv "$LAB/home/state/$ID.muse-session" "$LAB/binding.saved"
rc=0
drive "$tag" "live proof charlie: list open questions" \
  "" "run_fmsend_escape $tag" || rc=$?
sleep 0.5
out=$(cat "$EV/$tag.out")
mv "$LAB/binding.saved" "$LAB/home/state/$ID.muse-session"
check "$tag" "exit 0" "$([ $rc -eq 0 ] && echo 1 || echo 0)" "rc=$rc out=$out"
check "$tag" "Escape was delivered" "$(esc_in "$tag-attempt")" "delivery log slice had no Escape"
check "$tag" "NO C-u was sent" "$([ "$(cu_in "$tag-attempt")" = 0 ] && echo 1 || echo 0)" "C-u appeared in delivery log"
check "$tag" "warned the restore cannot be proven" "$(has "$out" 'cannot be proven')" "warning missing: $out"
check "$tag" "the session log records the cancelled run" "$(cancel_proved "$tag")" "no cancelled terminal event"
capture_pane "$tag"
reset_composer

# ===============================================================================
# B1: fm-control interrupt PRESERVES fresh typed input
# ===============================================================================
tag=B1-fmcontrol-fresh-preserved
rc=0
drive "$tag" "live proof delta: review the failing tests" \
  "type_literal 'URGENT captain note: keep this too'" \
  "run_fmcontrol_interrupt $tag" || rc=$?
sleep 0.5
out=$(cat "$EV/$tag.out")
content=$(composer_content)
check "$tag" "exit 0" "$([ $rc -eq 0 ] && echo 1 || echo 0)" "rc=$rc out=$out"
check "$tag" "interrupt-delivered with cancel=confirmed" "$([ "$(has "$out" 'interrupt-delivered')" = 1 ] && [ "$(has "$out" 'cancel=confirmed')" = 1 ] && echo 1 || echo 0)" "out=$out"
check "$tag" "Escape was delivered" "$(esc_in "$tag-attempt")" "delivery log slice had no Escape"
check "$tag" "NO C-u was sent" "$([ "$(cu_in "$tag-attempt")" = 0 ] && echo 1 || echo 0)" "C-u appeared in delivery log"
check "$tag" "warned the composer holds other text" "$(has "$out" 'left untouched')" "warning missing: $out"
check "$tag" "fresh captain text still in composer" "$(has "$content" 'URGENT captain note')" "content=[$content]"
capture_pane "$tag"
reset_composer

# ===============================================================================
# B2: fm-control interrupt REFUSES on an unprovable composer (loud failure)
# ===============================================================================
tag=B2-fmcontrol-unprovable-refuses
mv "$LAB/home/state/$ID.muse-session" "$LAB/binding.saved"
rc=0
drive "$tag" "live proof echo: draft a migration note" \
  "" "run_fmcontrol_interrupt $tag" || rc=$?
sleep 0.5
out=$(cat "$EV/$tag.out")
mv "$LAB/binding.saved" "$LAB/home/state/$ID.muse-session"
check "$tag" "exit nonzero (loud refusal)" "$([ $rc -ne 0 ] && echo 1 || echo 0)" "rc=$rc"
check "$tag" "Escape was delivered first" "$(esc_in "$tag-attempt")" "delivery log slice had no Escape"
check "$tag" "NO C-u was sent" "$([ "$(cu_in "$tag-attempt")" = 0 ] && echo 1 || echo 0)" "C-u appeared in delivery log"
check "$tag" "refusal names the unproven restore" "$(has "$out" 'cannot be proven')" "out=$out"
capture_pane "$tag"
reset_composer

# ===============================================================================
# B3: fm-control interrupt clears a PROVEN restored prompt
# ===============================================================================
tag=B3-fmcontrol-restored-cleared
rc=0
drive "$tag" "live proof foxtrot: check the build status" \
  "" "run_fmcontrol_interrupt $tag" || rc=$?
sleep 0.5
out=$(cat "$EV/$tag.out")
check "$tag" "exit 0" "$([ $rc -eq 0 ] && echo 1 || echo 0)" "rc=$rc out=$out"
check "$tag" "interrupt-delivered with cancel=confirmed" "$([ "$(has "$out" 'interrupt-delivered')" = 1 ] && [ "$(has "$out" 'cancel=confirmed')" = 1 ] && echo 1 || echo 0)" "out=$out"
check "$tag" "Escape was delivered" "$(esc_in "$tag-attempt")" "delivery log slice had no Escape"
check "$tag" "C-u clear fired (verdict was restored)" "$(cu_in "$tag-attempt")" "delivery log slice had no C-u"
check "$tag" "composer is empty after the clear" "$([ "$(composer_state)" = empty ] && echo 1 || echo 0)" "state=$(composer_state)"
capture_pane "$tag"

# ===============================================================================
# C1: a restored prompt with REPEATED SPACES still proves restored
# ===============================================================================
tag=C1-whitespace-restored-cleared
rc=0
drive "$tag" "fix  the  flaky  login  flow  before  the  release" \
  "" "run_fmsend_escape $tag" || rc=$?
sleep 0.5
out=$(cat "$EV/$tag.out")
check "$tag" "exit 0" "$([ $rc -eq 0 ] && echo 1 || echo 0)" "rc=$rc out=$out"
check "$tag" "C-u clear fired despite double spaces" "$(cu_in "$tag-attempt")" "delivery log slice had no C-u"
check "$tag" "composer is empty after the clear" "$([ "$(composer_state)" = empty ] && echo 1 || echo 0)" "state=$(composer_state)"
capture_pane "$tag"

# ===============================================================================
# C2: a restored prompt longer than the capture window (wrapped restore) still
# proves restored via the suffix match
# ===============================================================================
tag=C2-wrapped-long-restored-cleared
LONG="live proof golf: the quick brown fox jumps over the lazy dog while the calm river flows past the quiet village and the patient owl watches the slow moon rise over the sleeping hills again and again until morning comes"
rc=0
drive "$tag" "$LONG" "" "run_fmsend_escape $tag" || rc=$?
sleep 0.5
out=$(cat "$EV/$tag.out")
check "$tag" "exit 0" "$([ $rc -eq 0 ] && echo 1 || echo 0)" "rc=$rc out=$out"
check "$tag" "C-u clear fired for the wrapped restore" "$(cu_in "$tag-attempt")" "delivery log slice had no C-u"
check "$tag" "composer is empty after the clear" "$([ "$(composer_state)" = empty ] && echo 1 || echo 0)" "state=$(composer_state)"
capture_pane "$tag"

# ===============================================================================
# D1: a composer that NEVER STABILIZES (captain typing throughout) is never
# cleared
# ===============================================================================
tag=D1-never-stabilized-skip
rc=0
# start the run manually (no interrupt in drive), then type throughout
before=$(cancel_count)
mark "$tag-attempt1"
if start_run "live proof hotel: inspect the release notes"; then
  sleep 0.5
  #
  # the run is now in flight; start a background typer, then send Escape
  (
    for i in $(seq 1 80); do
      "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "k$((i % 10))"
      sleep 0.1
    done
  ) &
  TYPER=$!
  sleep 0.4
  run_fmsend_escape "$tag" || rc=$?
  kill "$TYPER" 2>/dev/null || true
  wait "$TYPER" 2>/dev/null || true
else
  rc=1
fi
printf '%s %s' "$before" "$(cancel_count)" > "$EV/$tag.cancel"
sleep 0.5
out=$(cat "$EV/$tag.out")
content=$(composer_content)
check "$tag" "exit 0" "$([ $rc -eq 0 ] && echo 1 || echo 0)" "rc=$rc out=$out"
check "$tag" "Escape was delivered" "$(esc_in "$tag-attempt")" "delivery log slice had no Escape"
check "$tag" "NO C-u was sent" "$([ "$(cu_in "$tag-attempt")" = 0 ] && echo 1 || echo 0)" "C-u appeared in delivery log"
check "$tag" "warned the composer never stabilized" "$(has "$out" 'never stabilized')" "out=$out"
check "$tag" "typed characters survived in the composer" "$(printf '%s' "$content" | grep -cE 'k[0-9]' | awk '{print ($1>0)?1:0}')" "content=[$content]"
check "$tag" "the session log records the cancelled run" "$(cancel_proved "$tag")" "no cancelled terminal event"
capture_pane "$tag"
reset_composer

# --- session log summary --------------------------------------------------------
node - "$SESSION_LOG" > "$EV/session-log-summary.txt" <<'NODE'
const fs = require("fs");
const lines = fs.readFileSync(process.argv[2], "utf8").split("\n");
for (const line of lines) {
  if (!line.includes('"kind":"run"')) continue;
  try {
    const r = JSON.parse(line);
    const e = r?.payload?.event;
    if (r?.payload?.kind !== "run") continue;
    if (e?.kind === "started") console.log(`started  prompt=${JSON.stringify(e.prompt)}`);
    if (e?.kind === "terminal") console.log(`terminal ${e.terminal} (duration ${e.turn_duration_ms}ms)`);
  } catch {}
}
NODE

cp "$KEYLOG" "$EV/send-keys.log"
printf '\nLIVE RESULT: %s (%s failed checks)\n' "$([ $FAILURES -eq 0 ] && echo PASS || echo FAIL)" "$FAILURES" >> "$RESULTS"
echo "socket=$SOCKET"
cat "$RESULTS"
[ $FAILURES -eq 0 ]
