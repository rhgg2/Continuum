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
   acceptance criterion, not the green run.  ← in flight
2. **Phase 2 — eager restore add** (§ `deferred` can move; the lazy
   closure is removable) — `:2671`'s `addLazy` becomes a plain
   `batch.add` with a provisional raw end from the logical ceiling and
   `realised` set at seat time; the walk's existing `:3533`
   write-through corrects it. Retires the closure and the post-hoc read
   of `rec`. **Not separable from phase 4** — the spike's "measured
   identical" was measured before a fixture looked; under phase 1's it
   loses `endppqC` on its own (§ `deferred` can move, 2026-07-29).
3. **Phase 3 — comment corrections** (§ But the parallel threading is
   about the cell backref, not the end) — `:3897` cites "one
   mm:modify/MIDI_Sort", a cost the nest already absorbs; the real
   constraint is the cell backref. `:3894`'s ordering rule stays, and
   is pinned by phase 1's clipped-restore case rather than a spec of
   its own (D2).
4. **Phase 4 — backref by uuid** (§ But the parallel threading is about
   the cell backref, not the end) — replace the parallel
   `restoredByChan` extras list with a `uuid → colEvt` map so the walk
   reads one index and still resolves the cell. Untested; dropping the
   threading outright loses `endppqC` silently, so phase 1 is what makes
   this attemptable at all.

## Settled by the spike — not doing

- **Per-batch cadence changes across the ten accumulators.** Nine of
  the ten already commit at the end of the function that populates
  them; there is nothing to move. Only `deferred` crosses a stage
  boundary, and phase 2 is that one case. (§ Nine of the ten already
  commit at their own stage boundary)
- **Sort churn (H3).** Never measured, and now moot: no cadence change
  is on the table that would add a commit.

## Landed  (newest first; prune below ~4)

- 2026-07-29 tm: park-restore fixture with teeth — E4b goes red; phases 2+4 collapse to one change (§ The suite does not discriminate any of this)
- 2026-07-29 design: spike results — cadence measured rather than read;

## Now

(empty — phase 1 landed. `tm_park_restore_end_spec` puts a restore in a swung channel and asserts both frames, so reconstructed E4b goes red on `endppqC` alone with mm still green. The same check reclassified phase 2: an eager add flips `frontierTails`' uuid-first seed resolution to the index entry, which carries no `colEvt`, so it loses `endppqC` on its own and cannot land before phase 4. Run /plan-next to promote the queued clipped-restore case, or to re-plan 2+4 as one item.)

## Queued (current phase; one-liners)

1. A second case in that file: a restore clipped short of its authored
   ceiling by a later on-take neighbour, in the same swung channel.
   Assert that the raw end and the cell's `endppqC` both sit at the clip
   point rather than the ceiling. This is where a provisional end
   written at add time and the corrected end written by the tail walk
   differ, so an add whose fix-up never fires becomes visible — which is
   what makes phase 2 attemptable at all. Clipping is also the pass
   whose seat keys are meant to have settled first, so this case carries
   the E3 red-check too (deferred committed before clampWrites); per D2
   phase 3 does not add an ordering spec of its own.
