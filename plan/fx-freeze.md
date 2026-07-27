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

- 2026-07-27 tm: restore flushingParked on the error path (§ Implementation notes)
- **F1 — pb/at as first-class gm members** (2026-07-11) — every seam
- **F2a — projext undo** (2026-07-12..14, own record in

## Now

(empty — the flushingParked error-path reset landed, so the suppression window is safe for freezeRegion's four ds writes; run /plan-next to promote the freezeRegion raw core)

## Queued (current phase; one-liners)

1. `tm:freezeRegion(uuid)` raw core, region host — conversion order
   under the suppression, all before one rebuild in one undo block:
   clear `derived` (mm metadata assign; notes keep uuid/lane/detune) →
   drop covered fxParked entries → drop the region → drop its windows
   from `prevWindows` → dirtyChan + flush. `tm_fx_region_spec` pins:
   arp authored + audible, chord gone with *no restore on next rebuild*
   (standing-reconcile regression), seats stand as authored, tails clip
   cross-window, one undo reverts wholly (rides pextStore).
2. Note-host arm — `freezeRegion` handles a self-parked note host (its
   fxParked spec IS the destroyed parked member) and an on-take augment
   host (clear its `fx` chain instead); spec pins a note host freezing
   by the same seam.
3. tm eligibility gates — refuse before any mutation on note-window
   overlap with another live region (merged `parkWindows` union) and on
   same-target continuous overlap (painter-fold seats not separable);
   spec pins each refusal. (Group-only fx-carrying-host-note gate
   deferred to phase 3 with the group verb it gates.)
4. tv freeze-to-raw verb — command wiring + confirm modal for the
   parked-member destruction, `util.atomic` wrapping the post-confirm
   continuation (modal resolves on a later frame), gate refusals
   surfaced to the user; `tv_fx_region_spec` pins verb, confirm, and
   refusal surfacing.
