# fx patterns — plan

> source: `design/fx-patterns.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **P1 — gridPane extraction** (§ P1) — grid core + lane strip out of
   trackerRender; bindings shared as `pageBindings.tracker` — landed
2. **P2 — pattern store** (§ Data model) — `fxPatterns` ds key + tm
   `dataChanged` arm — landed (the arm went dead at P3.5; the Now
   brief deletes it)
3. **P3 — patternEditor** (§ The checkout model / § The mini stack) —
   checkout stack + modal, both kinds, live preview — landed
4. **P3.5 — inline bodies** (§ P3.5) — param stores the body, commit
   via `setFxField`; shared library re-scoped to a copy shelf — landed
5. **P4 — polish** (§ P4) — queue below ← in flight

## Landed (newest first; prune below ~4)

- 2026-07-24 pe: Save becomes a picker; drawPicker gains onCreate (§ P4)
- 2026-07-24 pe: library copy shelf — Save/Load in the toolbar (§ P4)
- 2026-07-24 plan extracted from the design doc; P4 decisions taken
- 2026-07-11 pe: mini toolbar — RPB ticker, commit/cancel, focus fix

## Now

(empty — Save-as-picker landed; run /plan-next to promote the next P4 item)

## Queued (current phase; one-liners)

- shelf management: rename + delete rows inside the Load picker
- mini undo: register fenced undo/redo on the mini cmgr; poll the mini
  ps while the modal is open
- polyphony infra: `lanes='mono'|'poly'` on pattern field descriptors;
  poly readback keeps authored lanes, binds lane add/remove; shipped
  kinds all stay mono
- rpb in body: persist rowPerBeat through the whitelist; open seeds the
  toolbar ticker from it
