#!/usr/bin/env bash
# bin/fm-fleet-lib.sh - fleet placement for omp ship workers on donor hosts.
#
# Sourced by bin/fm-fleet.sh. No side effects on source.
#
# The fleet is opt-in: config/fleet-hosts lists the donor hosts and their
# limits, and its absence means no task is ever placed off this machine.
# docs/fleet-placement.md owns the operator contract (setup, launch,
# monitoring, recovery, removal); this file owns the config grammar, the
# sample format, the availability state machine, and the placement decision.
#
# The availability model follows Crabbox's `serve` availability gating
# (github.com/openclaw/crabbox docs/providers/serve.md, MIT): host CPU above a
# ceiling or memory pressure at warn must persist before a host turns busy,
# all signals must stay clear for five minutes before it turns available
# again, an unknown signal blocks new placement at once, and a busy host only
# stops new work - nothing here ever moves or stops a running worker.
#
# config/fleet-hosts grammar, one host per line, `#` comments and blank lines
# ignored:
#
#   <name> ssh=<alias> os=<darwin|linux> root=<abs-dir> [key=value...]
#
#   ssh=        OpenSSH config alias (strict host keys, public-key auth).
#   os=         darwin or linux; checked against the live sample.
#   root=       absolute directory on the host that holds Firstmate's fleet
#               files: bin/omp, the agent dir, clones, worktrees, sessions.
#   session=    herdr or tmux: what hosts the worker on that host (default
#               tmux). herdr requires the host's Herdr readiness
#               (docs/fleet-placement.md "Herdr view").
#   slots=      most fleet workers at once on this host (default 1).
#   max_cpu=    host CPU ceiling as a percent of all cores (default 50).
#   reserve_cpus=      cores kept free for the host's own workloads (default 2).
#   reserve_mem_gb=    GiB kept free for the host's own workloads (default 4).
#   worker_cpus=       cores one worker is assumed to use (default 2).
#   worker_mem_gb=     GiB one worker is assumed to use (default 3).
#   hours=HH-HH        local-time window when new placements are allowed,
#                      start inclusive, end exclusive, wrapping midnight
#                      when start > end; absent means always.
#   tz=<IANA zone>     zone for hours= (default the host's own zone).
#   busy_procs=a,b     process names whose presence makes the host busy at
#                      once, with no hold (for example Runner.Worker, a CI
#                      job on a GitHub Actions runner).
#   enabled=0          keep the record but never place on it.
#
# A host sample is one line of space-separated key=value pairs printed by
# fm_fleet_probe_script running on that host:
#
#   os=<darwin|linux> cpus=<logical cores> cpu_pct=<busy % over a 2 s sample>
#   load1=<1-min load> load5=<5-min load> mem_avail_mb=<available MiB>
#   mem_pressure=<normal|warn|critical|unknown> hour=<local hour 0-23>
#   busy=<process name|-> workers=<live fleet workers on the host>
#
# Memory pressure is the kernel's own verdict: macOS
# `sysctl kern.memorystatus_vm_pressure_level` (1 normal, 2 warn, 4 critical);
# Linux PSI `/proc/pressure/memory` (some avg60 >= 10 warn, full avg60 >= 5
# critical), else MemAvailable below 10% warn and below 5% critical. Warn or
# worse is no headroom.
set -u

FM_FLEET_DEFAULT_SLOTS=1
FM_FLEET_DEFAULT_MAX_CPU=50
FM_FLEET_DEFAULT_RESERVE_CPUS=2
FM_FLEET_DEFAULT_RESERVE_MEM_GB=4
FM_FLEET_DEFAULT_WORKER_CPUS=2
FM_FLEET_DEFAULT_WORKER_MEM_GB=3
# Hysteresis windows (seconds): how long an over-ceiling signal must persist
# before a host turns busy, and how long every signal must stay clear before a
# busy host turns available again.
FM_FLEET_BUSY_HOLD=${FM_FLEET_BUSY_HOLD:-60}
FM_FLEET_CLEAR_HOLD=${FM_FLEET_CLEAR_HOLD:-300}

# fm_fleet_host_field <record-line> <key> [default]: one key=value field from
# a config/fleet-hosts record or a host sample.
fm_fleet_host_field() {
  local line=$1 key=$2 def=${3-} word
  for word in $line; do
    case "$word" in
      "$key="*) printf '%s' "${word#*=}"; return 0 ;;
    esac
  done
  printf '%s' "$def"
}

# fm_fleet_hosts <config-file>: the valid host records, one normalized line
# each ("<name> <fields...>"). An invalid record stops the read with an error
# naming the line, because a typo in a resource limit must never silently
# widen where work lands.
fm_fleet_hosts() {
  local file=$1 raw line name n=0 key val word
  [ -f "$file" ] || return 0
  while IFS= read -r raw || [ -n "$raw" ]; do
    n=$((n + 1))
    line=${raw%%#*}
    line=$(printf '%s' "$line" | tr -s '[:space:]' ' ')
    line=${line# }
    line=${line% }
    [ -n "$line" ] || continue
    name=${line%% *}
    case "$name" in
      ''|*[!A-Za-z0-9._-]*|*=*)
        echo "error: $file:$n: host name '$name' must be [A-Za-z0-9._-]+" >&2
        return 1
        ;;
    esac
    for word in ${line#"$name"}; do
      key=${word%%=*}
      val=${word#*=}
      [ "$key" != "$word" ] || { echo "error: $file:$n: '$word' is not key=value" >&2; return 1; }
      case "$key" in
        ssh) case "$val" in ''|*[!A-Za-z0-9._@-]*) echo "error: $file:$n: ssh=$val is not an SSH alias" >&2; return 1 ;; esac ;;
        os) case "$val" in darwin|linux) ;; *) echo "error: $file:$n: os= must be darwin or linux" >&2; return 1 ;; esac ;;
        session) case "$val" in herdr|tmux) ;; *) echo "error: $file:$n: session= must be herdr or tmux" >&2; return 1 ;; esac ;;
        root)
          case "$val" in
            /*) case "$val" in *[!A-Za-z0-9._/-]*) echo "error: $file:$n: root=$val has unsupported characters" >&2; return 1 ;; esac ;;
            *) echo "error: $file:$n: root= must be absolute" >&2; return 1 ;;
          esac
          ;;
        slots|reserve_cpus|reserve_mem_gb|worker_cpus|worker_mem_gb)
          case "$val" in ''|*[!0-9]*) echo "error: $file:$n: $key=$val must be a whole number" >&2; return 1 ;; esac ;;
        max_cpu)
          case "$val" in ''|*[!0-9]*) echo "error: $file:$n: max_cpu=$val must be a whole percent" >&2; return 1 ;; esac
          [ "$val" -ge 1 ] && [ "$val" -le 100 ] || { echo "error: $file:$n: max_cpu=$val must be 1-100" >&2; return 1; }
          ;;
        hours)
          case "$val" in
            [0-2][0-9]-[0-2][0-9]) ;;
            *) echo "error: $file:$n: hours=$val must be HH-HH" >&2; return 1 ;;
          esac
          [ "$((10#${val%-*}))" -le 24 ] && [ "$((10#${val#*-}))" -le 24 ] \
            || { echo "error: $file:$n: hours=$val out of range" >&2; return 1; }
          ;;
        tz) case "$val" in ''|*[!A-Za-z0-9_/+-]*) echo "error: $file:$n: tz=$val is not a zone name" >&2; return 1 ;; esac ;;
        busy_procs) case "$val" in ''|*[!A-Za-z0-9._,-]*) echo "error: $file:$n: busy_procs=$val must be comma-separated process names" >&2; return 1 ;; esac ;;
        enabled) case "$val" in 0|1) ;; *) echo "error: $file:$n: enabled= must be 0 or 1" >&2; return 1 ;; esac ;;
        *) echo "error: $file:$n: unknown field '$key'" >&2; return 1 ;;
      esac
    done
    for key in ssh os root; do
      [ -n "$(fm_fleet_host_field "$line" "$key")" ] \
        || { echo "error: $file:$n: host $name is missing $key=" >&2; return 1; }
    done
    printf '%s\n' "$line"
  done < "$file"
}

# fm_fleet_host_record <config-file> <name>: the one record for <name>.
fm_fleet_host_record() {
  local records line
  records=$(fm_fleet_hosts "$1") || return 1
  while IFS= read -r line; do
    [ "${line%% *}" = "$2" ] && { printf '%s\n' "$line"; return 0; }
  done <<EOF
$records
EOF
  echo "error: no fleet host named $2 in $1" >&2
  return 1
}

# fm_fleet_probe_script <root> <tz> <busy-procs>: POSIX sh source that prints
# one sample line on the host. Runs non-interactively over SSH, so it uses
# only base-system tools present on macOS and Linux. The CPU fraction is a
# 2-second sample of whole-host utilization.
fm_fleet_probe_script() {
  local root=$1 tz=$2 procs=$3
  cat <<EOF
PATH=/usr/bin:/bin:/usr/sbin:/sbin:\$PATH
os=\$(uname -s | tr 'A-Z' 'a-z')
pressure=unknown
if [ "\$os" = darwin ]; then
  cpus=\$(sysctl -n hw.logicalcpu)
  set -- \$(sysctl -n vm.loadavg)
  load1=\$2 load5=\$3
  pagesz=\$(sysctl -n hw.pagesize)
  avail=\$(vm_stat | awk -v p="\$pagesz" '/Pages free/ {f=\$3} /Pages inactive/ {i=\$3} /Pages speculative/ {s=\$3} /Pages purgeable/ {g=\$3} END {gsub(/\\./,"",f); gsub(/\\./,"",i); gsub(/\\./,"",s); gsub(/\\./,"",g); printf "%d", (f+i+s+g)*p/1048576}')
  cpu=\$(top -l 2 -n 0 -s 2 | awk '/CPU usage/ {line=\$0} END {n=split(line, a, " "); for (i=1;i<=n;i++) if (a[i] ~ /idle/) {v=a[i-1]; sub(/%/,"",v); printf "%d", 100 - v + 0.5}}')
  case "\$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)" in
    1) pressure=normal ;; 2) pressure=warn ;; 4) pressure=critical ;;
  esac
else
  cpus=\$(getconf _NPROCESSORS_ONLN)
  read -r load1 load5 _ < /proc/loadavg
  avail=\$(awk '/^MemAvailable:/ {printf "%d", \$2/1024}' /proc/meminfo)
  s1=\$(awk '/^cpu / {print \$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9, \$5+\$6}' /proc/stat)
  sleep 2
  s2=\$(awk '/^cpu / {print \$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9, \$5+\$6}' /proc/stat)
  cpu=\$(printf '%s %s\n' "\$s1" "\$s2" | awk '{t=\$3-\$1; i=\$4-\$2; if (t > 0) printf "%d", (t-i)*100/t + 0.5}')
  if [ -r /proc/pressure/memory ]; then
    pressure=\$(awk '/^some/ {split(\$3,a,"="); s=a[2]} /^full/ {split(\$3,b,"="); f=b[2]} END {if (f+0 >= 5) print "critical"; else if (s+0 >= 10) print "warn"; else print "normal"}' /proc/pressure/memory)
  else
    pressure=\$(awk '/^MemTotal:/ {t=\$2} /^MemAvailable:/ {a=\$2} END {if (t <= 0) print "unknown"; else if (a*100/t < 5) print "critical"; else if (a*100/t < 10) print "warn"; else print "normal"}' /proc/meminfo)
  fi
fi
if [ -n '$tz' ]; then hour=\$(TZ='$tz' date +%H); else hour=\$(date +%H); fi
hour=\$(printf '%s' "\$hour" | sed 's/^0//')
busy=-
for p in \$(printf '%s' '$procs' | tr ',' ' '); do
  if pgrep -x "\$p" >/dev/null 2>&1; then busy=\$p; break; fi
done
workers=0
for f in '$root'/run/*.pid; do
  [ -f "\$f" ] || continue
  pid=\$(cat "\$f" 2>/dev/null)
  case "\$pid" in ''|*[!0-9]*) continue ;; esac
  kill -0 "\$pid" 2>/dev/null && workers=\$((workers + 1))
done
printf 'os=%s cpus=%s cpu_pct=%s load1=%s load5=%s mem_avail_mb=%s mem_pressure=%s hour=%s busy=%s workers=%s\n' \
  "\$os" "\$cpus" "\${cpu:-}" "\$load1" "\$load5" "\$avail" "\$pressure" "\${hour:-0}" "\$busy" "\$workers"
EOF
}

# fm_fleet_in_hours <window HH-HH|empty> <hour>: 0 when <hour> is inside.
fm_fleet_in_hours() {
  local win=$1 hour=$2 start end
  [ -n "$win" ] || return 0
  start=$((10#${win%-*}))
  end=$((10#${win#*-}))
  hour=$((10#$hour))
  if [ "$start" -eq "$end" ]; then
    return 0
  elif [ "$start" -lt "$end" ]; then
    [ "$hour" -ge "$start" ] && [ "$hour" -lt "$end" ]
  else
    [ "$hour" -ge "$start" ] || [ "$hour" -lt "$end" ]
  fi
}

# fm_fleet_sample_valid <sample>: 0 when every numeric field parses.
fm_fleet_sample_valid() {
  local s=$1 k v
  for k in cpus cpu_pct mem_avail_mb hour workers; do
    v=$(fm_fleet_host_field "$s" "$k")
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
  done
  for k in load1 load5; do
    v=$(fm_fleet_host_field "$s" "$k")
    case "$v" in ''|*[!0-9.]*) return 1 ;; esac
  done
  [ "$(fm_fleet_host_field "$s" cpus)" -gt 0 ]
}

# fm_fleet_pressure_reason <record> <sample>: the reason a sample is over its
# host's ceilings right now, or nothing when it is clear. Busy processes are
# reported separately because they skip the busy hold.
fm_fleet_pressure_reason() {
  local rec=$1 s=$2 max cpus cpu load1 pressure
  max=$(fm_fleet_host_field "$rec" max_cpu "$FM_FLEET_DEFAULT_MAX_CPU")
  cpus=$(fm_fleet_host_field "$s" cpus)
  cpu=$(fm_fleet_host_field "$s" cpu_pct)
  load1=$(fm_fleet_host_field "$s" load1)
  pressure=$(fm_fleet_host_field "$s" mem_pressure)
  case "$pressure" in
    warn|critical) printf 'memory pressure %s' "$pressure"; return 0 ;;
  esac
  if [ "$cpu" -gt "$max" ]; then
    printf 'cpu %s%% > %s%%' "$cpu" "$max"; return 0
  fi
  awk -v l="$load1" -v c="$cpus" -v m="$max" 'BEGIN { if (l * 100 / c > m) { printf "load %.2f > %d%% of %d cores", l, m, c; exit 0 } exit 1 }'
}

# fm_fleet_availability <state-file> <record> <sample> <now>: advance one
# host's persisted availability state machine and print its verdict line:
#   available <reason>
#   busy <reason>
#   unknown <reason>
# State file: one line
#   state=<available|busy> over_since=<epoch|-> last_busy=<epoch|-> last=<epoch>
# Rules (Crabbox serve's gating; Firstmate samples on demand, so the kernel's
# own 1- and 5-minute load averages stand in for the samples it did not take):
# - unreachable or unreadable signals: unknown now, state unchanged;
# - a busy process: busy now, no hold;
# - over a ceiling: busy once observed over for FM_FLEET_BUSY_HOLD, or at once
#   when the 1-minute load average itself is over the ceiling, because that
#   average already spans the hold. A gap since the previous sample longer
#   than the hold restarts that run, since an unobserved gap proves nothing;
# - clear: a busy host turns available only when FM_FLEET_CLEAR_HOLD has
#   passed since it was last observed busy and the 5-minute load average is
#   under the ceiling, so a burst inside an unsampled gap still holds it busy;
# - with no state file, a clear sample starts available only when its
#   5-minute load average is under the ceiling.
fm_fleet_availability() {
  local file=$1 rec=$2 s=$3 now=$4 state=available over=- last_busy=- prev='' reason
  local max cpus load1 load5 load1_over=0 load5_over=0 last proc
  if [ -f "$file" ]; then
    prev=$(cat "$file")
    state=$(fm_fleet_host_field "$prev" state available)
    over=$(fm_fleet_host_field "$prev" over_since -)
    last_busy=$(fm_fleet_host_field "$prev" last_busy -)
    last=$(fm_fleet_host_field "$prev" last 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ "$((now - last))" -le "$FM_FLEET_BUSY_HOLD" ] || over=-
  fi
  if [ -z "$s" ]; then
    printf 'unknown unreachable\n'; return 0
  fi
  if ! fm_fleet_sample_valid "$s"; then
    printf 'unknown unreadable sample\n'; return 0
  fi
  if [ "$(fm_fleet_host_field "$s" mem_pressure)" = unknown ]; then
    printf 'unknown memory pressure unreadable\n'; return 0
  fi
  max=$(fm_fleet_host_field "$rec" max_cpu "$FM_FLEET_DEFAULT_MAX_CPU")
  cpus=$(fm_fleet_host_field "$s" cpus)
  load1=$(fm_fleet_host_field "$s" load1)
  load5=$(fm_fleet_host_field "$s" load5)
  awk -v l="$load1" -v c="$cpus" -v m="$max" 'BEGIN { exit !(l * 100 / c > m) }' && load1_over=1
  awk -v l="$load5" -v c="$cpus" -v m="$max" 'BEGIN { exit !(l * 100 / c > m) }' && load5_over=1
  proc=$(fm_fleet_host_field "$s" busy -)
  if [ "$proc" != - ]; then
    state=busy over=$now last_busy=$now
    reason="$proc running"
  elif reason=$(fm_fleet_pressure_reason "$rec" "$s"); then
    [ "$over" != - ] || over=$now
    if [ "$state" = busy ] || [ "$((now - over))" -ge "$FM_FLEET_BUSY_HOLD" ] || [ "$load1_over" = 1 ]; then
      state=busy
      last_busy=$now
    else
      reason="$reason for $((now - over))s (busy after ${FM_FLEET_BUSY_HOLD}s)"
    fi
  else
    over=-
    if [ "$state" = busy ]; then
      if [ "$last_busy" != - ] && [ "$((now - last_busy))" -lt "$FM_FLEET_CLEAR_HOLD" ]; then
        reason="clear for $((now - last_busy))s (available after ${FM_FLEET_CLEAR_HOLD}s)"
      elif [ "$load5_over" = 1 ]; then
        reason="clear now but 5-min load $load5 is over the ceiling"
      else
        state=available
        reason=clear
      fi
    elif [ -z "$prev" ] && [ "$load5_over" = 1 ]; then
      state=busy
      last_busy=$now
      reason="5-min load $load5 over the ceiling"
    else
      reason=clear
    fi
  fi
  printf 'state=%s over_since=%s last_busy=%s last=%s\n' "$state" "$over" "$last_busy" "$now" > "$file.tmp.$$" \
    && mv "$file.tmp.$$" "$file"
  printf '%s %s\n' "$state" "$reason"
}

# fm_fleet_evaluate <record> <sample> <availability-line> <pending>: one
# verdict line for placement.
#   ok <name> spare_cpu=<x.xx> spare_mem_gb=<x.xx>
#   no <name> <reason>
# <pending> counts this home's unexpired reservations for launches on the
# host whose worker has not started yet; started workers are already in the
# sample's workers= and load, so two concurrent placements can never both
# claim the last slot and a running worker is never counted twice.
fm_fleet_evaluate() {
  local rec=$1 s=$2 avail=$3 pending=${4:-0} name os slots rcpu rmem wcpu wmem hours
  local s_os cpus load1 mem hour workers held
  name=${rec%% *}
  if [ "$(fm_fleet_host_field "$rec" enabled 1)" = 0 ]; then
    printf 'no %s disabled in config\n' "$name"; return 0
  fi
  case "$avail" in
    "available clear") ;;
    available*) printf 'no %s rising: %s\n' "$name" "${avail#available }"; return 0 ;;
    *) printf 'no %s %s\n' "$name" "$avail"; return 0 ;;
  esac
  os=$(fm_fleet_host_field "$rec" os)
  s_os=$(fm_fleet_host_field "$s" os)
  if [ "$s_os" != "$os" ]; then
    printf 'no %s os mismatch (config %s, host %s)\n' "$name" "$os" "$s_os"; return 0
  fi
  hours=$(fm_fleet_host_field "$rec" hours)
  hour=$(fm_fleet_host_field "$s" hour)
  if ! fm_fleet_in_hours "$hours" "$hour"; then
    printf 'no %s outside hours %s (local hour %s)\n' "$name" "$hours" "$hour"; return 0
  fi
  slots=$(fm_fleet_host_field "$rec" slots "$FM_FLEET_DEFAULT_SLOTS")
  workers=$(fm_fleet_host_field "$s" workers)
  held=$((workers + pending))
  if [ "$held" -ge "$slots" ]; then
    printf 'no %s full (%s of %s slots)\n' "$name" "$held" "$slots"; return 0
  fi
  rcpu=$(fm_fleet_host_field "$rec" reserve_cpus "$FM_FLEET_DEFAULT_RESERVE_CPUS")
  rmem=$(fm_fleet_host_field "$rec" reserve_mem_gb "$FM_FLEET_DEFAULT_RESERVE_MEM_GB")
  wcpu=$(fm_fleet_host_field "$rec" worker_cpus "$FM_FLEET_DEFAULT_WORKER_CPUS")
  wmem=$(fm_fleet_host_field "$rec" worker_mem_gb "$FM_FLEET_DEFAULT_WORKER_MEM_GB")
  cpus=$(fm_fleet_host_field "$s" cpus)
  load1=$(fm_fleet_host_field "$s" load1)
  mem=$(fm_fleet_host_field "$s" mem_avail_mb)
  awk -v n="$name" -v c="$cpus" -v l="$load1" -v rc="$rcpu" -v wc="$wcpu" \
    -v a="$mem" -v rm="$rmem" -v wm="$wmem" -v h="$pending" 'BEGIN {
      sc = c - rc - l - h * wc
      sm = a / 1024 - rm - h * wm
      if (sc < wc) { printf "no %s cpu headroom %.2f < %d (load %.2f of %d cores)\n", n, sc, wc, l, c; exit }
      if (sm < wm) { printf "no %s memory headroom %.2f GiB < %d\n", n, sm, wm; exit }
      printf "ok %s spare_cpu=%.2f spare_mem_gb=%.2f\n", n, sc - wc, sm - wm
    }'
}

# fm_fleet_pick <verdict-lines>: the winning host name from fm_fleet_evaluate
# output, or nonzero when none is eligible. Most spare cores wins, ties broken
# by spare memory, then by name.
fm_fleet_pick() {
  printf '%s\n' "$1" | awk '$1 == "ok" {
      split($3, c, "="); split($4, m, "=")
      printf "%s %s %s\n", c[2], m[2], $2
    }' | sort -k1,1nr -k2,2nr -k3,3 | awk 'NR == 1 {print $3; found = 1} END {exit !found}'
}
