#!/usr/bin/env bash
# Manual live driver: exercises the real bin/fm-brief.sh, fm-spawn.sh,
# fm-promote.sh, and fm-teardown.sh against a disposable FM home.
set -u
# Sandbox fleet: same documented bypass firstmate's test helpers export (bin/fm-gate-refuse-lib.sh).
export FM_GATE_REFUSE_BYPASS=1
ROOT=${ROOT:?}
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-dod-drive.XXXXXX")
trap 'rm -rf "$T"' EXIT
H=$T/home; P=$T/proj; FB=$T/bin
mkdir -p "$H/data" "$H/state" "$H/config" "$P" "$FB"
git -C "$P" init -q
printf '#!/bin/sh\nexit 1\n' > "$FB/tmux"; chmod +x "$FB/tmux"
spawn() { FM_ROOT_OVERRIDE='' FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" \
  FM_PROJECTS_OVERRIDE="$T/none" FM_CONFIG_OVERRIDE="$H/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
  PATH="$FB:$PATH" "$ROOT/bin/fm-spawn.sh" "$@" 2>&1; }
scaffold() { # id observation
  FM_HOME="$H" "$ROOT/bin/fm-brief.sh" "$1" proj --mode direct-PR >/dev/null 2>&1
  local b="$H/data/$1/brief.md" c
  c=$(cat "$b"); c=${c//'{TASK}'/Ship it.}; c=${c//'{FIRSTMATE_SPEC}'/Build it.}
  [ "$2" = KEEP ] || c=${c//'{VERIFY}'/$2}
  printf '%s\n' "$c" > "$b"
}
echo "=== 1. Scaffolded ship brief carries a Completion observation section ==="
FM_HOME="$H" "$ROOT/bin/fm-brief.sh" show-1 proj --mode direct-PR >/dev/null 2>&1
awk '/^# Completion observation$/{e=1} e' "$H/data/show-1/brief.md"
echo
echo "=== 2. Spawn with {VERIFY} unfilled ==="
scaffold s-unfilled KEEP; spawn s-unfilled "$P" claude --mode direct-PR --yolo off; echo "rc=$? meta_exists=$([ -e "$H/state/s-unfilled.meta" ] && echo yes || echo no)"
for obs in "PR merged" "ready for review" "CI is passing on main and checks green" "pushed and PR approved" \
           "v2 deployed to staging and /health returns 200" "fm-watch daemon running and logging beats"; do
  id="s-$(printf '%s' "$obs" | tr -c 'a-z0-9' '-' | cut -c1-20)"
  echo; echo "=== Spawn with verify: $obs ==="
  scaffold "$id" "$obs"; spawn "$id" "$P" claude --mode direct-PR --yolo off | tail -3
  echo "rc=${PIPESTATUS[0]}"
done
echo; echo "=== Spawn with brief lacking the section entirely ==="
mkdir -p "$H/data/s-none"
printf '# Task\n## Captain'\''s intent\nShip it.\n\n## Firstmate spec\nBuild it.\n\n# Definition of done\nDelivery contract: mode=direct-PR\n' > "$H/data/s-none/brief.md"
spawn s-none "$P" claude --mode direct-PR --yolo off; echo "rc=$? meta_exists=$([ -e "$H/state/s-none.meta" ] && echo yes || echo no)"
