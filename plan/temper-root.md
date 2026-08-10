# The temper's root — plan

> source: `design/temper-root.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — Root arithmetic** (§ Sound and notation, § The blast
   radius 1–4) — the four authored fields with their default,
   `tuning.derive` stamping `rootCents` and `octaveBase`, and the two
   conversions reading them.
2. **Phase 2 — Negative octaves** (§ Negative octaves) — the octave
   label as a magnitude in `colour.tracker.negative`, the field sized
   over both ends of the range, and the tint routed from `stepToParts`
   out to `gridPane`.  ← next
3. **Phase 3 — Authoring the root** (§ The blast radius 5–9) — editor
   rows for the four fields, `rootStep` restated as step edits renumber
   around it, the root surviving a round-trip through the library, and
   the `docs/tuning.md` § Coordinate systems rewrite.

## Landed  (newest first; prune below ~4)

- 2026-08-10 tuning: read the root in the coordinate conversions (§ The blast radius 1–2)
- 2026-08-10 tuning: derive rootCents and octaveBase from the temper root (§ Sound and notation)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty — Phase 1's last item is in flight.)
