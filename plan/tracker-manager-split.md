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

- 2026-09-02 tm: the rebuild stages take the time context as a parameter (design/decisions.md 2026-09-02)
- 2026-09-02 tm: the frame projection is a context built once per pass (design/decisions.md 2026-09-02)
- 2026-09-01 tm: one window population per rebuild (design/decisions.md 2026-09-01)
- 2026-09-01 tm: one clip for a lane's authored notes, on-take and parked (design/decisions.md 2026-09-01)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **tm: the dirt seed minters move to dirt.lua.** `parkSeed` and
  `rawSeed` become `dirt.parkSeed` and `dirt.rawSeed`, so the journal
  owns the seed shape its `--shape` annotation already names. `parkSeed`
  takes the seat's raw ppq as an argument, leaving the projection with
  the caller. Callers are `seedParkedEdit`, `flushParked` and four sites
  in `rebuildRegionPark`, plus the cc sites that mint `rawSeed`.

- **tm: pb cents↔raw arithmetic moves to tuning.** `tuning` gains the
  two conversions, each taking the pb limit in cents; its invariant that
  raw 14-bit conversion is tm's alone is revised to match. Each side
  keeps its own `pbRange` cache — tm's `pbLim`, dropped per rebuild.
  Callers are `tm:flush`, the index's `makeEntry` and `refreshEntry`,
  and six engine sites across `rebuildPbs`, `rebuildFx` and
  `rebuildRegionPark`.

- **tm: the pipeline takes its last ambient reads and returns its
  closing state.** `rebuildPipeline` receives `fxNotesByHost` and an
  already globals-expanded `fxRegions` from the rebuild head, so
  `expandGlobals` stays edit-side with `tm:explodeRegion`. The channels
  needing a mute conform come back with the pass's maps, and
  `derivedInputs = derivationInputs()` moves to `tm:rebuild`'s tail.
  After it the region reads nothing at file scope but the eight
  dependencies and the required libraries.

- **tm: the engine's own names gather at the region.** The twenty-odd
  engine-only file-scope names move down into the region so it is one
  contiguous slice: the fx-expansion helper family (`coverInto` through
  `windowSet`), the reconcile skeletons, `coverOnsets`, `ccGridStep`,
  the fx map builders `buildFreezeRects`, `buildFxTargets` and
  `buildFxRealisation`, and the constants `FRONTIER_SEED_CAP` and `EPS`.
  `windowSet`'s one edit-side use is the empty census the accessors
  stand on before the first pass, which the move must place. Pure
  movement otherwise: no signature changes, and the suite is the check.

- **tm: the engine leaves as `trackerRebuild.lua`.** The region becomes
  a module instantiated with `mm`, `cm`, `ds`, `timeContext`, `index`,
  `stager`, `dirt` and `frame`, and `tm:rebuild` calls its pipeline.
  `tm_pb_gating_spec`'s identity assertion on `onTake.pb` and
  `tm_gate_parity_spec`'s `VOLATILE` set are the two specs a faithful
  move disturbs (§ What the specs hold). `docs/trackerManager.md`
  § Rebuild and its subsections name the new file.

## Follow-up (same file, after the move)

Nesting reduction inside two stages. None of it changes what crosses
the boundary; each shortens a function too long to read in one pass.

- tm: the lane-1 union stream as one set of queries, three seek copies to one (rebuildPbs, ~80 lines)
- tm: replaceWindows and seatScope at file scope (rebuildPbs, ~120 lines)
- tm: the fx base builders take their channel and spans (rebuildFx, ~40 lines)

