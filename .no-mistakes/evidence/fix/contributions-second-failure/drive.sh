#!/usr/bin/env bash
# Live driver: real bin/fm-contributions.sh poll against a disposable FM home with a fake gh forge.
# Usage: drive.sh <repo-root> <scenario>
set -u
REPO=$1; SCEN=$2
# Reuse the suite's fixture builders (new_home, forge_home, wrap_forge, with_home) without running tests.
sed -e '/^failures=0/,$d' -e "s|\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh|$REPO/tests/lib.sh|" "$REPO/tests/fm-contributions.test.sh" > "$TMPDIR/fmc-helpers.$$.sh"
. "$TMPDIR/fmc-helpers.$$.sh"; rm -f "$TMPDIR/fmc-helpers.$$.sh"
ROOT=$REPO
home=$(new_home "live-$SCEN"); forge_home "$home"; wrap_forge "$home"
poll() { # time fault
  if [ "$2" = ok ]; then : > "$home/forge/fault"; else printf 'down\n' > "$home/forge/fault"; fi
  local out; out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$1" "$ROOT/bin/fm-contributions.sh" poll 2>&1); rc=$?
  printf '%s forge=%-4s rc=%s stdout=[%s]' "$1" "$2" "$rc" "$out"
  for t in "${OWNERS[@]}"; do
    [ -f "$home/data/$t/contributions.json" ] && printf ' %s:%s' "$t" "$(jq -c '.records[0]|{error:(.error!=null),fail_streak}' "$home/data/$t/contributions.json")"
  done; echo
}
OWNERS=(delivery)
case $SCEN in
  single)
    poll 2026-09-20T09:00:00Z down; poll 2026-09-20T09:10:00Z down; poll 2026-09-20T09:20:00Z down; poll 2026-09-20T09:30:00Z down
    poll 2026-09-20T09:40:00Z ok; poll 2026-09-20T09:50:00Z down; poll 2026-09-20T10:00:00Z down ;;
  flap)
    for i in 0 1 2 3; do poll 2026-09-20T1$i:00:00Z down; poll 2026-09-20T1$i:30:00Z ok; done ;;
  late)
    poll 2026-09-20T09:00:00Z down
    printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"; OWNERS=(delivery duplicate)
    echo "# late owner 'duplicate' added"
    poll 2026-09-20T09:10:00Z down; poll 2026-09-20T09:20:00Z down; poll 2026-09-20T09:30:00Z down; poll 2026-09-20T09:40:00Z ok ;;
  invalid)
    printf -- '- [ ] %s - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' "$3" >> "$home/data/backlog.md"; OWNERS=(delivery)
    echo "# shared owner with invalid id '$3' added"
    poll 2026-09-20T09:00:00Z down; poll 2026-09-20T09:10:00Z down; poll 2026-09-20T09:20:00Z down ;;
esac
