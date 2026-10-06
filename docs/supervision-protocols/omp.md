Mode: omp (Oh My Pi) extension background wake.

When this session owns supervision and no legacy away daemon flag is active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Confirm the omp primary auto-loaded both project extensions from `.omp/extensions/`; omp has no project-trust gate, so a plain `omp` started with this home as its working directory loads them with no dialog.
   If `bin/fm-session-start.sh` reported the omp extensions as not loaded, restart omp inside this home; pass `-e __FM_OMP_TURNEND_EXT__ -e __FM_OMP_EXT__` only when omp must start from another directory, because omp loads a file named both ways twice.
3. Initial process cycle only: make the one required `fm_watch_arm_omp` call; if startup already owned the fleet lock, this is an ownership-based no-op.
   Use `/fm-watch-arm-omp` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through omp's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. If the extension says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_omp` again.
5. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live omp process, and owns every later successor launch.
6. Ordinary same-process session replacement (`/new`, `/resume`, `/fork`) retires only the prior generation; when the replacement owns the fleet lock, its `session_start` arms the new generation without a model turn or another `fm_watch_arm_omp` call.
   The generation-owner contract and in-flight actionable-close handoff live in `.omp/extensions/fm-primary-omp-watch.ts`; because omp reports no shutdown reason, every shutdown with a pending actionable close persists the handoff, and the next owning `session_start` in any process replays only the records whose own wake main has not yet acknowledged.
7. After an actionable child close, the extension rechecks session-lock ownership and verifies one successor before it delivers the follow-up wake; its bounded fallback is defined in `docs/watcher-continuity.md`.
8. Ordinary work, turn completion, and ordinary signal, stale, check, heartbeat, or other wake handling: do not call `fm_watch_arm_omp` again because continuity is extension-owned rather than model-memory-owned.
9. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
10. Missing, failed, or unhealthy cycle only: if a later notification explicitly reports one of those repair conditions, drain queued wakes, inspect the failure text, call `fm_watch_arm_omp`, and restart omp inside this home if the extensions are not loaded.
   A redundant call while the extension owns an arm child or scheduled retry, or a call from an in-process task subagent whose session found a live owner, is an ownership-based `watcher: unchanged` no-op, not an independent health claim.
11. Never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the pre-tool seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_OMP_TURNEND_EXT__`).

The turn-end guard on omp is structural, not advisory: `__FM_OMP_TURNEND_EXT__` answers omp's blocking `session_stop` hook, and when `bin/fm-turnend-guard.sh` returns 2 it forces one continuation carrying the guard text, bounded to one per turn by the `stop_hook_active` flag omp sets on the continuation's own stop.
An interrupted turn never raises `session_stop`, so a supervisor-initiated interrupt is not guarded; `bin/fm-control.sh` owns that postcondition.

The supervision branch is OFF unless this home's `config/omp-supervision-branch` names `on` or `report-only` ([docs/configuration.md](../configuration.md#omp-supervision-branch-configomp-supervision-branch)); [docs/pi-supervision-branch.md](../pi-supervision-branch.md) owns the branch contract it shares with Pi.
With the file absent this path stays unchanged: every actionable wake is delivered to this conversation exactly as on Claude, and the lease, outcome-store, and `fm_branch_processed` contracts do not apply.
`on` hands each eligible task-local wake to the in-process supervision branch first; a wake the branch cannot handle, every decision-owned and check-class row, and every watcher-failure alarm stay on this path, and an outcome main must act on arrives as one hidden processing request that only `fm_branch_processed` acknowledges.
A routine outcome the branch reports as `silent` - one whose handling found no state change, such as a worker still working with nothing new - is stored in the durable outcome store but never shown in this conversation; every other routine outcome arrives as a ⛵ note, and `fm_branch_outcomes` reads every stored outcome, silent ones included.
`report-only` delivers every wake to this conversation unchanged and lets the branch shadow it read-only while it records what it would do in `state/omp-branch-shadow.jsonl`, so it is the proof stage, never a working configuration.
A wake that reaches this conversation while it is idle starts a turn at once, one left unconsumed for 90 seconds is re-poked, and a wake the branch holds past its row-grant TTL (10 minutes) comes back here with a one-line note; `.omp/extensions/fm-primary-omp-watch.ts` owns those rules and [docs/watcher-continuity.md](../watcher-continuity.md#wake-queue-stall-alarm) owns the alarm for anything older.
The away daemon is never launched on omp: `/afk` writes only the away-posture record and this protocol keeps running under it, while `/quiet` refuses because the daemon cannot take monitoring over from this extension-owned watcher (`bin/fm-afk-launch.sh`).

The turn-end guard extension lives at `__FM_OMP_TURNEND_EXT__`.
The watcher extension lives at `__FM_OMP_EXT__`.
Both are tracked, project-local `.omp/extensions/*.ts` files that omp auto-discovers from this home with no trust dialog; `bin/fm-session-start.sh` reports when the running omp session has not loaded both required extensions.
