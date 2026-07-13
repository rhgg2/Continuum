# Library model: workspace / library split

2026-07-13. Applies to the two existing user libraries (swings, tempers);
the model is the template for fx patterns, generator scripts, and wiring
macros later.

## Problem

Swings and tempers live at two cm tiers with different lifetimes —
`project` (travels with the project) and `global` (the user's machine) —
behind one editing surface. The tier being written is invisible editor
state (`state.tier` / `selTier`), `homeTier()` falls through to global
when no project copy exists, and every slider gesture is a commit. So
"browse a global temper, touch one thing" silently mutates the library.

Two secondary defects:

- `cm:seedGlobalFromDefault` copies the factory catalogue (EDO presets,
  classic swings) into the global tier. That conflates factory content
  with things the user chose to keep, makes factory presets editable
  (another accident surface), and means catalogue updates never reach
  an installed machine.
- A project can *use* a global entry with no project copy (editor-side
  selection never localizes), so self-containment silently depends on
  discipline. (The pickers already localize on pick — the editors don't.)

## Model

Three ownership levels, one invariant:

| level | store | contents | writable? |
|---|---|---|---|
| **Factory** | schema defaults (`configManager.lua` DEFAULTS) | shipped catalogue | never |
| **Library** | cm `global` tier | user-published entries only | only via *publish* / *delete* |
| **Project** | cm `project` tier | everything the project uses | **the only edit surface** |

**Invariant: all editing writes land at the project tier.** Editing an
entry whose selection is a Library or Factory row forks it to project
first (implicit, inside the same undo point as the edit), then writes.
Accidental library edits become impossible rather than discouraged.

Resolution order is unchanged — `mergeTiers` already reads
project → global → defaults — so Factory needs no new plumbing at
realisation time.

Verbs (uniform across asset types):

- **use** — picking an entry copies it to project if absent (already
  shipped: `localizeSwing`, `pickTemper`).
- **publish** — copy project entry → library. Explicit button (today's
  `promote` / "dup global"). Confirm when overwriting a divergent
  library copy.
- **revert** — copy library/factory entry → project copy, discarding
  project drift (today's `demote` body, re-aimed).
- **tidy** — delete project entries that are pristine (deep-equal to
  their library/factory source) and unreferenced. Explicit button;
  automatic GC deferred until clutter proves annoying.
- **delete** — project rows (unless referenced), library rows always.
  Factory rows never.

**Modified badge**: a project entry whose name shadows a library or
factory entry and differs from it shows a dirty marker in the tree and
pickers. Computed by deep-eq on demand — both copies are local, so no
provenance metadata, no hashes.

Synthetic floors (`identity`, `12EDO`) stay as they are: excluded from
listings, undeletable, the nil-selection sentinels.

The cm tier keeps its internal name `global`; only UI copy changes
("Library" section, plus a new read-only "Factory" section).

## Current-state inventory

- `configManager.lua:71-79` — factory catalogues already live in schema
  defaults. `:489 seedGlobalFromDefault` is the seeding to kill.
- `chrome.lua:372 libPicker` — picker groups: Off / project / `+`others
  (merged minus project). Calls `seedGlobalFromDefault`.
- `trackerView.lua:579 localizeSwing`, `:591 setSwingSlot`,
  `:601 setColSwingSlot` — copy-on-use for swings.
  `:622 setSwingComposite(name, composite, tier)` /
  `:630 setTemper(name, temper, tier)` — tier-parameterised write-through
  used by the editors; the tier params are what let editor writes reach
  global.
- `trackerRender.lua:37 pickTemper` — temper copy-on-use, inlined
  (asymmetric with swing's home in trackerView).
- `swingEditor.lua:411-470` — tier-aware block: `projectSwings` /
  `globalSwings` (seeds), `homeTier` (global fallthrough), `switchTo`,
  `promote`, `demote`, `deleteSel`. `:267 swingWrite` is the sole write
  path; `:234 swingRead` reads the selection's tier copy.
- `temperEditor.lua:43-56` — same shape (`projectTempers` /
  `globalTempers` / `homeTier`); `:106 temperWrite` sole write path;
  `:190 promote`, `:199 demote`; `:377/:390` New/Import modals create at
  `selTier or 'project'`.
- `editorRender.lua:29-68` — library tree (Active / Project / Global
  sections) + action bar (`add` / `import` / `dup global` /
  `dup project` / `reset` / `del`) driven by each pane's descriptor.
- `swingEditor.lua:511 inUseNames` / `arrangeManager takesUsing(name)` —
  reference scan for swings (delete-gating; reusable for tidy). No
  temper analogue yet.

## Plan

Steps land in order; each is independently green.

### 1. `library.lua` — shared tier logic

New module, closures over a cm handle, instantiated once and threaded
like other services. The tier logic currently duplicated across five
sites (both editors' project/global accessors + promote/demote,
trackerView's `localizeSwing`, trackerRender's `pickTemper`,
`libPicker`'s seeding) collapses into it. Per library key
(`'swings'`, `'tempers'`):

```lua
lib.names(key)            -- { project = {..}, library = {..}, factory = {..} } sorted,
                          --   factory minus shadowed? no: full lists; UI dedups by section order
lib.get(key, name)        -- resolved: project → library → factory
lib.localize(key, name)   -- copy-on-use; no-op if project copy exists or name is synthetic
lib.forkToProject(key, name) -- localize + return the project copy for editing
lib.publish(key, name)    -- project → library (deep-clone)
lib.revert(key, name)     -- library/factory → project (deep-clone)
lib.modified(key, name)   -- project copy exists, shadows a source, and differs (deep-eq)
lib.tidy(key, inUse)      -- delete pristine ∧ not inUse[name] project entries; returns names
lib.delete(key, level, name)
```

Synthetic-name sets passed at instantiation per key. New spec
`tests/specs/library_spec.lua` covers the verbs over harness cm.

### 2. cm: kill seeding, expose factory

- Delete `cm:seedGlobalFromDefault` (+ its `config_schema_spec` cases).
- Add `cm:defaultFor(key)` — deep-copy of the schema default, so
  `library.lua` can list/compare factory without a merged read.
- One-off cleanup of already-seeded machines: on first library read,
  purge global entries deep-equal to their factory default (the seeding
  in reverse). Small, self-contained, removable post-beta. Pre-beta
  rules apply — no compat shims beyond this.

### 3. Pickers

`chrome.libPicker` drops the seed call and gains the modified badge on
project rows. Grouping stays Off / project / `+`others (others =
library ∪ factory, deduped); splitting others into Library/Factory
groups is optional polish, not required. `pickTemper`'s inline
localization is replaced by `lib.localize` (and moves to trackerView so
swing/temper pick paths are symmetric); `localizeSwing` body is replaced
by the same call.

### 4. Editors: writes always land at project

- `tv:setSwingComposite` / `tv:setTemper` lose their `tier` params —
  they always write project.
- `swingWrite` / `temperWrite` (the sole write paths) call
  `lib.forkToProject` when the current selection is a library/factory
  row, retarget the selection to the project copy, then write. The fork
  shares the gesture's undo point (as `demote`'s `util.atomic` wrap
  does today).
- `homeTier` survives only for *selection* defaulting (which row to
  highlight); it no longer picks a write target.
- New/Import modals always create at project (drop the
  `selTier or 'project'` tier capture).
- `promote` → `lib.publish` behind a confirm-on-divergent-overwrite
  modal (modalHost). `demote` disappears as a user verb; its body
  becomes `lib.revert`.

### 5. editorRender: tree + action bar

- Sections: Active / Project / Library / Factory. Factory rows render
  like library rows but are never deletable/publishable; selecting one
  is fine (first edit forks).
- Action bar: `add`, `import`, `publish` (project rows),
  `revert` (project rows that shadow a source), `reset` (unchanged:
  snapshot revert within the session), `tidy` (Project folder
  selection), `del` (per-section gating above).
- Modified badge on project rows via `lib.modified`.

### 6. Docs

- `docs/swingEditor.md` § Library tiers rewritten to this model.
- `docs/configManager.md` seeding paragraph removed; `defaultFor` noted.
- `docs/library.md` — the model prose (largely this doc's Model
  section); this design doc then archives.

## Open questions

1. **Publish overwrite confirm** — worth a modal in v1, or is silent
   overwrite acceptable given the library row can be re-derived from
   any project that used it? Leaning modal: it's the one remaining
   destructive-to-library gesture.
2. **Tidy for tempers** — reference scan needs a `takesUsing` analogue
   over take/track-tier `temper` values. If that's awkward, v1 ships
   tidy for swings only and tempers keep manual delete.
3. **Picker grouping** — one `+` group vs split Library/Factory groups.
4. **`reset` (snapshot revert)** — with REAPER undo now covering editor
   gestures, does the session snapshot still earn its button, or does
   `revert` (to library) subsume the need?
