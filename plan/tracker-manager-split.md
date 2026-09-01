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
5. **Phase 5 — one window population** (§ One window population) — one
   clip rule over the authored onsets of a lane, on-take and parked
   alike; one window pass per rebuild, and `settleWindows` with it the
   park fixpoint go.  ← in flight
6. **Phase 6 — the engine leaves** (§ Phase 3, § Open) —
   `trackerRebuild.lua` and its eight dependencies, with `tm` named as
   what it actually is.

## Landed  (newest first; prune below ~4)

- 2026-09-01 tm: one clip for a lane's authored notes, on-take and parked (design/decisions.md 2026-09-01)
- 2026-09-01 tm: the park scans ask the window set (design/tracker-manager-split.md § One window population)
- 2026-08-31 tm: producer -> host, one word for what runs a chain (design/decisions.md 2026-08-31)
- 2026-08-31 tm: one word for a window, one for a span (design/decisions.md 2026-08-31)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **One window pass per rebuild.** `clipNoteHosts` and `buildFxWindows`
   run once, ahead of the park stage, which takes the set as data and hands
   it on; `rebuildFx` partitions its hosts by the frame's parked list, which
   is what the second pass was recomputing. `settleWindows` goes, and the
   park fixpoint with it (`docs/trackerManager.md` § The placement fixpoint).
   Green-first, pinned by `tm_gate_parity_spec`.

