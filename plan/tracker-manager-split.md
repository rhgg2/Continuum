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

- 2026-09-02 tm: the engine leaves as trackerRebuild.lua (design/decisions.md 2026-09-02)
- 2026-09-02 tm: the engine's own names gather at the region (design/decisions.md 2026-09-02)
- 2026-09-02 tm: the rebuild pipeline takes its inputs and returns its state (design/decisions.md 2026-09-02)
- 2026-09-02 tm: pb cents↔raw arithmetic moves to tuning (design/decisions.md 2026-09-02)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **tm: the lane-1 union as one stream.** `rebuildPbs` asks five
   questions of the union of a channel's authored lane-1 notes (the raw
   index) and the pass's derived lane-1 stream (`liveLane1ByChan`):
   `lane1DetuneAt`, `lane1Between`, `firstLane1`, `anyDetuneJump`, and
   `seatScope`'s `nextLane1After`. Three of them merge the two sources by
   the same nearer-of-two comparison, written out each time. One union
   door built per dirty channel beside `liveLane1ByChan` answers all
   five, and `rebuildPbs` loses ~80 lines. Green-first against
   `tm_seat_scope_spec` and `tm_pb_seam_spec`.

1. **tm: `replaceWindows` and `seatScope` at file scope.** The two are
   ~120 lines of closure inside `rebuildPbs`, called from one per-channel
   loop. They close over `pbChains`, `pbBase`, `pbScope`, `gridStep`,
   `pbLimCents` and the time context; taking those as parameters lifts
   both to file scope. Follows item 1, which changes `seatScope`'s
   lane-1 seek. Green-first against `tm_pb_keep_split_spec` and
   `tm_seat_scope_spec`.

1. **tm: the fx base builders at file scope.** `pbBaseFor` and
   `ccBasesFor` already take their channel and spans, and only the time
   context binds them into `rebuildFx`. Passing it lifts ~40 lines out to
   file scope beside `coverInto`, the scan they both use. Green-first
   against `tm_gate_parity_spec`.

