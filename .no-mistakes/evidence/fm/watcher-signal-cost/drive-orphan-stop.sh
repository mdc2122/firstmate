#!/usr/bin/env bash
# Live driver: register a never-completing source, let reconcile start it, then
# remove its registration and run reconcile again; it should report stopped=1.
# Usage: drive-orphan-stop.sh <product-root> <label> <iterations>
set -u
ROOT=$1; LABEL=$2; N=${3:-3}
SB=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-orphan.XXXXXX")
export FM_PROCEVENT_CLAIM_ROOT="$SB/claims"; mkdir -p "$FM_PROCEVENT_CLAIM_ROOT"; chmod 700 "$FM_PROCEVENT_CLAIM_ROOT"
export FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=60
cat > "$SB/blocker.sh" <<'SH'
#!/usr/bin/env bash
while [ ! -e "$1" ]; do [ "$SECONDS" -lt 120 ] || exit 75; sleep 0.2; done
SH
chmod +x "$SB/blocker.sh"
echo "=== [$LABEL] orphaned-runner stop, $N iterations, load: $(uptime | sed 's/.*load averages*: //')"
for i in $(seq 1 "$N"); do
  H="$SB/h$i"; mkdir -p "$H/state"; id="orphan-$i"
  FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" register lavish "$id" -- "$SB/blocker.sh" "$SB/never" >/dev/null
  FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
  sleep 0.5
  pid=$(sed -n 2p "$FM_PROCEVENT_CLAIM_ROOT/$id.claim" 2>/dev/null)
  rm -f "$H/state/procevent/$id.source"
  t0=$(python3 -c 'import time;print(time.time())')
  out=$(FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" reconcile 2>&1)
  t1=$(python3 -c 'import time;print(time.time())')
  printf '  #%s runner=%s elapsed=%.1fs -> %s\n' "$i" "$pid" "$(python3 -c "print($t1-$t0)")" "$out"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { echo "    runner still alive; killing"; kill -KILL -"$pid" "$pid" 2>/dev/null; }
done
pkill -f "$SB/blocker.sh" 2>/dev/null
rm -rf "$SB"
