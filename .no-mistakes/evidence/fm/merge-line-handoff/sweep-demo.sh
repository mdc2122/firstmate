# One watcher sweep over a merge-queue-app base with a 4-PR declared line, all green,
# none queued yet. Prints which PRs the watcher handed to the queue in that single sweep.
sweep_demo() {  # <label>
  local dir
  dir=$(queue_line_case "sweep-demo-$1" 4)
  queue_line_cycle "$dir" c1
  printf '%s: PRs handed to the merge queue in sweep 1: [%s]\n' "$1" "$(forge_merges "$dir")"
  grep '^pr merge' "$dir/gh.log" | sed 's/^/    gh /'
  grep -h 'merge line' "$dir/home/state/.watch-triage.log" 2>/dev/null | sed 's/^/    triage: /' | head -8
}
