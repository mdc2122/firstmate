# Fleet placement

Fleet placement runs bounded omp ship workers on the operator's other machines without choosing a machine by hand.
Firstmate samples every configured donor host, places the task on the host with the most spare capacity after that host's own reserve, starts the worker there in a git worktree, and keeps supervising it from this machine.
On hosts set up for Herdr, every remote worker appears in this machine's Herdr view under the saved machine `fleet-<host>`, next to local work.

Placement only decides where new work lands.
Running work never moves between hosts: a host that turns busy or fails only stops new placements there, and an interrupted worker resumes on the same host or its work is fetched home and relaunched as new work.

[`bin/fm-fleet.sh`](../bin/fm-fleet.sh) owns the commands, [`bin/fm-fleet-lib.sh`](../bin/fm-fleet-lib.sh) owns the host config grammar and the placement rule, and [`bin/backends/fleet.sh`](../bin/backends/fleet.sh) routes the ordinary task tools to a remote worker.

## Opt-in and removal

Fleet placement is off unless this home has `config/fleet-hosts`.
Without that file every `fm-fleet.sh` command refuses, the watcher skips its fleet mirror, and nothing is ever placed off this machine.

Remove a host by deleting its line from `config/fleet-hosts`, or set `enabled=0` to keep the record.
Remove fleet placement entirely by deleting `config/fleet-hosts` after releasing every fleet task (`fm-fleet.sh release <id>`).
The per-host artifacts below are removed with the commands listed under [Host removal](#host-removal).

## Host config

`config/fleet-hosts` holds one line per donor host:

```text
studio1 ssh=studio1 os=darwin session=herdr root=/Users/studio1/fm-fleet slots=1 reserve_cpus=8 reserve_mem_gb=32 worker_cpus=2 worker_mem_gb=4
strix ssh=strix os=linux session=herdr root=/home/clawdbot/fm-fleet slots=1 reserve_cpus=4 reserve_mem_gb=16 worker_cpus=2 worker_mem_gb=4 busy_procs=Runner.Worker
desktop-linux ssh=desktop-linux os=linux session=herdr root=/home/morley/fm-fleet slots=1 reserve_cpus=4 reserve_mem_gb=16 hours=08-20 tz=America/Chicago busy_procs=Runner.Worker
```

The header of [`bin/fm-fleet-lib.sh`](../bin/fm-fleet-lib.sh) owns every field and its default.
`hours=` is the hard window for new placements, `busy_procs=` names processes such as a GitHub Actions job (`Runner.Worker`) that make a host busy at once, and `reserve_cpus=` and `reserve_mem_gb=` are headroom kept for the host's own workloads.
An invalid line stops every command with the line number, because a typo in a limit must never widen where work lands.

## Placement and busy hosts

`fm-fleet.sh hosts` samples every host in parallel and prints one verdict per host; `place` and `launch` use the same verdicts.
A host is eligible only when it is reachable, its OS matches, the local hour is inside `hours=`, it has a free slot, its availability state is `available`, and its spare cores and memory after the reserve still fit one more worker.
The eligible host with the most spare cores wins.
When no host is eligible, `place` and `launch` exit 4 and print every host's reason: the task stays queued and no host is ever overloaded.

The availability state copies the gating idea of Crabbox's `serve` provider ([openclaw/crabbox](https://github.com/openclaw/crabbox) `docs/providers/serve.md`, MIT), adapted to on-demand sampling:

- CPU over the host's `max_cpu=` ceiling (default 50% of all cores, judged by both the sampled CPU fraction and the 1-minute load per core) or memory pressure at warn or worse turns a host busy only after it persists across samples for 60 seconds; a shorter burst never turns it busy.
- A busy host turns available again only after 5 minutes with no busy observation and a 5-minute load average under the ceiling.
- A `busy_procs=` process makes the host busy at once.
- An unreachable host or an unreadable signal blocks new placement without changing the recorded state.
- A rising signal still inside its 60-second hold takes no new work but does not flip the host to busy.

Memory pressure is the kernel's own verdict: macOS `sysctl kern.memorystatus_vm_pressure_level` (2 is warn, 4 is critical), and Linux `/proc/pressure/memory` (or `MemAvailable` below 10% and 5% where PSI is absent).
Per-host state lives in `state/fleet/<host>.availability`.

A reservation (`state/fleet/<id>.reservation`) holds a host's slot from placement until the worker's process appears in the host's own sample, or until its deadline (`FM_FLEET_RESERVATION_TTL`, default 600 seconds) passes, so a launch that dies before starting frees its slot on its own.
Placement runs under one lock, so concurrent launches never take the same last slot.

## Host setup

Each donor needs SSH from this machine with public-key auth, `git`, `jq` here, and Herdr there (or `tmux` for a `session=tmux` fallback host).
`fm-fleet.sh setup <host>` then installs the omp release binary matching this machine's omp version into `<root>/bin/omp` (checked against the release `SHA256SUMS.txt`) and writes `<root>/agent/models.yml` with only this home's providers that go through the studio1 gateway.
API keys in that file are the `CLIPROXY_KEY` environment reference; setup writes the key once to `<root>/agent/gateway.env` (mode 0600) from this machine's environment.
Setup touches nothing outside `<root>`: no shell profile, no `~/.omp`, and no Claude, Codex, or pi credentials, and no OAuth session is ever copied.

### Herdr view

`session=herdr` puts each worker in a workspace `fm-<id>` on the host's own Herdr server in the named session `fm-fleet`, never the host's `default` session.
This machine reaches it through a Herdr saved machine, so the worker shows in this machine's Herdr sidebar with no SSH command:

1. Install the Herdr release that matches this machine's Herdr into `~/.local/bin/herdr` on the host (the path Herdr's remote discovery uses).
2. Run `herdr server --session fm-fleet` on the host as a service: a systemd user unit on Linux, or an Aqua LaunchAgent in `gui/<uid>` on macOS.
   Saved machines require the server to be its own session leader; under launchd that needs a fork before `setsid`, because launchd already makes the job a process-group leader.
3. Add the profile here: `herdr machine add <ssh-alias> --label fleet-<host> --remote-session fm-fleet`.

The units used in the pilot:

```ini
# ~/.config/systemd/user/firstmate-fleet-herdr.service (Linux)
[Service]
ExecStart=%h/.local/bin/herdr server --session fm-fleet
Restart=on-failure
RestartSec=10
[Install]
WantedBy=default.target
```

```text
# ~/Library/LaunchAgents/dev.firstmate.fleet-herdr.plist (macOS), ProgramArguments:
/bin/zsh -l -c "exec /usr/bin/perl -MPOSIX -e 'my $p = fork() // die \"fork: $!\"; if ($p == 0) { POSIX::setsid() >= 0 or die \"setsid: $!\"; exec @ARGV or die \"exec: $!\" } $SIG{TERM} = sub { kill \"TERM\", $p }; waitpid($p, 0); exit($? >> 8)' \"$HOME/.local/bin/herdr\" server --session fm-fleet"
# plus LimitLoadToSessionType=Aqua, RunAtLoad, KeepAlive={SuccessfulExit=false}, ThrottleInterval=10
```

`session=herdr` is the default: a host record with no `session=` uses Herdr.
A host that cannot meet these may fall back to `session=tmux`, and its record must then say why with `tmux_reason=<token>` (for example `tmux_reason=no-gui-session`); a `session=tmux` record without a reason is refused.
Its workers run in a detached tmux session `fm-<id>` that is not in the Herdr view, `fm-fleet.sh hosts`, `place`, and `launch` print the reason next to that host, and `fm-fleet.sh attach <id>` prints the SSH command that opens it.

## Launch

```sh
bin/fm-fleet.sh launch <task-id> <project-dir> --model <provider/id> --effort <level>
```

The task's brief must already exist at `data/<task-id>/brief.md`.
Launch places the task, pushes the project's current `HEAD` into a bare mirror on the host as branch `fm/<task-id>`, creates the worktree, prepends fleet worker paths to the brief, and starts omp there with the session directory `<root>/sessions/<task-id>`.
It records the task as `state/<task-id>.meta` with `backend=fleet` and `mode=local-only` before it creates the host worktree, so a launch that fails part way still leaves a record that `state`, `stop`, and `release` work on: hosts hold no GitHub credential and never push, and results come home through `fetch`.

## Monitoring and steering

When `config/fleet-hosts` exists the watcher runs one detached `fm-fleet.sh sync` each cycle.
Syncs of one task run one at a time, so the watcher's sync and the one each `fm-send` rings never mirror the same status bytes twice.
Sync mirrors the host's status log into `state/<id>.status`, turn-end markers into `state/<id>.turn-ended`, and the worker's busy and idle events into the ordinary busy-state record, so the watcher, `bin/fm-crew-state.sh`, and the fleet view treat a remote worker like a local one.
`bin/fm-send.sh <id> '<text>'` writes the usual durable inbox record, delivers it to the host's inbox, and rings the doorbell in the worker's pane; the worker's move into `handled/` on the host is mirrored back as the acknowledgement.
`bin/fm-peek.sh <id>` reads the remote pane, and `fm-fleet.sh state <id>` reports `alive`, `dead`, `missing`, or `unreadable` (an unreachable host is never treated as a dead worker).

## Recovery

- Reconnect: workers live in the host's Herdr server or tmux, not in an SSH connection, so a dropped connection, a closed Herdr client, or a restarted primary changes nothing; reopen Herdr or rerun the command.
- Agent exit or crash: `fm-fleet.sh resume <id>` relaunches omp in the same host endpoint and worktree with `--resume` on the saved session, so the conversation history continues; it refuses while the old omp is alive or the host does not answer.
- Results: `fm-fleet.sh fetch <id>` fetches `fm/<id>` into the project as `refs/fleet/<id>`, saves the uncommitted diff (tracked and untracked) to `data/<id>/fleet/uncommitted.patch`, and archives the omp session and status log to `data/<id>/fleet/session.tar`, without touching the host worktree or index.
- Host lost: fetch what the host still serves, then launch the work again as a new task; placement chooses another host.
- Release: `fm-fleet.sh release <id>` stops the worker first (SIGTERM, then SIGKILL after 10 seconds; it refuses if omp still survives), so nothing changes after the snapshot, then fetches, refuses while uncommitted work exists (resume the worker to commit it, or set `FM_FLEET_RELEASE_DISCARD=1` once the saved patch suffices), and otherwise closes its endpoint and removes the host worktree while keeping the branch on both sides.
  A released task is no longer synced, so its old host markers never wake firstmate, and `sync`, `ring`, `key`, `type`, `stop`, `fetch`, `resume`, and `release` refuse it with exit 5 (teardown treats that as already closed), so the saved work in `data/<id>/fleet` is never overwritten.
  `fetch` replaces the saved patch, session archive, and head only when every read succeeds.
  When the host worktree is already gone (a launch that failed before creating it, or a release interrupted after removing it), `fetch` and `release` keep every saved file in `data/<id>/fleet` byte-identical, adding an empty patch only when none was saved, and release records the task as released with nothing to remove.
- Cleanup: `bin/fm-teardown.sh` refuses a fleet task until it has been released, because its local landed-work checks cannot see a worktree on another host; `--force` does not lift that refusal.

## Host removal

For each host, after `fm-fleet.sh release` for its tasks:

- Fleet files: `ssh <host> rm -rf <root>`.
- Herdr profile here: `herdr machine remove <profile-id>` (from `herdr machine list --json`); this leaves the host's sessions running.
- Herdr service on Linux: `systemctl --user disable --now firstmate-fleet-herdr.service && rm ~/.config/systemd/user/firstmate-fleet-herdr.service`.
- Herdr service on macOS: `launchctl bootout gui/$(id -u)/dev.firstmate.fleet-herdr && rm ~/Library/LaunchAgents/dev.firstmate.fleet-herdr.plist`.
- Herdr binary: `rm ~/.local/bin/herdr` only when nothing else on that account uses it.

## Fleet hosts in this deployment

| host | role | placement |
|---|---|---|
| studio1 | M3 Ultra, gateway host and production standby | eligible; `reserve_cpus=8 reserve_mem_gb=32` keeps the gateway reserve; never touch `~/.viral-host-role` or production trees |
| strix | Strix Halo Linux, GitHub Actions runner | eligible below CI: `busy_procs=Runner.Worker` |
| desktop-linux | the operator's interactive Linux desktop | daytime only: `hours=08-20 tz=America/Chicago` plus `busy_procs=Runner.Worker` |
| tmuxbot | M4 mini | excluded until it can reach the studio1 gateway over TCP (connections to tailnet peers are refused from SSH sessions there) |
| grokbot | M4 mini | excluded by the operator's rule for that host |

## Verification

`bin/fm-test-run.sh tests/fm-fleet-placement.test.sh` covers the opt-in, hysteresis, memory pressure, busy processes, hours, reservation, and exit-4 contracts with sampled fixtures and no SSH.
The live pilot evidence (placements, Herdr sidebar captures, steering, crash and resume, fetch) is kept with the task's private report, not here.
