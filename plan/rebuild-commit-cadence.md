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
2. **Phase 2 — eager restore add, backref by seat stamp** (§ `deferred`
   can move; § D3) —  ← in flight
   `:2671`'s `addLazy` becomes a plain `batch.add` with a provisional
   raw end from the logical ceiling and `realised` set at seat time;
   the walk's existing `:3533` write-through corrects it. No new
   conduit: `stampColEvt` (`:992`) is the backref, and `:4703` already
   stamps these restores one stage late, so moving the add moves the
   stamp with it and `restoredByChan` (`:3844`, `:3853`) goes entirely.
   **One change, not two**: the eager add flips `frontierTails`'
   uuid-first seed resolution (`:3757`) onto the index entry, which
   carries `colEvt` only once stamped, so the add and the stamp are the
   same commit by construction (§ D3, 2026-07-29).
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

- 2026-07-30 tm: eager park-restore add, seat-stamped at the park stage — deferred's last stage-crossing use goes (§ D3)
- 2026-07-29 tm: the clipped restore case — ceiling raw 619 vs bound raw 379; closes phase 1 (§ The suite does not discriminate any of this)
- 2026-07-29 tm: park-restore fixture with teeth — E4b goes red; phases 2+4 collapse to one change (§ The suite does not discriminate any of this)
- 2026-07-29 design: spike results — cadence measured rather than read;

## Now

(empty — phase 2 item 1 landed; the queued item is retiring mmBatch's lazy-add door, now callerless. Run /plan-next to promote it.)

## Queued (current phase; one-liners)

1. Retire `mmBatch`'s lazy-add door, which item 1 leaves with no
   callers anywhere: the `lazyAdds` accumulator (`:1940`), the
   `addLazy` entry and its comment (`:1945`), the `#lazyAdds` term in
   the empty-batch guard (`:1948`), and the resolve loop inside
   `mm:modify` (`:1958`). Purely subtractive with no behaviour change,
   so the standing suite is its own check. Separate from item 1 so the
   deletion of a batch door is reviewable apart from the cadence change
   that orphaned it.
