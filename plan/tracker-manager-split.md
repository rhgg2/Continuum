# trackerManager: the algebra and the engine — plan

> source: `design/tracker-manager-split.md` — synthesis compiled from
> there; don't design here.

## Phases

1. **Phase 1 — the algebra leaves** (§ Phase 1) — landed 2026-08-30, in
   five commits; the model moved to `docs/algebra.md`.
2. **Phase 2 — the dirt spine** (§ Phase 2) — `dirt.lua` with one join
   verb, collapsing the three hand-written joins and fixing the two that
   are wrong.  ← in flight
3. **Phase 3 — pb at its seam** (§ What the specs hold 4) — coverage of
   `rebuildPbs`'s keep/live split, `pbScope` gating, and the seating ↔
   synthesis seam, before anything moves.
4. **Phase 4 — the seams drawn in place** (§ Phase 3 3–10) — the frame as
   a handle carrying its seven operations, index and stager as door
   tables, the fx maps returned rather than assigned, and `forget()` on
   the take-tier path; all still inside tm.
5. **Phase 5 — the engine leaves** (§ Phase 3 1–2, 11–17, § Open) —
   `trackerRebuild.lua` and its eight dependencies, with `tm` named as
   what it actually is.

## Landed  (newest first; prune below ~4)

- 2026-08-30 curves: take the fold of parallel chains from trackerManager (design/tracker-manager-split.md § Phase 1 2, 5)
- 2026-08-30 curves: take the breakpoint curve algebra from trackerManager and mm (design/tracker-manager-split.md § Phase 1 1–3)
- 2026-08-30 spans: take the half-open span algebra from trackerManager (design/tracker-manager-split.md § Phase 1 1–2)
- 2026-08-30 util: take the two ppq index seeks from trackerManager (design/tracker-manager-split.md § Phase 1 4)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **The join verb.** One write verb over the dirt lattice,
   `join(chan, dirt)`, taking `true`, a seed or a seed list, with the
   wholesale cap enforced in one place. It subsumes `dirtyChan` and
   `seedDirty`, and replaces the two hand-written joins that are wrong:
   the tail walk's emission carries a seed list past the cap forever,
   and `absorbReloadDirt`'s fold assigns its deduped list over standing
   seed dirt. Red-first on both, the cap case in `tm_tail_gating_spec`.

1. **`dirt.lua`.** The journal leaves trackerManager: `dirtyChans`,
   `staleSwing`, the join, the per-channel read the stage gates branch
   on, the mid-pipeline `staleSwing` clear, and `wipe` returning the
   channels it consumed for the mute-conform sweep. The module requires
   nothing. The seed minters, `seedCovers`/`seedRowsFor` and
   `clearSwing` stay with the structures they read, and gate parity pins
   the move green.
