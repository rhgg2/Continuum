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
- **Pitch** — three rungs: intent cents is what a note means (the step
  it was written on), detune is where it sounds, pb is realisation
  (channel-wide stream). The view layer never touches pb directly.
  See `docs/tuning.md`.

## Documentation layers

`--KIND:` annotations in source carry single-line invariants,
contracts, shapes, emitted signals and REAPER touchpoints. They are
one-liners, capped short (except `--shape`); `docs/CONVENTIONS.md` has
the full details.

Rationale that wouldn't fit in a line live in `docs/<file>.md` with a
one-line pointer at the site (`-- see docs/<file>.md § <section>`).
The docs hold WHY: non-local information that forces the code's shape.

Ongoing work larger than a couple of commits has a design doc in
`design/` and a plan in `plan/`: the design doc holds the model being
proposed, without justifications; the plan holds the machinery —
phases, what landed, what's next.

`docs/` is the only permanent layer, and the others drain into it as
work progresses. Thus, citations should only point into `docs/` or
into `design/` of an active plan. Outside of the plan workflow,
`docs/` is updated alongside code as an atomic block.

Docs, design docs and the decisions log share the register of
`docs/STYLE.md`.

## Navigating the code

`map/<module>.map` and `map/specs/<spec>.map` are symbol maps,
regenerated on every edit. Besides direct reading, the maps can be
queried via `mcp__continuum_map__map_query`. These are optimised for
cross-cutting queries you can put a name to; save the `Explore` agent
for genuinely fuzzy and open-ended queries.

Use `mcp__reaper_docs__reaper_doc_lookup` for ReaScript/ReaImGui APIs.

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

## Commits

`config:` is the scope for Claude Code's own machinery — skills,
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
- Tables crossing a pass boundary get role-named fields (`xLo`/`xHi`,
  `chanLeft`, `pitchWidth`, `viewRows`) rather than bare coordinates.
- Section banners: `----- Name`. Major: `----------- PUBLIC`.

## `util.lua`

This is a grab-bag of idioms that recur in the code.

- `util.add(t, v)` for `t[#t+1] = v`
- `util.bucket(t, k, v)` appends `v` to a table under `t[k]`, creating
  it if `nil`.
- `util.assign(t1, t2)` merges keys of `t2` into `t1`; clear a key
  with the sentinel `util.REMOVE`.
- `util.clone(src, exclude)` (shallow) and `util.deepClone` (deep).
- `util.deepEq(t1, t2)`.
- `util.key(...)` builds an opaque NUL-joined compound key; also
  `util.keys(t)` for the key list of a table.
- For ppq-sorted dense tables: `util.seek` for the event before/after
  a ppq, `util.between` for a half-open window, `util.insertSorted` to
  splice without a re-sort.
- `util.isNote(e)` is the note/CC test.
- Scalars: `util.clamp`, `util.round(n, to)`.
- `util.installHooks(owner)` installs the subscribe/unsubscribe/forward
  protocol on `owner` and returns its `fire`.
- `util.atomic(label, fn)` wraps a call as one REAPER undo block.
- `util.instantiate(name, deps)` runs a factory module, and is the test
  seam via `util._stubs`.
- Persistence: `util.serialise`/`unserialise` for the escaped P_EXT
  wire form, `util.prettySerialise`/`prettyUnserialise` for a
  hand-editable Lua literal.
