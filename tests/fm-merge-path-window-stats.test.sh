#!/usr/bin/env bash
# Tests the windowing and arm-classification logic of
# bin/fm-merge-path-window-stats.py, the parts a later re-measure relies on to
# attribute time correctly: every PR-hour interval is clipped to
# [--since, --until] at both edges, a PR still open at --until runs to the
# window end, consecutive-merge cycles keep only pairs merged inside the
# window, and an auto-merge arm is classified from the supervisor action
# ledger only within its 60 s before / 5 s after match window.
# No network: only the pure functions are exercised, through the module.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || fail "python3 is required by bin/fm-merge-path-window-stats.py"

out=$(python3 - "$ROOT/bin/fm-merge-path-window-stats.py" <<'PY' 2>&1
import importlib.util, sys

spec = importlib.util.spec_from_file_location("window_stats", sys.argv[1])
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)

W0, W1 = 1000.0, 2000.0
failures = []


def check(name, got, want):
    if got != want:
        failures.append(f"{name}: got {got!r}, want {want!r}")


# clip: only the part of an interval inside the window counts
check("clip straddles start", M.clip(500, 1200, W0, W1), 200)
check("clip straddles end", M.clip(1800, 2600, W0, W1), 200)
check("clip spans window", M.clip(0, 5000, W0, W1), 1000)
check("clip inside", M.clip(1100, 1300, W0, W1), 200)
check("clip before window", M.clip(100, 900, W0, W1), 0.0)
check("clip after window", M.clip(2100, 2900, W0, W1), 0.0)
check("clip touches start", M.clip(500, 1000, W0, W1), 0.0)

# pr_hours: green before the window and armed after it is green-unarmed for
# exactly the window, split by the busy queue intervals (also clipped)
busy = M.merge_intervals([(800, 1100), (1050, 1200), (1900, 2500)])
check("busy intervals merge", busy, [[800, 1200], [1900, 2500]])
h = M.pr_hours([dict(pr=1, green=500, armed=2500, mq_start=None, merged=2600)], busy, W0, W1)[1]
check("unarmed busy clipped", h["green_unarmed_queue_busy"], 300)
check("unarmed idle clipped", h["green_unarmed_queue_idle"], 700)
check("armed after window adds nothing", h["armed_not_enqueued"], 0.0)

# an open line entry (merged None) waits until the window end, not forever
h = M.pr_hours([dict(pr=2, green=1500, armed=None, mq_start=None, merged=None)], [], W0, W1)[2]
check("open entry runs to --until", h["green_unarmed_queue_idle"], 500)
check("open entry flagged", h["open_at_until"], True)

# a PR that merged and went live inside the window: each state ends where the next starts
h = M.pr_hours([dict(pr=3, green=900, armed=1100, mq_start=1150, merged=1400, joined=1500, live=2300)],
               [], W0, W1)[3]
check("lifecycle green_unarmed", h["green_unarmed_queue_idle"], 100)
check("lifecycle armed_not_enqueued", h["armed_not_enqueued"], 50)
check("lifecycle in_queue", h["in_queue"], 250)
check("lifecycle merged_not_joined", h["merged_not_joined"], 100)
check("lifecycle joined_not_live clipped", h["joined_not_live"], 500)

# a PR merged without an auto-squash arm stops being green-unarmed at its merge
h = M.pr_hours([dict(pr=5, green=1100, armed=None, mq_start=None, merged=1400)], [], W0, W1)[5]
check("unarmed merge ends green_unarmed", h["green_unarmed_queue_idle"], 300)
check("unarmed merge then merged_not_joined", h["merged_not_joined"], 600)

# an open entry whose gitea-mq check already ended (ejected) leaves the queue then
open_rows = [dict(pr=6, green=None, armed=None, mq_start=1200, mq_done=1300, merged=None),
             dict(pr=7, green=1100, armed=1150, mq_start=1600, mq_done=None, merged=None)]
check("ejected entry busy ends at check end", M.busy_intervals([], open_rows, W0, W1), [[1200, 1300], [1600, W1]])
h = M.pr_hours([dict(pr=8, green=1100, armed=1150, mq_start=1200, mq_done=1300, merged=None)], [], W0, W1)[8]
check("ejected entry in_queue ends at check end", h["in_queue"], 100)
check("check ended before window is not busy",
      M.busy_intervals([], [dict(mq_start=500, mq_done=900)], W0, W1), [])

# release stages count only finished tickets
tk = [dict(join=1000, canary=1100, promote=1160, deploy=1200, done=1500),
      dict(join=1000, canary=1100, promote=None, deploy=None, done=None)]
st = M.ticket_stages(tk)
check("ticket stages count finished only", (st["join_to_done"]["n"], st["canary_to_promote"]["n"],
                                            st["deploy_to_done"]["n"]), (1, 1, 1))

# a PR never green owns no PR-hours
check("never green skipped", M.pr_hours([dict(pr=4, green=None, armed=None, mq_start=None, merged=None)],
                                        [], W0, W1), {})

# cycles: only consecutive merges whose both ends fall inside the window
rows = [dict(pr=p, merged=m, green=g, armed=a, arm_class=None)
        for p, m, g, a in ((10, 900, 800, 850), (11, 1100, 800, 1000), (12, 1500, 1000, 1200), (13, 2100, 1200, 2000))]
cyc = M.cycles(rows, W0, W1)
check("cycles inside window", [(c["prev"], c["nxt"]) for c in cyc], [(11, 12)])
check("cycle next was green", cyc[0]["next_was_green"], True)
check("cycle merge to next arm", cyc[0]["merge_to_next_arm"], 100)

# arm_class: the 60 s before / 5 s after ledger window, latest matching row wins
url = "https://github.com/o/r/pull/"


def row(pr, epoch, origin):
    return dict(target=f"{url}{pr}", epoch=epoch, origin=origin)


check("not armed", M.arm_class("o/r", 812, None, [row(812, 1000, "fm-watch.sh")]), None)
check("watcher 60s before", M.arm_class("o/r", 812, 1000, [row(812, 940, "fm-watch.sh")]), "watcher")
check("hand 5s after", M.arm_class("o/r", 812, 1000, [row(812, 1005, "direct")]), "hand")
check("61s before is unledgered", M.arm_class("o/r", 812, 1000, [row(812, 939, "fm-watch.sh")]), "unledgered")
check("6s after is unledgered", M.arm_class("o/r", 812, 1000, [row(812, 1006, "direct")]), "unledgered")
check("other PR ignored", M.arm_class("o/r", 812, 1000, [row(81, 1000, "direct"), row(1812, 1000, "direct")]),
      "unledgered")
check("same PR number in another repo ignored",
      M.arm_class("o/r", 812, 1000, [dict(target="https://github.com/x/o/r/pull/812", epoch=1000, origin="direct"),
                                    dict(target="https://github.com/o/other/pull/812", epoch=1000, origin="direct")]),
      "unledgered")
check("latest watcher row decides", M.arm_class("o/r", 812, 1000, [row(812, 970, "direct"), row(812, 990, "fm-watch.sh")]),
      "watcher")
check("latest hand row decides", M.arm_class("o/r", 812, 1000, [row(812, 990, "fm-watch.sh"), row(812, 999, "direct")]),
      "hand")

print("\n".join(failures) if failures else "ok")
PY
)
[ "$out" = ok ] || fail "window stats logic: $out"
pass "window clipping, cycles, and arm classification"
