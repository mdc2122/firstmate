# fm-flow-wait.py session-match: base 26e74f8a vs fix f8913cf7
Six worker sessions whose launch prompts are REAL bin/fm-brief.sh briefs (scout exploit, ship shipfix, secondmate mate-docs, scout anatomy) encoded by bin/fm-operational-input.sh, plus a legacy {note}-template brief and a bare-path brief.
exploit/shipfix task text cites anatomy.status and quotes a literal append to it.

## base: task spawn sessions kind touch_types
anatomy 2026-10-12T09:00:00Z 4 ship -
bare 2026-10-12T14:00:00Z 1 scout -
legacy 2026-10-12T13:00:00Z 1 scout -

## fix: task spawn sessions kind touch_types
anatomy 2026-10-12T09:00:00Z 1 scout -
bare 2026-10-12T14:00:00Z 1 scout -
exploit 2026-10-12T10:00:00Z 1 scout -
legacy 2026-10-12T13:00:00Z 1 scout -
mate-docs 2026-10-12T12:00:00Z 1 other -
shipfix 2026-10-12T11:00:00Z 1 ship -

## exploit launch prompt (lines with .status)
5:An earlier investigation (status notes in <tmp>/home/fm/state/anatomy.status) found the source.
6:It reported with `echo "done: found it" >> '<tmp>/home/fm/state/anatomy.status'`.
9:Reproduce it; the anatomy worker appended via: echo "blocked: x" >> <tmp>/home/fm/state/anatomy.status
31:   `echo "{state}: {one short line}" >> '<tmp>/home/fm/state/exploit.status'`
