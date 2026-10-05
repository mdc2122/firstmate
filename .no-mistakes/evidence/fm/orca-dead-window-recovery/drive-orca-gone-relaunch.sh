#!/usr/bin/env bash
# Drives the real bin/fm-control.sh / bin/fm-spawn.sh in a disposable FM_HOME
# with the stateful stand-in Orca CLI from tests/fm-control-relaunch.test.sh.
set -u
WT_ROOT=${1:?worktree root}
cd "$WT_ROOT/tests"
# shellcheck disable=SC1090
H=$(mktemp); sed -e "s|\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh|$WT_ROOT/tests/lib.sh|" -e '/^test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint$/,$d' fm-control-relaunch.test.sh > "$H"; . "$H"; rm -f "$H"
show() { echo "\$ $*"; }
st() { local d=$1 id=$2; echo "  meta: terminal=$(meta_field "$d" "$id" terminal) harness=$(meta_field "$d" "$id" harness) worktree=$(meta_field "$d" "$id" worktree) busy_gen=$(meta_field "$d" "$id" busy_gen)"; echo "  orca open terminals: [$(tr '\n' ' ' < "$d/fake/orca-terminals")]"; }

echo "=== S1 happy path: vanished terminal -> replacement in recorded worktree ==="
d=$(new_case s1 ev1); add_orca_ship_task "$d" ev1 gone; echo wip > "$d/wt/wip.txt"
st "$d" ev1
show fm-control ev1 relaunch --note "the Orca window vanished"
run_orca "$d" control ev1 relaunch --note "the Orca window vanished"; echo "  rc=$?"
st "$d" ev1; echo "  orca calls:"; sed 's/^/    /' "$d/fake/orca-log" | grep -E 'terminal (create|close)|worktree' ; echo "  wip.txt=$(cat "$d/wt/wip.txt")"
echo "  worktrees under case: $(find "$d" -maxdepth 2 -name 'wip.txt' | wc -l | tr -d ' ')"

echo; echo "=== S2 adversarial: terminal still listed ==="
d=$(new_case s2 ev2); add_orca_ship_task "$d" ev2 live
show fm-control ev2 relaunch --note x; run_orca "$d" control ev2 relaunch --note x; echo "  rc=$?"
show fm-spawn ev2 --relaunch --harness claude; run_orca "$d" spawn ev2 --relaunch --harness claude; echo "  rc=$?"
grep -c 'terminal create' "$d/fake/orca-log" | sed 's/^/  terminal create calls: /'

echo; echo "=== S3 adversarial: terminal gone but a non-harness process sits in the worktree ==="
d=$(new_case s3 ev3); add_orca_ship_task "$d" ev3 gone
(cd "$d/wt" && exec "$d/fake/agentbin/node" 60) </dev/null >/dev/null 2>&1 & occ=$!; echo "$occ" >> "$ORCA_AGENT_PIDS"; sleep 0.5
show fm-control ev3 relaunch --note x; run_orca "$d" control ev3 relaunch --note x; echo "  rc=$?"; kill "$occ" 2>/dev/null
grep -c 'terminal create' "$d/fake/orca-log" | sed 's/^/  terminal create calls: /'

echo; echo "=== S4 adversarial: truncated orca terminal list ==="
d=$(new_case s4 ev4); add_orca_ship_task "$d" ev4 gone
show fm-control ev4 relaunch --note x; FM_FAKE_ORCA_LIST_TRUNCATED=1 run_orca "$d" control ev4 relaunch --note x; echo "  rc=$?"

echo; echo "=== S5 failure after publish (cross-harness claude->opencode, no agent appears) then retry ==="
d=$(new_case s5 ev5); add_orca_ship_task "$d" ev5 gone; echo wip > "$d/wt/wip.txt"
before=$(cat "$d/home/state/ev5.meta"); st "$d" ev5
show fm-control ev5 relaunch --harness opencode --note "first attempt"
FM_FAKE_ORCA_NO_AGENT=1 FM_CONTROL_LAUNCH_WAIT=1 run_orca "$d" control ev5 relaunch --harness opencode --note "first attempt"; echo "  rc=$?"
st "$d" ev5
[ "$(cat "$d/home/state/ev5.meta")" = "$before" ] && echo "  meta restored byte-exact: yes" || echo "  meta restored byte-exact: NO"
echo "  opencode plugin present: $([ -e "$d/wt/.opencode/plugins/fm-busy-state.js" ] && echo YES || echo no)"
echo "  busy-gen file: $(cat "$d/home/state/ev5.busy-gen" 2>/dev/null || echo '<absent>')"
echo "  busy-state: $(cat "$d/home/state/ev5.busy-state" 2>/dev/null | tr '\n' ' ' || true)"
echo "  journal rollback=$(journal_field "$d" ev5 rollback)"
grep -E 'terminal close' "$d/fake/orca-log" | sed 's/^/  orca: /'
show fm-control ev5 relaunch --note "second attempt"
run_orca "$d" control ev5 relaunch --note "second attempt"; echo "  rc=$?"
st "$d" ev5; echo "  wip.txt=$(cat "$d/wt/wip.txt")"
echo "  brief has 'first attempt': $(grep -c 'first attempt' "$d/home/data/ev5/brief.md")  'second attempt': $(grep -c 'second attempt' "$d/home/data/ev5/brief.md")"

echo; echo "=== S6 exit still refused on Orca ==="
d=$(new_case s6 ev6); add_orca_ship_task "$d" ev6 gone
show fm-control ev6 exit; run_orca "$d" control ev6 exit; echo "  rc=$?"
orca_relaunch_cleanup
