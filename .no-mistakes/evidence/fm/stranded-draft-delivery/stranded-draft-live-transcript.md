# Live stranded-draft scenarios (isolated tmux -L fmstrand, FM_HOME under /tmp/fm-strand.JRhO)

## S1 fm-send against Claude-style composer holding a stranded FIRSTMATE_OP watcher draft
fm-send stderr: fm-send: submitted a stranded operational draft that was blocking the composer's pending text; ... (exit 0)
worker submit log:
SUBMITTED: ⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: s:fm-t1

## S1b real fm-watch re-ring after rc4 (home1)
[2026-10-19T13:38:29-0500] steer-inbox delivery attempt: t1 001.msg result=0
[2026-10-19T13:38:32-0500] steer-inbox delivery attempt: t1 001.msg result=0
[2026-10-19T13:38:36-0500] steer-inbox delivery attempt: t1 001.msg result=0
SUBMITTED: : Firstmate instruction waiting: list '/tmp/fm-strand.JRhO/home1/state/t1.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/tmp/fm-strand.JRhO/home1/state/t1.inbox'/handled/.
SUBMITTED: : Firstmate instruction waiting: list '/tmp/fm-strand.JRhO/home1/state/t1.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/tmp/fm-strand.JRhO/home1/state/t1.inbox'/handled/.
SUBMITTED: : Firstmate instruction waiting: list '/tmp/fm-strand.JRhO/home1/state/t1.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/tmp/fm-strand.JRhO/home1/state/t1.inbox'/handled/.

## S2 real fm-watch finds stranded draft at re-ring (home3)
[2026-10-19T13:39:14-0500] steer-inbox: submitted a stranded operational draft blocking t3's composer; doorbell re-rings on the next due tick
[2026-10-19T13:39:14-0500] steer-inbox delivery attempt: t3 001.msg result=4
[2026-10-19T13:39:17-0500] steer-inbox delivery attempt: t3 001.msg result=0
[2026-10-19T13:39:20-0500] steer-inbox delivery attempt: t3 001.msg result=0
[2026-10-19T13:39:24-0500] steer-inbox delivery attempt: t3 001.msg result=0
SUBMITTED: : Firstmate instruction waiting: list '/tmp/fm-strand.JRhO/home3/state/t3.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/tmp/fm-strand.JRhO/home3/state/t3.inbox'/handled/.
SUBMITTED: ⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: check: pr-merged t3
SUBMITTED: : Firstmate instruction waiting: list '/tmp/fm-strand.JRhO/home3/state/t3.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/tmp/fm-strand.JRhO/home3/state/t3.inbox'/handled/.
SUBMITTED: : Firstmate instruction waiting: list '/tmp/fm-strand.JRhO/home3/state/t3.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/tmp/fm-strand.JRhO/home3/state/t3.inbox'/handled/.
SUBMITTED: : Firstmate instruction waiting: list '/tmp/fm-strand.JRhO/home3/state/t3.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/tmp/fm-strand.JRhO/home3/state/t3.inbox'/handled/.

## S3/S4 human + near-miss pending text: fm-send 'doorbell skipped', worker submit logs empty
ls: /tmp/fm-strand.JRhO/submit-human.log: No such file or directory
ls: /tmp/fm-strand.JRhO/submit-near.log: No such file or directory

## S5 stuck harness (Enter does not free composer)
ENTER-IGNORED (stuck mode)
ENTER-IGNORED (stuck mode)
ENTER-IGNORED (stuck mode)
ENTER-IGNORED (stuck mode)
[2026-10-19T13:39:55-0500] steer-inbox delivery attempt: stuck 001.msg result=1
[2026-10-19T13:39:58-0500] steer-inbox delivery attempt: stuck 001.msg result=1
[2026-10-19T13:40:00-0500] steer-inbox delivery attempt: stuck 001.msg result=1
stale: s:fm-stuck (delivery-blocked: /tmp/fm-strand.JRhO/home-stuck/state/stuck.inbox/001.msg still unhandled after 3 doorbell attempts - the composer's unsubmitted text blocks every doorbell; clear or submit the composer's pending text so steers can reach the worker)

## S6 real pi 0.x in tmux: typed draft renders WITHOUT U+2063
composer state=pending, content=[FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: s:fm-pi] (0 U+2063 bytes)
fm_task_inbox_ring -> ring_rc=1 ; draft still in composer, steer starved

## S6b real grok in tmux: same draft renders WITHOUT U+2063; composer state=pending-unproven (rings normally)
