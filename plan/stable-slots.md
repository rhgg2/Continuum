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

- 2026-07-26 mm: verbs report key dirt; flushTake splices the wire (Phase 2f) (§ incremental serialise)
- 2026-07-26 mm: midiBlob gains the wire splice helpers (Phase 2e) (§ incremental serialise)
- 2026-07-26 mm: sidecar rows become state the verbs maintain (Phase 2d) (§ incremental serialise)
- 2026-07-26 mm: sidecar texts key on their owner's slot (Phase 2c) (§ incremental serialise)

## Now

(empty — 2f landed, closing the incremental-serialise loop: flushTake now splices the wire it holds instead of rebuilding it. 2g (widen the wire key to lift the 5e4 slot cap) leads Queued; run /plan-next to promote it.)

## Queued (current phase; one-liners)

1. *(in Now)* 2f — the verb sites report per-slot key dirt beside `markChan` and
   `flushTake` splices the held wire instead of rebuilding it.
2. 2g — widen the wire key to `ppq*1e9 + rank*1e8 + slot*2` behind named constants in
   midiBlob, lifting the slot cap from 5e4 to 5e7 and deleting the guard the design doc
   wanted: ppqs reach mm integer-**typed** (`util.round` → `math.floor`,
   `string.unpack('i4')`), so keys are int64 with 4× headroom. Touches midiBlob's key
   sites plus `mm_blob_serialise_spec`'s two helpers; verify nothing (`voicing`'s onsets
   the one unread path) hands mm a float ppq, since that drops the bound back to 2^53.
