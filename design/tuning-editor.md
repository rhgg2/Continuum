# Tuning editor — design & state of play

Goal: add a **tuning editor** to Continuum, in the spirit of Scale
Workshop (sevish.com/scaleworkshop). Scope grew into a shared
**project-tier library workbench page** hosting both the tuning (temper)
editor and the existing swing editor.

Status: **phases 1–2 complete and committed; the phase-3 token
compilers landed too. Live UI verified in REAPER.** What remains of
phase 3 is the *bulk* generators — MOS and harmonic-series — that emit a
whole scale at once. Everything else in the original plan is in:

- Intensional temper backend (`pitches`/`periodPitch` source tokens,
  `cents`/`period` derived), EDO presets emitted as `i\n` tokens, a
  per-temper `periodAsStep` toggle (separate-box vs trailing-row period).
- Scala `.scl` import (strict-file + lenient-paste parsers) and a paste
  box; ascending sort so cents stay monotonic.
- Variable-width pitch cells: `tuning.derive` stamps `cellWidth`; the
  tracker pitch column sizes to it (`tv:cellWidth()`); nameless cells
  fall back to `degree-octave` (Option B).
- `temperEditor` is a full authoring pane (cents/period/per-step name,
  add/remove, snapshot/Reset/dirty) mirroring `swingEditor`.
- **Step 4 done**: the shared library shell is extracted —
  `editorRender.lua` owns the tree palette; both panes feed it a
  `libraryDescriptor()`.
- `docs/editorPage.md` is written.

---

## The existing pitch model (ground truth — already in the codebase)

Read `docs/tuning.md` for the full model. Key facts:

- `tuning.lua` is a **pure** coordinate module. A temperament ("temper"
  in code) is now **intensional** — source tokens, derived geometry:
  ```
  temper = {
    name,
    pitches      = { '1/1', '9/8', ... },   -- source tokens (Scala grammar)
    periodPitch  = '2/1',                    -- source token for the period
    stepNames    = { ... } | {},             -- optional, per step (Option B)
    periodAsStep = bool,                     -- display: trailing row vs own box
    -- derived by tuning.derive:
    cents        = { 0, ... },               -- pitches → cents
    period       = 1200,                     -- periodPitch → cents
    octaveStep, cellWidth,
  }
  ```
  `tuning.derive(temper)` compiles `pitches`→`cents`, `periodPitch`→
  `period`, and stamps `octaveStep` + `cellWidth`. Pure; returns the
  temper. `cents[]` ascending, one `stepNames[]` per step (or empty).
- **`tuning.scalaPitch(token)`** is the per-token compiler (Scala
  grammar): `n/d` ratio, bare integer (harmonic `n/1`), `.`-decimal
  cents, `n\m` (step of an EDO), `n\m<equave>` (step of an equal
  division of an arbitrary equave; equave is itself a token, default
  `2/1`). Returns cents or nil. **This is where phase-3's "JI ratios"
  and "`n\edo` steps" live** — anywhere a pitch token is accepted.
- Built-in presets: 12/19/31/53-EDO, built by `edo(n, names)` which
  emits `i\n` tokens through `derive`.
- **Library**: tempers live in two tiers — `cfg.tempers` at **project**
  and a personal **global** library lazily seeded from the EDO
  catalogue (`cm:seedGlobalFromDefault('tempers', {['12EDO']=true})`,
  minus the synthetic floor). The active temper is the `temper` slot
  (take/track/project tiers), referenced by name. `findTemper(name,
  userLib)` resolves userLib then built-in presets.
- **Copy-on-assign**: picking a temper localizes it into the project
  tier; projects are self-contained, realisation never leans on
  global/defaults.
- Swing is the structural twin: library `cfg.swings`, slots by name,
  same two-tier + lazy-seed + localize story. Differs only in the
  content pane.
- **Intent/realisation split**: detune is per-note intent (cents); pb is
  channel-wide realisation. The view never touches pb. This is *below*
  anything the editor does — untouched by all phases.

---

## Decisions locked (with the user)

1. **Naming for arbitrary scales → option B.** Step names are
   *optional*; display falls back to degree/octave when a scale has no
   letter spelling. Confined to the display layer.
2. **Scala `.scl` import — early** (phase 2, done). `.kbm` deferred.
3. **Compilers — token-level done, bulk generators "day two."** Ratio /
   harmonic / `n\edo` / arbitrary-equave compile per-token via
   `scalaPitch`. MOS and harmonic-series *bulk generators* remain.
4. **One page, switcher letter "E"**, both editors behind a toolbar
   pane-selector (Swing | Tuning).
5. **Fast path: yes** — pickers/keys jump to the editor on the entry in
   force (drop-in); close returns to the previous page.
6. **F10 = global switch to editor page.**
7. **The editor edits project- and global-tier swings and tempers
   only.** It is a context-free library workbench. Per-take / per-channel
   assignment stays on the tracker (the toolbar pickers, which hold take
   context).
8. **Nameless-step cell display → widen, don't cram.** Keep the `-`
   separator; per-temper `cellWidth` widens the tracker pitch column to
   the widest label rather than squeezing into 3 chars.

---

## Architecture (as built)

The page mirrors the arrangePage pattern (controller / render split),
with the heavy authoring living in two self-contained content panes that
share one library-tree palette.

| file | role |
|---|---|
| `editorPage.lua` | Coord-driven **controller**. Instantiates the swing/temper panes + the renderer; publishes the `editor` facade (`edit(lib, name)`). Page lifecycle (`bind`/`unbind`) and every render hook delegate straight to `editorRender`. No take binding — pane state persists across visits. |
| `editorRender.lua` | **Render-only.** Owns pane-selection UI state (`'swing' \| 'temper'`) and the `droppedIn` flag; draws the toolbar pane-selector, the body split (content pane + library tree), and the status bar. Reaches the two panes only — never `cm`/`ds`. Houses the shared `libraryTree` (see below). |
| `temperEditor.lua` | Tuning content pane. Full authoring: header (name/period/`periodAsStep`), step table (per-step cents + optional name, add/remove), New + Import modals, snapshot/Reset/dirty. Reads `cm` directly for the library tiers. |
| `swingEditor.lua` | Swing content pane (migrated from the take-scoped tracker overlay). Same library-tier story; `tv` dependency replaced by the tracker **facade**. |

### The shared library shell (step 4)

Both panes expose `libraryDescriptor()` → a `libraryTreeSpec`; the
renderer's `libraryTree(spec)` draws it. One palette, two panes.

```
libraryTreeSpec = {
  x, y, h, label,
  active    = {{col, name}},      -- Active <col>: <name>, with a 'select' jump
  project   = { name, ... },      -- Project folder leaves
  global    = { name, ... },      -- Global folder leaves
  synthetic = { [name]=true },    -- merge-floor entries (e.g. 12EDO); undeletable
  undeletable = { [name]=true },
  sel       = { tier, name },     -- folder (name=nil) scopes add/import; leaf arms dup/del
  dirty?    = bool,               -- gates Reset (swing only)
  onSelect(tier, name), onNew(), onImport?(), onPromote(name),
  onDemote(name), onReset?(), onDelete(tier, name),
}
```

Action bar: `add` / `import?` / `dup global` (promote) / `dup project`
(demote) / `reset?` / `del`. `onImport`/`onReset` are optional — the
temper pane supplies `import`, the swing pane supplies `reset`; the tree
shows a button only when its callback is present.

### The facade seam (crux of the original migration)

The editor page is **off the tracker stack** and **context-free** (no
bound take). Take-context **reads** route through the tracker `facade`
(`facade`-injected); writes are project/global-tier library writes only.
The earlier transitional `setTemper`/`setProjectTemper` facade methods
are gone — the editor edits the library, assignment stays on the tracker.

### Lifecycle / keys

- `editor.edit(lib, name)` (facade) → `er:edit`: sets pane + selection
  and flips `droppedIn`. The `editTuning`/`editSwing` commands (which
  hold coord) then switch the page. Mirrors samplePage's
  `diveToSampler`.
- `droppedIn` (drop-in from a tracker picker) gates the `Close (Esc)`
  button, page-level Esc, and the status hint; cleared on `unbind`.
- Page-level Esc returns to the previous page, guarded by
  `not modalHost:isOpen()` and `not IsAnyItemActive` so an active
  InputText/slider or sub-modal keeps Esc for itself.
- `focusState`: `pageSuppressed = true` always (root globals live, page
  bindings off); `suppressKbd` when a modal or picker is active;
  `acceptCmds = not suppressKbd and not IsAnyItemActive`.

### Coordinator / wiring

- `coordinator.lua`: `E` switcher button; tracks `previous` page;
  `coord:previousPage()` getter.
- `continuum.lua`: registers `editor` page; root commands
  `switchToEditor` (F10), `editTuning`, `editSwing` (Super+E),
  `closeEditor` (→ previous page or tracker).
- `trackerRender.lua`: `✎` edit buttons on the tuning/swing toolbar
  pickers → `cmgr:invoke('editTuning'|'editSwing')`.

### New / Import (modalHost)

Both temper modals are hosted by `modalHost` (kinds `temperNew`,
`temperImport`), routed there in commit `35e7e9d`:

- **New** — name + empty scale, opens it for editing.
- **Import** — a paste box (lenient `parseScalaPitches`) plus a "load
  `.scl`" button (`GetUserFileNameForRead` → strict `parseScalaFile`,
  description becomes the suggested name). The Create button re-parses
  the box through `scalaToTemper` after any manual edits.

`scalaToTemper` bridges Scala's convention (unison implicit, period
last) to Continuum's (step 1 = `1/1`, period separate): prepend `1/1`,
sort ascending, split the widest interval off as `periodPitch`, set
`periodAsStep = true` so the scale reads top-to-bottom like the file.

---

## What is NOT done / known gaps

- **MOS / harmonic-series bulk generators** — the only real remainder of
  phase 3 (see below). Per-token ratio/EDO/equave compiling already
  works everywhere a token is typed.
- `.kbm` keyboard-mapping import — deferred.
- No compiler-specific UI beyond free-token entry + Scala import. MOS /
  harmonic generators will each need a small parameter form.

---

## Phase 3 — bulk generators ("day two")

The token compilers are done; what's left are front-ends that emit a
*whole* `pitches` list from a few parameters, then hand off to `derive`:

1. **MOS (moment of symmetry)** — from a generator interval, a period,
   and a size, produce the MOS scale (the stack of the generator reduced
   into the period, kept only at sizes where the scale is well-formed —
   two step sizes). Parameters: generator token, period token, count (or
   a "next MOS size" stepper).
2. **Harmonic / subharmonic series** — a contiguous segment of the
   harmonic series (e.g. harmonics 8…16) as the scale; the integers
   already compile via `scalaPitch` (`n` → `n/1`), so this is mostly a
   "emit `lo..hi` as tokens" generator with a root choice.

Both are pure functions emitting token lists; they slot in beside
`scalaToTemper` and reuse the same `derive` + library-write path. A
generator dropdown in the New/Import modal family is the natural home.

---

## Resume checklist (cold start)

1. Read this file + `docs/tuning.md` + `docs/editorPage.md`.
2. `mcp__readium_docs__map_query` over `tuning`, `temperEditor`,
   `editorRender`, `editorPage`, `swingEditor` for current shapes
   (`api`/`fn`/`shape` kinds).
3. The remaining work is the **bulk generators** (MOS, harmonic). They
   touch `tuning.lua` (new pure generators) + `temperEditor.lua` (a
   parameter form) — >2 files plus a new UI surface, so plan first.
