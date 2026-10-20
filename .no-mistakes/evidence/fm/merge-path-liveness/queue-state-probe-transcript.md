# Live transcript: bin/fm-pr-queue-state.sh against a fake gh (base main requires ci + merge-queue app check queue-mq)

## PR 825 shape: armed, green, auto-merge never requested, zero queue statuses
$ bin/fm-pr-queue-state.sh --unhanded https://github.com/o/r/pull/825
unhanded 0123456789abcdef0123456789abcdef01234567 false queue-mq not reported

## Same, queue-mq only an EXPECTED placeholder
$ bin/fm-pr-queue-state.sh --unhanded https://github.com/o/r/pull/825
unhanded 0123456789abcdef0123456789abcdef01234567 false queue-mq EXPECTED

## Auto-merge enabled but queue silent, no hand-off
$ bin/fm-pr-queue-state.sh --unhanded https://github.com/o/r/pull/825
unhanded 0123456789abcdef0123456789abcdef01234567 true queue-mq not reported

## Queue answered (queue-mq IN_PROGRESS) -> clear
$ bin/fm-pr-queue-state.sh --unhanded https://github.com/o/r/pull/825
clear

## CI still running -> ci-pending
$ bin/fm-pr-queue-state.sh --unhanded https://github.com/o/r/pull/825
ci-pending 0123456789abcdef0123456789abcdef01234567 ci pending

## Required CI never reported -> ci-pending not reported
$ bin/fm-pr-queue-state.sh --unhanded https://github.com/o/r/pull/825
ci-pending 0123456789abcdef0123456789abcdef01234567 ci not reported

## Red CI -> clear (not a liveness wait)
$ bin/fm-pr-queue-state.sh --unhanded https://github.com/o/r/pull/825
clear

## Handed-over waiting line carries reported=false + detail (EXPECTED only)
$ bin/fm-pr-queue-state.sh https://github.com/o/r/pull/825 ["queue-mq"]
waiting 0123456789abcdef0123456789abcdef01234567 false queue-mq EXPECTED

## Handed-over waiting line, queue moving -> reported=true
$ bin/fm-pr-queue-state.sh https://github.com/o/r/pull/825 ["queue-mq"]
waiting 0123456789abcdef0123456789abcdef01234567 true queue-mq QUEUED

## Adversarial: green PR, base has NO merge-queue app check -> clear (no false wake)
$ bin/fm-pr-queue-state.sh --unhanded https://github.com/o/r/pull/825
clear
(exit 0)

## Adversarial: forge read fails (unreadable pr view payload) -> no output (unknown, watcher changes nothing)
$ bin/fm-pr-queue-state.sh --unhanded https://github.com/o/r/pull/825
<no output> (exit 0)

## Adversarial: draft PR -> clear
$ bin/fm-pr-queue-state.sh --unhanded https://github.com/o/r/pull/825
clear

## Probe never mutates: gh calls made across all probes
50
no pr merge / disable-auto calls
