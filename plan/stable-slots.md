# stable slots — plan

> source: `design/stable-slots.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 0 — pins**. Landed 2026-07-25.
2. **Phase 1 — stable slots in mm** ← in flight, three commits: 1a the ordered
   walk, 1b the flip, 1c the chanIdx walk order.
3. **Phase 2 — incremental serialise.** Persistent sorted key array and packed
   chunk list; per-event key dirt reported at the three verb sites that
   already call `markChan`; a slot-cap guard falling back to full
   regeneration. Targets: `serialise` 16.3ms → ~1ms, `sidecars` 2.1ms → ~0,
   and the `seenOnset` scan (0.75ms) confined to the full path.

## Landed  (newest first; prune below ~4)

- 2026-07-25 mm: loc becomes a stable slot; verbs splice the order arrays (Phase 1b)
- 2026-07-25 mm: ppq-ordered reads go through an order injection (Phase 1a)
- 2026-07-25 mm: pin the equal-ppq add rule and flush determinism (Phase 0)

## Now

(empty — Phase 1c is next in Queued — run /plan-next to promote it.)

## Queued (current phase; one-liners)

- **Phase 1c — chanIdx walk order.** 1b leaves `rawInChan` filtering
  the global order array (option 2): correct, but O(total) per
  dirty-channel walk. Measure per-bucket order arrays maintained by
  the verbs (option 1) against it on HAMMERKLAVIER, and land option 1
  only if the measurement earns it; `mm_chan_index_spec` is the pin
  either way.
