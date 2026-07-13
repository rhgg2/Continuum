# CLAUDE.md

Continuum is a Lua 5.4 tracker-style MIDI editor for REAPER.

## Architecture

**Layered manager pattern.** Each layer transforms data from the layer
below and propagates changes upward via callbacks. Never reach through
a layer to manipulate data belonging to another — use the public API
of the adjacent layer instead.

`continuum.lua` wires everything; `coordinator` owns the UI frame
and switches between pages. Each page sits at the top of a `page →
view → manager → ...` stack (currently tracker, sampler, wiring,
arrange). Cross-cutting services: `commandManager` (key binding +
dispatch, root + per-page scopes), `configManager` (5-tier config:
global → project → track → take → transient), `modalHost`, plus
shared chrome/painter helpers and pure modules (`util`, `timing`,
`tuning`, `fs`, `DAG`, `groups`). For the live module set and how
they connect, use `mcp__readium_docs__map_query`.

Two critical concepts in the tracker stack:

- **Time** — two frames (logical / realisation), connected by swing.
  Delay is a per-note offset on the raw note-on, not a frame of its
  own. See `docs/timing.md`.
- **Pitch** — detune is intent (per-note metadata); pb is realisation
  (channel-wide stream). The view layer never touches pb directly.
  See `docs/tuning.md`.

Layers in the tracker stack expose a signal-keyed callback protocol
via `util.installHooks`.

## Documentation layers

Four places carry information about a module:

1. **Source** (`<file>.lua`) — WHAT.
2. **`--KIND:` annotations** embedded in source — single-line
   invariants, contracts, shapes, emitted signals, REAPER
   touchpoints. See `docs/CONVENTIONS.md` for the kind list,
   attachment rules, and the `?`-prefix-for-inferred convention.
3. **`.map`** (`map/<file>.map`) — derived semantic outline, one per
   `.lua`. Tool-generated via the post-edit hook; never hand-edit.
   Read first — answers "where does X live" in one screen.
4. **`docs/<file>.md`** — prose. WHY only: the model, history,
   incidents that motivated a shape, cross-cut concerns that span
   files. Never repeats API surface; never restates what a `--KIND:`
   annotation already says.

**Length caps — hard, mechanical.** `--invariant:` / `--contract:` /
`--emits:` / `--reaper:` are one line, ≤100 chars (aim 90). `--shape:`
is exempt from the line cap but only for *describing the shape* (field
names, types, nesting) — it is not a dumping ground for prose,
rationale, or examples; those belong in `docs/<file>.md`. Inline
comments cap at **2 lines**; a WHY that needs more goes in
`docs/<file>.md` with a one-line pointer at the site
(`-- see docs/<file>.md § <section>`).

**Before authoring annotations, comments, or docs:** read
`docs/CONVENTIONS.md` — it carries the contract/annotation/doc
boundary rules, section-divider grammar, and the rationale behind the
caps above. Model docs to imitate: `docs/timing.md`, `docs/tuning.md`,
`docs/configManager.md`.

## How to work

- **MCP tool schemas — load before calling.** The global rule applies
  here too: before the first call to any MCP tool in a session, run
  `ToolSearch select:<name>` and match every parameter to the live
  schema. Project-specific MCP tools: `mcp__readium_docs__*`,
  `mcp__readium_tests__*`, `mcp__reaper__*`.

- Read `map/<file>.map` before fetching source ranges from
  `<file>.lua` — including for files you've worked with before.
  `docs/<file>.md` for the WHY. Specs have maps too:
  `map/specs/<spec>.map` outlines each `tests/specs/*_spec.lua`
  (intent, cases, harness surface), and `map_query`'s `usedby`
  includes them — ask it "which specs exercise X" before reading
  spec source.

- Cross-module navigation: use `mcp__readium_docs__map_query` before
  grepping `map/*.map` — the tool's schema documents filters,
  wildcards, and return shape. Gotchas worth knowing on top of the
  schema: `uses`/`usedby` resolve receivers through the file's alias
  table, so targets read as `tm:rebuild`, not
  `trackerManager:rebuild`; `forward` edges point to the **source's**
  signal, not the receiver's; method calls on runtime receivers (not
  in the alias table) are dropped, so `usedby` has a real recall gap
  there.

- Framework docs (ReaScript / ReaImGui): use
  `mcp__readium_docs__reaper_doc_lookup`, not raw grep over the
  bundled HTML. Grep only if a name is missing from the parsed
  entries.

- Tests: `mcp__readium_tests__lua_test_run`. Bugfixes red-first;
  refactors pin the invariant. Specs in `tests/specs/`, registered
  in `tests/run.lua`.

- Live REAPER: `mcp__reaper__reaper_eval` runs a Lua chunk inside the
  running Continuum instance — reach for it when harness and REAPER
  disagree, or to verify real behaviour after a change. Needs Continuum
  open in REAPER (times out otherwise). The tool description carries
  the env and safety contract; `docs/bridge-cookbook.md` the recipes
  (read state, add/edit/delete notes, units) — read it instead of
  rediscovering; `docs/bridge.md` the model. Confirm before
  destructive chunks; route undoable edits through mm/tm with an
  `undo_label`; chunks must terminate — a hang freezes REAPER.

- Wired-behaviour specs (commands, hooks, lifetime, UI path) must
  exercise the **real** production wiring — not a fake handler that
  re-implements it. Stub ImGui/REAPER at the surface, never the
  behaviour under test.

- On the `trackerManager`/`trackerView`/`midiManager` stack: read
  the target fixture before the code. `configManager` tier shadowing
  and fake-mm-only methods are the usual red-test source here.

## Coding style

Aim for limpid elegance. Use whatever paradigm is most expressive and
direct. Compact, but clear.

- Comments should not contain in-progress work context.
- This repo is closures-over-state, not objects-with-methods.
- Tables that cross a function or pass boundary (layout plans, geometry,
  results) get role-named fields — `xLo/xHi`, `chanLeft`, `pitchWidth`,
  never `x1/x2/hW`. Bare coordinate names are for tight local math only.
- Scope tightly: wrap private helpers in `local fn do ... end`.
- Section banners: `----- Name`. Major: `----------- PUBLIC`.
- No OO-type conventions: no underscore-prefixed "private" names, no
  `setmetatable`-driven inheritance or metatable-as-class, no
  `ClassName` UpperCamelCase for modules or constructors.
- Screen-space drawlist work goes through `chrome.screenPainter()` (identity
  painter, chrome's palette), never raw `GetWindowDrawList` + `DrawList_Add*` —
  it keeps colours named and lines crisp. Build one per draw fn, inside the
  target window. See docs/decisions.md § 2026-07-10.

## Committing

Whenever a change lands and the suite is green, stop and remind me to
commit before moving on. Don't offer to commit: just nag, once. The
`/commit` skill handles the mechanics.
