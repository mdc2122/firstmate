# Live omp 18.4.4 validation (mock LLM, isolated HOME/PI_CODING_AGENT_DIR, lab clone per commit)

Real `omp --mode rpc` loaded the tracked `.omp/extensions` from a clone of each commit and armed the real `bin/fm-watch.sh` through `/fm-watch-arm-omp`.
A local OpenAI-compatible mock recorded every model request. A lab-only extension posted an idle custom note (no triggerTurn), standing in for the supervision branch's ⛵ note that preceded the 2026-10-06 stall.

## Incident reproduction: idle note, then a worker signal, with no captain input
| commit | wake delivered as | first model request carrying the wake |
|---|---|---|
| base fe95b47 | `followUp` (rpc `queue_update` shows it parked) | none for ~106s, then released only when a "captain" prompt was typed (00:38:42) |
| target 91f3e09 | aside (starts a turn) | 4s after the signal (00:30:59 signal -> 00:31:03 request) |

## Target-only live scenarios
- Re-poke: a follow-up queued mid-turn, then the turn was aborted (captain interrupt). After 6s idle (FM_OMP_WAKE_REPOKE_SECS=6) a hidden re-poke started a turn naming the wake, and omp drained the parked wake right behind it. Triage log line: "omp extension re-poked 1 unconsumed wake(s) after 6s idle".
- Provider error ("Request was aborted" 400) mid-turn: the queued wake still reached the model right after the failed turn.
- Stall alarm, idle main (FM_WAKE_QUEUE_STALL_SECS=20): check row `wake-queue-stall-1` appended, alert channel command fired ("2 notification(s) queued with no conversation taking them for 21s"), and the check wake reached main.
- Stall alarm, long main turn (70s turn, FM_BUSY_TURN_MAX_SECS=45): `state/.main-turn-busy` = "<omp pid> 1 <epoch>", with the pid equal to the `state/.lock` pid. No alarm at the 20s threshold; the alarm fired at the 45s cap, while the turn was still running. The marker was removed at agent_end. See omp-live-tgt-long-turn-deferral-timeline.txt.
- Branch hand-back (config/omp-supervision-branch=on, branch LLM requests hang, TTL 8s, grace 2s): the branch took the wake at 00:41:54. Main received the same wake with the hand-back note at 00:42:02. Main's drain then printed "WAKE ROWS REVERTED FROM SUPERVISION BRANCH: 2 row(s) held 34s without branch progress (TTL 8s)". The next signal skipped the stuck branch and went straight to main.
