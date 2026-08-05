# CLAUDE.md

This is Continuum, a Lua 5.4 tracker-style MIDI editor for REAPER -
pre-beta, so its persisted shapes change freely.

## Architecture

**Layered manager pattern.** Each layer transforms data from the layer
below and propagates changes upward via signal-keyed callbacks
installed with `util.installHooks`.

The callback protocol keeps the layers agreeing about what's true; so
reaching through skips the propagation and leaves them holding
different pictures of the same state. That's why calls go through the
public API of the adjacent layer rather than reaching past it.

`continuum.lua` wires everything; `coordinator` owns the UI frame and
switches between pages. Each page manages a `page → view → manager →
...` stack (currently tracker, sampler, wiring, arrange, editor); it
builds the substack and drives lifecycle on the layer that owns it. So
the adjacent-layer guidance above governs calls *within* the chain,
not the page's reach into it.

Each piece of state has one owner, so a special case is usually
evidence of having located the wrong owner rather than a pragmatic
shortcut. `cm` is sole truth for config keys, `dataStore` for document
data; unknowns raise, and cm deep-copies at its boundary so callers
never clone. 

Two critical concepts in the tracker stack:

- **Time** — two frames (logical / realisation), connected by swing.
  Delay is a per-note offset on the raw note-on, not a frame of its
  own. See `docs/timing.md`.
- **Pitch** — detune is intent (per-note metadata); pb is realisation
  (channel-wide stream). The view layer never touches pb directly.
  See `docs/tuning.md`.

## Documentation layers

`--KIND:` annotations in source carry single-line invariants,
contracts, shapes, emitted signals and REAPER touchpoints. They are
one-liners, capped short (except `--shape`); `docs/CONVENTIONS.md` has
the full details.

Rationale, history or examples that wouldn't fit in a line live in
`docs/<file>.md` with a one-line pointer at the site (`-- see
docs/<file>.md § <section>`). The docs hold the current WHY, but don't
describe the API surface or repeat annotations in the code.

Ongoing work larger than a couple of commits has a design doc in
`design/` and a plan in `plan/`: the design doc holds the intent and
the decisions, the plan holds the machinery — phases, what landed,
what's next.

Docs, design docs and the decisions log share a stated register:
`docs/STYLE.md` — the tone it is pitched at, how a section is ordered,
and what counts as ornament rather than claim. Worth reading before
writing any of the three.

## Navigating the code

`map/<file>.map` answers "where does X live" in one screen and is
regenerated on every edit. For cross-file queries,
`mcp__continuum_map__map_query` is faster and more complete than
grepping `map/*.map`; its schema documents the filters, query syntax
and return shape. `mcp__reaper_docs__reaper_doc_lookup` reads parsed
ReaScript/ReaImGui entries.

`mcp__reaper__reaper_eval` runs a Lua chunk inside the running
Continuum instance. Undoable edits route through mm/tm with an
`undo_label`. `docs/bridge-cookbook.md` has the recipes,
`docs/bridge.md` the model.

## Tests

`mcp__continuum_tests__lua_test_run`. Test specs live in
`tests/specs/` and register in `tests/run.lua`. Bugfixes go red-first;
refactors pin the invariant. For new features, an effective red-first
stubs the function, so the red comes from an assertion rather than a
nil call. `mcp__continuum_perturb__spec_perturb` applies authored
breakages to throwaway copies of the tree and says which the spec
noticed.

`map/specs/<spec>.map` outlines each spec (intent, cases, harness
surface) and `map_query`'s `usedby` includes them under `scope='all'`, so
"which specs exercise X" is askable before reading spec source.

## Commits

**`config:` is the scope for Claude Code's own machinery** — skills,
hooks, settings, agents, and tools whose only consumer is a skill
(e.g. `tools/comment_hygiene.py`).

## Coding style

The items below are the house dialect rather than rules with teeth;
matching them keeps the codebase reading as one voice.

- The repo is closures-over-state, not objects-with-methods, and it
  carries none of the OO furniture: no underscore-prefixed "private"
  names, no `setmetatable` inheritance or metatable-as-class, no
  `ClassName` UpperCamelCase for modules or constructors.
- Things are scoped tightly, with private helpers wrapped in `local fn
  do ... end`.
- Registry tables are one line per entry. The `registerAll{...}`
  command table is a scannable verb → `{fn, undoDesc}` map, so
  multi-line bodies are extracted to a named `local function` rather
  than inlining a closure that breaks the alignment.
- Section banners: `----- Name`. Major: `----------- PUBLIC`.
