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
   of `rec`. Measured identical in the spike, mm and column both.
3. **Phase 3 — comment corrections** (§ But the parallel threading is
   about the cell backref, not the end) — `:3897` cites "one
   mm:modify/MIDI_Sort", a cost the nest already absorbs; the real
   constraint is the cell backref. `:3894`'s ordering rule stays and
   gains the spec that pins it, since the spike inverted it unnoticed.
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

- 2026-07-29 design: spike results — cadence measured rather than read;
  H1 narrowed to one batch, H2 reshaped (§ Spike results)

## Now

(empty — run /plan-phase to split phase 1 into Queued.)

## Queued (current phase; one-liners)

(empty)
