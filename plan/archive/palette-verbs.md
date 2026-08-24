# Palette verbs — plan

> source: `docs/arrangeManager.md`, `docs/arrangePage.md` — the model
> the design doc carried now lives there. Programme complete, closed
> 2026-08-24.

## Phases

1. **Phase 1 — Prune** — landed 2026-08-24, 2 commits; the model now
   sits in docs/arrangeManager.md and docs/arrangePage.md.
2. **Phase 2 — The commit** — landed 2026-08-24, 1 commit; the model now
   sits in docs/arrangeManager.md § Tidy.
3. **Phase 3 — The editor** — landed 2026-08-24, 7 commits; the model
   now sits in docs/arrangeManager.md § Seeding a tidy and
   docs/arrangePage.md § The tidy editor.

The seed and the preview names both live in am, as `am:seedTidy` and
`am:tidyNames`, so that everything but the ImGui stands under test. The
render layer still holds the assignment alone.

## Landed  (newest first; prune below ~4)

- 2026-08-24 ui: a name field read live, so its Add/Create button sees it
- 2026-08-24 arrange: an editable base list in the tidy editor
- 2026-08-24 arrange: a tidy button on the palette, and its seeded editor
- 2026-08-24 am: preview the names a tidy will write, keyed by slot index
- 2026-08-24 am: seed a tidy from the track's slot names

