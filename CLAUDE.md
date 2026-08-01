# CLAUDE.md

Hi Claude! This is Continuum, a Lua 5.4 tracker-style MIDI editor for
REAPER. These notes are for your orientation, and are conventions, not
restrictions. If the guidance fights the work in front of you, I'm
happy for you to trust your judgement.

## Architecture

**Layered manager pattern.** Each layer transforms data from the layer
below and propagates changes upward via signal-keyed callbacks
installed with `util.installHooks`.

The callback protocol keeps the layers agreeing about what's true; so
reaching through skips the propagation and leaves them holding
different pictures of the same state. That's why calls go through the
public API of the adjacent layer rather than reaching past it.

`continuum.lua` wires everything; `coordinator` owns the UI frame and
switches between pages. Each page *coordinates* a `page → view →
manager → ...` stack (currently tracker, sampler, wiring, arrange,
editor) rather than sitting atop it: it builds the substack and drives
lifecycle on the layer that owns it. So the adjacent-layer rule above
governs calls *within* the chain, not the page's reach into it. There
are also many cross-cutting services; the live module set and how
they connect can be found using `mcp__continuum_map__map_query`.

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
the kind list, attachment rules, the `?`-prefix-for-inferred
convention, the caps themselves, the contract/annotation/doc boundary
and section-divider grammar.

Anything that doesn't fit in a line is rationale, history or an
example, and belongs in `docs/<file>.md` with a one-line pointer at the
site (`-- see docs/<file>.md § <section>`). That file is the only layer
with room for WHY — the model, the history, the incident that motivated
a shape, the concern that spans files — and it doesn't restate API
surface or repeat an annotation, because the reader already has those.

## Programme plans

Every piece of ongoing work larger than a couple of commits has a
design doc in `design/` and a plan in `plan/`: the design doc holds the
model and the decisions, the plan holds the machinery — phases, what
landed, what's next. `plan/CURRENT` is a stack, newest first: the top
line is live and the rest are parked. The in-flight item's
implementation brief is `plan/IMPL.md` — untracked and short-lived:
`/plan-next` writes it, `/implement-next` works from it, the landing
bookkeeping deletes it.

`design/` is intent, not current state — `docs/<file>.md` is what is
true now.

## Thoughts on design narration

Most design docs adopt the impersonal present tense, with no hedges
and no speaker. This is fine for conveying where a design stands
today, but founders when revisions are needed; it is hard to honour
the intent of the design, as this is often not reconstructible from
the visible edifice.

A shape I find more honest and more useful is a plausible
re-narration: a viable path to the design, possibly not the path
actually taken, but which conveys the principles behind it and
empowers the reader to act in sympathy with the original goals.

Along the way, there will be various traps; motivating cases that
don't generalise, tempting choices that look right and aren't. A
superficially tidy exposition that omits these tempts the reader to
fall into the same traps again. Putting them back in helps the reader
immensely; it's often also the thing a red spec can pin.

## Navigating the code

- **Maps make things easier.** `map/<file>.map` answers "where does X
  live" in one screen and is regenerated on every edit, so it's
  current even for a file you opened weeks ago; `docs/<file>.md` for
  the WHY.

- **Cross-module navigation — `mcp__continuum_map__map_query`.** Faster
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
  both) is for: table-constructor keys and `function recv.name(...)`
  declarations count as writes, so producer sites are covered.
  Omitting `module` gives the repo-wide blast radius, specs included.

- **Framework docs** — `mcp__reaper_docs__reaper_doc_lookup` reads
  the parsed ReaScript/ReaImGui entries. Falling back to grep over the
  bundled HTML is fine when a name is missing from them.

- **Live REAPER — `mcp__reaper__reaper_eval`** runs a Lua chunk inside
  the running Continuum instance, and needs it open in REAPER or it
  times out. Confirm with me before anything destructive; undoable
  edits route through mm/tm with an `undo_label`.
  `docs/bridge-cookbook.md` has the recipes, `docs/bridge.md` the
  model.

## Tests

- **The basics** — `mcp__continuum_tests__lua_test_run`. Test specs
  live in `tests/specs/` and register in `tests/run.lua`. Bugfixes go
  red-first; refactors pin the invariant. For new features, an
  effective red-first stubs the function, so the red comes from an
  assertion rather than a nil call.

- **Tooth-testing a green spec** — `mcp__continuum_perturb__spec_perturb`
  applies authored breakages to throwaway copies of the tree and
  reports which ones the spec noticed. Good for the tests a blunt
  red-first can't prove effective.

- **Test maps** — `map/specs/<spec>.map` outlines each spec (intent,
  cases, harness surface) and `map_query`'s `usedby` includes them, so
  "which specs exercise X" is askable before reading spec source.

- **Wired-behaviour specs** — commands, hooks, lifetime, the UI path —
  only earn their keep if they exercise the **real** production
  wiring, so the tests stub ImGui and REAPER at the surface and leave
  the behaviour under test alone.

## Commits

- **`config:` is the scope for Claude Code's own machinery** — skills,
  hooks, settings, agents, and tools whose only consumer is a skill
  (e.g. `tools/comment_hygiene.py`). Changes that also touch product
  code take on the product's scope.

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
- Things are scoped tightly, with private helpers wrapped in `local fn
  do ... end`.
- Registry tables are one line per entry. The `registerAll{...}`
  command table is a scannable verb → `{fn, undoDesc}` map, so
  multi-line bodies are extracted to a named `local function` rather
  than inlining a closure that breaks the alignment.
- Section banners: `----- Name`. Major: `----------- PUBLIC`.
