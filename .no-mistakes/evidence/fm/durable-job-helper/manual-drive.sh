#!/usr/bin/env bash
# Manual live drive of bin/fm-durable-job.sh against a private tmux server.
set -u
H="$1/bin/fm-durable-job.sh"
T=$(mktemp -d /tmp/fmdj.XXXXXX); T=$(cd "$T" && pwd -P)
export TMUX_TMPDIR="$T/tmux"; mkdir -p "$TMUX_TMPDIR"; unset TMUX
trap 'tmux kill-server >/dev/null 2>&1; rm -rf "$T"' EXIT
step() { printf '\n### %s\n' "$*"; }
cd "$T"

step "S1 long job (50s) launched from a tool-call-shaped parent whose process group is SIGKILLed after it returns"
set -m; /bin/bash -c "cd '$T' && '$H' long50 long.txt -- /bin/sh -c 'sleep 50; echo hash=abc123' > launch.out 2>&1" & pg=$!; set +m
wait $pg; sleep 0.3; kill -KILL -- -$pg 2>/dev/null; echo "parent group $pg killed"
cat launch.out
sess=$(sed -n 's/.* session=\([^;]*\);.*/\1/p' launch.out)
echo "--- .partial while running:"; cat long.txt.partial
tmux has-session -t "=$sess" && echo "has-session on due-check session name: rc=0 (valid target)"
sleep 45; echo "after 45s: verdict exists? $( [ -e long.txt ] && echo yes || echo no )"
for i in $(seq 1 100); do [ -e long.txt ] && break; sleep 0.2; done
echo "--- verdict:"; cat long.txt; echo "partial left? $( [ -e long.txt.partial ] && echo yes || echo no )"

step "S2 failing job writes result=error with exit and stderr tail"
"$H" fail1 fail.txt -- /bin/sh -c 'echo "cannot read /Volumes/FLEET-8TB: Operation not permitted" >&2; exit 3'
for i in $(seq 1 50); do [ -e fail.txt ] && break; sleep 0.1; done; cat fail.txt

step "S3 job whose binary does not exist still yields an error verdict"
"$H" nobin nobin.txt -- /no/such/binary --x
for i in $(seq 1 50); do [ -e nobin.txt ] && break; sleep 0.1; done; cat nobin.txt

step "S4 args with spaces and quotes are passed verbatim"
"$H" quoting q.txt -- printf '%s|' "a b" "it's" '$HOME' >/dev/null
for i in $(seq 1 50); do [ -e q.txt ] && break; sleep 0.1; done; echo "stdout: $(cat q.txt.stdout)"; head -1 q.txt

step "S5 name with a dot is refused (exit 2) and no session created"
"$H" fleet.sha256 dot.txt -- true; echo "rc=$?"; tmux ls 2>/dev/null | grep -c fleet.sha256 || true
step "S5b name with slash / space refused"
"$H" 'a/b' s.txt -- true; echo "rc=$?"; "$H" 'a b' s.txt -- true; echo "rc=$?"

step "S6 existing verdict / partial refused (exit 2)"
"$H" again long.txt -- true; echo "rc=$?"
: > p.txt.partial; "$H" again p.txt -- true; echo "rc=$?"

step "S7 missing result dir refused (exit 2); missing -- gives usage exit 2"
"$H" x nodir/r.txt -- true; echo "rc=$?"
"$H" x r.txt true >/dev/null 2>&1; echo "usage rc=$?"

step "S8 FM_DURABLE_JOB_START_TIMEOUT knob is gone: setting it to garbage changes nothing"
FM_DURABLE_JOB_START_TIMEOUT=0 "$H" knob knob.txt -- true; echo "rc=$?"
"$H" --help | grep -n 'within\|START_TIMEOUT'

step "S9 relative result in subdir reported as absolute path; cmd runs in caller cwd"
mkdir -p sub; "$H" cwd sub/r.txt -- pwd
for i in $(seq 1 50); do [ -e sub/r.txt ] && break; sleep 0.1; done; echo "job pwd: $(cat sub/r.txt.stdout)"
