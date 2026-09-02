# trackerManager: the algebra and the engine — plan

> source: `design/tracker-manager-split.md` — synthesis compiled from
> there; don't design here.

## Phases

1. **Phase 1 — the algebra leaves** (§ Phase 1) — landed 2026-08-30, in
   five commits; the model moved to `docs/algebra.md`.
2. **Phase 2 — the dirt spine** (§ Phase 2) — landed 2026-08-31, in one
   commit; the model moved to `docs/trackerManager.md` § Derivation dirt.
3. **Phase 3 — pb at its seam** (§ What the specs hold 4) — landed
   2026-08-31, in three commits: `tm_pb_keep_split_spec`,
   `tm_seat_scope_spec` and `tm_pb_seam_spec`.
4. **Phase 4 — the seams drawn in place** — landed 2026-08-31, in thirteen
   commits; the model moved to `docs/trackerManager.md` § The frame handle.
5. **Phase 5 — one window population** (§ One window population) — landed
   2026-09-01, in three commits; the model is `docs/trackerManager.md`
   § Note host clips and windows.
6. **Phase 6 — the time context** — landed 2026-09-02, in two commits;
   the model moved to `docs/timing.md` § The time context.
7. **Phase 7 — the engine leaves** (§ Phase 3) — landed 2026-09-02, in
   five commits, as `trackerRebuild.lua` and `fxWindows.lua`; the model
   is `docs/trackerManager.md` § The frame handle and § Fx window census.
8. **Phase 8 — the nesting inside the stages** ← in flight — three lifts
   inside `trackerRebuild.lua`. None changes what crosses a boundary or
   what any doc states, so the design doc carries no section for it.

## Landed  (newest first; prune below ~4)

- 2026-09-02 tm: the fx base builders at file scope (plan § Phase 8)
- 2026-09-02 tm: replaceWindows and seatScope at file scope (plan § Phase 8)
- 2026-09-02 tm: the lane-1 union answers through one door (design/decisions.md 2026-09-02)
- 2026-09-02 tm: the engine leaves as trackerRebuild.lua (design/decisions.md 2026-09-02)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty)

