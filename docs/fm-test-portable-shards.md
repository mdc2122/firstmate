# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-latest`.
The current serial and parallel tables were refreshed on 2026-10-21 from green run [39649458952](https://github.com/mdc2122/firstmate/actions/runs/39649458952): 194 serial scripts, 7454 s of script time, and 24 proven-isolated parallel scripts.
That run's per-script maxima are the source for every hint in `portable_serial_weight_hints` except the eight split drivers described below, whose slices are the measured script total divided by four.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

The retained hints are the slowest completed value each script reached across six CI runs on 2026-09-10: [34459949083](https://github.com/kunchenguid/firstmate/actions/runs/34459949083), [34460760299](https://github.com/kunchenguid/firstmate/actions/runs/34460760299), [34462530836](https://github.com/kunchenguid/firstmate/actions/runs/34462530836), [34462758357](https://github.com/kunchenguid/firstmate/actions/runs/34462758357), [34466966385](https://github.com/kunchenguid/firstmate/actions/runs/34466966385), and [34470382458](https://github.com/kunchenguid/firstmate/actions/runs/34470382458).
Shard 2 completed in all six, so its scripts come from the uploaded `fm-test-timing-portable-parallel-2` artifacts.
Shard 1 was cancelled at its job cap in five of the six, so its scripts come from the `FM_TEST_END duration_ms=` markers in each cancelled job's log, which record every script that finished before the cancellation, plus the one complete `fm-test-timing-portable-parallel-1` artifact from run 34462758357.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

The measurements cover all 24 candidates, with six samples per script except:

| Samples | Scripts |
|---:|---|
| 4 | `tests/fm-lint.test.sh` |
| 3 | `tests/fm-pi-primary-types.test.sh`, `tests/fm-review-diff.test.sh` |
| 1 | `tests/fm-brief.test.sh`, `tests/fm-transition-lib.test.sh` |

The two scripts with one sample are the tail of shard 1 that only the complete run reached.
Collect completed per-script measurements for every member before calculating a split.
A cancelled lane's elapsed duration is only a lower bound; its unfinished scripts have no completed duration for that invocation.
The complete historical run supplies tail-script hints, not a completion time for any later cancelled invocation or for the rebalanced jobs.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
Run 39649458952 measured the two lanes at 1280 s of serial script time with `fm-captain-hold-lifecycle.test.sh` alone at 403 s, so CI runs each lane with `--jobs 4` on a four-vCPU runner: more workers only add contention and the longest script is the floor.
The CI cap and its rationale are owned by [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` (`PORTABLE_SERIAL_SHARDS=24`) and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Two scripts dominated the lane: `fm-watch-triage.test.sh` at 945 s and `fm-pr-check-security.test.sh` at 838 s on run 39649458952. No shard count can hide a single 945 s script, so both are split into four independent case groups:

| Driver | Cases | Hint |
|---|---:|---:|
| `tests/fm-pr-check-security-<1..4>.test.sh` | 24/24/24/22 | 209600 ms each |
| `tests/fm-watch-triage-<1..4>.test.sh` | 31/31/31/30 | 236150 ms each |

The helper setup and every case body live in `tests/fm-<name>-cases.sh`; each driver sources that library and calls only its own group, so the four groups run on four runners without duplicating the shared setup. Case bodies and their order are unchanged. The former monolithic files are gone, so the coverage guard's inventory follows the split files.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The embedded hints are the slowest completed `duration_ms` per script across the five serial shard artifacts of green run [39649458952](https://github.com/mdc2122/firstmate/actions/runs/39649458952) on 2026-10-21, plus the split-driver slices above.
That run replaced a mixture of older CI runs, local measurements, and extrapolations, including a 603 s estimate for `fm-pr-check-security.test.sh` that the completed run measured at 838 s.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.
It also reports `serial_shard_max_ms=` and refuses a shard above `PORTABLE_SERIAL_MAX_SHARD_MS` (330000 ms), so a new slow test or a shard-count change fails the guard instead of quietly making one runner the critical path.
The 330 s ceiling is the honest floor for 24 shards: 7454 s / 24 is 310.6 s, so a strict 300 s ceiling is arithmetically impossible without changing the lane's composition.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for either bound to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size, shard composition, and balance rather than a copied table.
Run 39649458952 measured the old five-shard split at 1262-1845 s per shard. With 24 shards and the two giants split, `--check-coverage` reports `serial_shard_max_ms=311411`, so the job and step caps are now hang tripwires with roughly 2.3x margin over the packed maximum rather than the expected wall.
The wall on N runners is at least `ceil(24 / N)` times the slowest shard: six Linux runners put the full serial lane near 21 minutes even at perfect balance, which is a capacity fact for `ci-runners`, not a partitioning defect.

The largest individual hint in `portable_serial_weight_hints` sets the estimated floor for any serial shard count.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" -R kunchenguid/firstmate --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A per-script timeout still allows the runner to write its artifact, but an enclosing step or job cancellation can prevent that write.
Pick runs where every serial shard is green: failed or timeout durations are not healthy packing measurements.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane, and that no shard's packed hints exceed `PORTABLE_SERIAL_MAX_SHARD_MS`.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the PR-gate artifact names; `.github/workflows/nightly.yml` reuses that workflow and aggregates every lane artifact in the nightly run.
The PR gate no longer waits on an aggregate job: `ci-ok` depends only on the lanes that must be green before merge.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | See [CI workflow](../.github/workflows/ci.yml) | The workflow owns the parallel cap rationale and its evidence limits. |
| portable serial 1-24 | 20 min job / 14 min step in the [CI workflow](../.github/workflows/ci.yml) | Run 39649458952 measured 7454 s of serial script time; after the split and 24-way packing the maximum shard is 311 s, so both caps are hang tripwires with more than 2x margin. |
| Herdr | family-run step bound and job backstop in the [CI workflow](../.github/workflows/ci.yml) | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally; the step budget exceeds twice the measured green p90, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are intended as hang tripwires; a passing coverage guard does not establish a healthy job duration.
`.github/workflows/ci.yml` owns the exact numbers.

The [CI workflow](../.github/workflows/ci.yml) enables the runner's measured per-script bounds and shared step budget with reporting margin in every behavior lane, including stock-macOS compatibility.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh)'s header and `--help` own timeout mechanics; `per_script_timeout_auto_secs` owns the measured bound table and its provenance.
Refresh an entry from the timing artifacts whenever a script's slowest healthy run approaches its bound, the same way the shard hints are refreshed.

## Infrastructure flake retry

The workflow enables the runner's opt-in process-level infrastructure retry in every behavior lane.
The runner's header and `--help` own eligibility and log markers; its JSON writer owns timing fields.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh) covers process outcomes, recorded-exit retry vetoes during stream-draining timeouts, shared serial budgets, and stock-Bash final-attempt counts and failure transcripts.
Use the labeled logs, step summaries, and timing artifacts to count retries across runs rather than losing that evidence in manual reruns.
