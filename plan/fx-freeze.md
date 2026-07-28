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

- 2026-07-28 tv: bind freeze -- Ctrl-E and the fx tab's action row (§ Freeze to raw)
- 2026-07-28 tm: freezeRegion -- the raw core, region host (§ Freeze to raw)
- 2026-07-27 tm: restore flushingParked on the error path (§ Implementation notes)
- **F1 — pb/at as first-class gm members** (2026-07-11) — every seam

## Now

(empty — queued item 3 landed early so the core can be driven by hand in REAPER; items 1-2 (note-host arm, tm eligibility gates) still stand in this phase. Run /plan-next to promote the next commit.)

## Queued (current phase; one-liners)

1. Note-host arm — `freezeRegion` handles a self-parked note host (its
   fxParked spec IS the destroyed parked member) and an on-take augment
   host (clear its `fx` chain instead); spec pins a note host freezing
   by the same seam.
2. tm eligibility gates — refuse before any mutation on note-window
   overlap with another live region (merged `parkWindows` union) and on
   same-target continuous overlap (painter-fold seats not separable);
   spec pins each refusal. (Group-only fx-carrying-host-note gate
   deferred to phase 3 with the group verb it gates.)
3. ~~tv freeze-to-raw verb~~ — landed 2026-07-28 ahead of items 1-2, to
   drive the core by hand in REAPER. `freezeFxRegion` on Ctrl-E plus a
   `freeze` button on the fx tab, both through `tv:freezeRegion`
   (`util.atomic`); region hosts only, note hosts and every ungated
   overlap decline silently. **No confirm** — see § Freeze to raw.
   Refusal surfacing is deferred to item 2, which is what creates a
   refusal to surface; the codebase has no toast/alert facility, so
   that is a mechanism decision, not wiring.
