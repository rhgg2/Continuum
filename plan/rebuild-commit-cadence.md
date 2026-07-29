# rebuild commit cadence — plan

> source: `design/rebuild-commit-cadence.md` — synthesis compiled from
> there; don't design here.

## Phases

1. **Phase 1 — a fixture with teeth** (§ The suite does not discriminate
   any of this) — park-restore coverage that can tell the cadences
   apart: a restore in a swung channel, so logical and raw stop
   agreeing, and one clipped short of its authored ceiling by a
   neighbour. Asserts the restored note's raw end **and** its cell's
   `endppqC`. Green-first, since HEAD is correct — the teeth are the
   acceptance criterion, not the green run.  ← done
2. **Phase 2 — eager restore add, backref by uuid** (§ `deferred` can
   move; § But the parallel threading is about the cell backref) —  ← in flight
   `:2671`'s `addLazy` becomes a plain `batch.add` with a provisional
   raw end from the logical ceiling and `realised` set at seat time;
   the walk's existing `:3533` write-through corrects it. The
   `restoredByChan` extras list (`:3844`, `:3853`) becomes a `uuid →
   colEvt` map, so the walk reads one index and still resolves the
   cell. **One change, not two**: the eager add flips `frontierTails`'
   uuid-first seed resolution (`:3757`) onto the index entry, which
   carries no `colEvt`, so the backref has to be resolvable by uuid
   before the add can move (§ `deferred` can move, 2026-07-29).
3. **Phase 3 — comment corrections** (§ But the parallel threading is
   about the cell backref, not the end) — `:3897` cites "one
   mm:modify/MIDI_Sort", a cost the nest already absorbs; the real
   constraint is the cell backref. Last, not first: phase 2 rewrites
   `:3842` outright and changes what is left in the `deferred` batch,
   so correcting the neighbours ahead of it means writing them twice.
   `:3894`'s ordering rule stays, and stays unpinned — D2 revised
   2026-07-29, the clipped case cannot carry E3.

## Settled by the spike — not doing

- **Per-batch cadence changes across the ten accumulators.** Nine of
  the ten already commit at the end of the function that populates
  them; there is nothing to move. Only `deferred` crosses a stage
  boundary, and phase 2 is that one case. (§ Nine of the ten already
  commit at their own stage boundary)
- **Sort churn (H3).** Never measured, and now moot: no cadence change
  is on the table that would add a commit.

## Landed  (newest first; prune below ~4)

- 2026-07-29 tm: the clipped restore case — ceiling raw 619 vs bound raw 379; closes phase 1 (§ The suite does not discriminate any of this)
- 2026-07-29 tm: park-restore fixture with teeth — E4b goes red; phases 2+4 collapse to one change (§ The suite does not discriminate any of this)
- 2026-07-29 design: spike results — cadence measured rather than read;

## Now

**Nothing compiled — phase 1 is closed.** Phase 2 is in flight but not
yet split. Run `/plan-phase` to break it into commit-sized items, then
`/plan-next`.

**What phase 1 leaves phase 2.**
`tests/specs/tm_park_restore_end_spec.lua` now carries two cases, and
case 2 is the one that watches the eager add. Verified in the spike by
forcing `laneClip = math.huge` at `trackerManager.lua:3522-3524` —
which is exactly the shape of an add whose walk fix-up never fires.
Three assertions bite, in source order, each needing the one above
neutered to reach it:

| assertion | under the known-bad variant |
|---|---|
| `authored.endppq` 379 | 619 — the clip is gone even before the park |
| `restored.endppq` 379 | 619 — the restored end is the ceiling, uncorrected |
| `util.round(cell.endppqC)` 360 | 600 — the cell ceiling is the ceiling too |

Case 1 stays green throughout, since its ceiling *is* its bound. So a
phase 2 regression surfaces at `authored.endppq` first; the two below
it are the ones that speak to the restore path specifically, and are
worth reading past the first failure when it fires.

**D2 revised** is at `design/rebuild-commit-cadence.md:225-239` —
drafted by `/plan-next` when the decision was settled, landed by the
same commit as the case. `:3894`'s ordering rule stays unpinned;
nothing on this programme inverts it.

## Queued (current phase; one-liners)

(empty — run /plan-phase to split merged phase 2 into commit-sized
items.)
