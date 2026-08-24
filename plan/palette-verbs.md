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

- 2026-08-24 am: tidy a track's slot names into families (§ Committing an assignment)
- 2026-08-24 arrange: a prune button on the palette, and no per-slot verbs (§ Prune)
- 2026-08-24 am: prune a track's parked slots (§ Prune)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. `am:seedTidy(trackIdx)` returns the base list and the seed assignment:
   bases are the distinct `util.variantRoot`s of the track's MIDI slot
   names, sorted; each slot is assigned to the base matching its root; an
   unnamed slot is omitted, and so is every slot carrying an ambiguous
   base — one two or more slots hold plain. Audio slots take no part.
   Cases in `am_spec`.

1. `tidyNames` becomes `am:tidyNames(trackIdx, assignment)`, keyed by slot
   index and covering every MIDI slot, so the editor can show the name a
   slot will get. `am:tidySlots` consumes it, translating to slot id and
   dropping the names that are unchanged. A case pins the preview against
   what the write leaves behind.

1. A `tidy` button on the palette beside `prune`, opening a `tidyTrack`
   modal kind: the seeded base list above, one row per MIDI slot below
   with its key, current name, a base combo, and the name from
   `am:tidyNames`. Commit calls `av:tidySlots` inside one undo block. The
   base list is fixed at this stage.

1. The base list becomes editable: entries can be added, edited and
   deleted, and deleting one drops its members from the assignment, which
   pins them. The rows re-preview as the list changes.
