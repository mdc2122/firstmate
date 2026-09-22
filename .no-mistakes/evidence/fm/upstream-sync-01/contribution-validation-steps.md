# Contributions validation

Real product CLI, real gh and GitHub API; no remote writes.

Created isolated home `.test-retry-tmp/live-home` with data/state/config/projects directories and backlog ownership for `https://github.com/mdc2122/firstmate/pull/9`. Ran:

```sh
FM_HOME="$PWD/.test-retry-tmp/live-home" FM_ROOT_OVERRIDE="$PWD" FM_STATE_OVERRIDE="$PWD/.test-retry-tmp/live-home/state" FM_DATA_OVERRIDE="$PWD/.test-retry-tmp/live-home/data" FM_CONFIG_OVERRIDE="$PWD/.test-retry-tmp/live-home/config" TMPDIR="$PWD/.test-retry-tmp" bin/fm-contributions.sh poll
```

Persisted record has merged state, null error, and real GitHub checks/reviews. Copied this emitted record to a second task owner, deliberately changed its state to open and error to a prior interrupted-write marker, then reran the same command: the product replaced its observation and timestamp with the settled terminal record and cleared the error. Added nonexistent PR /999999999 ownership and reran: product persisted the unavailable error and emitted its user-facing diagnostic.

Ran `python3 .test-retry-tmp/live-retry-proxy.py` against a fresh isolated home. Its loopback CONNECT proxy rejected the first two TLS connections with HTTP 502, then relayed actual GitHub TLS without inspection or fabricated response bodies. Actual connections at 0.186s, 1.257s, and 3.391s demonstrate the one/two-second retry backoffs. The third attempt succeeded; the complete real GitHub record was persisted with null error and no unavailable diagnostic. Driver copied to evidence as `contribution-live-retry-driver.py`.

Focused existing regression tests ran from a temporary driver copied from `tests/fm-contributions.test.sh` up to its execution loop, selecting only these existing executable tests (mock forge; not live evidence):

- test_transient_failure_retries_to_success
- test_partial_failure_retries_to_success
- test_persistent_failure_exhausts_retries
- test_budget_refusal_between_calls
- test_budget_bounded_call_timeout
- test_genuine_failure_near_deadline_is_unavailable
- test_diverged_owner_converges_to_terminal

Executed `TMPDIR="$PWD/.test-retry-tmp" bash tests/.retry-validation.sh`. All passed. Temporary driver/home removed after evidence capture.

Partial paginated stdout failure remains covered only by the mocked regression; the real GitHub PR has a single review page and the opaque TLS proxy cannot target a later pagination response. A suitable multi-page test PR and controllable network failure after its first page would enable that live proof.

## Live deadline proof

Located open fork PR #8 with `gh pr list --repo mdc2122/firstmate --state open --limit 3 --json number,url,title`. Ran `python3 .test-retry-deadline/driver.py`: first obtained a genuine fresh observation with real gh in an isolated home, then polled again through a process-local loopback HTTPS proxy holding CONNECT with `FM_CONTRIBUTIONS_BUDGET=2`. The connection began at 0.195s; poll returned successfully at 2.460s with no stdout/stderr, no wake, and byte-identical prior persisted record. Evidence: contribution-live-deadline.json and contribution-live-deadline-driver.py. Removed isolated home and driver after capture.
