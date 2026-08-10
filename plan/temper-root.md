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

(nothing yet)

## Now

(empty — run /plan-next to compile the top Queued item into a brief.)

## Queued (current phase; one-liners)

1. Stamp `rootCents` and `octaveBase` in `tuning.derive`. The four
   authored fields — `rootPitch`, `rootDetune`, `rootStep`,
   `rootOctave` — are read where an author has stated them and default
   to `(0, 0) = (1, −1)` where they are absent, so the presets stay as
   they are written and gain no fields. `rootCents` is `rootPitch · 100
   + rootDetune − cents[rootStep]` and `octaveBase` is `rootOctave`
   untransformed. Both are stamped above the existing `octaveWidth` and
   `cellWidth` lines, which phase 2 rewrites in terms of them. The
   `--shape` line and `derive`'s `--contract` grow the two names. Spec:
   a temper authored `(69, −101.27) = (10, 4)` derives `rootCents =
   5898.73` and `octaveBase = 4`; a preset with no root stated derives
   `0` and `−1`.

2. Read the pair in `tuning.midiToStep` and `tuning.stepToMidi`.
   `midiToStep` subtracts `rootCents` from the sounding cents before
   reducing into the period, and returns `octave + octaveBase` where it
   returned `octave − 1`. `stepToMidi` inverts both, so its cents
   become `(octave − octaveBase) · period + steps[step] + rootCents`.
   The MIDI-relative-octave invariant at `tuning.lua:8` is restated in
   terms of the root. Spec: the presets round-trip unchanged, pinning
   that each line reduces at the default root to the arithmetic it
   replaced; under `(0, −31.77) = (1, −1)` every pitch flattens by a
   third of a semitone and no name moves; under `(0, 0) = (1, 3)` no
   pitch moves and every octave reads four higher.
