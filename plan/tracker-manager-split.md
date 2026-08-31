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

- 2026-08-31 tm: pin the seam between seating and absorber synthesis (design/tracker-manager-split.md § What the specs hold 4)
- 2026-08-31 tm: pin the seat scope a dirt seed closes to (design/tracker-manager-split.md § What the specs hold 4)
- 2026-08-31 tm: pin the keep/live split of a clipped pb window (design/tracker-manager-split.md § What the specs hold 4)
- 2026-08-31 dirt: take the derivation journal from trackerManager (design/tracker-manager-split.md § Phase 2)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **The frame as a handle.** `channels` and its seven operations —
   `sortByPPQ`, `rawThenLogical`, `sortNoteColumn`, `insertNoteCell`,
   `shedLane`, `setCell`, `isSorted` — gather into one `frame` table
   declared where `channels` is now. The operations keep their
   signatures, each taking a frame or a piece of one, and the per-pass
   `shedLanes` set travels with them. The handle is the stable name and
   its `channels` field swaps each pass, where `tm:rebuild` mints the
   new map today.

1. **The index as a door table.** The fourteen names RAW INDEX
   forward-declares become fields of one `index` table the block
   returns, each shortened where `index` already carries the prefix.
   `index.byUuid` joins them and `tm:byUuid` delegates, which settles
   § Open 1's first half. Twenty-seven engine call sites and six
   edit-side ones move onto the doors.

1. **The stager as a door table.** The same move for STAGER's ten
   names, whose callers are tm's mutation API and its lifecycle.

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

