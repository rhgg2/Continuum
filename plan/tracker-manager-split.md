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
6. **Phase 6 — the time context** (§ The time context) — the frame
   projection becomes a value built once per pass, and the stages take
   it as a parameter.
7. **Phase 7 — the engine leaves** (§ Phase 3) — the engine's own
   names regrouped in place and the dirt gates onto one door, then
   `trackerRebuild.lua` and its eight dependencies.

## Landed  (newest first; prune below ~4)

- 2026-09-02 tm: the frame projection is a context built once per pass (design/decisions.md 2026-09-02)
- 2026-09-01 tm: one window population per rebuild (design/decisions.md 2026-09-01)
- 2026-09-01 tm: one clip for a lane's authored notes, on-take and parked (design/decisions.md 2026-09-01)
- 2026-09-01 tm: the park scans ask the window set (design/tracker-manager-split.md § One window population)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- tm: the rebuild stages take the time context as a parameter

## Follow-up (same file, after the move)

Nesting reduction inside two stages. None of it changes what crosses
the boundary; each shortens a function too long to read in one pass.

- tm: the lane-1 union stream as one set of queries, three seek copies to one (rebuildPbs, ~80 lines)
- tm: replaceWindows and seatScope at file scope (rebuildPbs, ~120 lines)
- tm: the fx base builders take their channel and spans (rebuildFx, ~40 lines)

