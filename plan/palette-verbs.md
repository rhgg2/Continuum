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
   its assignment and the name it will get.  ← in flight

The seed and the preview names both live in am, as `am:seedTidy` and
`am:tidyNames`, so that everything but the ImGui stands under test. The
render layer still holds the assignment alone.

## Landed  (newest first; prune below ~4)

- 2026-08-24 arrange: an editable base list in the tidy editor (§ The editor)
- 2026-08-24 arrange: a tidy button on the palette, and its seeded editor (§ The editor)
- 2026-08-24 am: preview the names a tidy will write, keyed by slot index (§ Where the naming lives)
- 2026-08-24 am: seed a tidy from the track's slot names (§ The editor)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty)
