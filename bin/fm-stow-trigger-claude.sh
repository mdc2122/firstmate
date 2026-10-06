#!/usr/bin/env bash
# fm-stow-trigger-claude.sh - Claude Code hook adapter for bin/fm-stow-trigger.sh.
#
# Claude Code exposes no context-usage reading to a hook, so a Claude primary
# gets only the pre-compaction trigger: the tracked .claude/settings.json runs
#   PreCompact    -> fm-stow-trigger-claude.sh compacting
#   SessionStart  -> fm-stow-trigger-claude.sh cycle   (startup, clear, compact;
#                    an in-process resume keeps its old cycle, while a
#                    process-level resume re-takes state/.lock and so starts a
#                    new cycle under fm-stow-trigger.sh's holder-change rule)
# with the hook payload on stdin. Like the omp and Pi extensions, it reports only
# from a genuine primary checkout whose fleet lock this session holds, and stands
# down on a Cursor-delivered payload. It never blocks or delays compaction or a
# session start: the report runs detached with no output, and this always exits
# 0 with nothing on stdout.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

ACTION=${1:-}
case "$ACTION" in
  compacting|cycle) ;;
  *) exit 0 ;;
esac

PAYLOAD=$(cat 2>/dev/null || true)

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_session_lock_owned_by_self "$STATE" || exit 0

if [ "$ACTION" = cycle ] && command -v jq >/dev/null 2>&1; then
  case "$(printf '%s' "$PAYLOAD" | jq -r '.source? // empty' 2>/dev/null)" in
    resume|reload|fork) exit 0 ;;
  esac
fi

"$SCRIPT_DIR/fm-stow-trigger.sh" "$ACTION" </dev/null >/dev/null 2>&1 &
exit 0
