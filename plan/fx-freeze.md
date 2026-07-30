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

## Landed  (newest first; prune below ~4)

- 2026-07-31 gen: add thinCurve, a bounded Douglas-Peucker over linear runs (§ Freeze to group)
- 2026-07-30 tm: freeze eligibility gates, computed over the producer census (§ Eligibility gates)
- 2026-07-30 tm: identity-stamp park windows; freeze resync drops by id (§ Eligibility gates)
- 2026-07-30 tm: lift the producer census out of assembleParkWindows (§ Eligibility gates)

## Now

(empty — phase 2 is landed; run `/plan-phase` to split phase 3 into commit-sized items.)

## Queued (current phase; one-liners)

(empty — refilled by `/plan-phase` when phase 3 opens.)
