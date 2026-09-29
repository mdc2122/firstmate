#!/usr/bin/env bash
# Live driver: real bin/fm-procevent.sh CLI, isolated FM_HOME + claim root.
set -u
ROOT=$1; T=$(mktemp -d /tmp/fmpe-live.XXXXXX)
export FM_PROCEVENT_CLAIM_ROOT="$T/claims"
PE="$ROOT/bin/fm-procevent.sh"
BL="$T/blocker.sh"; cat > "$BL" <<'B'
#!/usr/bin/env bash
while [ ! -e "$1" ]; do sleep 0.05; done
printf '%s\n' "$2"
B
chmod +x "$BL"
BIN="$T/bin"; mkdir -p "$BIN"; REAL_PS=$(command -v ps)
cat > "$BIN/ps" <<P
#!/usr/bin/env bash
if [ -n "\${FM_PROCEVENT_RUNNER_GROUP:-}" ]; then
  : > "$T/entered"; for _ in \$(seq 1 300); do [ -e "$T/gate" ] && break; sleep 0.1; done
fi
exec "$REAL_PS" "\$@"
P
chmod +x "$BIN/ps"
lf() { awk -F '\t' -v id="$2" '$3=="check" && index($4,"procevent:" id ":launch-failed:")==1' "$1/state/.wake-queue" 2>/dev/null | grep -c . ; }

echo "== Scenario 1: healthy launch =="
H1="$T/h1"; mkdir -p "$H1/state"
FM_HOME=$H1 "$PE" register lavish healthy-src -- "$BL" "$T/trig1" "hello" >/dev/null
out=$(FM_HOME=$H1 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=30 "$PE" reconcile); rc=$?
echo "reconcile rc=$rc: $out"; echo "launch-failed wakes: $(lf $H1 healthy-src)"
: > "$T/trig1"; for _ in $(seq 1 100); do grep -q "procevent lavish healthy-src" "$H1/state/.wake-queue" 2>/dev/null && break; sleep 0.1; done
echo "result wake rows:"; awk -F '\t' '{print "  "$3" | "$4" | "$5}' "$H1/state/.wake-queue"

echo "== Scenario 2: registration retired while launch is unconfirmed =="
H2="$T/h2"; mkdir -p "$H2/state"
FM_HOME=$H2 "$PE" register lavish retired-src -- "$BL" "$T/trig2" "never" >/dev/null
PATH="$BIN:$PATH" FM_HOME=$H2 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=30 "$PE" reconcile > "$T/r2.out" 2>&1 & RP=$!
for _ in $(seq 1 300); do [ -e "$T/entered" ] && break; sleep 0.1; done
echo "runner held before claim: $([ -e "$T/entered" ] && echo yes || echo no)"
FM_HOME=$H2 "$PE" retire retired-src; echo "retire rc=$?"
: > "$T/gate"; wait $RP; rc=$?
echo "reconcile rc=$rc: $(cat "$T/r2.out")"
echo "launch-failed wakes: $(lf $H2 retired-src)"
echo "claim file present: $([ -e "$FM_PROCEVENT_CLAIM_ROOT/retired-src.claim" ] && echo yes || echo no)"

echo "== Scenario 3 (adversarial): live registration, runner never claims inside window =="
rm -f "$T/entered" "$T/gate"
H3="$T/h3"; mkdir -p "$H3/state"
FM_HOME=$H3 "$PE" register lavish slow-src -- "$BL" "$T/trig3" "slow" >/dev/null
out=$(PATH="$BIN:$PATH" FM_HOME=$H3 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 "$PE" reconcile 2>&1); rc=$?
echo "reconcile rc=$rc: $out"; echo "launch-failed wakes: $(lf $H3 slow-src)"
: > "$T/gate"; sleep 1
for h in $H1:healthy-src $H2:retired-src $H3:slow-src; do FM_HOME=${h%%:*} "$PE" retire ${h#*:} >/dev/null 2>&1; done
: > "$T/trig1"; : > "$T/trig2"; : > "$T/trig3"; sleep 1; rm -rf "$T"
