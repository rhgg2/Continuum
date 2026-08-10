# The temper's root — plan

> source: `design/temper-root.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — Root arithmetic** (§ Sound and notation, § The blast
   radius 1–4) — the four authored fields with their default,
   `tuning.derive` stamping `rootCents` and `octaveBase`, and the two
   conversions reading them.  landed 2026-08-10, 2 commits
2. **Phase 2 — Negative octaves** (§ Negative octaves) — the octave
   label as a magnitude in `colour.tracker.negative`, the field sized
   over both ends of the range, and the tint routed from `stepToParts`
   out to `gridPane`.  ← in flight
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

- Size the octave field over both ends of the range. `octaveFieldWidth`
  (`tuning.lua:34-36`) reads the wider of the bottom magnitude `floor(-rootCents
  / period) + octaveBase` and the top `floor((12700 - rootCents) / period) +
  octaveBase`, in place of the literal `floor(12700 / period) - 1`. The default
  root leaves every preset's width where it is. `tuning.stepToText` goes in the
  same commit: its only callers are ten sites in `tuning_spec`, which asserts
  through `stepToParts` instead.
- Render a negative octave as a tinted magnitude. `octaveLabel` drops the sign,
  `stepToParts` returns the negativity as a third value computed after the
  `octaveStep` bump (`tuning.lua:462-467`), `ctx:noteProjection` passes it out
  (`viewContext.lua:44`), and `renderNote` tints the octave columns through
  `overrides` as the delay lane does (`gridPane.lua:139-143`). The untempered
  fallback label loses its `M` the same way (`gridPane.lua:84`), and
  `docs/tuning.md` § Display 1 is rewritten. `trackerView` needs no edit —
  `tv:noteProjection` already returns every value through.
