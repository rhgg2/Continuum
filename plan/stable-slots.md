# stable slots — plan

> source: `design/stable-slots.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 0 — pins**. Landed 2026-07-25.
2. **Phase 1 — stable slots in mm**. Landed 2026-07-25 in three commits: 1a the
   ordered walk, 1b the flip, 1c the chanIdx walk order.
3. **Phase 2 — incremental serialise.**  ← in flight. Persistent sorted key array and packed
   chunk list; per-event key dirt reported at the three verb sites that
   already call `markChan`; a slot-cap guard falling back to full
   regeneration. Targets: `serialise` 16.3ms → ~1ms, `sidecars` 2.1ms → ~0,
   and the `seenOnset` scan (0.75ms) confined to the full path.

## Landed  (newest first; prune below ~4)

- 2026-07-26 mm: the wire key becomes the slot (Phase 2a) (§ incremental serialise)
- 2026-07-25 mm: chanIdx becomes one order array per channel (Phase 1c) (§ chanIdx)
- 2026-07-25 mm: loc becomes a stable slot; verbs splice the order arrays (Phase 1b)
- 2026-07-25 mm: ppq-ordered reads go through an order injection (Phase 1a)

## Now

(empty — 2a landed: serialise keys on the slot and mm hands it the live sparse tables. Next is 2b, the persistent wire state object; run /plan-next to promote it.)

## Queued (current phase; one-liners)

1. *(in Now)* 2a — the wire key becomes the slot; `denseByOrder` goes.
2. 2b — mm holds a `wire` state object (keys + packed chunks) across
   flushes; midiBlob gains build/render over it. Pure restructure, rebuilt
   whole each flush, blob byte-identical — the plumbing 2c splices.
3. 2c — the three verb sites (`mm:add`, `mm:assign`, `mm:delete`) report key
   dirt beside `markChan`; splices maintain the key array and re-pack only
   the touched chunk and its successor; slot-cap guard falls back to full
   regen. Blob-equality pin: incremental vs full regen after gesture storms
   on both rebuild fixtures.
4. 2d — sidecar texts key on their owner's slot, so the texts array stops
   being rebuilt every flush (`sidecars` 2.1ms → ~0).
