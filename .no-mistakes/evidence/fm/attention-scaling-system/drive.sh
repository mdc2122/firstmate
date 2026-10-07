#!/usr/bin/env bash
# Manual drive of the real scripts against a disposable FM_HOME.
set -u
R=/Users/studio2/.no-mistakes/worktrees/662ae98237ac/01M4BVX3TZ2SKNRN342TSM0MQZ
T=$(mktemp -d /tmp/fm-drive.XXXX); H=$T/home
mkdir -p $H/state $H/data; cp $R/.tasks.toml $H/
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > $H/data/backlog.md
export FM_HOME=$H HOME=$T FM_QUEUE_ZERO_NOW=2026-10-07T12:00:00Z FM_CAPTAIN_HOLD_NOW=2026-10-07T12:00:00Z FM_ATTENTION_NOW=2026-10-07T14:00:00Z
ax(){ tasks-axi "$@" --file $H/data/backlog.md >/dev/null; }
ch(){ $R/bin/fm-captain-hold.sh hold "$@" >/dev/null; echo "  -> exit $?"; }
qz(){ $R/bin/fm-queue-zero.sh "$@"; }
until_of(){ grep "^- \[ \] $1 " $H/data/backlog.md | sed -n 's/.*hold-until: \([0-9-]*\).*/\1/p'; }
echo "== S1 gate: owner: firstmate re-dated via fm-captain-hold.sh"
ax add follow "a follow-up nobody is on"
for d in 2099-10-02 2099-10-03 2099-10-04; do echo "\$ fm-captain-hold.sh hold follow --reason 'owner: firstmate' --until $d"; ch follow --reason "owner: firstmate - after deploy" --until $d; done
echo "  hold-until now: $(until_of follow)"
echo "write state/follow.status (new evidence), retry 2099-10-04"; echo "working: x" > $H/state/follow.status
ch follow --reason "owner: firstmate - after deploy" --until 2099-10-04; echo "  hold-until now: $(until_of follow)"
echo; echo "== S2 gate: captain-kind 'decide later' re-dated three times"
ax add later "parked call"
for d in 2099-10-02 2099-10-03 2099-10-04; do echo "\$ fm-captain-hold.sh hold later --reason 'decide later' --until $d"; ch later --reason "decide later" --until $d; done
echo "  hold-until now: $(until_of later)"
echo; echo "== S3 captain's own words never refused"
ax add tabled "tabled"; w=$T/w.txt
for d in 2099-10-02 2099-10-03 2099-10-04 2099-10-05; do printf 'Push it to %s.\n' $d > $w; echo "\$ ... --until $d --captain-words-file"; ch tabled --reason "captain tabled it" --until $d --captain-words-file $w; done
echo; echo "== S4 direct tasks-axi re-dates around the gate -> redated; then each answer"
ids="by-status by-watch by-mate by-crew by-captain-undated by-captain-dated by-close"
for i in $ids; do ax add $i "row $i"; ax hold $i --reason later --until 2099-10-02; done; qz check >/dev/null
for i in $ids; do ax hold $i --reason later --until 2099-10-03; done; qz check >/dev/null
for i in $ids; do ax hold $i --reason later --until 2099-10-04; done
echo "\$ fm-queue-zero.sh scan --local | grep redated"; qz scan --local | grep redated
echo "-- giving answers: status line, watch, secondmate hand-off, br crew item, undated captain call, (adversarial) dated captain hold w/o words, close"
echo "working: on it" > $H/state/by-status.status
mkdir -p $H/state/procevent; echo adapter=when > $H/state/procevent/when-by-watch.source
echo "- sm-web - web (home: $H/sm-web; scope: web; projects: web; added 2026-09-01)" > $H/data/secondmates.md
echo "\$ fm-captain-hold.sh hold by-mate --reason 'owner: sm-web' --until 2099-10-05"; ch by-mate --reason "owner: sm-web - building" --until 2099-10-05
mkdir -p $H/data/beads; ( cd $H/data/beads && br init >/dev/null 2>&1 && br create "crew mirror" -l mirror:by-crew >/dev/null 2>&1 ) ; echo "  br crew item: $( cd $H/data/beads && br list --json 2>/dev/null | jq -c '[.issues[]?.labels]' 2>/dev/null)"
echo "\$ fm-captain-hold.sh hold by-captain-undated --reason 'pick the vendor'"; ch by-captain-undated --reason "pick the vendor"
echo "\$ fm-captain-hold.sh hold by-captain-dated --reason 'pick the vendor' --until 2099-10-06 (no words; expect refusal)"; ch by-captain-dated --reason "pick the vendor" --until 2099-10-06
ax done by-close
echo "\$ fm-queue-zero.sh scan --local"; qz scan --local
qz check >/dev/null; echo "ledger strikes: $(jq -c '[.rows[]|{id,strikes}]' $H/state/.queue-zero-holds.json 2>/dev/null || jq -c . $H/state/.queue-zero-holds.json)"
echo; echo "== S5 load + attention line"
echo "\$ fm-queue-zero.sh load"; qz load; echo
echo "\$ fm-attention-check.sh scan"; $R/bin/fm-attention-check.sh scan
echo; echo "== S6 fleet-pins / Class E absent (HOME has no ~/.fleet-backup)"
$R/bin/fm-attention-check.sh scan | grep -ci 'class-e' | sed 's/^/  class-e segments on line: /'
rm -rf $T
