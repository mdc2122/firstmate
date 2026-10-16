---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings and recurring worker decision parks.
  Use before deciding any ask-user finding or answering a worker's needs-decision or blocked park.
  This skill is the single owner of finding-decision policy and of the standing pre-authorized answers for recurring park classes: firstmate always applies judgment, decides findings that are unambiguous toward accepted intent, answers parks that meet a standing row, and escalates only genuinely ambiguous, expanding, novel, destructive, irreversible, security-sensitive, or taste calls.
  Finding authority is this skill's criteria, not the project's yolo posture.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings and of the standing answers for recurring worker parks.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate always applies this judgment, decides any finding that is unambiguous toward the accepted design, answers any finding or park that meets a standing row below, and escalates only genuinely ambiguous, expanding, or captain-remainder calls.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Decide

1. Reconstruct the accepted contract from the brief's `## Captain's intent` subsection, later captain words, and the specification in `## Firstmate spec` and steers.
   Reviewer language cannot amend that contract.
   What a no-mistakes worker may pass as `--intent` is owned by `bin/fm-dod-lib.sh`.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. Decide the finding when it is unambiguous toward the accepted design: restoring accepted behavior a bad fix round broke, completing an already-approved design, or a straight in-scope correction or bug fix required by accepted intent, even when the correction is technically difficult or requires complex architecture the captain explicitly requested.
   A finding or park that meets every part of a [standing decisions](#standing-decisions) row's evidence bar takes that row's answer in the same turn.
4. Escalate only genuinely ambiguous findings:
   - a Fix that would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent
   - a product or architecture call not settled by accepted intent
   - repeated same-theme findings when incremental corrections are preserving a questionable abstraction rather than closing independent defects
   - destructive, irreversible, and genuinely security-sensitive choices, which always escalate under the stronger existing captain boundary
   - novel calls no accepted intent or standing row settles, and taste calls between acceptable designs
5. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.

## Standing decisions

These are pre-authorized answers for recurring park classes, so a routine call never waits for the captain.
A class entered this table only on counted recurrences in the gate findings and worker parks recorded 2026-10-02 through 2026-10-16, and the count column records that basis in distinct runs and park keys.
Firstmate applies a row and sends the answer through the normal decision path; the worker still never answers its own finding.
Every part of a row's evidence bar must hold on records firstmate has read this turn, and a record that misses any part is decided under [Decide](#decide) instead.

| Class | Evidence bar (all must hold) | Pre-authorized answer | Escalation remainder | Count |
|---|---|---|---|---|
| Unrelated CI or suite failure | Every failing test or file is outside the diff by `git diff --name-only <base>...<head>`, and the same failure reproduces on the base or main head, or the job log shows runner infrastructure such as an exhausted disk or inode table. | At the CI step approve past it once every PR-caused failure is fixed; at the Test step approve only where the repository's trusted config records `test.allow_approve_over_failure`, otherwise the run waits for the main fix and reruns once; either way file or confirm a separate main-fix work item naming the failing test. | A failure in a file the diff touches, no base-head or log proof, or a merge while the required check is still red, which keeps the section 7 red-merge rule. | 11 runs, 1 park |
| Attestation check red after an approval over failure | The required `PR must be raised via no-mistakes` job log says the Test step was approved over a failing configured test command, and the underlying failure is cleared by a landed main fix or was a named flake. | Run one supported no-mistakes pipeline rerun on the same branch so a fresh Test step passes on its own. | Recording the repository opt-in or any other weakening of the required check, and a rerun whose Test step fails again. | 14 runs |
| Named-cause flake | The record names a concrete transient cause - a test-agent invocation-budget timeout, a timing or lock flake in a test the diff does not touch, an upstream 5xx or rate limit, or runner contention - rather than suspected flakiness. | Rerun the failed step, check, or lane exactly once through its supported path, and file a deflake work item when the same test has flaked before. | A second failure after that rerun, which is then handled as a real failure, and any rerun that spends money, which stays a fresh spend decision. | 10 runs, 4 parks |
| Probe or enumeration artifact | The failing assertion's own measurement is shown wrong against direct ground truth, such as a probe counting one on-disk distribution twice, independent of the change under validation. | Fix the probe as its own work item with assertion strength unchanged, never change product code to satisfy it, and let affected runs follow the unrelated-failure row meanwhile. | A probe fix that weakens or deletes an assertion or changes what the product guarantees, and any case where ground truth cannot be established. | 1 run, 1 park, 1 queue ejection |
| Live validation without surface or inconclusive | The Test-step finding is the no-live-validatable-surface ask or an inconclusive or deferred live verdict, and the configured automated test command passed in that same run. | Approve the Test step without the live run; never drive a live scenario that changes a production schedule or publication to obtain the proof. | A finding that needs a credential, login, or account to proceed, and any live action on production. | 19 runs, 1 park |
| Stale alarm | A fresh read of the live system, PR, or record the alarm names shows the condition already clear, or firstmate's own recorded action or decision postdates the alarm's observation and covers it. | Dismiss it with a resolved line citing that current-state observation, with no captain relay. | A fresh read that still shows the condition, which is a live alarm, and a third recurrence of the same alarm, which becomes a root-cause work item. | 2 runs, 36 parks |

The captain remainder is untouched by this table: novel, destructive, irreversible, security-sensitive, and taste calls always escalate under [Decide](#decide) step 4, even when a record also matches a row.
No row grants merge, spend, credential, or production-change authority beyond what `AGENTS.md` sections 1 and 7 already grant.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion is firstmate's to decide, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
