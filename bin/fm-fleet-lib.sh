#!/usr/bin/env bash
# bin/fm-fleet-lib.sh - fleet placement for omp ship workers on donor hosts.
#
# Sourced by bin/fm-fleet.sh. No side effects on source.
#
# The fleet is opt-in: config/fleet-hosts lists the donor hosts and their
# limits, and its absence means no task is ever placed off this machine.
# docs/fleet-placement.md owns the operator contract (setup, launch,
# monitoring, recovery, removal); this file owns the config grammar, the
# sample format, and the placement decision.
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
#   slots=      most fleet workers at once on this host (default 1).
#   reserve_cpus=      cores kept free for the host's own workloads (default 2).
#   reserve_mem_gb=    GiB kept free for the host's own workloads (default 4).
#   worker_cpus=       cores one worker is assumed to use (default 2).
#   worker_mem_gb=     GiB one worker is assumed to use (default 3).
#   hours=HH-HH        local-time window when new placements are allowed,
#                      start inclusive, end exclusive, wrapping midnight
#                      when start > end; absent means always.
#   tz=<IANA zone>     zone for hours= (default the host's own zone).
#   busy_procs=a,b     process names whose presence makes the host busy
#                      (for example Runner.Worker for a CI runner).
#   enabled=0          keep the record but never place on it.
#
# A host sample is one line of space-separated key=value pairs printed by
# fm_fleet_probe_script running on that host:
#
#   os=<uname -s lowercased> cpus=<logical cores> load1=<1-min load>
#   mem_avail_mb=<available MiB> hour=<local hour 0-23> busy=<proc|-> workers=<n>
#
# Placement score: a host is eligible only when every check passes; the
# eligible host with the most spare cores (cpus - reserve - load1 - reserved
# worker cores) wins, ties broken by spare memory, then by name.
set -u

FM_FLEET_DEFAULT_SLOTS=1
FM_FLEET_DEFAULT_RESERVE_CPUS=2
FM_FLEET_DEFAULT_RESERVE_MEM_GB=4
FM_FLEET_DEFAULT_WORKER_CPUS=2
FM_FLEET_DEFAULT_WORKER_MEM_GB=3

# fm_fleet_host_field <record-line> <key> [default]: one key=value field from
# a config/fleet-hosts record.
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
        root) case "$val" in /*) case "$val" in *[!A-Za-z0-9._/-]*) echo "error: $file:$n: root=$val has unsupported characters" >&2; return 1 ;; esac ;; *) echo "error: $file:$n: root= must be absolute" >&2; return 1 ;; esac ;;
        slots|reserve_cpus|reserve_mem_gb|worker_cpus|worker_mem_gb)
          case "$val" in ''|*[!0-9]*) echo "error: $file:$n: $key=$val must be a whole number" >&2; return 1 ;; esac ;;
        hours)
          case "$val" in
            [0-2][0-9]-[0-2][0-9]) ;;
            *) echo "error: $file:$n: hours=$val must be HH-HH" >&2; return 1 ;;
          esac
          [ "${val%-*}" -le 24 ] && [ "${val#*-}" -le 24 ] 2>/dev/null \
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
# only base-system tools present on macOS and Linux.
fm_fleet_probe_script() {
  local root=$1 tz=$2 procs=$3
  cat <<EOF
os=\$(uname -s | tr 'A-Z' 'a-z')
if [ "\$os" = darwin ]; then
  cpus=\$(sysctl -n hw.logicalcpu)
  load1=\$(sysctl -n vm.loadavg | awk '{print \$2}')
  pagesz=\$(sysctl -n hw.pagesize)
  avail=\$(vm_stat | awk -v p="\$pagesz" '/Pages free/ {f=\$3} /Pages inactive/ {i=\$3} /Pages speculative/ {s=\$3} /Pages purgeable/ {g=\$3} END {gsub(/\\./,"",f); gsub(/\\./,"",i); gsub(/\\./,"",s); gsub(/\\./,"",g); printf "%d", (f+i+s+g)*p/1048576}')
else
  cpus=\$(getconf _NPROCESSORS_ONLN)
  load1=\$(cut -d' ' -f1 /proc/loadavg)
  avail=\$(awk '/^MemAvailable:/ {printf "%d", \$2/1024}' /proc/meminfo)
fi
if [ -n '$tz' ]; then hour=\$(TZ='$tz' date +%H); else hour=\$(date +%H); fi
hour=\$(printf '%s' "\$hour" | sed 's/^0//')
busy=-
for p in \$(printf '%s' '$procs' | tr ',' ' '); do
  if pgrep -x "\$p" >/dev/null 2>&1; then busy=\$p; break; fi
done
workers=0
if [ -d '$root/run' ]; then
  for f in '$root'/run/*.pid; do
    [ -f "\$f" ] || continue
    pid=\$(cat "\$f" 2>/dev/null)
    case "\$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "\$pid" 2>/dev/null && workers=\$((workers + 1))
  done
fi
printf 'os=%s cpus=%s load1=%s mem_avail_mb=%s hour=%s busy=%s workers=%s\n' "\$os" "\$cpus" "\$load1" "\$avail" "\${hour:-0}" "\$busy" "\$workers"
EOF
}

# fm_fleet_sample_field <sample> <key>
fm_fleet_sample_field() {
  fm_fleet_host_field "$1" "$2"
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

# fm_fleet_evaluate <record> <sample> <reserved-elsewhere>: one verdict line.
#   ok <name> spare_cpu=<x.xx> spare_mem_gb=<x.xx>
#   no <name> <reason>
# <reserved-elsewhere> counts placements this home holds on the host that the
# sample's worker count may not show yet (a launch still in flight), so two
# concurrent placements can never both claim the last slot.
fm_fleet_evaluate() {
  local rec=$1 sample=$2 pending=${3:-0} name os slots rcpu rmem wcpu wmem hours
  local s_os cpus load1 avail hour busy workers held
  name=${rec%% *}
  os=$(fm_fleet_host_field "$rec" os)
  slots=$(fm_fleet_host_field "$rec" slots "$FM_FLEET_DEFAULT_SLOTS")
  rcpu=$(fm_fleet_host_field "$rec" reserve_cpus "$FM_FLEET_DEFAULT_RESERVE_CPUS")
  rmem=$(fm_fleet_host_field "$rec" reserve_mem_gb "$FM_FLEET_DEFAULT_RESERVE_MEM_GB")
  wcpu=$(fm_fleet_host_field "$rec" worker_cpus "$FM_FLEET_DEFAULT_WORKER_CPUS")
  wmem=$(fm_fleet_host_field "$rec" worker_mem_gb "$FM_FLEET_DEFAULT_WORKER_MEM_GB")
  hours=$(fm_fleet_host_field "$rec" hours)
  if [ "$(fm_fleet_host_field "$rec" enabled 1)" = 0 ]; then
    printf 'no %s disabled in config\n' "$name"; return 0
  fi
  if [ -z "$sample" ]; then
    printf 'no %s unreachable\n' "$name"; return 0
  fi
  s_os=$(fm_fleet_sample_field "$sample" os)
  cpus=$(fm_fleet_sample_field "$sample" cpus)
  load1=$(fm_fleet_sample_field "$sample" load1)
  avail=$(fm_fleet_sample_field "$sample" mem_avail_mb)
  hour=$(fm_fleet_sample_field "$sample" hour)
  busy=$(fm_fleet_sample_field "$sample" busy)
  workers=$(fm_fleet_sample_field "$sample" workers)
  case "$cpus:$avail:$hour:$workers" in
    *[!0-9:]*|:*|*::*|*:)
      printf 'no %s unreadable sample\n' "$name"; return 0 ;;
  esac
  case "$load1" in ''|*[!0-9.]*) printf 'no %s unreadable sample\n' "$name"; return 0 ;; esac
  if [ "$s_os" != "$os" ]; then
    printf 'no %s os mismatch (config %s, host %s)\n' "$name" "$os" "$s_os"; return 0
  fi
  if ! fm_fleet_in_hours "$hours" "$hour"; then
    printf 'no %s outside hours %s (local hour %s)\n' "$name" "$hours" "$hour"; return 0
  fi
  if [ -n "$busy" ] && [ "$busy" != - ]; then
    printf 'no %s busy (%s running)\n' "$name" "$busy"; return 0
  fi
  held=$((workers + pending))
  if [ "$held" -ge "$slots" ]; then
    printf 'no %s full (%s of %s slots)\n' "$name" "$held" "$slots"; return 0
  fi
  awk -v n="$name" -v c="$cpus" -v l="$load1" -v rc="$rcpu" -v wc="$wcpu" \
    -v a="$avail" -v rm="$rmem" -v wm="$wmem" -v h="$held" 'BEGIN {
      sc = c - rc - l - h * wc
      sm = a / 1024 - rm - h * wm
      if (sc < wc) { printf "no %s cpu headroom %.2f < %d (load %.2f of %d)\n", n, sc, wc, l, c; exit }
      if (sm < wm) { printf "no %s memory headroom %.2f GiB < %d\n", n, sm, wm; exit }
      printf "ok %s spare_cpu=%.2f spare_mem_gb=%.2f\n", n, sc - wc, sm - wm
    }'
}

# fm_fleet_pick <verdict-lines>: the winning host name from fm_fleet_evaluate
# output, or nonzero when none is eligible.
fm_fleet_pick() {
  printf '%s\n' "$1" | awk '$1 == "ok" {
      split($3, c, "="); split($4, m, "=")
      printf "%s %s %s\n", c[2], m[2], $2
    }' | sort -k1,1nr -k2,2nr -k3,3 | awk 'NR == 1 {print $3; found = 1} END {exit !found}'
}
