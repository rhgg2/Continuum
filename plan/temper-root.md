# The temper's root — plan

> source: `design/temper-root.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — Root arithmetic** (§ Sound and notation, § The blast
   radius 1–3) — the four authored fields with their default,
   `tuning.derive` stamping `rootCents` and `octaveBase`, and the two
   conversions reading them.  ← in flight
2. **Phase 2 — Negative octaves** (§ Negative octaves) — the octave
   label as a magnitude in `colour.tracker.negative`, the field sized
   over both ends of the range, and the tint routed from `stepToParts`
   out to `gridPane`.
3. **Phase 3 — Authoring the root** (§ The blast radius 4–8) — editor
   rows for the four fields, `rootStep` restated as step edits renumber
   around it, the root surviving a round-trip through the library, and
   the `docs/tuning.md` § Coordinate systems rewrite.

## Landed  (newest first; prune below ~4)

- 2026-08-10 tuning: derive rootCents and octaveBase from the temper root (§ Sound and notation)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. Read the pair in `tuning.midiToStep` and `tuning.stepToMidi`.
   `midiToStep` subtracts `rootCents` from the sounding cents before
   reducing into the period, and returns `octave + octaveBase` where it
   returned `octave − 1`. `stepToMidi` inverts both, so its cents
   become `(octave − octaveBase) · period + steps[step] + rootCents`.
   The MIDI-relative-octave invariant at `tuning.lua:8` is restated in
   terms of the root. Spec: the presets round-trip unchanged, pinning
   that each line reduces at the default root to the arithmetic it
   replaced; under `(0, −31.77) = (1, −1)` every pitch flattens by a
   third of a semitone and no name moves; under `(0, 0) = (1, 3)` no
   pitch moves and every octave reads four higher. Every temper the
   conversions see is derived, in production and in the fixtures, with
   one exception to state rather than guard: a project saved by an
   earlier build carries tempers stamped without the pair, and reading
   them goes nil. Pre-beta, so the break is accepted.
