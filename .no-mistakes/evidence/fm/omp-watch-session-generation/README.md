# Live validation: omp in-process helper session must not displace the watcher owner

Product driven: the installed omp 18.2.6 (`omp --mode rpc`) auto-discovering
`.omp/extensions/fm-primary-omp-watch.ts` from a lab clone of the repository,
with a scripted OpenAI-compatible model server (`lab/fake-openai.mjs`) so every
model turn is deterministic. `lab/drive.sh` is the exact driver.

Flow per run: main arms the watcher with `fm_watch_arm_omp` -> main spawns one
in-process `task` helper whose model calls `fm_watch_arm_omp` itself -> omp
disposes the idle helper (task.agentIdleTtlMs=3000) -> main calls
`fm_watch_arm_omp` again -> owner shutdown attempt.

- `omp-live-helper-session-fixed-5886c9d.txt`: target commit. Helper start and
  shutdown are logged `inert`, the same watcher pid survives, and main's later
  arm call answers "unchanged - omp extension already owns an arm child".
- `omp-live-helper-session-base-9b11db8-regression.txt`: base commit, same
  driver. The helper's disposal killed the watcher and main's later arm call
  answered "watcher: not armed - omp session is shutting down" (the reported symptom).
- `session-generations.log`: the new diagnostic log from the fixed run.
- `omp-own-log-session-exits-fixed.jsonl`: omp's own "Session exit recorded
  reason dispose" line, whose timestamp matches the `session_shutdown inert` line.
- `helper-subagent-model-requests-fixed.jsonl`: the helper's model requests,
  showing its `fm_watch_arm_omp` result "another live omp session in this process owns the watcher".
- `omp-rpc-tool-frames-fixed.jsonl`: main session tool frames from the rpc stream.
- `fm-omp-harness-watch-tests.out`: the two watch-extension tests from tests/fm-omp-harness.test.sh.

Not observed live: the owner's own `session_shutdown owner` line. omp rpc mode
did not dispose the main session on stdin close, the `close` rpc command, or
SIGINT within the wait; that line is covered by the harness test only.
