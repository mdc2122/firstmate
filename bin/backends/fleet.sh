#!/usr/bin/env bash
# bin/backends/fleet.sh - session-provider adapter for omp workers that
# bin/fm-fleet.sh placed on a donor host.
#
# A fleet task's record carries backend=fleet, window=fleet:<task-id>, and the
# host-side endpoint in fleet_endpoint= (`herdr:<workspace>/<pane>` on the
# host's fm-fleet Herdr server, or `tmux:fm-<id>` on the host's tmux). Every
# operation below delegates to bin/fm-fleet.sh, which owns the SSH and Herdr
# saved-machine transport, so fm-send, fm-peek, fm-watch, fm-crew-state,
# fm-control, and fm-teardown reach a remote worker through the ordinary
# backend dispatch in bin/fm-backend.sh. Sourced only through
# fm_backend_source fleet.
#
# Target string shape: `fleet:<task-id>`.

fm_backend_fleet_id() {  # <target> -> task id
  case "$1" in
    fleet:?*) printf '%s' "${1#fleet:}" ;;
    *) return 1 ;;
  esac
}

fm_backend_fleet_cli() {  # <args...>
  "$FM_BACKEND_LIB_DIR/fm-fleet.sh" "$@"
}

# fm_backend_fleet_capture: bounded plain-text read of the worker's pane.
# Returns FM_BACKEND_CAPTURE_ABSENT only on the host's own positive verdict
# that the endpoint is gone; an unreachable host is an ordinary read failure.
fm_backend_fleet_capture() {  # <target> <lines>
  local id
  id=$(fm_backend_fleet_id "$1") || return 1
  if fm_backend_fleet_cli peek "$id" "${2:-40}" 2>/dev/null; then
    return 0
  fi
  [ "$(fm_backend_fleet_cli state "$id" 2>/dev/null)" != missing ] || return "$FM_BACKEND_CAPTURE_ABSENT"
  return 1
}

# fm_backend_fleet_send_key: one named key. Escape, Enter, and C-c map to the
# host endpoint's own key names.
fm_backend_fleet_send_key() {  # <target> <key>
  local id
  id=$(fm_backend_fleet_id "$1") || return 1
  fm_backend_fleet_cli key "$id" "$2"
}

# fm_backend_fleet_send_text_submit: type <text> once and submit. The verdict
# is `empty` when the host accepted both, `send-failed` otherwise; a remote
# composer is not classified, so delivery proof stays with the steering inbox.
fm_backend_fleet_send_text_submit() {  # <target> <text> ...
  local id
  id=$(fm_backend_fleet_id "$1") || { printf 'send-failed'; return 0; }
  if fm_backend_fleet_cli type "$id" "$2" >/dev/null 2>&1; then
    printf 'empty'
  else
    printf 'send-failed'
  fi
}

# fm_backend_fleet_kill: stop the worker and close its endpoint without
# discarding anything: the host worktree, branch, and omp session stay until
# `fm-fleet.sh release` fetches them home.
fm_backend_fleet_kill() {  # <target>
  local id
  id=$(fm_backend_fleet_id "$1") || return 1
  fm_backend_fleet_cli stop "$id"
}

# fm_backend_fleet_agent_state: the recovery-grade vocabulary of
# fm_backend_agent_state, read on the host (bin/fm-fleet.sh state): alive,
# dead (endpoint present, omp gone), missing (endpoint gone), or unreadable
# (host or its Herdr did not answer - never proof of death).
fm_backend_fleet_agent_state() {  # <target>
  local id out
  id=$(fm_backend_fleet_id "$1") || { printf 'unreadable'; return 0; }
  out=$(fm_backend_fleet_cli state "$id" 2>/dev/null) || out=unreadable
  case "$out" in
    alive|dead|missing) printf '%s' "$out" ;;
    *) printf 'unreadable' ;;
  esac
}

fm_backend_fleet_agent_alive() {  # <target>
  case "$(fm_backend_fleet_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_fleet_target_exists: cheap presence read.
fm_backend_fleet_target_exists() {  # <target>
  case "$(fm_backend_fleet_agent_state "$1")" in
    alive|dead) return 0 ;;
  esac
  return 1
}
