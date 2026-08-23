# Palette verbs — plan

> source: `design/palette-verbs.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — Prune** — landed 2026-08-24, 2 commits; the model now
   sits in docs/arrangeManager.md and docs/arrangePage.md.
2. **Phase 2 — The commit** — landed 2026-08-24, 1 commit; the model now
   sits in docs/arrangeManager.md § Tidy.
3. **Phase 3 — The editor** (§ The editor) — the seed (bases from the
   distinct roots, ambiguous bases and unnamed slots pinned) and the modal
   kind that shows it: base list above, one row per MIDI slot below with
   its assignment and the name it will get.  ← next

Phase 3 has to settle where the seed derivation lives. `am:seedTidy` puts
it under test; the design says only that the editor hands over the
assignment, which the render layer can't be tested through.

## Landed  (newest first; prune below ~4)

- 2026-08-24 am: tidy a track's slot names into families (§ Committing an assignment)
- 2026-08-24 arrange: a prune button on the palette, and no per-slot verbs (§ Prune)
- 2026-08-24 am: prune a track's parked slots (§ Prune)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty — the phase's last item is in flight.)
