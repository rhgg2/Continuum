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

- 2026-09-26 tm: park pas in place in their host's lane (design § Parking)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **tm: the pc column holds authored pcs alone** — the CC walk's wholesale path skips derived pcs,
   as its splice path already does. `reconcilePCsForChan` reads the previous emission's synthesised
   pcs from um's index, clipped to the seed spans, and `rebuildPCs` drops its column splice, so the
   column exists only when it holds an event or `extraColumns` asks for it. docs:
   `docs/trackerManager.md` § CC walk, § PC synthesis. Spec: in tracker mode a synthesised pc is in
   mm and absent from the pc column; an authored pc sits in the column; a clean re-pass leaves the
   synthesised pcs unchurned; a seed-span edit reconciles only the pcs in its spans.

1. **tm: the CC walk projects the pb column as intent** — both CC walk paths project authored pbs
   with `val` as cents, leaving out absorbers and the markerless seats a window owns (the walk's
   `pbSeat` test). `rebuildPbs` stops projecting the column and stamps `detune` on each column pb it
   re-derives. A foreign pb projects with no `val`; the pass that back-derives its cents writes
   them to mm and seeds the pb's cell, so the next pass's CC walk projects them as `val`. The
   `priorPb` carry, `ppqRaw`, the `anyVisible` keep rule and the `hidden` flag retire — `hidden`
   with its filters in trackerView, gridPane, `groupMembers` and groupManager's field list. docs:
   `docs/tuning.md` § Absorber reconciliation, `docs/trackerManager.md` § CC walk, § Absorber
   reconciliation. Spec: an authored pb sits in the column with `val` as its cents and `detune` as
   its base voice's detune; an absorber is in mm and absent from the column; a clean pass carries
   the column; a detune change restamps `detune` and leaves `val`; a foreign pb gains its `val` on
   the pass after the one that derives its cents.
