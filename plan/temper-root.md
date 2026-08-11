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
   out to `gridPane`.  landed 2026-08-10, 2 commits
3. **Phase 3 — Authoring the root** (§ The blast radius, § Negative
   octaves) — editor rows for the four fields with the root kept out of
   the library, the root restated as step edits renumber around it, an
   octave column that can type the range a root opens, and the
   `docs/tuning.md` § Coordinate systems rewrite.  ← in flight

## Landed  (newest first; prune below ~4)

- 2026-08-11 tuning: enter a negative octave in the octave column (§ Negative octaves 6–8)
- 2026-08-11 tuning: follow the root when a step edit moves or deletes its step (§ The blast radius 6–8)
- 2026-08-11 tuning: author the temper root, keeping it out of the library (§ What a root is, § The blast radius)
- 2026-08-10 tuning: size the octave field over both ends of the range (§ Negative octaves 4)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. A shift-held digit overwrites one place of the octave field and stays
   on the row, the gesture the sample and delay fields already take, so an
   octave of two digits can be typed. Spec in `vm_temper_entry_spec`.

2. Rewrite `docs/tuning.md` § Coordinate systems and § Addressable range
   so the anchor is the root rather than `cents 0 ≡ MIDI 0`, drop the
   claim that the first step of every temperament is `C`, and list the
   four authored fields in § Temper shape.
