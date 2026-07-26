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

- 2026-07-26 mm: sidecar texts key on their owner's slot (Phase 2c) (§ incremental serialise)
- 2026-07-26 mm: serialise splits into buildWire + render (Phase 2b) (§ incremental serialise)
- 2026-07-26 mm: the wire key becomes the slot (Phase 2a) (§ incremental serialise)
- 2026-07-25 mm: chanIdx becomes one order array per channel (Phase 1c) (§ chanIdx)

## Now

(empty — 2c landed: rank 3 split into 3/4/5 with passthrough at 6, and a sidecar's key is now a pure function of its owner's slot and ppq. Next up is 2d, the verb-reported key dirt; run /plan-next to promote it.)

## Queued (current phase; one-liners)

1. *(in Now)* 2c — sidecar texts key on their owner's slot; rank 3 splits into
   3/4/5 with passthrough at 6; `buildWire` takes grouped texts.
2. 2d — the three verb sites (`mm:add`, `mm:assign`, `mm:delete`) report key
   dirt beside `markChan`, for notes, ccs **and** their sidecar texts under one
   discipline; splices maintain the key array and re-pack only the touched
   chunk and its successor; slot-cap guard falls back to full regen. The texts
   groups become mm state the verbs maintain, so `sidecars` 2.1ms → ~0 lands
   here too. Blob-equality pin: incremental vs full regen after gesture storms
   on both rebuild fixtures.
