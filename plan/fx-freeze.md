# fx freeze — plan

> source: `design/fx-freeze.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — freeze to raw** (§ Freeze to raw) — `tm:freezeRegion`
   as the producer-shaped primitive: clear `derived`, drop the covered
   fxParked entries, drop the region and its `prevWindows`, one flush;
   plus the tm-side eligibility gates.  ← in flight
2. **Phase 2 — the curve thinner** (§ Freeze to group) — pure
   tolerance-bounded Douglas-Peucker over the standing densified seats,
   emitting linear breakpoints; cents for pb, steps for cc.
3. **Phase 3 — freeze to group** (§ Freeze to group) — re-seat the
   curves sparse, mint a stock gm group via `markGroup` on um-live staged
   events inside the same flush, gm rect-conflict gate on the tv verb.

## Landed  (newest first; prune below ~4)

- 2026-07-30 tm: identity-stamp park windows; freeze resync drops by id (§ Eligibility gates)
- 2026-07-30 tm: lift the producer census out of assembleParkWindows (§ Eligibility gates)
- 2026-07-29 tm: declare parks to computeFxWindows; chain runs once (§ Eligibility gates)
- 2026-07-28 tm: one producer, one census entry -- dedupe and one-for-one (§ Eligibility gates)

## Now

(empty — identity stamp landed; run /plan-next to promote the eligibility-gates item)

## Superseded

The compiled gates brief of 2026-07-28 was refuted by adversarial
review before implementation; its two fatal findings are recorded in
the design doc (`§ Eligibility gates`) and its sound parts return in
queued item 2. The brief text itself is dropped from this file — it
contradicted this note by still being here.

## Queued (current phase; one-liners)

1. tm eligibility gates, against the census — same-target overlap by
   **owner identity** (not window value, so an identical-window
   neighbour is visible), the covered-fx-host gate, and the inverse
   note-host-span gate; pb-inclusive boundary. Specs pin each refusal
   and pin that a disjoint neighbour still freezes. Supersedes the
   refuted brief. The census lands above `freezeRegion` (the lift's
   placement decision), so only `computeFxWindows` needs a forward
   declaration in the list at `:792` if the gates call it directly.
