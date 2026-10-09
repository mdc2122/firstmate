#!/usr/bin/env bash
# Live end-to-end drive: hold -> complete -> answer via the real fm-captain-hold.sh,
# real tasks-axi retention archives the answered row, then verify/complete/teardown
# with the BASE (unfixed) and TARGET (fixed) scripts in disposable homes.
set -u
WT=/Users/studio2/.no-mistakes/worktrees/662ae98237ac/01M4H814KAZVX5EF86H3P7XDZ4
T=$(mktemp -d /tmp/fm-j7l-drive.XXXXXX)
mkdir -p "$T/base"; (cd "$WT" && git archive e17fcfa92fae790682e719d8f503eb53c3ea2032) | tar -x -C "$T/base"
TA=$(command -v tasks-axi)
mkhome() { # <name> <tasks.toml-content>
  local h="$T/$1"; mkdir -p "$h/data" "$h/state" "$h/config" "$h/projects" "$h/fakebin"
  printf '%s\n' "$2" > "$h/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$h/data/backlog.md"
  for b in tmux treehouse no-mistakes gh gh-axi; do printf '#!/bin/sh\nexit 0\n' > "$h/fakebin/$b"; chmod +x "$h/fakebin/$b"; done
  echo "$h"; }
cap() { # <root> <home> args...
  local r=$1 h=$2; shift 2
  PATH="$h/fakebin:$PATH" REAL_TASKS_AXI="$TA" FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" \
   FM_DATA_OVERRIDE="$h/data" FM_CONFIG_OVERRIDE="$h/config" "$r/bin/fm-captain-hold.sh" "$@"; }
td() { local r=$1 h=$2; shift 2
  PATH="$h/fakebin:$PATH" FM_ROOT_OVERRIDE="$r" FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" \
   FM_DATA_OVERRIDE="$h/data" FM_CONFIG_OVERRIDE="$h/config" "$r/bin/fm-teardown.sh" "$@"; }
ta() { local h=$1 c=$2; shift 2; (cd "$h" && tasks-axi "$c" "$@" --file "$h/data/backlog.md"); }  # address the backlog the way firstmate does (fm_backlog_tasks_axi_addressing)
meta() { # <home> <id>
  cat > "$2/state/$1.meta" <<EOF
window=firstmate:fm-$1
worktree=$2/projects/missing-$1
project=$2/projects/sample
harness=codex
kind=scout
mode=scout
spawn_gen=fixture-$1
EOF
  printf 'done: report complete\n' > "$2/state/$1.status"; mkdir -p "$2/data/$1"
  printf '# Report\n\nOne captain call.\n' > "$2/data/$1/report.md"; }
# Builds a home where <scout> attested <call>, the call was answered, and real retention archived it.
setup_answered_archived() { # <home> <scout> <call>
  local h=$1 s=$2 c=$3 i
  ta "$h" add "$s" "Scout $s" --kind scout --repo sample --start >/dev/null
  meta "$s" "$h"
  cap "$WT" "$h" hold "$c" --title "Captain call $c" --reason "captain choice pending" --repo sample >/dev/null || echo "!! hold failed"
  cap "$WT" "$h" complete "$s" "$c" || echo "!! complete failed"
  printf 'Captain chose option B.\n' > "$h/decision.txt"
  cap "$WT" "$h" answer "$c" --decision-file "$h/decision.txt" || echo "!! answer failed"
  for i in $(seq 1 12); do ta "$h" add "filler-$i" "Filler $i" --kind task --repo sample >/dev/null; ta "$h" done "filler-$i" >/dev/null; done
  ta "$h" prune --keep 10 >/dev/null 2>&1 || true
}
DEFTOML='backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10'

echo "=== S1: answered call archived by real retention (repo default .tasks.toml) ==="
H=$(mkhome s1 "$DEFTOML"); setup_answered_archived "$H" sample-scout sample-call
echo "--- tasks-axi show sample-call (live backlog):"; ta "$H" show sample-call 2>&1 | head -3
echo "--- archived row in data/done-archive.md:"; grep -n -A8 -- '- \[x\] sample-call - ' "$H/data/done-archive.md"
echo "--- BASE verify:"; cap "$T/base" "$H" verify sample-scout; echo "exit=$?"
echo "--- FIXED verify:"; cap "$WT" "$H" verify sample-scout; echo "exit=$?"
echo "--- FIXED complete (re-attest):"; cap "$WT" "$H" complete sample-scout sample-call; echo "exit=$?"

echo; echo "=== S2: non-default [markdown] path, no archive key -> default <data>/done-archive.md ==="
H=$(mkhome s2 'backend = "markdown"

[markdown]
path = "elsewhere/backlog.md"
done_keep = 10'); setup_answered_archived "$H" s2-scout s2-call
echo "--- live show:"; ta "$H" show s2-call 2>&1 | head -1
echo "--- archived row:"; grep -l -- '- \[x\] s2-call - ' "$H"/data/*.md
echo "--- BASE verify:"; cap "$T/base" "$H" verify s2-scout; echo "exit=$?"
echo "--- FIXED verify:"; cap "$WT" "$H" verify s2-scout; echo "exit=$?"

echo; echo "=== S3: explicit custom archive key wins ==="
H=$(mkhome s3 'backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "retired/old.md"
done_keep = 10'); setup_answered_archived "$H" s3-scout s3-call
echo "--- live show:"; ta "$H" show s3-call 2>&1 | head -1
echo "--- archived row in:"; grep -rl -- '- \[x\] s3-call - ' "$H/retired" "$H/data"
echo "--- decoy: copy the row into data/done-archive.md stripped of its resolution record must not matter; remove from configured archive -> must fail:"
cp "$H/retired/old.md" "$H/retired/old.md.bak"
printf '## Archived\n- [x] s3-call - decoy\n  Resolution recorded by fm-captain-hold.\n  Resolution mode: answered\n' > "$H/data/done-archive.md"
sed -i '' '/s3-call - /,$d' "$H/retired/old.md"
echo "--- FIXED verify with answer only in the UNconfigured default file:"; cap "$WT" "$H" verify s3-scout; echo "exit=$?"
mv "$H/retired/old.md.bak" "$H/retired/old.md"; rm -f "$H/data/done-archive.md"
echo "--- FIXED verify:"; cap "$WT" "$H" verify s3-scout; echo "exit=$?"

echo; echo "=== S4 (adversarial): archived plain done row without resolution record fails closed ==="
H=$(mkhome s4 "$DEFTOML")
ta "$H" add s4-call "Ordinary task" --kind task --repo sample >/dev/null; ta "$H" done s4-call >/dev/null
for i in $(seq 1 12); do ta "$H" add "f-$i" "F $i" --kind task --repo sample >/dev/null; ta "$H" done "f-$i" >/dev/null; done
ta "$H" prune --keep 10 >/dev/null 2>&1 || true
grep -c -- '- \[x\] s4-call - ' "$H/data/done-archive.md"
meta s4-scout "$H"; printf 'decisions_reviewed=1\ndecision_keys=s4-call\n' >> "$H/state/s4-scout.meta"
echo "--- FIXED verify:"; cap "$WT" "$H" verify s4-scout; echo "exit=$?"

echo; echo "=== S5 (adversarial): substring-colliding archived id must not satisfy a shorter key ==="
H=$(mkhome s5 "$DEFTOML"); setup_answered_archived "$H" s5-scout s5-call-extra
meta s5b-scout "$H"; printf 'decisions_reviewed=1\ndecision_keys=s5-call\n' >> "$H/state/s5b-scout.meta"
echo "--- FIXED verify of key s5-call (only s5-call-extra archived):"; cap "$WT" "$H" verify s5b-scout; echo "exit=$?"

echo; echo "=== S6: live task wins over an archived namesake ==="
H=$(mkhome s6 "$DEFTOML"); setup_answered_archived "$H" s6-scout s6-call
ta "$H" add s6-call "Re-opened live namesake, not held" --kind task --repo sample >/dev/null
echo "--- FIXED verify (live unheld row s6-call must be checked, not the archive):"; cap "$WT" "$H" verify s6-scout; echo "exit=$?"
rm -rf "$T"
