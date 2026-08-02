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
3. **Phase 3 — freeze to group** (§ Freeze to group) — thin the
   curves subtractively inside the conversion's own flush, mint a stock
   gm group via `markGroup` on the resulting column events, gm
   rect-conflict gate on the tv verb.  ← in flight

## Landed  (newest first; prune below ~4)

- 2026-08-02 tm: compute the mint rect and pull the closing pb seat inside it (§ Freeze to group)
- 2026-08-01 tm: add freezeToGroup -- thin the curves, hand back the members (§ Freeze to group)
- 2026-07-31 tm: store freeze eligibility per rebuild; views decline before undo (§ Eligibility gates)
- 2026-07-31 gen: add thinCurve, a bounded Douglas-Peucker over linear runs (§ Freeze to group)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. tv: the freeze-to-group verb — a second command and fx-tab button
   (Ctrl-Shift-E, mirroring Ctrl-Shift-D's duplicate-to-group; no
   modal), gating on gm's `regionConflict` against the mint rect
   before any mutation, then conversion, `gm:markGroup` over the
   column-event members `tm:freezeToGroup` returns, and the closing
   flush inside the undo block; the eligibility predicate gains the
   rect-conflict input. Spec: group minted with note and thinned-curve
   members, each refusal declines before any mutation, one rebuild for
   the conversion and one for the mint.
2. spec: the minted group is ordinary — instance 2 replays both note
   and curve members, a mirror edit propagates, deleting the group
   works, and tiling a copy directly below leaves the copy above with
   every member; pins "no frozen-ness survives the mint".
