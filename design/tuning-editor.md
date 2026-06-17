# Tuning editor — design & state of play

Goal: add a **tuning editor** to Continuum, in the spirit of Scale
Workshop (sevish.com/scaleworkshop). Scope grew into a shared
**project-tier library workbench page** hosting both the tuning (temper)
editor and the existing swing editor.

Status as of commit `f3c817d` ("editor: add project-tier swing/temper
workbench page"): **phase 1 done, committed, suite green (1514/0).**
Phases 2–3 not started.

---

## The existing pitch model (ground truth — already in the codebase)

Read `docs/tuning.md` for the full model. Key facts:

- `tuning.lua` is a **pure** coordinate module. A temperament ("temper"
  in code) is:
  ```
  temper = { name, period=1200, cents={0,...}, stepNames={...}, octaveStep }
  ```
  `cents[]` ascending, one `stepNames[]` per step, `octaveStep` derived.
  Built-in presets: 12/19/31/53-EDO via `edo(n, names)`.
- **Library**: `cfg.tempers` (project tier); the active temper is the
  `temper` slot (take/track/project tiers), referenced by name.
  `findTemper(name, userLib)` resolves userLib then built-in presets.
- Swing is the structural twin: library `cfg.swings`, slots by name,
  seeded from presets, has a picker. Differs only in the content pane.
- **Intent/realisation split**: detune is per-note intent (cents); pb is
  channel-wide realisation. The view never touches pb. This is *below*
  anything the editor does — untouched by all phases.

---

## Decisions locked (with the user)

1. **Naming for arbitrary scales → option B.** Step names become
   *optional*; display falls back to degree/cents when a scale has no
   letter spelling. (Scale Workshop scales are intervals with no note
   names / no "C".) Confined to the display layer.
2. **Scala `.scl` import — early** (phase 2). `.kbm` deferred.
3. **Compilers (JI ratios, `n\edo` steps, MOS/harmonic) — "day two"**
   (phase 3).
4. **One page, switcher letter "E"**, hosting both editors behind a
   toolbar pane-selector (Swing | Temper).
5. **Fast path: yes** — pickers/keys jump to the editor on the entry in
   force; close returns to the previous page.
6. **F10 = global switch to editor page.**
7. **The editor edits project-tier swings and tempers only.** It is a
   context-free library workbench. Per-take / per-channel assignment
   stays on the tracker (the toolbar pickers, which hold take context).

### Refinements made during phase 1 (deviations from the first plan)

- **No generic "shared library shell" yet.** The swing editor already
  carries its own tier-aware library row (Save global, Delete
  proj/global, Take/Chan shortcuts, +New). Genericizing now would be
  speculative (only one real instance). Extract a shared shell in
  phase 2 once the tuning editor's real CRUD needs are visible.
- **Pane selection lives in the toolbar**, not a left rail.

---

## Architecture (phase 1, as built)

The page mirrors the arrangePage pattern (controller / facade /
delegated render), but the heavy rendering lives in the two self-
contained content panes.

| file | role |
|---|---|
| `editorPage.lua` (new) | coord-driven controller. Owns `pane` state + the two panes, publishes the `editor` facade (`edit(lib, name)`), toolbar pane-selector, body dispatch + Esc-to-close, focusState. |
| `temperEditor.lua` (new) | tuning pane. **Phase 1 = read-only**: seeds EDO presets into `cfg.tempers` + sets project temper; shows the active temper's steps (index · name · cents). |
| `swingEditor.lua` (migrated) | from take-scoped tracker overlay → editor pane. `tv` dependency replaced by the **tracker facade**. |

### The facade seam (crux of the migration)

The editor page is **off the tracker stack** and **context-free** (no
bound take ⇒ `cm` has no take/track context — `tp:unbind →
tm:bindTake(nil) → cm:setContext(nil)`).

- Take-context **reads** route through the tracker facade:
  `tracker().timeSig()`, `tracker().cursorAnchor()` (both tolerate
  nil — swing pane defaults 4/4 / no highlight).
- **Writes are project-tier only** (context-free): library writes
  (`setSwingComposite`, `setTemper`) and the project-tier active temper
  (`setProjectTemper` — new `tv` method, project-only sibling of
  `setTemperSlot`).
- **Removed**: `setSwingSlot`/`setTemperSlot` from the editor surface
  (they write take/track tiers → error off-tracker). Swing `+New` no
  longer auto-assigns to the take; it creates the library entry and
  opens it for editing.

Tracker facade (`trackerPage.lua`) now also publishes: `timeSig`,
`cursorAnchor`, `setSwingComposite`, `setTemper`, `setProjectTemper`.

### Coordinator / wiring

- `coordinator.lua`: `E` switcher button; tracks `previous` page;
  `coord:previousPage()` getter.
- `continuum.lua`: registers `editor` page; root commands
  `switchToEditor` (F10), `editTuning`, `editSwing` (Super+E),
  `closeEditor` (→ `coord:setActive(previousPage or 'tracker')`).
- `trackerRender.lua`: removed the swing body-overlay hosting
  (instantiation, render-takeover, `pageSuppressed`, `closeTransients`,
  the toolbar-greying branch). Added `✎` edit buttons to the
  tuning/swing toolbar pickers → `cmgr:invoke('editTuning'|'editSwing')`.
  Command palette entries repointed (`editTuning`/`editSwing`).
- `trackerPage.lua`: dropped `closeTransients` calls.

### Lifecycle / keys

- `editorPage:edit(lib, name)` sets the pane + selection; the command
  then `coord:setActive('editor')` (mirrors `diveToSampler`).
- Esc / Close → `closeEditor` command → previous page. Esc guarded by
  `not IsAnyItemActive` + `not pane:modalActive()`.
- focusState: `pageSuppressed = true` (root globals live, page bindings
  off); `acceptCmds = not suppressKbd and not IsAnyItemActive`.

---

## What is NOT done / known gaps

- **Live UI unverified.** Only specs + `luac -p` checked; no REAPER run.
  Worth a manual pass: E button, F10, ✎ buttons, Esc-return, swing edit
  round-trip, temper preset seeding.
- Temper pane is read-only (no cents authoring yet).
- `docs/editorPage.md` referenced in the header but not written.
- No generic shared library shell (deferred — see above).

---

## Phase 2 — tuning content pane (next)

### Landed (2026-06-17): library seeding & project self-containment

- Built-in catalogues are the cm **defaults** (`swings`; `tempers` is now
  `util.deepClone(tuning.presets)`). `cm:seedGlobalFromDefault(key, exclude)`
  lazily materialises the personal **global** library from the catalogue
  (minus the synthetic floor) the first time the library is read — the editor
  palette (`globalSwings`/`globalTempers`) or a picker (`chrome.libPicker`).
  No startup seed, no flag.
- **Copy-on-assign**: `tv:setSwingSlot`/`setColSwingSlot` localize a picked
  swing into the project tier (`localizeSwing`); `pickTemper` now guards on the
  project tier. Projects are self-contained; realisation never leans on
  global/defaults. See `docs/swingEditor.md` § Library tiers.
- The two picker builders collapsed into `chrome.libPicker` (trackerRender's
  local `libPickerItems` is gone). Temper's transitional "Seed preset:" buttons
  removed; `setTemper`/`setProjectTemper` dropped from the tracker facade — the
  editor edits the library, assignment stays on the tracker.

1. **Cents/period/name editor** in `temperEditor.lua`: add/remove/edit
   step cents, period, name; optional per-step names.
2. **Option-B display change** in `tuning.lua` (names optional):
   - `computeOctaveStep`: no names ⇒ no C-tail relabel ⇒ octave bumps at
     the period (return `#cents + 1`).
   - `stepToText`: name present ⇒ today's behaviour; absent ⇒
     degree-based label.
   - Add `tuning.lua` specs for the nameless path. `tm_tuning_spec`'s
     I1–I5 are realisation-layer invariants — untouched.
3. **Scala `.scl` import**: parse comment/count/pitches; ratios →
   `1200*log2(n/d)`, cents pass through. Map to Continuum as
   `cents = {0} ∪ scl[1..n-1]`, `period = scl[n]`, `stepNames = {}`.
   `.kbm` deferred.
4. **Extract the shared library shell** if swing + temper CRUD now
   genuinely overlaps (the "third instance" test).

### Open sub-decision for phase 2 (bring mockups)

**Nameless-step cell display.** Tracker pitch cells are fixed 3-char
(`C-4`). A nameless scale degree has no letter spelling. Options:
degree-only, 2-char degree + 1-char octave, or widen the pitch cell when
the active temper is nameless. Needs a visual call — present ASCII
mockups via AskUserQuestion.

---

## Phase 3 — compilers ("day two")

JI ratios (`3/2` → cents), `n\edo` steps, then MOS / harmonic-series
generators — all front-ends that emit a cents list into the temper.

---

## Resume checklist (cold start)

1. Read this file + `docs/tuning.md`.
2. `mcp__readium_docs__map_query` over `tuning`, `temperEditor`,
   `editorPage`, `swingEditor` for current shapes.
3. Confirm phase-2 scope + the nameless-cell display decision before
   coding (touches `tuning.lua` + tracker cell renderer = >2 files →
   plan first).
