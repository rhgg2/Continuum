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
   rect-conflict gate on the tv verb.  ← landed 2026-08-03 (4 commits)

## Landed  (newest first; prune below ~4)

- 2026-08-03 spec: the minted group is ordinary -- instance, mirror, delete, tile (§ Freeze to group)
- 2026-08-03 tv: freeze an fx producer to a mirror group (§ Freeze to group)
- 2026-08-02 tm: compute the mint rect and pull the closing pb seat inside it (§ Freeze to group)
- 2026-08-01 tm: add freezeToGroup -- thin the curves, hand back the members (§ Freeze to group)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty — every phase has landed; run /plan-close.)
