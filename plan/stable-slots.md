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

- 2026-07-26 mm: sidecar rows become state the verbs maintain (Phase 2d) (§ incremental serialise)
- 2026-07-26 mm: sidecar texts key on their owner's slot (Phase 2c) (§ incremental serialise)
- 2026-07-26 mm: serialise splits into buildWire + render (Phase 2b) (§ incremental serialise)
- 2026-07-26 mm: the wire key becomes the slot (Phase 2a) (§ incremental serialise)

## Now

(empty — 2d landed: the two sidecar groups are mm state now, seated and dropped at the six sites that maintain the order arrays, and flushTake walks nothing. Its bridge probe on HAMMERKLAVIER was not run, so the ~0 `sidecars` span is argued from the code rather than measured; the span itself was kept, now bracketing a lone table constructor, and is a fair candidate for deletion at 2f. 2e — midiBlob's wire splice helpers — is next in Queued; run /plan-next to promote it.)

## Queued (current phase; one-liners)

1. *(in Now)* 2d — the sidecar groups become persistent slot-keyed mm state,
   seated beside `indexPut`/`indexDrop`; `flushTake` stops walking.
2. 2e — midiBlob gains the wire splice helpers: drop a key, insert a key,
   re-pack the touched chunk and its successor (their `dppq` moved). Pure, and
   pinned key-for-key against a full `buildWire` regen.
3. 2f — the three verb sites (`mm:add`, `mm:assign`, `mm:delete`) report key
   dirt beside `markChan`, for notes, ccs **and** their sidecars under one
   discipline; `flushTake` applies the dirt to the persistent `wire` instead of
   rebuilding it; slot-cap guard falls back to full regen. Blob-equality pin:
   incremental vs full regen after gesture storms on both rebuild fixtures —
   with 2d's caveat, that a cc row never written reloads as a legitimately plain
   cc, so a missed seat reproduces itself and needs a direct row count beside it.
