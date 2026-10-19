# Round 2 live stranded-draft scenarios (target f702f2e8; isolated tmux -L fmst, disposable FM_HOME under /tmp/fmst)

## L1 real pi 0.84.2: typed FIRSTMATE_OP watcher draft (no Enter), then real fm-send
```
## pre: composer state empty-pane = empty
## after typing stranded draft (no Enter): composer state = pending
## composer content = [FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: s:fm-pi] (U+2063 count: 0)
## screen bottom:
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: s:fm-pi
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
/private/tmp/fmst
0.0%/1.0M (auto)                                                                                                        
## run real fm-send
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: never, grace 300s).
●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
●  This is a supervision warning only; the requested message WILL still be sent.
●  watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
fm-send: submitted a stranded operational draft that was blocking the composer's pending text; the steer is durably recorded at /tmp/fmst/home-pi/state/pi1.inbox/001.msg and the watcher's next re-ring delivers the ordinary doorbell
fm-send exit=0
## screen after fm-send:
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Update Available
 New version 1.3.0 is available. Run pi update
 Changelog: https://pi.dev/changelog
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: s:fm-pi
 Let
 ⠦ Working...
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
/private/tmp/fmst
0.0%/1.0M (auto)                                                                                                                            
## composer state now = unknown
001.msg
handled

/tmp/fmst/home-pi/state/pi1.inbox/handled:
```
## L1b pi idles, watcher-role re-ring, worker acts + acks
```
## pi idle after draft turn (agent_state=alive composer=empty) after ~78s
## watcher-role re-ring rc=0
## acted=yes acked=yes after ~2s
 Also check whether the wake itself needs handling via fm-wake-drain.sh. There's no .wake-queue in home-pi/state. So no drain needed; the wake was a stranded dr
 stale banner .guard-watcher-stale-banner says "stale-beacon" — informative.                                                                                    
 Let me do the actions. Use bash.                                                                                                                               
 Also, maybe I should acknowledge the wake properly. The wake text "stale: s:fm-pi" as a primary wake would normally be handled by inspecting the pane, but as t
 machine-issued and I've handled it by processing my inbox.                                                                                                     
 Let me perform the touch and mv.                                                                                                                               
 $ set -e                                                                                                                                                       
 touch /tmp/fmst/acted-pi                                                                                                                                       
 mv /tmp/fmst/home-pi/state/pi1.inbox/001.msg /tmp/fmst/home-pi/state/pi1.inbox/handled/001.msg                                                                 
 ls -l /tmp/fmst/acted-pi                                                                                                                                       
 find /tmp/fmst/home-pi/state/pi1.inbox -type f -print                                                                                                          
 -rw-r--r--@ 1 studio2  wheel  0 Oct 19 13:48 /tmp/fmst/acted-pi                                                                                                
 /tmp/fmst/home-pi/state/pi1.inbox/handled/001.msg                                                                                                              
 Took 0.0s                                                                                                                                                      
 Now reply with one short line, addressed to the user. But should I say "captain"? The AGENTS.md says the firstmate addresses the user as captain in every chat 
 and the rule says the obligation is limited to chat and binds every agent reading this file. So I should include "captain" at least once. Hmm, but the user mes
 the tested worker. The instruction says "Reply with one short line."                                                                                           
 I'll reply one short line including "captain" to comply: "Captain, handled the wake and acknowledged the steer: touched /tmp/fmst/acted-pi and moved 001.msg in
 That's one line.                                                                                                                                               
 Captain, handled the wake and acknowledged the steer: touched /tmp/fmst/acted-pi and moved 001.msg into pi1.inbox/handled/.                                    
 : Firstmate instruction waiting: list '/tmp/fmst/home-pi/state/pi1.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to      
 '/tmp/fmst/home-pi/state/pi1.inbox'/handled/.                                                                                                                  
 ⠏ Working...                                                                                                                                                   
/private/tmp/fmst
↑36k ↓5.0k R187k CH96.4% 3.4%/1.0M (auto)                                                                                                                       
```
## fm-watch scenario: draft
```
initial fm-send exit=0
composer before watcher: pending :: ❯ ⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: check: pr-merged t3
--- triage log (steer-inbox):
[2026-10-19T13:50:00-0500] steer-inbox: submitted a stranded operational draft blocking draft's composer; doorbell re-rings on the next due tick
[2026-10-19T13:50:00-0500] steer-inbox delivery attempt: draft 001.msg result=4
[2026-10-19T13:50:03-0500] steer-inbox delivery attempt: draft 001.msg result=0
[2026-10-19T13:50:06-0500] steer-inbox delivery attempt: draft 001.msg result=0
--- watcher stdout:
stale: s:fm-draft (unread firstmate instruction: /tmp/fmst/home-draft/state/draft.inbox/001.msg still unhandled after 3 doorbell delivery attempts with an idle pane; inspect the worker)
--- worker submit log:
SUBMITTED: : Firstmate instruction waiting: list '/tmp/fmst/home-draft/state/draft.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/tmp/fmst/home-draft/state/draft.inbox'/handled/.
SUBMITTED: ⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: check: pr-merged t3
SUBMITTED: : Firstmate instruction waiting: list '/tmp/fmst/home-draft/state/draft.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/tmp/fmst/home-draft/state/draft.inbox'/handled/.
SUBMITTED: : Firstmate instruction waiting: list '/tmp/fmst/home-draft/state/draft.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/tmp/fmst/home-draft/state/draft.inbox'/handled/.
--- composer after: empty
```
## fm-watch scenario: stuck
```
composer before fm-send: pending
fm-send: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at /tmp/fmst/home-stuck/state/stuck.inbox/001.msg and the watcher will re-ring
initial fm-send exit=0
composer before watcher: pending :: ❯ ⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: s:fm-stuck
--- triage log (steer-inbox):
[2026-10-19T13:50:31-0500] steer-inbox delivery attempt: stuck 001.msg result=1
[2026-10-19T13:50:33-0500] steer-inbox delivery attempt: stuck 001.msg result=1
[2026-10-19T13:50:35-0500] steer-inbox delivery attempt: stuck 001.msg result=1
--- watcher stdout:
stale: s:fm-stuck (delivery-blocked: /tmp/fmst/home-stuck/state/stuck.inbox/001.msg still unhandled after 3 doorbell attempts - the composer's unsubmitted text blocks every doorbell; clear or submit the composer's pending text so steers can reach the worker)
--- worker submit log:
ENTER-IGNORED (stuck mode)
ENTER-IGNORED (stuck mode)
ENTER-IGNORED (stuck mode)
ENTER-IGNORED (stuck mode)
--- composer after: pending
```
## fm-watch scenario: human
```
composer before fm-send: pending
fm-send: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at /tmp/fmst/home-human/state/human.inbox/001.msg and the watcher will re-ring
initial fm-send exit=0
composer before watcher: pending :: ❯ hold on, let me think about this
--- triage log (steer-inbox):
[2026-10-19T13:51:01-0500] steer-inbox delivery attempt: human 001.msg result=1
[2026-10-19T13:51:03-0500] steer-inbox delivery attempt: human 001.msg result=1
[2026-10-19T13:51:06-0500] steer-inbox delivery attempt: human 001.msg result=1
--- watcher stdout:
stale: s:fm-human
--- worker submit log:
--- composer after: pending
```
## fm-watch scenario: near
```
composer before fm-send: pending
fm-send: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at /tmp/fmst/home-near/state/near.inbox/001.msg and the watcher will re-ring
initial fm-send exit=0
composer before watcher: pending :: │ > so I asked FIRSTMATE_OP: v1 watcher to do it but nothing happened                                         
--- triage log (steer-inbox):
[2026-10-19T13:51:17-0500] steer-inbox delivery attempt: near 001.msg result=1
[2026-10-19T13:51:19-0500] steer-inbox delivery attempt: near 001.msg result=1
[2026-10-19T13:51:22-0500] steer-inbox delivery attempt: near 001.msg result=1
--- watcher stdout:
stale: s:fm-near
--- worker submit log:
--- composer after: pending
```
