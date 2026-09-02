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
7. **Phase 7 — the engine leaves** (§ Phase 3) ← in flight — the shared
   names find their homes, the engine's own gather at the region, and
   then `trackerRebuild.lua` takes its eight dependencies.

## Landed  (newest first; prune below ~4)

- 2026-09-02 tm: the engine leaves as trackerRebuild.lua (design/decisions.md 2026-09-02)
- 2026-09-02 tm: the engine's own names gather at the region (design/decisions.md 2026-09-02)
- 2026-09-02 tm: the rebuild pipeline takes its inputs and returns its state (design/decisions.md 2026-09-02)
- 2026-09-02 tm: pb cents↔raw arithmetic moves to tuning (design/decisions.md 2026-09-02)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

## Follow-up (same file, after the move)

Nesting reduction inside two stages. None of it changes what crosses
the boundary; each shortens a function too long to read in one pass.

- tm: the lane-1 union stream as one set of queries, three seek copies to one (rebuildPbs, ~80 lines)
- tm: replaceWindows and seatScope at file scope (rebuildPbs, ~120 lines)
- tm: the fx base builders take their channel and spans (rebuildFx, ~40 lines)

