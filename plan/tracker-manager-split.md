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
4. **Phase 4 — the seams drawn in place** (§ Phase 3 3–10, 15) — the frame
   as a handle carrying its seven operations, index and stager as door
   tables, the fx maps coming back by return, and `forget()` on the
   take-tier path; all still inside tm.  ← in flight
5. **Phase 5 — the engine leaves** (§ Phase 3 1–2, 11–17, § Open) —
   `trackerRebuild.lua` and its eight dependencies, with `tm` named as
   what it actually is.

## Landed  (newest first; prune below ~4)

- 2026-08-31 tm: gather the stager's doors onto one table (design/tracker-manager-split.md § Phase 3 8)
- 2026-08-31 tm: gather the raw index's doors onto one table (design/tracker-manager-split.md § Phase 3 14, § Open 1)
- 2026-08-31 config: teach the maps about door tables (design/tracker-manager-split.md § Phase 3 8)
- 2026-08-31 tm: gather the frame and its operations into one handle (design/tracker-manager-split.md § Phase 3 14)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **The fx maps come back by return.** `buildFreezeMaps`,
   `buildFxTargets` and `buildFxRealisation` return their maps, and
   `rebuildPipeline` hands the set up to `tm:rebuild`, which installs
   it. `fxParkedByProducer` is minted wholesale each pass and joins
   them; `fxNotesByProducer` keeps a clean channel's lists across
   passes, so it is handed in and mutated in place, which the rule
   allows.

1. **`forget()` on the take-tier path.** `parkedClipEnd` and `fxHostWin`
   get one explicit clear, called where a take swap or a wholesale
   re-read enters `tm:rebuild`. Their invalidation today is implicit in
   the wholesale dirt each of them gates on, and a cache outliving a
   take swap is a bug nothing in the code names.

