#!/usr/bin/env bash
# Scenario 3: a real fm-watch.sh contends for .watch.lock held by (a) a zombie
# former watcher, (b) a genuinely recycled pid, (c) a live watcher, (d) a live
# watcher started under a different TZ. Usage: <repo-root> <label> [cases]
set -u
ROOT=$1; LABEL=$2; CASES=${3:-zombie recycled live live-tz}
ENVU=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE)
newlab() { LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null; S=$LAB/state; }
waitlock() { for _ in $(seq 1 200); do [ -s "$S/.watch.lock/pid" ] && [ -e "$S/.last-watcher-beat" ] && return 0; sleep 0.05; done; return 1; }
contend() { # run a second real watcher with a 15s cap; report its verdict
  local tz=${1:-} out=$LAB/contender.out
  ( [ -n "$tz" ] && export TZ=$tz; exec "${ENVU[@]}" FM_HOME="$LAB" "$ROOT/bin/fm-watch.sh" ) > "$out" 2>&1 & local c=$!
  for _ in $(seq 1 150); do kill -0 $c 2>/dev/null || break; [ "$(cat "$S/.watch.lock/pid" 2>/dev/null)" = "$c" ] && break; sleep 0.1; done
  if [ "$(cat "$S/.watch.lock/pid" 2>/dev/null)" = "$c" ]; then
    echo "    contender pid=$c ACQUIRED .watch.lock (reclaimed); owner-identity: $(cat "$S/.watch.lock/owner-identity" 2>/dev/null)"
    kill -TERM $c; wait $c 2>/dev/null
  else
    wait $c 2>/dev/null; echo "    contender pid=$c did NOT acquire; lock pid still $(cat "$S/.watch.lock/pid" 2>/dev/null); contender said: $(tr '\n' ' ' < "$out")"
  fi
}
for case in $CASES; do
  newlab
  case $case in
  zombie)
    perl -e '$p=fork; if(!$p){exec @ARGV} open F,">",shift(@{[$ENV{PIDF}]}); print F "$p\n"; close F; sleep 1 while 1' \
      "${ENVU[@]}" FM_HOME="$LAB" "$ROOT/bin/fm-watch.sh" > /dev/null 2>&1 &
    PARENT=$!; waitlock; Z=$(cat "$S/.watch.lock/pid"); kill -KILL "$Z"; sleep 0.5
    echo "[$LABEL/zombie] watcher pid=$Z SIGKILLed under a non-reaping parent; ps stat=$(ps -o stat= -p $Z | tr -d ' '); kill -0: $(kill -0 $Z 2>/dev/null && echo alive || echo dead); recorded owner-identity: $(cat "$S/.watch.lock/owner-identity" 2>/dev/null || echo '<none>')"
    contend; kill $PARENT 2>/dev/null; wait $PARENT 2>/dev/null ;;
  recycled)
    ( exec "${ENVU[@]}" FM_HOME="$LAB" "$ROOT/bin/fm-watch.sh" ) > /dev/null 2>&1 & W=$!
    waitlock; P=$(cat "$S/.watch.lock/pid"); REC=$(cat "$S/.watch.lock/owner-identity" 2>/dev/null || echo '<none>')
    kill -KILL $W; wait $W 2>/dev/null
    echo "[$LABEL/recycled] watcher pid=$P SIGKILLed and reaped (lock left behind, owner-identity: $REC); cycling pids until $P is reused..."
    perl -e 'my $t=shift; for my $i (1..400000){ my $p=fork; die unless defined $p; if(!$p){ if($$==$t){ exec "sleep","600" } POSIX::_exit(0) } if($p==$t){ print "$p\n"; exit 0 } waitpid($p,0) } exit 1' -MPOSIX "$P" > "$LAB/recycled.pid" &
    wait $!
    if [ "$(cat "$LAB/recycled.pid" 2>/dev/null)" = "$P" ]; then
      echo "    pid $P now belongs to unrelated live process: $(ps -o pid=,lstart=,command= -p $P)"
      contend; kill $P 2>/dev/null
    else echo "    could not recycle pid $P (another process took it)"; fi ;;
  live|live-tz)
    tz=; [ $case = live-tz ] && tz=Asia/Tokyo
    ( [ -n "$tz" ] && export TZ=America/Los_Angeles; exec "${ENVU[@]}" FM_HOME="$LAB" "$ROOT/bin/fm-watch.sh" ) > /dev/null 2>&1 & W=$!
    waitlock
    echo "[$LABEL/$case] live watcher pid=$W ${tz:+(TZ=America/Los_Angeles; contender TZ=$tz) }owner-identity: $(cat "$S/.watch.lock/owner-identity" 2>/dev/null || echo '<none>')"
    contend "$tz"
    echo "    original holder still alive: $(kill -0 $W 2>/dev/null && echo yes || echo no); lock pid=$(cat "$S/.watch.lock/pid" 2>/dev/null)"
    kill -TERM $W; wait $W 2>/dev/null ;;
  esac
  rm -rf "$LAB"
done
