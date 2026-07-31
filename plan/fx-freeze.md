# fx freeze — plan

> source: `design/fx-freeze.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — freeze to raw** (§ Freeze to raw) — `tm:freezeRegion`
   as the producer-shaped primitive: clear `derived`, drop the covered
   fxParked entries, drop the region and its `prevWindows`, one flush;
   plus the tm-side eligibility gates.  ← landed 2026-07-30 (8 commits)
2. **Phase 2 — the curve thinner** (§ Freeze to group) — pure
   tolerance-bounded Douglas-Peucker over the linear runs of the
   standing seats, keeping step and curved points verbatim; tolerance
   in the dest's own unit.  ← landed 2026-07-31 (1 commit)
3. **Phase 3 — freeze to group** (§ Freeze to group) — re-seat the
   curves sparse, mint a stock gm group via `markGroup` on um-live staged
   events inside the same flush, gm rect-conflict gate on the tv verb.
   ← in flight

## Landed  (newest first; prune below ~4)

- 2026-07-31 tm: store freeze eligibility per rebuild; views decline before undo (§ Eligibility gates)
- 2026-07-31 gen: add thinCurve, a bounded Douglas-Peucker over linear runs (§ Freeze to group)
- 2026-07-30 tm: freeze eligibility gates, computed over the producer census (§ Eligibility gates)
- 2026-07-30 tm: identity-stamp park windows; freeze resync drops by id (§ Eligibility gates)

## Now

(empty — phase 3's queue holds the group conversion next; run /plan-next to promote it)

## Queued (current phase; one-liners)

1. tm: the group-shaped conversion — a group arm on the freeze
   primitive that runs the raw conversion, deletes the dense
   continuous seats, and stages the thinned breakpoints
   (`generators.thinCurve`, tolerance from a new cm entry in the
   dest's own unit) as authored events with fresh uuids and cents
   sidecars, leaving everything staged so the caller can mint the
   group before the single closing flush. Spec: seats re-seat sparse,
   a post-freeze take round-trip keeps uuid and sidecar, and nothing
   flushes until the caller says so.
2. tm: the mint rect — compute the output footprint (note lanes used
   plus curve streams, crossed with the region window; instance 1
   anchored at the region origin) once, pre-freeze, exposed so the tv
   gate and the mint reuse the same rect. Spec: the footprint of a
   mixed note-and-curve output.
3. tv: the freeze-to-group verb — a second command and fx-tab button
   (Ctrl-Shift-E, mirroring Ctrl-Shift-D's duplicate-to-group; no
   modal), gating on gm's `regionConflict` against the mint rect
   before any mutation, then conversion, `gm:markGroup` over the
   um-live staged events, and one flush inside the undo block; the
   eligibility predicate gains the rect-conflict input. Spec: group
   minted with note and thinned-curve members, each refusal declines
   before any mutation, one flush and one rebuild.
4. spec: the minted group is ordinary — instance 2 replays both note
   and curve members, a mirror edit propagates, and deleting the
   group works; pins "no frozen-ness survives the mint".
