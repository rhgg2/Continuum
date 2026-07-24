# fx patterns — plan

> source: `design/fx-patterns.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **P1 — gridPane extraction** (§ P1) — grid core + lane strip out of
   trackerRender; bindings shared as `pageBindings.tracker` — landed
2. **P2 — pattern store** (§ Data model) — `fxPatterns` ds key + tm
   `dataChanged` arm — landed (the arm went dead at P3.5; the
   library-shelf item below deletes it)
3. **P3 — patternEditor** (§ The checkout model / § The mini stack) —
   checkout stack + modal, both kinds, live preview — landed
4. **P3.5 — inline bodies** (§ P3.5) — param stores the body, commit
   via `setFxField`; shared library re-scoped to a copy shelf — landed
5. **P4 — polish** (§ P4) — queue below ← in flight

## Landed (newest first; prune below ~4)

- 2026-07-24 plan extracted from the design doc; P4 decisions taken
  (copy shelf, fenced mini undo, per-kind lanes, rpb in body; isolated
  preview dropped)
- 2026-07-11 pe: mini toolbar — RPB ticker, commit/cancel, focus fix
- 2026-07-10 pe: endL editable in grid, exact modal sizing, rpb resets to 4
- 2026-07-10 curve: seed pe curves linear, grab edge anchors, hit step risers

## Now

(empty — run /plan-next to promote the first P4 item.)

## Queued (current phase; one-liners)

- library shelf: Save/Load (+ rename/delete) in the pe toolbar,
  kind-filtered picker, overwrite confirm; writes `fxPatterns` via the
  main ds; delete the dead tm arm + `derivationInputs` entry
- mini undo: register fenced undo/redo on the mini cmgr; poll the mini
  ps while the modal is open
- polyphony infra: `lanes='mono'|'poly'` on pattern field descriptors;
  poly readback keeps authored lanes, binds lane add/remove; shipped
  kinds all stay mono
- rpb in body: persist rowPerBeat through the whitelist; open seeds the
  toolbar ticker from it
