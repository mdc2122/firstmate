#!/usr/bin/env bash
# Live driver: runs the real bin/fm-procevent.sh reconcile from <root> against
# a disposable FM_HOME and a private claim root while another process holds a
# source's machine-wide lock. Prints wall-clock per pass and reconcile output.
# Usage: drive-reconcile.sh <checkout-root> <label>
set -u
ROOT=$1; LABEL=$2
SB=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-reconcile.XXXXXX")
export FM_PROCEVENT_CLAIM_ROOT="$SB/claims"
mkdir -p "$FM_PROCEVENT_CLAIM_ROOT"; chmod 700 "$FM_PROCEVENT_CLAIM_ROOT"
export FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=3
CAP=25   # cap on any single pass so the base run cannot hang forever
holders=()

cleanup() {
  for p in "${holders[@]}"; do kill "$p" 2>/dev/null; done
  for h in "$SB"/home-*; do
    [ -d "$h/state/procevent" ] || continue
    for s in "$h"/state/procevent/*.source; do
      [ -e "$s" ] || continue
      id=${s##*/}; id=${id%.source}
      FM_HOME="$h" "$ROOT/bin/fm-procevent.sh" retire "$id" >/dev/null 2>&1
    done
  done
  pkill -f "$SB/blocker.sh" 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT

cat > "$SB/blocker.sh" <<'SH'
#!/usr/bin/env bash
while [ ! -e "$1" ]; do [ "$SECONDS" -lt 120 ] || exit 75; sleep 0.2; done
printf '%s\n' "$2"
SH
chmod +x "$SB/blocker.sh"

hold() {  # <source-id> -> holds that source's lock until $SB/release-<id>
  local id=$1
  bash -c '
    . "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_source_lock_acquire "$2" || exit 1
    trap "fm_procevent_source_lock_release \"$2\"" EXIT
    : > "$3/ready-$2"
    while [ ! -e "$3/release-$2" ]; do sleep 0.05; done
  ' _ "$ROOT" "$id" "$SB" &
  holders+=($!)
  while [ ! -e "$SB/ready-$id" ]; do sleep 0.05; done
  echo "  [holder pid $! holds the machine-wide lock for source '$id']"
}
release() { : > "$SB/release-$1"; sleep 0.3; }

timed_reconcile() {  # <home> [env...]
  local home=$1; shift
  local t0 t1 out rc
  t0=$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')
  t0=$(python3 -c 'import time;print(time.time())')
  out=$(env "$@" FM_HOME="$home" perl -e 'alarm shift; exec @ARGV' "$CAP" \
        "$ROOT/bin/fm-procevent.sh" reconcile 2>&1); rc=$?
  t1=$(python3 -c 'import time;print(time.time())')
  printf '  reconcile %s -> rc=%s elapsed=%.1fs%s\n' "$*" "$rc" \
    "$(python3 -c "print($t1-$t0)")" "$([ "$rc" = 142 ] && echo "  ** KILLED at ${CAP}s cap: still blocked on the lock **")"
  printf '    output: %s\n' "$(printf '%s' "$out" | tr '\n' ' ')"
}

echo "=== [$LABEL] $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "$ROOT") ==="

echo "--- A: foreign home's leftover claim, its lock held by a live process"
HA="$SB/home-a"; mkdir -p "$HA/state/procevent"
printf '%s\n%s\nforeign-token\nforeign-identity\n' "$SB/home-gone" 999999 \
  > "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim"; chmod 600 "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim"
hold foreign-src
timed_reconcile "$HA"
timed_reconcile "$HA" FM_PROCEVENT_SOURCE_LOCK_TIMEOUT=60
[ -e "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim" ] && echo "  foreign claim left in place for its own home: yes"
release foreign-src

echo "--- B: this home's registered source, its lock held past the bound"
HB="$SB/home-b"; mkdir -p "$HB/state"
FM_HOME="$HB" "$ROOT/bin/fm-procevent.sh" register lavish own-src -- "$SB/blocker.sh" "$SB/never" held >/dev/null
hold own-src
timed_reconcile "$HB"
timed_reconcile "$HB" FM_PROCEVENT_SOURCE_LOCK_TIMEOUT=2
[ -e "$FM_PROCEVENT_CLAIM_ROOT/own-src.claim" ] && echo "  claim present while held: yes" || echo "  claim present while held: no (deferred)"
release own-src
timed_reconcile "$HB"
[ -e "$FM_PROCEVENT_CLAIM_ROOT/own-src.claim" ] && echo "  after release, next pass started the source (claim present): yes" || echo "  after release, claim present: NO"

echo "--- C: a captured result pending publish, its source lock held"
HC="$SB/home-c"; mkdir -p "$HC/state/procevent" "$HC/state/procevent-inbox"
printf 'held result\n' > "$HC/state/procevent-inbox/pub-src.3.result"
printf 'lavish\n' > "$HC/state/procevent-inbox/pub-src.3.adapter"
chmod 600 "$HC"/state/procevent-inbox/*
hold pub-src
timed_reconcile "$HC" FM_PROCEVENT_SOURCE_LOCK_TIMEOUT=2
release pub-src
timed_reconcile "$HC"
echo "  wake queue payloads: $(awk -F '\t' '{print $5}' "$HC/state/.wake-queue" 2>/dev/null | tr '\n' ';')"
