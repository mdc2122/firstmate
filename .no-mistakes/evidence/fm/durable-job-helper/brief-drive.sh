#!/usr/bin/env bash
# Scaffold real ship and scout briefs into a throwaway FM_HOME and show rule 8.
W=$1; H=/tmp/fmbrief-home; mkdir -p $H/data
printf -- "- direct-proj [direct-PR] - fixture (added 2026-07-01)\n" > $H/data/projects.md
for a in "ship-dj-a1 some-proj --mode no-mistakes" "scout-dj-b1 some-proj --scout"; do
  set -- $a
  out=$(FM_HOME=$H "$W/bin/fm-brief.sh" "$@" 2>&1); echo "\$ fm-brief.sh $a -> rc=$?"
  [ -f "$H/data/$1/brief.md" ] || echo "$out" | tail -3
  grep -n "fm-durable-job" "$H/data/$1/brief.md"
done
rm -rf /tmp/fmbrief-home
