# Intent and emission — plan

> source: `design/intent-emission.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — PA intent** (§ Parking, § The stages) — the stash seat takes pas into their note lanes
   under `parked`, PA dispatch moves ahead of every emission stage, and `parkPAs` flips a pa in place
   off its host's lane rather than off um's index, so the `parked.pa` list retires.  ← in flight
2. **Phase 2 — pb and pc columns in the CC walk** (§ Pitchbend and program change intent 1–2, 4,
   § Emission's output 1–2, 4) — the CC walk projects the pb column with `val` as intent cents and
   the pc column with authored pcs alone, `rebuildPbs` stamps `detune` as a cue rather than
   projecting the column, absorbers and synthesised pcs leave the columns, and the `priorPb` carry
   retires.
3. **Phase 3 — Parked pbs in the pb column** (§ Parking, § Pitchbend and program change intent 3)
   — the stash seat takes pbs into the pb column under `parked`, `parkPbs` flips a pb in place off
   the column rather than off um's index, and `pbBaseFor` reads the column alone, so
   `frame.authoredPb`'s union and the per-channel `parked` table retire.
4. **Phase 4 — Cues and the realisation map** (§ Emission's output, § Reading intent) —
   `REALISATION` becomes the cue set with `parked` and pb `detune` in it, the realisation map's
   parked share covers every kind a host parks, and each emission stage reads um's index only for
   the previous emission.

## Landed  (newest first; prune below ~4)

(nothing yet)

## Now

(empty)

## Queued (current phase; one-liners)

1. **tm: park pas in place in their host's lane** — `seatStash` seats pa specs in their lanes under
   `parked`, each spec carrying its `lane` as the column event minus its cues. `rebuildPA` moves to
   directly after `seatStash` and dispatches on-take pas alone. Its parked-host branch binds over the
   host's lane bound, computed at dispatch with `frame.clippedSpanEnd` over the lane's events, since
   `endppqC` is unstamped there. `parkPAs` flips a covered pa in place in its host's lane and restores
   one by clearing `parked`, so the index scan, the `exciseEvents` sweep, `installParked('pa')` and the
   carried `parked.pa` slot retire. docs: `docs/trackerManager.md` § PA dispatch, § The pipeline and
   the PA scan paragraph. Spec: in `tm_parked_carry_spec`, a newly parked host's pa flips in place
   and leaves mm; a clean pass carries the seat; a wholesale pass reseats it from the stash in its
   lane; a restore returns it to mm; and an mm pa under an already-parked host parks the same pass.
