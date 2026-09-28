#!/usr/bin/env bash
# Live driver: runs the real bin/fm-watch.sh and bin/fm-pr-green-blocked.sh
# against a fake forge CLI, reproducing the motivating case (yolo armed, green
# PR behind main, merge refused) and the probe's classification matrix.
set -u
WT=/Users/studio2/.no-mistakes/worktrees/662ae98237ac/01M3MM8XGWG6EF8P6YEH41DG3T
cd "$WT" || exit 2
. tests/lib.sh
. bin/fm-pr-lib.sh
. bin/fm-check-lib.sh
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
REAL_JQ=$(command -v jq)
WATCH=$ROOT/bin/fm-watch.sh; POLL=$ROOT/bin/fm-pr-poll.sh; REGISTER=$ROOT/bin/fm-check-register.sh
TMP_ROOT=$(fm_test_tmproot drive-green-blocked)
FAILS=0
say() { printf '\n### %s\n' "$*"; }
ok()  { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILS=$((FAILS+1)); }

make_case() {
  local dir=$TMP_ROOT/$1 fakebin fake_root
  fakebin=$dir/fakebin; fake_root=$dir/root
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/wt" "$fakebin" "$fake_root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_root/bin/fm-guard.sh"; chmod +x "$fake_root/bin/fm-guard.sh"
  ln -sf "$REAL_JQ" "$fakebin/jq"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "api graphql")
    printf '%s\n' "state=${FM_TEST_GH_GRAPHQL_STATE:-OPEN}" "merged=${FM_TEST_GH_GRAPHQL_MERGED:-false}" "queued=${FM_TEST_GH_GRAPHQL_QUEUED:-false}" 'base=main'
    exit 0 ;;
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        [ "${FM_TEST_GH_VIEW_FAIL:-0}" = 0 ] || exit 1
        if [ -n "${FM_TEST_GH_ROLLUP_JSON:-}" ]; then printf '%s\n' "$FM_TEST_GH_ROLLUP_JSON"; else
          printf '%s\n' "{\"state\":\"${FM_TEST_GH_STATE:-OPEN}\",\"isDraft\":${FM_TEST_GH_DRAFT:-false},\"mergeable\":\"${FM_TEST_GH_MERGEABLE:-MERGEABLE}\",\"mergeStateStatus\":\"${FM_TEST_GH_MERGE_STATE:-CLEAN}\",\"headRefOid\":\"${FM_TEST_GH_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}\",\"baseRefName\":\"main\",\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"name\":\"ci\",\"status\":\"${FM_TEST_GH_STATUS:-COMPLETED}\",\"conclusion\":\"${FM_TEST_GH_CONCLUSION:-SUCCESS}\"}${FM_TEST_GH_EXTRA:+,$FM_TEST_GH_EXTRA}]}"
        fi
        exit 0 ;;
      *headRefOid,reviewDecision*)
        printf '%s\n' "{\"headRefOid\":\"${FM_TEST_GH_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}\",\"reviewDecision\":\"APPROVED\"}"; exit 0 ;;
    esac ;;
  "pr merge")
    if [ "${FM_TEST_GH_MERGE_FAIL:-0}" != 0 ]; then
      echo 'X Pull request #1 is not mergeable: the base branch was modified; update the branch and try again.' >&2
      exit 1
    fi
    exit 0 ;;
esac
case " $* " in
  *" api repos/"*"/commits/"*"/check-runs?filter=all&per_page=100 "*) printf '%s\n' '[{"check_runs":[]}]' ;;
  *" api --paginate repos/"*"/commits/"*"/check-runs"*) printf '%s\n' '{"check_runs":[]}' ;;
  *" api repos/"*"/commits/"*"/statuses?per_page=100 "*) printf '%s\n' '[[]]' ;;
  *" api --paginate repos/"*"/rules/branches/"*merge_queue*) ;;
  *" api --paginate repos/"*"/rules/branches/"*) printf '%s\n' "${FM_TEST_GH_RULES_JSON:-[]}" ;;
  *" api repos/"*"/branches/"*) bj=${FM_TEST_GH_BRANCH_JSON:-}; [ -n "$bj" ] || bj='{"name":"main","protected":false}'; printf '%s\n' "$bj" ;;
  *" api repos/"*"/pulls/"*) printf '%s\n' "{\"state\":\"open\",\"user\":{\"login\":\"author\"},\"head\":{\"sha\":\"${FM_TEST_GH_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}\"},\"draft\":false,\"mergeable\":true,\"merged_at\":null}" ;;
  *" api repos/"*) printf '%s\n' '{"permissions":{"push":false}}' ;;
  *" headRefOid "*) printf '%s\n' "${FM_TEST_GH_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
  *" state "*) printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}" ;;
esac
SH
  cat > "$fakebin/gh-axi" <<'SH2'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in "pr view") printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_AXI_STATE:-open}" ;; esac
exit 0
SH2
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/glab"
  chmod +x "$fakebin/gh" "$fakebin/gh-axi" "$fakebin/glab"
  : > "$dir/gh.log"
  printf '%s\n' "$dir"
}

run_watcher() {  # <dir> <out>
  local dir=$1 out=$2
  rm -f "$dir/home/state/.last-check"
  perl -e 'use POSIX qw(setpgid); my $pid=fork; die unless defined $pid; if (!$pid) { setpgid(0, 0); exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", -$pid; alarm 2; local $SIG{ALRM}=sub { kill "KILL", -$pid }; waitpid $pid, 0; exit 124 }; alarm 20; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=5 FM_YOLO_MERGE_TIMEOUT=10 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 FM_TEST_GH_LOG="$dir/gh.log" PATH="$dir/fakebin:$BASE_PATH" "$WATCH" > "$out" 2> "$out.err"
  local rc=$?
  printf -- '--- watcher rc=%s; stdout (wake lines):\n' "$rc"; sed 's/^/    /' "$out"
  [ -s "$out.err" ] && { printf -- '--- stderr:\n'; sed 's/^/    /' "$out.err"; }
  return $rc
}
ack() { # <state>
  local state=$1 err=$1/.drv-ack.err seq gen
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || return 1
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"; [ -n "$seq" ] && [ -n "$gen" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null
}
show_record() { # <state>
  if [ -f "$1/task-a.pr-green-blocked" ]; then printf -- '--- state/task-a.pr-green-blocked: %s\n' "$(cat "$1/task-a.pr-green-blocked")"; else printf -- '--- state/task-a.pr-green-blocked: (absent)\n'; fi
}

URL=https://github.com/o/r/pull/1
##############################################################################
say "SCENARIO 1: yolo-armed green PR behind main; forge refuses the merge; one green-unmergeable wake after the threshold"
dir=$(make_case yolo-behind); state=$dir/home/state
fm_write_meta "$state/task-a.meta" "window=fm-task-a" "yolo=on" "pr=$URL"
fm_pr_url_parse "$URL"
fm_pr_poll_prepare "$state" task-a "$FM_PR_PROVIDER" "$URL" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$POLL" && fm_pr_poll_publish_prepared || bad "poll seed"
printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$state/z-stop.check.sh"; chmod 0700 "$state/z-stop.check.sh"
FM_HOME="$dir/home" "$REGISTER" z-stop >/dev/null || bad "register stop check"

export FM_TEST_GH_STATE=OPEN FM_TEST_GH_MERGE_STATE=BEHIND FM_TEST_GH_CONCLUSION=SUCCESS FM_TEST_GH_MERGE_FAIL=1
say "1a. first sweep, threshold 1800s: yolo merge attempted and refused, episode opens, no alert"
printf -- '--- what the guarded merge gate says for this PR (bin/fm-pr-merge.sh run directly):\n'
FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_GH_LOG="$dir/gh-direct.log" PATH="$dir/fakebin:$BASE_PATH" bin/fm-pr-merge.sh task-a "$URL" --squash 2>&1 | sed 's/^/    /'; printf '    merge gate rc=%s\n' "${PIPESTATUS[0]}"
grep -c '^pr merge ' "$dir/gh-direct.log" | sed 's/^/--- forge merge calls made by that direct attempt: /'
printf -- '--- priming sweep: the merge attempt armed the contributions check, whose one-time "observation unavailable" wake (the fake forge holds no contribution data) is absorbed here so later sweeps reach the PR poll:\n'
FM_PR_GREEN_BLOCKED_SECS=1800 run_watcher "$dir" "$dir/w0.out"; ack "$state" || bad "priming ack"
FM_PR_GREEN_BLOCKED_SECS=1800 run_watcher "$dir" "$dir/w1.out"
grep -c '^pr merge ' "$dir/gh.log" | sed 's/^/--- fake gh saw pr merge calls: /'
grep 'yolo merge attempt' "$state/.watch-triage.log" | sed 's/^/--- triage: /'
show_record "$state"
case "$(cat "$dir/w1.out")" in *green-unmergeable*) bad "alerted before threshold" ;; *stop-cycle*) ok "no alert before the 30-minute threshold" ;; *) bad "unexpected wake output" ;; esac
[ -f "$state/task-a.pr-green-blocked" ] && ok "episode record opened with alerted=0" || bad "no episode record"
ack "$state" || bad ack

say "1b. 31 minutes later (episode record's first-seen epoch backdated by 1860s, default threshold 1800s kept): the one wake fires naming the PR and reason"
read -r r_url r_head r_first r_alerted < "$state/task-a.pr-green-blocked"
printf '%s %s %s %s\n' "$r_url" "$r_head" "$((r_first - 1860))" "$r_alerted" > "$state/task-a.pr-green-blocked"
show_record "$state"
run_watcher "$dir" "$dir/w2.out"
show_record "$state"
case "$(cat "$dir/w2.out")" in *"task-a.check.sh: green-unmergeable $URL for "*"m: branch is behind the base branch"*) ok "wake names the PR URL, age, and 'branch is behind the base branch'" ;; *) bad "no green-unmergeable wake: $(cat "$dir/w2.out")" ;; esac
grep -F "green-unmergeable" "$state/.wake-queue" | sed 's/^/--- durable wake row: /'
ack "$state" || bad ack

say "1c. sweep again, still blocked: no second wake for the same episode"
FM_PR_GREEN_BLOCKED_SECS=0 run_watcher "$dir" "$dir/w3.out"
case "$(cat "$dir/w3.out")" in *green-unmergeable*) bad "episode alerted twice" ;; *) ok "no repeat wake for the same episode" ;; esac
ack "$state" || bad ack

say "1d. worker re-pushes a new head (rebase), still behind: fresh episode, its own timer, no immediate alert"
FM_TEST_GH_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb FM_PR_GREEN_BLOCKED_SECS=1800 run_watcher "$dir" "$dir/w4.out"
show_record "$state"
case "$(cat "$dir/w4.out")" in *green-unmergeable*) bad "new head inherited old episode age" ;; *) ok "re-pushed head started a fresh episode (record shows new head, alerted=0)" ;; esac
ack "$state" || bad ack

say "1e. PR becomes mergeable (CLEAN) but the forge merge still fails: clear reading ends the episode"
FM_TEST_GH_MERGE_STATE=CLEAN FM_PR_GREEN_BLOCKED_SECS=0 run_watcher "$dir" "$dir/w5.out"
show_record "$state"
[ ! -e "$state/task-a.pr-green-blocked" ] && ok "clear reading removed the episode record" || bad "record survived a clear reading"
case "$(cat "$dir/w5.out")" in *green-unmergeable*) bad "mergeable PR alerted" ;; *) ok "no alert for a mergeable PR" ;; esac
ack "$state" || bad ack

say "1f. adversarial: FM_PR_GREEN_BLOCKED_SECS=abc (garbage) falls back to 1800, so a fresh block does not alert at once"
FM_TEST_GH_MERGE_STATE=BEHIND FM_PR_GREEN_BLOCKED_SECS=abc run_watcher "$dir" "$dir/w6.out"
show_record "$state"
case "$(cat "$dir/w6.out")" in *green-unmergeable*) bad "garbage threshold alerted immediately" ;; *) ok "garbage threshold fell back to the default, no alert" ;; esac
ack "$state" || bad ack

say "1g. the merge lands (forge merge succeeds, GraphQL says MERGED): poll retires and takes the episode record with it"
FM_TEST_GH_MERGE_FAIL=0 FM_TEST_GH_GRAPHQL_STATE=MERGED FM_TEST_GH_GRAPHQL_MERGED=true FM_PR_GREEN_BLOCKED_SECS=0 run_watcher "$dir" "$dir/w7.out"
show_record "$state"
[ ! -e "$state/task-a.pr-green-blocked" ] && ok "merged poll retirement removed the episode record" || bad "record survived the merge"
[ ! -e "$state/task-a.check.sh" ] && ok "merge poll retired" || bad "poll still armed after merge"
unset FM_TEST_GH_STATE FM_TEST_GH_MERGE_STATE FM_TEST_GH_CONCLUSION FM_TEST_GH_MERGE_FAIL FM_TEST_GH_HEAD

##############################################################################
say "SCENARIO 2: probe classification matrix (bin/fm-pr-green-blocked.sh run directly against the fake forge)"
pdir=$(make_case probe)
probe() { # <label> <expected> env...
  local label=$1 expected=$2 got; shift 2
  got=$(env FM_TEST_GH_LOG="$pdir/gh.log" PATH="$pdir/fakebin:$BASE_PATH" "$@" bin/fm-pr-green-blocked.sh "${PROBE_URL:-$URL}" 2>&1)
  printf '%-78s -> %s\n' "$label" "${got:-(silence)}"
  if [ "$got" = "$expected" ]; then ok "$label"; else bad "$label: expected [$expected] got [$got]"; fi
}
H=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
probe "green, BEHIND"                                   "blocked $H branch is behind the base branch" FM_TEST_GH_MERGE_STATE=BEHIND
probe "green, DIRTY (conflicts)"                        "blocked $H merge conflicts with the base branch" FM_TEST_GH_MERGE_STATE=DIRTY FM_TEST_GH_MERGEABLE=CONFLICTING
probe "green, draft"                                    "blocked $H pull request is a draft" FM_TEST_GH_MERGE_STATE=BLOCKED FM_TEST_GH_DRAFT=true
probe "green, BLOCKED by protection, not queued"        "blocked $H base-branch protection refuses the merge (a required review or another branch rule)" FM_TEST_GH_MERGE_STATE=BLOCKED
probe "green, BLOCKED but waiting in merge queue"       "clear" FM_TEST_GH_MERGE_STATE=BLOCKED FM_TEST_GH_GRAPHQL_QUEUED=true
probe "green, BEHIND, queued (queue wins even when behind)" "clear" FM_TEST_GH_MERGE_STATE=BEHIND FM_TEST_GH_GRAPHQL_QUEUED=true
probe "green rollup (ci) but base requires ci+lint, lint unreported" "clear" FM_TEST_GH_MERGE_STATE=BEHIND FM_TEST_GH_BRANCH_JSON='{"name":"main","protected":true,"protection":{"required_status_checks":{"contexts":["ci","lint"],"checks":[]}}}'
probe "same, lint now reported green"                   "blocked $H branch is behind the base branch" FM_TEST_GH_MERGE_STATE=BEHIND FM_TEST_GH_BRANCH_JSON='{"name":"main","protected":true,"protection":{"required_status_checks":{"contexts":["ci","lint"],"checks":[]}}}' FM_TEST_GH_EXTRA='{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"}'
probe "ruleset requires lint (app-bound 15), lint unreported" "clear" FM_TEST_GH_MERGE_STATE=BEHIND FM_TEST_GH_RULES_JSON='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"lint","integration_id":15}]}}]'
probe "ci red (FAILURE), BEHIND"                        "clear" FM_TEST_GH_MERGE_STATE=BEHIND FM_TEST_GH_CONCLUSION=FAILURE
probe "ci pending (IN_PROGRESS), BEHIND"                "clear" FM_TEST_GH_MERGE_STATE=BEHIND FM_TEST_GH_STATUS=IN_PROGRESS FM_TEST_GH_CONCLUSION=
probe "green, CLEAN (mergeable)"                        "clear" FM_TEST_GH_MERGE_STATE=CLEAN
probe "green, UNSTABLE"                                 "clear" FM_TEST_GH_MERGE_STATE=UNSTABLE
probe "PR CLOSED"                                       "clear" FM_TEST_GH_STATE=CLOSED FM_TEST_GH_MERGE_STATE=UNKNOWN
probe "PR MERGED"                                       "clear" FM_TEST_GH_STATE=MERGED
say "2b. adversarial: unknown answers are silence (caller keeps its episode unchanged)"
probe "mergeability not computed yet (UNKNOWN)"         "" FM_TEST_GH_MERGE_STATE=UNKNOWN
probe "gh pr view fails"                                "" FM_TEST_GH_VIEW_FAIL=1
probe "malformed payload"                               "" FM_TEST_GH_ROLLUP_JSON='not json'
probe "payload with no rollup"                          "" FM_TEST_GH_ROLLUP_JSON='{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND","headRefOid":"aaaa","baseRefName":"main"}'
probe "BEHIND but head sha missing"                     "" FM_TEST_GH_ROLLUP_JSON='{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND","headRefOid":"","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}'
probe "BEHIND but branch-protection read unreadable"    "" FM_TEST_GH_MERGE_STATE=BEHIND FM_TEST_GH_BRANCH_JSON='garbage'
probe "BEHIND but rules read unreadable"                "" FM_TEST_GH_MERGE_STATE=BEHIND FM_TEST_GH_RULES_JSON='garbage'
PROBE_URL=https://gitlab.com/o/r/-/merge_requests/1 probe "GitLab URL is never probed" "" FM_TEST_GH_MERGE_STATE=BEHIND
PROBE_URL='https://github.com/o/r/pull/1;rm' probe "malformed URL" "" FM_TEST_GH_MERGE_STATE=BEHIND
got=$(PATH="$pdir/fakebin:$BASE_PATH" bin/fm-pr-green-blocked.sh 2>&1); [ -z "$got" ] && ok "no argument -> silence" || bad "no argument printed: $got"
got=$(PATH="$pdir/fakebin:$BASE_PATH" bin/fm-pr-green-blocked.sh "$URL" extra 2>&1); [ -z "$got" ] && ok "two arguments -> silence" || bad "two arguments printed: $got"
grep -c '^pr merge \|api -X\|--method' "$pdir/gh.log" | sed 's/^/--- probe forge calls that could write (pr merge, api -X, or --method): /'
grep -q '^pr merge \|api -X\|--method' "$pdir/gh.log" && bad "probe attempted a write" || ok "probe made only read calls across the whole matrix"
printf -- '--- distinct gh commands the probe issued:\n'; sed 's/ https:[^ ]*//' "$pdir/gh.log" | cut -c1-90 | sort -u | sed 's/^/    /'
say "2c. --help prints the contract"
PATH="$pdir/fakebin:$BASE_PATH" bin/fm-pr-green-blocked.sh --help | head -4 | sed 's/^/    /'

printf '\n==== driver result: %s failures ====\n' "$FAILS"
exit $FAILS
