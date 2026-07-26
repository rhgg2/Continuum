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

- **F1 — pb/at as first-class gm members** (2026-07-11) — every seam
  rides generically; the only production change was `toGroup` sourcing pb
  intent from `evt.cents` plus `makeEntry` carrying the pb `uuid`. Pinned
  by `gm_pb_member_spec` ×6 and `gm_at_member_spec` ×2.
- **F2a — projext undo** (2026-07-12..14, own record in
  `design/archive/projext-undo.md`) — pextStore mirrors undoable project
  slots to scratch P_EXT, so the `derived` clear rides REAPER undo. This
  was fx-freeze's only gate on "one undo reverts wholly".

## Now

(empty — new plan; run /plan-phase to split phase 1 into Queued.)

## Queued (current phase; one-liners)

(empty)
