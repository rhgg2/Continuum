# Intent and emission — plan

> source: `design/intent-emission.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — PA intent** (§ Parking, § The stages) — the stash seat takes pas into their note lanes
   under `parked`, PA dispatch moves ahead of every emission stage, and `parkPAs` flips a pa in place
   off its host's lane rather than off um's index, so the `parked.pa` list retires. Landed 2026-09-26,
   1 commit.
2. **Phase 2 — pb and pc columns in the CC walk** (§ Pitchbend and program change intent 1–2, 4,
   § Emission's output 1–2, 4) — the CC walk projects the pb column with `val` as intent cents and
   the pc column with authored pcs alone, `rebuildPbs` stamps `detune` as a cue rather than
   projecting the column, absorbers and synthesised pcs leave the columns, and the `priorPb` carry
   retires.  ← in flight
3. **Phase 3 — Parked pbs in the pb column** (§ Parking, § Pitchbend and program change intent 3)
   — the stash seat takes pbs into the pb column under `parked`, `parkPbs` flips a pb in place off
   the column rather than off um's index, and `pbBaseFor` reads the column alone, so
   `frame.authoredPb`'s union and the per-channel `parked` table retire.
4. **Phase 4 — Cues and the realisation map** (§ Emission's output, § Reading intent) —
   `REALISATION` becomes the cue set with `parked` and pb `detune` in it, the realisation map's
   parked share covers every kind a host parks, and each emission stage reads um's index only for
   the previous emission.

## Landed  (newest first; prune below ~4)

- 2026-09-26 tm: sweep synthesised pcs outside tracker mode (design § Pitchbend and program change intent)
- 2026-09-26 tm: parked note hosts run their chain (design § Parking)
- 2026-09-26 tm: the CC walk projects the pb column as intent (design § Pitchbend and program change intent)
- 2026-09-26 tm: the pc column holds authored pcs alone (design § Pitchbend and program change intent)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

