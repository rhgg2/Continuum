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

- 2026-07-26 mm: widen the wire key past the reachable slot cap (Phase 2g) (§ incremental serialise)
- 2026-07-26 mm: verbs report key dirt; flushTake splices the wire (Phase 2f) (§ incremental serialise)
- 2026-07-26 mm: midiBlob gains the wire splice helpers (Phase 2e) (§ incremental serialise)
- 2026-07-26 mm: sidecar rows become state the verbs maintain (Phase 2d) (§ incremental serialise)

## Now

(empty — phase 2 is complete. 2g landed; 2h's exit measurement is recorded in design/stable-slots.md § Measured after phase 2: serialise 0.3ms on glasswork and 0.8ms on HAMMERKLAVIER against a ~1ms target, flush 53.7 → 21.2. The programme has met its stated ceiling — run /plan-close to archive it.)

## Queued (current phase; one-liners)

(empty — 2g landed and 2h's measurement is recorded; phase 2 has nothing left
queued.)
