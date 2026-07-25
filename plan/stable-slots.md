# stable slots — plan

> source: `design/stable-slots.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 0 — pins**. Landed 2026-07-25.
2. **Phase 1 — stable slots in mm**. Landed 2026-07-25 in three commits: 1a the
   ordered walk, 1b the flip, 1c the chanIdx walk order.
3. **Phase 2 — incremental serialise.** Persistent sorted key array and packed
   chunk list; per-event key dirt reported at the three verb sites that
   already call `markChan`; a slot-cap guard falling back to full
   regeneration. Targets: `serialise` 16.3ms → ~1ms, `sidecars` 2.1ms → ~0,
   and the `seenOnset` scan (0.75ms) confined to the full path.

## Landed  (newest first; prune below ~4)

- 2026-07-25 mm: chanIdx becomes one order array per channel (Phase 1c) (§ chanIdx)
- 2026-07-25 mm: loc becomes a stable slot; verbs splice the order arrays (Phase 1b)
- 2026-07-25 mm: ppq-ordered reads go through an order injection (Phase 1a)
- 2026-07-25 mm: pin the equal-ppq add rule and flush determinism (Phase 0)

## Now

(empty — Phase 1 is complete; 1c was its last item. Run /plan-next to open Phase 2, incremental serialise.)

## Queued (current phase; one-liners)

(empty — 1c is Phase 1's last item; the next /plan-next opens Phase 2.)
