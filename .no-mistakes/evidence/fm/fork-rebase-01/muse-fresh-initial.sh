#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "/Users/Morley/.no-mistakes/worktrees/62b3bc0be3e5/01M3D8P5E7FPTP6VHHKC2V69JQ/tests/lib.sh"

ROOT="/Users/Morley/.no-mistakes/worktrees/62b3bc0be3e5/01M3D8P5E7FPTP6VHHKC2V69JQ"
MUSE_BIN=$(command -v muse 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-muse-signals-$$"
SESSION=muse-signals
TARGET="$SESSION:muse"

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

muse_prompt_glyph_is_bright() {  # <capture-path|--self-test>
  node - "$1" <<'NODE'
const fs = require("fs");

function applySgr(foreground, raw) {
  const fields = raw === "" ? ["0"] : raw.split(";");
  const params = fields.map((value) => value === "" ? 0 : Number(value));
  for (let index = 0; index < params.length; index += 1) {
    const code = params[index];
    if (code === 0 || code === 39) {
      foreground = null;
    } else if ((code >= 30 && code <= 37) || (code >= 90 && code <= 97)) {
      foreground = { kind: "indexed" };
    } else if (code === 48 || code === 58) {
      const mode = params[index + 1];
      const channels = params.slice(index + 2, index + 5);
      const channelFields = fields.slice(index + 2, index + 5);
      if (mode === 2 && channels.length === 3 && channelFields.every((value) => /^[0-9]+$/.test(value)) && channels.every((value) => Number.isInteger(value) && value >= 0 && value <= 255)) {
        index += 4;
      } else if (mode === 5 && /^[0-9]+$/.test(fields[index + 2] ?? "") && Number.isInteger(params[index + 2]) && params[index + 2] >= 0 && params[index + 2] <= 255) {
        index += 2;
      } else {
        break;
      }
    } else if (code === 38) {
      const mode = params[index + 1];
      const channels = params.slice(index + 2, index + 5);
      const channelFields = fields.slice(index + 2, index + 5);
      if (mode === 2 && channels.length === 3 && channelFields.every((value) => /^[0-9]+$/.test(value)) && channels.every((value) => Number.isInteger(value) && value >= 0 && value <= 255)) {
        foreground = { kind: "rgb", values: channels };
        index += 4;
      } else if (mode === 5 && /^[0-9]+$/.test(fields[index + 2] ?? "") && Number.isInteger(params[index + 2]) && params[index + 2] >= 0 && params[index + 2] <= 255) {
        foreground = { kind: "indexed" };
        index += 2;
      } else {
        foreground = { kind: "invalid" };
      }
    }
  }
  return foreground;
}

function lastGlyphForeground(pane) {
  const tokens = /\x1b\[([0-9;]*)m|[⟩❯]/gu;
  let foreground = null;
  let glyphForeground;
  for (const match of pane.matchAll(tokens)) {
    if (match[0] === "⟩" || match[0] === "❯") {
      glyphForeground = foreground;
    } else {
      foreground = applySgr(foreground, match[1]);
    }
  }
  return glyphForeground;
}

function isBrightTruecolor(pane) {
  const foreground = lastGlyphForeground(pane);
  if (!foreground || foreground.kind !== "rgb") return false;
  const [r, g, b] = foreground.values;
  return (r * 299 + g * 587 + b * 114) / 1000 >= 128;
}

const positive = "\x1b[38;2;90;160;255m\x1b[48;2;38;56;84m⟩";
const positiveMuse13 = "\x1b[38;2;90;160;255m\x1b[48;2;38;56;84m❯";
const brightThenDark = "\x1b[38;2;204;211;219mearlier bright\x1b[38;2;30;30;30m⟩";
const brightThenMalformed = "\x1b[38;2;204;211;219mearlier bright\x1b[38;2m⟩";
const brightThenOutOfRange = "\x1b[38;2;204;211;219mearlier bright\x1b[38;2;256;160;255m⟩";
if (!isBrightTruecolor(positive) || !isBrightTruecolor(positiveMuse13) || isBrightTruecolor(brightThenDark) || isBrightTruecolor(brightThenMalformed) || isBrightTruecolor(brightThenOutOfRange)) process.exit(2);
if (process.argv[2] === "--self-test") process.exit(0);

const pane = fs.readFileSync(process.argv[2], "utf8");
const foreground = lastGlyphForeground(pane);
if (!foreground || foreground.kind !== "rgb") {
  console.error("the final Muse prompt glyph has no effective truecolor foreground");
  process.exit(1);
}
const [r, g, b] = foreground.values;
const luminance = (r * 299 + g * 587 + b * 114) / 1000;
if (luminance < 128) {
  console.error(`the final Muse prompt glyph foreground is dark: ${r};${g};${b}, luminance ${luminance}`);
  process.exit(1);
}
NODE
}

if [ "${1:-}" = --ansi-self-test ]; then
  command -v node >/dev/null 2>&1 || fail "node is required to test Muse prompt glyph ANSI state"
  muse_prompt_glyph_is_bright --self-test || fail "Muse glyph color parser accepted a dark or malformed negative control"
  pass "Muse glyph color parser follows effective foreground state"
  exit 0
fi

fm_live_gate opt-in FM_MUSE_SIGNALS_LIVE muse tmux node

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-muse-signals.XXXXXX") || fail "could not create the isolated Muse lab"
trap cleanup EXIT
mkdir -p "$LAB/bin" "$LAB/config" "$LAB/data" "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated Muse workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated Muse workspace"

cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/bin/tmux"
PATH="$LAB/bin:$PATH"
export PATH

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -x 110 -y 32 -d -s "$SESSION" -n control -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"
# Pin the pane's terminal capabilities: the drift guard asserts Muse's real
# truecolor prompt styling, and Muse downgrades or disables color when the
# inherited terminal environment says to (COLORTERM unset, or NO_COLOR from
# the driving shell). The tmux server passes the ambient environment through
# to panes, so a host running this guard from a colorless harness would fail
# the glyph check for environmental rather than drift reasons.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n muse -c "$WORKSPACE" -- \
  env -u NO_COLOR XDG_CONFIG_HOME="$LAB/config" XDG_DATA_HOME="$LAB/data" \
  TERM=xterm-256color COLORTERM=truecolor \
  MUSE_NO_AUTO_UPDATE=1 MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on \
  "$MUSE_BIN" --provider echo --echo-delay-ms 10000 --yolo "firstmate Muse signal drift guard" \
  || fail "could not launch Muse with the echo provider"

SESSION_LOG=
for _ in $(seq 1 150); do
  SESSION_LOG=$(fm_busy_muse_matching_logs "$LAB/data/muse/sessions" "$WORKSPACE" 2>/dev/null | head -1)
  [ -z "$SESSION_LOG" ] || break
  sleep 0.2
done
[ -n "$SESSION_LOG" ] || fail "real Muse produced no workspace-bound session.jsonl"

RUN_STATE=
for _ in $(seq 1 150); do
  RUN_STATE=$(fm_busy_muse_run_state "$SESSION_LOG" 2>/dev/null || true)
  [ "$RUN_STATE" = busy ] && break
  sleep 0.2
done
[ "$RUN_STATE" = busy ] || fail "fm_busy_muse_run_state never observed the real echo turn in flight"
pass "Muse's real session protocol classifies busy in flight"

mkdir -p "$LAB/home/state"
fm_write_meta "$LAB/home/state/live.meta" "window=$TARGET" "kind=ship" "harness=muse"
printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=live\n' "$LAB/data/muse/sessions" "$WORKSPACE" > "$LAB/home/state/live.muse-session"
tmux send-keys -t "$TARGET" -l 'fresh unsent note'
sleep 0.3
FM_HOME="$LAB/home" "$ROOT/bin/fm-send.sh" live --key Escape > "/Users/Morley/.no-mistakes/evidence/01M3D8P5E7FPTP6VHHKC2V69JQ/muse-fresh-send.txt" 2>&1 || fail 'fresh interrupt failed'
tmux capture-pane -p -t "$TARGET" > "/Users/Morley/.no-mistakes/evidence/01M3D8P5E7FPTP6VHHKC2V69JQ/muse-fresh-screen.txt"
[ "$(fm_tmux_composer_content "$TARGET")" = 'fresh unsent note' ] || fail 'fresh input changed'
pass 'real Muse preserves fresh unsent note across fm-send Escape'
cleanup
trap - EXIT
