#!/usr/bin/env bash
# Behavior tests for fleet placement (bin/fm-fleet.sh place/hosts over
# bin/fm-fleet-lib.sh): opt-in config, hysteresis that does not flap on a
# brief spike, memory pressure and busy processes as no-headroom, hours
# windows, reservations that keep concurrent launches off a host's last slot
# and expire at their deadline, and the exit-4 queue result when every host is
# busy. Host samples come from the FM_FLEET_SAMPLE_CMD seam, so no SSH runs.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-placement-tests)

make_home() {  # <name> -> home path with a sampler and sample dir
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/samples"
  cat > "$home/sample" <<'SH'
#!/usr/bin/env bash
f="$FM_FAKE_SAMPLES/$1"
[ -f "$f" ] && cat "$f"
exit 0
SH
  chmod +x "$home/sample"
  printf '%s\n' "$home"
}

fleet() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_FLEET_SAMPLE_CMD="$home/sample" FM_FAKE_SAMPLES="$home/samples" \
    "$ROOT/bin/fm-fleet.sh" "$@"
}

sample() {  # <home> <host> <os> <cpus> <cpu_pct> <load1> <load5> <mem_mb> <pressure> <hour> <busy> [workers]
  printf 'os=%s cpus=%s cpu_pct=%s load1=%s load5=%s mem_avail_mb=%s mem_pressure=%s hour=%s busy=%s workers=%s\n' \
    "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12:-0}" > "$1/samples/$2"
}

# --- opt-in -----------------------------------------------------------------
home=$(make_home off)
out=$(fleet "$home" place t1 2>&1)
rc=$?
assert_equals 1 "$rc" "place refuses without config/fleet-hosts"
assert_contains "$out" "fleet placement is off" "the refusal names the off state"
assert_absent "$home/state/fleet" "no fleet state is created while off"

# --- invalid config fails closed --------------------------------------------
home=$(make_home badcfg)
printf 'a ssh=a os=linux root=/srv/fm slots=two\n' > "$home/config/fleet-hosts"
out=$(fleet "$home" hosts 2>&1)
expect_code 1 $? "a non-numeric limit is refused"
assert_contains "$out" "slots=two must be a whole number" "the error names the bad field"

# --- most spare cores wins; hours window and os check -----------------------
home=$(make_home pick)
cat > "$home/config/fleet-hosts" <<'EOF'
mac ssh=mac os=darwin root=/srv/fm reserve_cpus=8 reserve_mem_gb=32 slots=2
linux ssh=linux os=linux root=/srv/fm slots=1
day ssh=day os=linux root=/srv/fm hours=08-20
EOF
sample "$home" mac darwin 32 3 2 2 300000 normal 12 -
sample "$home" linux linux 32 5 1 1 100000 normal 12 -
sample "$home" day linux 64 0 0 0 200000 normal 22 -
out=$(fleet "$home" hosts)
assert_contains "$out" "no day outside hours 08-20 (local hour 22)" "a host outside its hours takes no work"
host=$(fleet "$home" place t1 2>/dev/null)
assert_equals linux "$host" "the host with the most spare cores after its reserve wins"

# --- concurrent placements never share a last slot; then exit 4 -----------
( fleet "$home" place t2 >"$home/t2.out" 2>/dev/null &
  fleet "$home" place t3 >"$home/t3.out" 2>/dev/null &
  wait )
assert_equals mac "$(cat "$home/t2.out")" "the second placement goes to the remaining host"
assert_equals mac "$(cat "$home/t3.out")" "the third placement takes the mac's second slot"
out=$(fleet "$home" place t4 2>&1 >/dev/null)
expect_code 4 "$(fleet "$home" place t4 >/dev/null 2>&1; echo $?)" "every slot held: place exits 4 and the task stays queued"
assert_contains "$out" "no linux full (1 of 1 slots)" "the queue result names each full host"
assert_absent "$home/state/fleet/t4.reservation" "a refused placement holds no reservation"
assert_equals linux "$(fleet "$home" place t1 2>/dev/null)" "placing a reserved task again returns its own host"

# --- an expired reservation frees its slot ----------------------------------
printf 'host=linux deadline=%s\n' "$(( $(date +%s) - 1 ))" > "$home/state/fleet/t1.reservation"
assert_equals linux "$(fleet "$home" place t5 2>/dev/null)" "a launch that never started frees the slot at its deadline"

# --- hysteresis: a brief spike does not flap, a sustained one turns busy ----
home=$(make_home hysteresis)
printf 'a ssh=a os=linux root=/srv/fm max_cpu=50\n' > "$home/config/fleet-hosts"
sample "$home" a linux 32 5 1 1 100000 normal 12 -
assert_contains "$(fleet "$home" hosts)" "ok a" "a quiet host is available"
sample "$home" a linux 32 90 2 1 100000 normal 12 -
out=$(fleet "$home" hosts)
assert_contains "$out" "no a rising: cpu 90% > 50% for 0s" "a spike inside the busy hold takes no new work but is not busy yet"
assert_contains "$(cat "$home/state/fleet/a.availability")" "state=available" "the spike alone leaves the host available"
sample "$home" a linux 32 5 1 1 100000 normal 12 -
assert_contains "$(fleet "$home" hosts)" "ok a" "the spike ended inside the hold: no flap to busy"
sample "$home" a linux 32 5 20 3 100000 normal 12 -
assert_contains "$(fleet "$home" hosts)" "no a rising: load 20.00 > 50% of 32 cores for 0s" \
  "a 1-minute load over the ceiling is a rising signal, not busy at once"
now=$(date +%s)
printf 'state=available over_since=%s last_busy=- last=%s\n' "$((now - 20))" "$((now - 10))" > "$home/state/fleet/a.availability"
sample "$home" a linux 32 5 1 1 100000 normal 12 -
assert_contains "$(fleet "$home" hosts)" "ok a" "a 20-second load burst that clears never turns the host busy"
sample "$home" a linux 32 5 20 3 100000 normal 12 -
fleet "$home" hosts >/dev/null
now=$(date +%s)
printf 'state=available over_since=%s last_busy=- last=%s\n' "$((now - 61))" "$((now - 30))" > "$home/state/fleet/a.availability"
assert_contains "$(fleet "$home" hosts)" "no a busy load 20.00 > 50% of 32 cores" \
  "a load over the ceiling across samples for 60 s turns the host busy"
sample "$home" a linux 32 5 1 3 100000 normal 12 -
assert_contains "$(fleet "$home" hosts)" "no a busy clear for" "a busy host stays busy until the clear hold passes"
FM_FLEET_CLEAR_HOLD=0 FM_HOME="$home" FM_FLEET_SAMPLE_CMD="$home/sample" FM_FAKE_SAMPLES="$home/samples" \
  "$ROOT/bin/fm-fleet.sh" hosts > "$home/clear.out"
assert_contains "$(cat "$home/clear.out")" "ok a" "after the clear hold a quiet host is available again"

# --- endpoint: Herdr by default, tmux only with a stated reason -------------
home=$(make_home endpoint)
printf 'a ssh=a os=linux root=/srv/fm session=tmux\n' > "$home/config/fleet-hosts"
out=$(fleet "$home" hosts 2>&1)
expect_code 1 $? "a session=tmux host without a reason is refused"
assert_contains "$out" "session=tmux without tmux_reason=" "the refusal asks for the reason"
printf 'a ssh=a os=linux root=/srv/fm tmux_reason=no-gui\n' > "$home/config/fleet-hosts"
fleet "$home" hosts >/dev/null 2>&1
expect_code 1 $? "a tmux reason on a Herdr host is refused"
printf 'a ssh=a os=linux root=/srv/fm session=tmux tmux_reason=no-gui\nb ssh=b os=linux root=/srv/fm\n' \
  > "$home/config/fleet-hosts"
sample "$home" a linux 32 5 1 1 100000 normal 12 -
sample "$home" b linux 32 5 1 1 100000 normal 12 -
out=$(fleet "$home" hosts)
assert_contains "$out" "ok a spare_cpu=27.00 spare_mem_gb=90.66 (session=tmux, not in the Herdr view: no-gui)" \
  "a tmux fallback host shows its reason in its verdict"
assert_equals "ok b spare_cpu=27.00 spare_mem_gb=90.66" "$(printf '%s\n' "$out" | grep '^ok b')" \
  "a host with no session= is a plain Herdr host"

# --- memory pressure, busy processes, unreachable ---------------------------
home=$(make_home signals)
printf 'a ssh=a os=linux root=/srv/fm\nb ssh=b os=darwin root=/srv/fm\nc ssh=c os=linux root=/srv/fm busy_procs=Runner.Worker\n' \
  > "$home/config/fleet-hosts"
sample "$home" a linux 32 5 1 1 100000 warn 12 -
sample "$home" c linux 32 5 1 1 100000 normal 12 Runner.Worker
out=$(fleet "$home" hosts)
assert_contains "$out" "no a rising: memory pressure warn" "warn memory pressure takes no new work"
assert_contains "$out" "no b unknown unreachable" "an unreachable host is unknown, never chosen"
assert_contains "$out" "no c busy Runner.Worker running" "a busy process makes the host busy with no hold"
expect_code 4 "$(fleet "$home" place t1 >/dev/null 2>&1; echo $?)" "no available host: exit 4"
pass "fleet placement: opt-in, hysteresis, pressure, hours, reservations, queue"
