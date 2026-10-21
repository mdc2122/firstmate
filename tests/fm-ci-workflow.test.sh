#!/usr/bin/env bash
# Contract tests for the firstmate CI program's workflow shape.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident (supersession and
# finite timeouts) plus the 2026-10-21 CI program: a 24-shard serial lane, an
# incremental PR lint, one required `ci-ok`, a merge-queue trigger, nightly-only
# lanes, and public-fork runner safety.
#
# The workflow is parsed as YAML and its concurrency expressions are resolved
# against simulated contexts, so the assertions describe what GitHub would do,
# not how the file happens to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"
NIGHTLY_WORKFLOW="$ROOT/.github/workflows/nightly.yml"
RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
assert_present "$NIGHTLY_WORKFLOW" ".github/workflows/nightly.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse the workflows as YAML"

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>". Only the expression constructs this
# workflow uses are resolved: an `a || b` fallback chain and an `==` comparison.
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3 merge_sha=$4
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.event.merge_group.head_sha" => ARGV[4],
  "github.run_id" => ARGV[3],
}

value = lambda do |token|
  token = token.strip
  next token[1..-2] if token.start_with?("\x27") && token.end_with?("\x27")
  raise "unresolvable context reference: #{token}" unless context.key?(token)
  context.fetch(token)
end

evaluate = lambda do |expression|
  expression = expression.strip
  if expression.include?("==")
    left, right = expression.split("==", 2)
    next value.call(left) == value.call(right) ? "true" : "false"
  end
  resolved = expression.split("||").map { |token| value.call(token) }.find { |v| !v.empty? }
  resolved.to_s
end

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { evaluate.call(Regexp.last_match(1)) }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id" "$merge_sha"
}

job_timeout() {  # <workflow> <job>
  ruby -ryaml -e '
job = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1])
puts job.fetch("timeout-minutes", "none")
' "$1" "$2"
}

job_field() {  # <workflow> <job> <ruby expression on `job`>
  ruby -ryaml -e '
job = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1])
puts(eval(ARGV[2]))
' "$1" "$2" "$3"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_triggers_cover_pr_merge_queue_and_nightly() {
  local reported
  reported=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
triggers = doc[true] || doc["on"]
raise "on: must be a mapping" unless triggers.is_a?(Hash)
missing = %w[pull_request push merge_group workflow_call].reject { |k| triggers.key?(k) }
puts missing.join(" ")
' "$CI_WORKFLOW") || fail "could not read ci.yml triggers"
  [ -z "$reported" ] || fail "ci.yml is missing triggers: $reported"
  pass "ci.yml triggers on pull_request, push, merge_group, and workflow_call"
}

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001 '') || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002 '') || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001 '') || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003 '') || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010 '') || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011 '') || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_merge_queue_entries_are_not_cancelled() {
  local first second
  first=$(resolve_concurrency merge_group '' 900020 aaaa1111) || fail "could not resolve merge_group concurrency"
  second=$(resolve_concurrency merge_group '' 900021 bbbb2222) || fail "could not resolve merge_group concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "distinct merge-group heads must get distinct groups, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "merge_group runs must not cancel each other, got $(cancel_of "$first")"
  pass "each merge-queue head keeps its own group and is never cancelled"
}

test_every_job_has_a_finite_timeout() {
  local workflow reported
  for workflow in "$CI_WORKFLOW" "$NIGHTLY_WORKFLOW"; do
    reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  next if job.key?("uses")   # a called reusable workflow has no local timeout
  timeout = job["timeout-minutes"]
  next if timeout.is_a?(Integer) && timeout > 0
  puts "#{name}: #{timeout.inspect}"
end
' "$workflow") || fail "could not read job timeouts from $workflow"
    [ -z "$reported" ] || fail "these jobs have no finite hang tripwire in $workflow:"$'\n'"$reported"
  done
  pass "every job in both workflows carries a finite timeout"
}

test_serial_matrix_matches_the_runner_shard_count() {
  local configured shards
  configured=$(sed -n 's/^PORTABLE_SERIAL_SHARDS=\([0-9][0-9]*\)$/\1/p' "$RUNNER")
  [ -n "$configured" ] || fail "could not read PORTABLE_SERIAL_SHARDS from bin/fm-test-run.sh"
  [ "$configured" = 24 ] || fail "PORTABLE_SERIAL_SHARDS must be 24, got $configured"
  shards=$(job_field "$CI_WORKFLOW" tests-portable-serial 'job.fetch("strategy").fetch("matrix").fetch("shard").join(" ")')
  [ "$(printf '%s\n' "$shards" | wc -w | tr -d ' ')" = "$configured" ] \
    || fail "serial matrix must have $configured entries, got: $shards"
  [ "$(printf '%s\n' "$shards" | awk '{print $1}')" = 1 ] \
    || fail "serial matrix must start at 1, got: $shards"
  [ "$(printf '%s\n' "$shards" | awk '{print $NF}')" = "$configured" ] \
    || fail "serial matrix must end at $configured, got: $shards"
  pass "the serial matrix is exactly the runner's 24 shards"
}

test_ci_ok_is_the_single_required_aggregate() {
  local needs
  needs=$(job_field "$CI_WORKFLOW" ci-ok 'job.fetch("needs").sort.join(" ")')
  [ "$needs" = "lint tests-portable-parallel-1 tests-portable-parallel-2 tests-portable-serial" ] \
    || fail "ci-ok must aggregate the PR gate, got needs: $needs"
  [ "$(job_field "$CI_WORKFLOW" ci-ok 'job.fetch("if", "")')" = "always()" ] \
    || fail "ci-ok must run with if: always() so it reports on a failed dependency"
  job_field "$CI_WORKFLOW" ci-ok 'job.fetch("steps").map { |s| s["run"].to_s }.join("\n")' \
    | grep -Fq 'all(. == "success")' \
    || fail "ci-ok must fail on any non-success dependency result"
  pass "ci-ok is the one aggregate and rejects skipped, cancelled, or failed dependencies"
}

test_pr_lint_is_incremental_and_nightly_is_full() {
  local runs
  runs=$(job_field "$CI_WORKFLOW" lint 'job.fetch("steps").map { |s| s["run"].to_s }.join("\n")')
  printf '%s' "$runs" | grep -Fq 'fm-lint.sh --changed' \
    || fail "the PR lint job must call fm-lint.sh --changed"
  printf '%s' "$runs" | grep -Fq 'fm-test-run.sh --check-coverage' \
    || fail "the PR lint job must keep the coverage guard green"
  local partitions
  partitions=$(job_field "$NIGHTLY_WORKFLOW" lint-full 'job.fetch("strategy").fetch("matrix").fetch("partition").length.to_s')
  [ "$partitions" = 12 ] || fail "nightly full lint must use 12 partitions, got $partitions"
  job_field "$NIGHTLY_WORKFLOW" lint-full 'job.fetch("steps").map { |s| s["run"].to_s }.join("\n")' \
    | grep -Fq 'fm-lint.sh --partition' \
    || fail "nightly lint-full must run the full canonical partitions"
  pass "PR lint is incremental and nightly lint is the full partitioned set"
}

test_nightly_owns_slow_and_platform_lanes() {
  local job
  for job in tests-herdr macos-stock-bash windows-shell-seams tests-timing-aggregate; do
    ruby -ryaml -e '
job = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1])
' "$NIGHTLY_WORKFLOW" "$job" >/dev/null 2>&1 \
      || fail "nightly.yml is missing the $job job"
  done
  for job in tests-herdr macos-stock-bash tests-timing-aggregate; do
    ruby -ryaml -e '
raise "still in ci.yml" if YAML.load_file(ARGV[0]).fetch("jobs").key?(ARGV[1])
' "$CI_WORKFLOW" "$job" >/dev/null 2>&1 \
      || fail "$job must not run in the PR gate"
  done
  [ "$(job_field "$NIGHTLY_WORKFLOW" tests-herdr 'job.fetch("timeout-minutes")')" = 75 ] \
    || fail "the Herdr nightly job must keep its 75-minute hang tripwire"
  pass "Herdr, macOS stock Bash, Windows, full lint, and timing aggregation are nightly-only"
}

test_untrusted_prs_never_run_on_self_hosted_runners() {
  local reported
  reported=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
required = [
  "github.event.pull_request.head.repo.full_name == github.repository",
  "github.actor != \x27dependabot[bot]\x27",
  "vars.RUNS_ON",
]
doc.fetch("jobs").each do |name, job|
  runs_on = job["runs-on"]
  next unless runs_on.is_a?(String)          # only the Linux jobs use the expression
  next if runs_on == "ubuntu-latest"         # ci-ok checks out nothing and runs no repo code
  missing = required.reject { |needle| runs_on.include?(needle) }
  puts "#{name}: #{missing.join(", ")}" unless missing.empty?
end
' "$CI_WORKFLOW") || fail "could not read ci.yml runs-on expressions"
  [ -z "$reported" ] || fail "these job runners are not fork-safe:"$'\n'"$reported"
  pass "every Linux job sends fork and Dependabot PRs to GitHub-hosted runners"
}

test_n100_job_is_light_and_not_required() {
  local labels
  labels=$(job_field "$CI_WORKFLOW" actionlint-light 'job.fetch("runs-on").join(",")')
  [ "$labels" = "self-hosted,n100,light,overflow" ] \
    || fail "the light workflow lint must stay on n100, got $labels"
  [ "$(job_field "$CI_WORKFLOW" actionlint-light 'job.fetch("timeout-minutes")')" = 10 ] \
    || fail "the n100 job must keep its 10-minute cap"
  job_field "$CI_WORKFLOW" ci-ok 'job.fetch("needs").include?("actionlint-light") ? "yes" : "no"' \
    | grep -qx no \
    || fail "the n100 job must not be a ci-ok dependency"
  pass "the n100 job is light, capped, and not in ci-ok's needs"
}

test_no_workflow_secrets_or_pull_request_target() {
  local bad
  bad=$(grep -nE 'pull_request_target|secrets\.' "$CI_WORKFLOW" "$NIGHTLY_WORKFLOW" || true)
  [ -z "$bad" ] || fail "workflow privilege expansion found:"$'\n'"$bad"
  pass "neither workflow uses pull_request_target or workflow secrets"
}

test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_merge_queue_entries_are_not_cancelled
test_every_job_has_a_finite_timeout
test_serial_matrix_matches_the_runner_shard_count
test_ci_ok_is_the_single_required_aggregate
test_pr_lint_is_incremental_and_nightly_is_full
test_nightly_owns_slow_and_platform_lanes
test_untrusted_prs_never_run_on_self_hosted_runners
test_n100_job_is_light_and_not_required
test_no_workflow_secrets_or_pull_request_target
