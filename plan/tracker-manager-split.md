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

- 2026-08-31 dirt: take the derivation journal from trackerManager (design/tracker-manager-split.md § Phase 2)
- 2026-08-30 curves: take the fold of parallel chains from trackerManager (design/tracker-manager-split.md § Phase 1 2, 5)
- 2026-08-30 curves: take the breakpoint curve algebra from trackerManager and mm (design/tracker-manager-split.md § Phase 1 1–3)
- 2026-08-30 spans: take the half-open span algebra from trackerManager (design/tracker-manager-split.md § Phase 1 1–2)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **The keep/live split of a clipped pb window** — a new spec on an fx
   producer whose pb chain `pbScope` clips: the live sub-span refolds
   from the chain curve, the kept sub-span's seats stand with no mm
   write, and a shared edge is live at its opening tick and kept
   everywhere else. Includes the fence — a kept-boundary seat inside a
   live seat span carries from the prior pb column instead of projecting
   fresh. Evidence: perturbations of `inKeptRange`, its opening-edge arm
   and `fencedPb` all killed.

1. **Seat scope: what a dirt seed closes to** — a new spec on
   `seatScope`. A lane-1 seed closes to a span reaching one tick back
   and forward to the next lane-1 onset, authored or derived; a pb seed
   closes to the gap between the neighbouring authored pbs; an
   unrecognised seed kind, wholesale dirt, and fresh derived lane-1
   output each ungate the channel. The out-of-scope remainder carries
   verbatim, its values untouched by a `centsToRaw` round trip, with
   uuid and realised refreshed from the index.

1. **The seating ↔ synthesis seam** — a new spec separating which seats
   a detune arrangement calls for from how absorbers realise them. An
   absorber standing at a seat is adopted with its uuid, a spare moves to
   an unfilled seat, leftovers are deleted, and each seat lands as raw =
   `centsToRaw(cents + detune)`. A seat inside a replace window persists
   native MIDI only; one outside every window carries the cents and ppqL
   sidecar.

