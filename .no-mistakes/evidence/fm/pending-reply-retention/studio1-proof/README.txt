Live proof on studio1s-mac-studio (idle M3 Ultra, load ~3-8), 2026-10-20.
All product commands ran under `taskpolicy -c utility nice -n 15`.
Product roots: new = branch head 32b51f83, old = 32b51f83^; both copied from
git archive into /tmp/fm-pending-proof-<ts>/, never a live home.

Synthetic home: 444 pending-reply records, 442 resolved (incl. one with
escalated_epoch=900 and a matching closed escalation), 2 open requests.

Tick, old code (tick-old.txt): 47.12s, 38.19s, 39.21s per pass; 444 records
scanned every pass; 0 archived.

Tick, new code (tick-new.txt): 8.21s first pass (moved 442 to archive/),
0.45s and 0.46s on later passes; 2 open requests stay scanned; 444 records
preserved.

Real fm-watch.sh, new code (watcher-new.txt): first pass archives 442 while
the beacon advances; 2 open requests survive; 444 records total.

Corrected adversarial proof (adversarial.txt): a resolved record whose
escalation genuinely cannot close (its parent status file is read-only and
carries the open blocked line) stays scanned with no archive copy and an
empty escalation_closed_epoch; the 2 open requests stay scanned; 442 settled
records archive with phase=resolved and resolved_epoch intact; 445/445
records preserved, none deleted.

Real fm-watch.sh with that unclosed escalation (watch-unclosed.txt): beats at
t+1s, t+9s, t+10s, t+12s (beacon cadence now seconds, not minutes); after the
run scanned=3 archived=442 total=445.

Note on the first driver fixture: drive-tick-load.sh's
ffffffffffff0001 record has escalated_epoch set but no open blocked line in
any parent status, so the existing close path correctly records its
escalation_closed_epoch and archives it. That is a settled record, not an
unclosed escalation; adversarial.txt replaces it with a genuinely unclosable
one, which the new code leaves scanned.

note: old watcher (watcher-old.txt) completed no archive pass before its
signal exit and left 444 scanned, as expected for code with no retention.