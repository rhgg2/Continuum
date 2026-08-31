# trackerManager: the algebra and the engine — plan

> source: `design/tracker-manager-split.md` — synthesis compiled from
> there; don't design here.

## Phases

1. **Phase 1 — the algebra leaves** (§ Phase 1) — landed 2026-08-30, in
   five commits; the model moved to `docs/algebra.md`.
2. **Phase 2 — the dirt spine** (§ Phase 2) — landed 2026-08-31, in one
   commit; the model moved to `docs/trackerManager.md` § Derivation dirt.
3. **Phase 3 — pb at its seam** (§ What the specs hold 4) — coverage of
   `rebuildPbs`'s keep/live split, `pbScope` gating, and the seating ↔
   synthesis seam, before anything moves.  ← in flight
4. **Phase 4 — the seams drawn in place** (§ Phase 3 3–10) — the frame as
   a handle carrying its seven operations, index and stager as door
   tables, the fx maps returned rather than assigned, and `forget()` on
   the take-tier path; all still inside tm.
5. **Phase 5 — the engine leaves** (§ Phase 3 1–2, 11–17, § Open) —
   `trackerRebuild.lua` and its eight dependencies, with `tm` named as
   what it actually is.

## Landed  (newest first; prune below ~4)

- 2026-08-31 tm: pin the seam between seating and absorber synthesis (design/tracker-manager-split.md § What the specs hold 4)
- 2026-08-31 tm: pin the seat scope a dirt seed closes to (design/tracker-manager-split.md § What the specs hold 4)
- 2026-08-31 tm: pin the keep/live split of a clipped pb window (design/tracker-manager-split.md § What the specs hold 4)
- 2026-08-31 dirt: take the derivation journal from trackerManager (design/tracker-manager-split.md § Phase 2)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty)

