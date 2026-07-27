# CLAUDE.md

Hi Claude! This is Continuum, a Lua 5.4 tracker-style MIDI editor for
REAPER. These notes are for your orientation, and are convention-only,
so don't agonise over them. If the guidance fights the work in front
of you, trust your judgement, but let me know: maybe the guidance
needs updating.

## Architecture

**Layered manager pattern.** Each layer transforms data from the layer
below and propagates changes upward via signal-keyed callbacks
installed with `util.installHooks`.

The callback protocol keeps the layers agreeing about what's true; so
reaching through skips the propagation and leaves them holding
different pictures of the same state. Thus, go through the public API
of the adjacent layer rather than reaching past it.

`continuum.lua` wires everything; `coordinator` owns the UI frame and
switches between pages. Each page *coordinates* a `page → view →
manager → ...` stack (currently tracker, sampler, wiring, arrange,
editor) rather than sitting atop it: it builds the substack and drives
lifecycle on the layer that owns it. So the adjacent-layer rule above
governs calls *within* the chain, not the page's reach into it. There
are also many cross-cutting services including
chrome/painter helpers; for the live module set and how they connect,
use `mcp__readium_docs__map_query`.

Two critical concepts in the tracker stack:

- **Time** — two frames (logical / realisation), connected by swing.
  Delay is a per-note offset on the raw note-on, not a frame of its
  own. See `docs/timing.md`.
- **Pitch** — detune is intent (per-note metadata); pb is realisation
  (channel-wide stream). The view layer never touches pb directly.
  See `docs/tuning.md`.

## Documentation layers

Four places carry information about a module:

1. **Source** (`<file>.lua`) — WHAT.
2. **`--KIND:` annotations** embedded in source — single-line
   invariants, contracts, shapes, emitted signals, REAPER
   touchpoints. See `docs/CONVENTIONS.md` for the kind list,
   attachment rules, and the `?`-prefix-for-inferred convention.
3. **`.map`** (`map/<file>.map`) — derived semantic outline, one per
   `.lua`. Read it first: it answers "where does X live" in one
   screen. These are generated, not hand-edited.
4. **`docs/<file>.md`** — prose, and the only layer with room for WHY:
   the model, the history, the incident that motivated a shape, the
   concern that spans files. It doesn't restate API surface or repeat
   a `--KIND:` annotation, because the reader already has those.

Annotations are one-liners, and (except for --shape) capped short so
they stay scannable. If it won't fit in a line, that means you're
holding rationale, history or an example, and those live in
`docs/<file>.md`, with a one-line pointer at the site (`-- see
docs/<file>.md § <section>`). See `docs/CONVENTIONS.md` for the caps
themselves, the contract/annotation/doc boundary, and section-divider
grammar.

## Programme plans

Every piece of ongoing work has a design doc in `design/` and a plan in
`plan/`. The doc holds the model and the decisions; the plan holds only
the machinery — phases, what landed, what's next — compiled out of the
doc and never designed in. Work too small for a design round still gets
a doc: `/plan-new` writes a short one from the conversation, and the
plan simply has no Phases section. `plan/CURRENT` is a stack, newest
first — the top line is live and the rest are parked, so a small job can
push in front of a running programme and pop back off when it closes.

`design/` is the durable home for design rationale, and it is closed: a
decision belonging to a live doc is written in that doc, and one with no
doc to belong to goes in `design/decisions.md`, the dated ledger. Every
doc opens with an `opened:` creation date, so the directory can be read
in order as the project's reasoning end to end. It is intent, though,
not current state — `docs/<file>.md` is what is true now.

For implementation work, read the plan file first — it carries what
just landed and a self-contained brief for what's next, so you rarely
need the design doc. There is one `/plan-*` command per granularity —
open, split, promote, close — each carrying its own description. The
commit skill's pre-agent steps handle landing bookkeeping.

## How to work - production

- **Maps before source.** `map/<file>.map` is cheap, current, and
  answers "where does X live" in one screen, which is why it's worth
  opening even for a file you know well; `docs/<file>.md` for the WHY.

- **Cross-module navigation — `mcp__readium_docs__map_query`.** Faster
  and more complete than grepping `map/*.map`; its schema documents
  the filters, query syntax and return shape. Gotchas on top of the
  schema: `uses`/`usedby` resolve receivers through the file's alias
  table, so targets read as `tm:rebuild`, not
  `trackerManager:rebuild`; `forward` edges point at the **source's**
  signal, not the receiver's, and kind='flow' follows the whole chain
  for you. `query` and `module` are regex, not glob — `query`
  substring-matched, `module` anchored.

- **Field-shaped questions** — who reads or writes `.ppqL`, who
  produces `endppqC` — are what kind='reads'/'writes' ('fields' for
  both) is for, and they beat a grep sweep: table-constructor keys and
  `function recv.name(...)` declarations count as writes, so producer
  sites are covered. Every map ends with a `# Fields` index. Omit
  `module` for the repo-wide blast radius, specs included.

- **Framework docs** — `mcp__readium_docs__reaper_doc_lookup` reads
  the parsed ReaScript/ReaImGui entries. Falling back to grep over the
  bundled HTML is fine when a name is missing from them.

- **Live REAPER — `mcp__reaper__reaper_eval`.** This runs a Lua chunk
  inside the running Continuum instance. Confirm with me before
  anything destructive, and route undoable edits through mm/tm with an
  `undo_label`. It needs Continuum open in REAPER or it times out.
  `docs/bridge-cookbook.md` has the recipes (read state,
  add/edit/delete notes, units) and `docs/bridge.md` the model.

## How to work - tests

- **The basics** — `mcp__readium_tests__lua_test_run`. Test specs live
  in `tests/specs/` and register in `tests/run.lua`. Bugfixes go
  red-first; refactors pin the invariant.

- **The green baseline** — a SessionStart hook reports the last
  unfiltered run. The suite is deterministic and takes ~20s, so when
  the hook says nothing the suite reads has changed since, that is a
  live fact about the tree in front of you: take the baseline and skip
  the run. When it says STALE, your edits are uncovered and only a run
  will tell you.
  
- **Test maps** — tests are mapped too — `map/specs/<spec>.map`
  outlines each `tests/specs/*_spec.lua` (intent, cases, harness
  surface) and `map_query`'s `usedby` includes them, so "which specs
  exercise X" is a question you can ask before reading spec source.
  The harness surface (`tests/*.lua`: harness, fakeReaper, …) maps
  alongside the modules.

- **Wired-behaviour specs** — commands, hooks, lifetime, the UI path —
  only earn their keep if they exercise the **real** production
  wiring, so stub ImGui and REAPER at the surface and leave the
  behaviour under test alone.
  
## Commits

- **Headline only.** `git commit -m "<headline>"` and nothing else: no
  body, no `Co-Authored-By`, no generated-with tagline. This overrides
  the global default, which asks for the trailer.
- **`config:` is the scope for Claude Code's own machinery** — skills,
  hooks, settings, agents, and tools whose only consumer is a skill
  (e.g. `tools/comment_hygiene.py`). They belong to no product
  subsystem, so a subsystem scope misreads. When a change also touches
  product code, scope by the product and mention the config knock-on.

## Coding style

The items below are the house dialect rather than rules with teeth;
matching them keeps the codebase reading as one voice.

- The repo is closures-over-state, not objects-with-methods, and it
  carries none of the OO furniture: no underscore-prefixed "private"
  names, no `setmetatable` inheritance or metatable-as-class, no
  `ClassName` UpperCamelCase for modules or constructors.
- Tables that cross a function or pass boundary — layout plans,
  geometry, results — get role-named fields: `xLo/xHi`, `chanLeft`,
  `pitchWidth` rather than `x1/x2/hW`. Bare coordinate names are for
  tight local math, where the role is visible a line away.
- Scope tightly: wrap private helpers in `local fn do ... end`.
- Registry tables stay one line per entry. The `registerAll{...}`
  command table is a scannable verb → `{fn, undoDesc}` map, so extract a
  multi-line body to a named `local function` rather than inlining a
  closure that breaks the alignment.
- Section banners: `----- Name`. Major: `----------- PUBLIC`.
- Comments carry the code's state, not the session's; no in-progress
  work context.
