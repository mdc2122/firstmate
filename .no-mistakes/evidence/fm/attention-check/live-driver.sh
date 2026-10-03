#!/usr/bin/env bash
# Live driver: builds a disposable firstmate home and drives the real
# bin/fm-attention-check.sh, bin/fm-fleet-view.sh against it.
set -u
W=/Users/studio2/.no-mistakes/worktrees/662ae98237ac/01M41RRYWA7PSK10QJBFTA2R8H
AC=$W/bin/fm-attention-check.sh
VIEW=$W/bin/fm-fleet-view.sh
ROOT=/tmp/fm-attn-live/run
rm -rf "$ROOT"; mkdir -p "$ROOT"
umask 022
ep() { jq -nr --arg t "$1" '$t | fromdateiso8601'; }
touch_at() { local s; s=$(TZ=UTC0 date -r "$1" +%Y%m%d%H%M.%S); TZ=UTC0 touch -t "$s" "$2"; }
say() { printf '\n### %s\n' "$*"; }

FAKEBIN=$ROOT/fakebin; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/no-mistakes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/tmux"   # no live windows: keep off the real tmux server
chmod +x "$FAKEBIN"/*

home_new() {
  local h=$ROOT/$1
  mkdir -p "$h/state" "$h/data" "$h/projects" "$h/config"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$h/data/backlog.md"
  printf '%s\n' "$h"
}
run() { local h=$1 now=$2; shift 2; PATH="$FAKEBIN:$PATH" FM_HOME="$h" FM_ATTENTION_NOW="$now" "$AC" "$@"; }
row() {  # home id verify [suffix]
  local tmp; tmp=$(mktemp)
  awk -v r="- [ ] $2 - work $2 (repo: x) (kind: ship) (since 2026-10-01)${4:-}" -v v="  verify: $3" \
    '{ print } /^## In flight/ { print r; print v }' "$1/data/backlog.md" > "$tmp" && mv "$tmp" "$1/data/backlog.md"
}
steer() {  # home task at body
  local d="$1/state/$2.inbox/handled" n; mkdir -p "$d"
  n=$(find "$d" -name '*.msg' | wc -l | tr -d ' ')
  printf 'schema=fm-task-inbox.v1\nat=%s\n--\n%s\n' "$3" "${4:-carry on}" > "$d/$(printf '%03d' $((n + 1))).msg"
}
gone() {  # home id epoch
  printf 'window=fm-%s\nkind=ship\n' "$2" > "$1/state/$2.meta"
  printf 'notified\n' > "$1/state/.endpoint-gone-fm-$2"; touch_at "$3" "$1/state/.endpoint-gone-fm-$2"
}
gcommit() {  # repo epoch msg
  printf '%s\n' "$3" >> "$1/README.md"; git -C "$1" add README.md
  GIT_COMMITTER_DATE="@$2 +0000" GIT_AUTHOR_DATE="@$2 +0000" git -C "$1" -c user.name=t -c user.email=t@x.invalid commit -qm "$3"
}
gtag() {  # repo epoch name   (annotated, like viral-moment's)
  GIT_COMMITTER_DATE="@$2 +0000" git -C "$1" -c user.name=t -c user.email=t@x.invalid tag -a "$3" -m "$3"
}
vm_repo() {  # home -> viral-moment-like repo: 15 merges in the window, prod tags annotated
  local r=$1/projects/viral-moment i t0
  mkdir -p "$r"; git -C "$r" init -q -b main; gcommit "$r" $((N - 40 * 3600)) init
  t0=$((N - 20 * 3600))
  for i in $(seq 1 15); do
    gcommit "$r" $((t0 + i * 3600)) "merge $i"
    # merges 3 and 9 wait 3 h for their release; every other ships within 20 min
    case $i in 3|9) ;; 4|10) gtag "$r" $((t0 + i * 3600 + 600)) "prod-$i" ;; *) gtag "$r" $((t0 + i * 3600 + 1200)) "prod-$i" ;; esac
  done
  git -C "$r" update-ref refs/remotes/origin/main HEAD
  printf '%s\n' "$r"
}

NOW=2026-10-03T14:00:00Z; N=$(ep $NOW)

say "S-A on-demand scan, empty home, real clock (no FM_ATTENTION_NOW)"
H=$(home_new empty)
before=$(find "$H" -type f | sort)
PATH="$FAKEBIN:$PATH" FM_HOME="$H" "$AC"; echo "rc=$?"
after=$(find "$H" -type f | sort)
[ "$before" = "$after" ] && echo "files unchanged by scan: yes" || echo "files unchanged by scan: NO"
PATH="$FAKEBIN:$PATH" FM_HOME="$H" "$AC" --help | head -3

say "S-B report-style RED day: decisions sampled by check through the day, ownerless row, low constraint share"
H=$(home_new redday)
row "$H" grokbot-if-lane-build "ship it"
row "$H" ballot-top-finishing "every top card gets a product review verdict"
gone "$H" grokbot-if-lane-build $((N - 38 * 3600))
for i in $(seq 1 9); do steer "$H" grokbot-if-lane-build "2026-10-03T0$((i % 9)):1${i}:00Z"; done
for i in 1 2 3; do steer "$H" ballot-top-finishing "2026-10-03T10:0${i}:00Z" "You are next in line for the release."; done
for i in 1 2 3; do steer "$H" grokbot-if-lane-build "2026-10-02T1${i}:00:00Z"; done
steer "$H" ballot-top-finishing "2026-10-02T16:00:00Z"
# Three decisions open together from 08:00 to 09:50; a fourth 10:00 to 12:30. Watcher samples every 10 min.
t=$(ep 2026-10-03T07:50:00Z)
while [ "$t" -le $((N - 3600)) ]; do
  iso=$(jq -nr --argjson e "$t" '$e | todate')
  hm=${iso:11:5}
  for k in 1 2 3; do
    if [[ "$hm" > "07:59" && "$hm" < "09:50" ]]; then
      printf 'needs-decision [key=q%s]: pick one\n' $k > "$H/state/w$k.status"
    elif [ -f "$H/state/w$k.status" ] && ! grep -q resolved "$H/state/w$k.status"; then
      printf 'resolved [key=q%s]: done\n' $k >> "$H/state/w$k.status"
    fi
  done
  if [[ "$hm" > "09:59" && "$hm" < "12:30" ]]; then
    printf 'needs-decision [key=q4]: release?\n' > "$H/state/w4.status"
  elif [ -f "$H/state/w4.status" ] && ! grep -q resolved "$H/state/w4.status"; then
    printf 'resolved [key=q4]: done\n' >> "$H/state/w4.status"
  fi
  for f in "$H"/state/w*.status; do [ -f "$f" ] && touch_at "$t" "$f"; done
  run "$H" "$iso" check || echo "check failed at $iso"
  t=$((t + 600))
done
echo "-- first-seen record after sampling (state/.attention-first-seen):"; cat "$H/state/.attention-first-seen"
echo "-- scan at 14:00Z:"; run "$H" $NOW scan

say "S-J check before 13:00Z only samples (no daily record)"
ls -1a "$H/state" | grep -E '^\.attention' ; [ -e "$H/state/.attention-check" ] && echo "daily record exists: YES (bad)" || echo "daily record exists: no"

say "S-B2 first check after 13:00Z wakes once on RED; a later check the same day stays quiet"
echo "-- check at 13:05Z:"; run "$H" 2026-10-03T13:05:00Z check; echo "rc=$?"
echo "-- durable wake queue:"; cat "$H/state/.wake-queue"
echo "-- daily record:"; cat "$H/state/.attention-check"
echo "-- check at 16:00Z (same day):"; out=$(run "$H" 2026-10-03T16:00:00Z check); echo "output='$out'"
echo "-- wake queue attention entries: $(grep -c attention "$H/state/.wake-queue")"

say "S-C merged-but-not-live: viral-moment with a main commit unreleased for 5 h"
H=$(home_new notlive)
R=$(vm_repo "$H")
echo "-- all merged & tagged (prod tag = origin/main):"; run "$H" $NOW scan
gcommit "$R" $((N - 5 * 3600)) "merged, not deployed"; git -C "$R" update-ref refs/remotes/origin/main HEAD
echo "-- after a 5h-old unreleased merge:"; run "$H" $NOW scan
echo "-- git cat-file -t prod-15: $(git -C "$R" cat-file -t prod-15)"

say "S-F adversarial: a lightweight prod tag on the unreleased commit must not hide it"
git -C "$R" tag prod-99
run "$H" $NOW scan

say "S-D AMBER day: daily line recorded without a wake and shown in the fleet view"
H=$(home_new amberday)
printf 'https://github.com/o/r/pull/7 abc %s 0\n' $((N - 3600)) > "$H/state/t1.pr-green-blocked"
echo "-- fleet view before any daily line (Attention section):"
PATH="$FAKEBIN:$PATH" FM_HOME="$H" "$VIEW" | sed -n '/^## Attention/,$p'
out=$(run "$H" 2026-10-03T13:05:00Z check); echo "check output='$out' rc=$?"
echo "-- daily record:"; cat "$H/state/.attention-check"
[ -e "$H/state/.wake-queue" ] && grep -c attention "$H/state/.wake-queue" || echo "wake queue: none (no wake)"
echo "-- fleet view after (Attention section):"
PATH="$FAKEBIN:$PATH" FM_HOME="$H" "$VIEW" | sed -n '/^## Attention/,$p'
echo "-- snapshot JSON .attention_check:"
PATH="$FAKEBIN:$PATH" FM_HOME="$H" "$VIEW" --json | jq -r .attention_check

say "S-E adversarial: backlog exists but is unreadable -> S8/S11 unknown, verdict unmoved"
H=$(home_new unreadable)
row "$H" lost "ship it"; gone "$H" lost $((N - 40 * 3600))
steer "$H" lost 2026-10-03T09:00:00Z; steer "$H" lost 2026-10-02T09:00:00Z
printf 'https://github.com/o/r/pull/7 abc %s 0\n' $((N - 3600)) > "$H/state/t1.pr-green-blocked"
echo "-- readable backlog:"; run "$H" $NOW scan
chmod 000 "$H/data/backlog.md"
echo "-- unreadable backlog:"; run "$H" $NOW scan
chmod 644 "$H/data/backlog.md"
rm "$H/data/backlog.md"
echo "-- backlog absent (empty fallback):"; run "$H" $NOW scan

say "S-G adversarial: dated waits are not ownerless"
H=$(home_new waits)
row "$H" paused "ship it"; gone "$H" paused $((N - 40 * 3600))
printf 'paused: waiting on upstream until 2026-10-04T09:00Z\n' > "$H/state/paused.status"
row "$H" held "ship it" " (hold: after load settles) (hold-kind: captain) (hold-until: 2026-10-06)"; gone "$H" held $((N - 40 * 3600))
row "$H" orphan "ship it"; gone "$H" orphan $((N - 13 * 3600))
run "$H" $NOW scan

say "S-H br blind spot: absent br -> no note"
H=$(home_new beads); mkdir -p "$H/data/beads/.beads"; : > "$H/data/beads/.beads/beads.db"
PATH="$FAKEBIN:/usr/bin:/bin:/opt/homebrew/bin" FM_HOME="$H" FM_ATTENTION_NOW=$NOW "$AC" scan
