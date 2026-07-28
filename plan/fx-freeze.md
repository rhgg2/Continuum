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

- 2026-07-28 tm: freezeRegion's note-host arm -- parked and on-take (§ Freeze to raw)
- 2026-07-28 tv: bind freeze -- Ctrl-E and the fx tab's action row (§ Freeze to raw)
- 2026-07-28 tm: freezeRegion -- the raw core, region host (§ Freeze to raw)
- 2026-07-27 tm: restore flushingParked on the error path (§ Implementation notes)

## Now

(empty — the note-host arm landed and the tv/render gates are open, so a note host freezes by hand; run /plan-next to promote the tm eligibility gates)

## Queued (current phase; one-liners)

1. tm eligibility gates — refuse before any mutation on note-window
   overlap with another live region (merged `parkWindows` union) and on
   same-target continuous overlap (painter-fold seats not separable);
   spec pins each refusal. (Group-only fx-carrying-host-note gate
   deferred to phase 3 with the group verb it gates.)
2. ~~tv freeze-to-raw verb~~ — landed 2026-07-28 ahead of items 1-2, to
   drive the core by hand in REAPER. `freezeFxRegion` on Ctrl-E plus a
   `freeze` button on the fx tab, both through `tv:freezeRegion`
   (`util.atomic`); region hosts only, note hosts and every ungated
   overlap decline silently. **No confirm** — see § Freeze to raw.
   Refusal surfacing is deferred to item 2, which is what creates a
   refusal to surface; the codebase has no toast/alert facility, so
   that is a mechanism decision, not wiring.
