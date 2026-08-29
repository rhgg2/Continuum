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

## Documentation, design and planning

The only durable documentation for this project is in `docs/`. It
states the current model, and non-local information that forces the
code's shape.

Ongoing work larger than a couple of commits has ephemeral
documentation: a design doc in `design/` and a plan in `plan/`. The
design doc holds the model being proposed, without justifications; the
plan holds the machinery of phases, what landed and what's next.

Docs, design docs and the decisions log share the register of
`docs/STYLE.md`.

## Tooling

`map/<module>.map` and `map/specs/<spec>.map` are symbol maps. They
are generated rather than tracked: built at session start in a tree
that lacks them, and regenerated on every edit. Besides direct
reading, the maps can be queried via `mcp__continuum_map__map_query`.
These are optimised for
cross-cutting queries you can put a name to; save the `Explore` agent
for genuinely fuzzy and open-ended queries.

Use `mcp__reaper_docs__reaper_doc_lookup` for ReaScript/ReaImGui APIs.

`mcp__reaper__reaper_eval` runs a Lua chunk inside the running
Continuum instance. Undoable edits route through mm/tm with an
`undo_label`. `docs/bridge-cookbook.md` has the recipes,
`docs/bridge.md` the model. `mcp__reaper__reaper_reload` ensures a
fresh, running instance of Continuum with the tree's code.
