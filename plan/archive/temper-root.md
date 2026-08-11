# The temper's root — plan

> source: `design/archive/temper-root.md` (archived; programme complete)
> — synthesis compiled from there; don't design here.

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
   `docs/tuning.md` § Coordinate systems rewrite.  landed 2026-08-11,
   5 commits

## Landed  (newest first; prune below ~4)

- 2026-08-11 docs: tuning gets root notes section (§ The blast radius 11)
- 2026-08-11 tuning: walk the octave field's places with a shift-held digit (§ Negative octaves 9–11)
- 2026-08-11 tuning: enter a negative octave in the octave column (§ Negative octaves 6–8)
- 2026-08-11 tuning: follow the root when a step edit moves or deletes its step (§ The blast radius 6–8)
- 2026-08-11 tuning: author the temper root, keeping it out of the library (§ What a root is, § The blast radius)

## Now

(empty — programme closed 2026-08-11. The four authored fields, the two
derived stamps and the negative-octave field all landed; the open items went
to `design/pipe-dreams.md` (hertz), `design/adaptive-tuning.md` § Open (the
key) and `docs/oddities.md` § Tuning (tidy's whole comparison).)

## Queued (current phase; one-liners)

(empty)
