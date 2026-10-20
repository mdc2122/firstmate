#!/usr/bin/env bash
# Drives the real bin/fm-merge-line.sh (and one fm-watch.sh sweep) in disposable FM_HOMEs
# seeded with the suite's fixture helpers (fake gh forge, real fm-pr-check.sh arming).
EV=$(cd "$(dirname "$0")" && pwd)
WT=${WT:?}
src=$(mktemp)
head -n 4472 "$WT/tests/fm-pr-check-security.test.sh" | sed "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh#$WT/tests/lib.sh#" > "$src"
. "$src"; rm -f "$src"
set +e
U=https://github.com/o/r/pull
g() { printf '$ fm-merge-line.sh gate --window %s\n' "$2"; merge_line "$1" gate --window "$2"; printf '  -> exit %s\n' "$?"; }
show() { printf '$ fm-merge-line.sh show\n'; merge_line "$1" show https://github.com/o/r | sed 's/^/  /'; }
nonyolo() { write_poll_meta "$1/home/state" "$2" "$3"; }

echo "=== S1: head pull/1 armed by live yolo=on task, not queued (guard: must hold)"
d=$(queue_line_case cli-s1 3); show $d; g $d $U/2
echo; echo "=== S1b: same head's task drops yolo=on (unarmed head): window opens past it"
nonyolo $d task-a $U/1; show $d; g $d $U/2; g $d $U/3; g $d $U/1
printf '$ fm-merge-line.sh head\n  %s\n' "$(merge_line $d head https://github.com/o/r)"
echo; echo "=== S2: head's task record deleted (ownerless head): window opens past it"
d=$(queue_line_case cli-s2 3); rm -f $d/home/state/task-a.meta; show $d; g $d $U/2; g $d $U/3
echo; echo "=== S3: fronted non-yolo head (guard: must still hold)"
d=$(queue_line_case cli-s3 3); nonyolo $d task-a $U/1; merge_line $d front $U/1 >/dev/null; show $d; g $d $U/2
echo; echo "=== S4: window size 1 behind an unarmed head admits only the first armed entry"
d=$(queue_line_case cli-s4 3); nonyolo $d task-a $U/1
FM_MERGE_LINE_QUEUE_WINDOW=1 bash -c ". /dev/null"; export FM_MERGE_LINE_QUEUE_WINDOW=1; g $d $U/2; g $d $U/3; unset FM_MERGE_LINE_QUEUE_WINDOW
echo; echo "=== S5: stalled middle entry (pull/2 unarmed) is skipped, not a blocker, for pull/3; pull/2 itself still in window"
d=$(queue_line_case cli-s5 4); nonyolo $d task-a $U/1; nonyolo $d task-b $U/2; g $d $U/3; g $d $U/4; g $d $U/2
echo; echo "=== S6: plain (non-merge-queue) base, unarmed head: one watcher sweep merges nothing behind it"
d=$(queue_line_case cli-s6 3); nonyolo $d task-a $U/1
cat > $d/rules.json <<'JSON'
[{"type":"pull_request","ruleset_id":101,"parameters":{}},
 {"type":"required_status_checks","ruleset_id":101,"parameters":{"required_status_checks":[{"context":"ci","integration_id":15368}]}}]
JSON
queue_line_cycle $d c1
printf 'forge pr merge calls: [%s]\n' "$(forge_merges $d)"
grep -h 'merge line' $d/home/state/.watch-triage.log 2>/dev/null | head -5 | sed 's/^/  triage: /'
echo; echo "=== S7: merge-queue base, unarmed head: one watcher sweep hands pull/2, pull/3 to the queue in order"
d=$(queue_line_case cli-s7 3); nonyolo $d task-a $U/1
queue_line_cycle $d c1
printf 'forge pr merge calls: [%s]\n' "$(forge_merges $d)"
grep '^pr merge' $d/gh.log | sed 's/^/  gh /'
for t in a b c; do printf '  task-%s.queue-merge: %s\n' $t "$(cat $d/home/state/task-$t.queue-merge 2>/dev/null || echo '<none>')"; done
show $d
