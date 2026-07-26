# stable slots — plan

> source: `design/archive/stable-slots.md` — synthesis compiled from there.
> Programme complete, closed 2026-07-26.

## Phases

1. **Phase 0 — pins**. Landed 2026-07-25.
2. **Phase 1 — stable slots in mm**. Landed 2026-07-25 in three commits: 1a the
   ordered walk, 1b the flip, 1c the chanIdx walk order.
3. **Phase 2 — incremental serialise**. Landed 2026-07-26 across 2a–2g, with
   2h the exit measurement. Persistent sorted key array and packed chunk
   list; per-event key dirt reported at the verb sites that already call
   `markChan`; the key widened so the slot cap stopped being reachable, so
   no fallback guard was owed. Targets `serialise` 16.3ms → ~1ms and
   `sidecars` 2.1ms → ~0 both met: 0.8ms on HAMMERKLAVIER, 0.3ms on
   glasswork, and the sidecars span no longer exists.

## Landed  (newest first; prune below ~4)

- 2026-07-26 mm: widen the wire key past the reachable slot cap (Phase 2g) (§ incremental serialise)
- 2026-07-26 mm: verbs report key dirt; flushTake splices the wire (Phase 2f) (§ incremental serialise)
- 2026-07-26 mm: midiBlob gains the wire splice helpers (Phase 2e) (§ incremental serialise)
- 2026-07-26 mm: sidecar rows become state the verbs maintain (Phase 2d) (§ incremental serialise)

## Now

(empty — programme closed 2026-07-26. The exit measurement is in
`design/archive/stable-slots.md` § Measured after phase 2: serialise 0.3ms on
glasswork and 0.8ms on HAMMERKLAVIER against a ~1ms target, flush 53.7 → 21.2.
The stated ceiling is met; going lower is interval-dirt's job on `reload` and
REAPER's on `setEvts`.)

## Queued (current phase; one-liners)

(empty)
