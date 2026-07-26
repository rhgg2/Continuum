# CLAUDE.md

Continuum is a Lua 5.4 tracker-style MIDI editor for REAPER.

These notes are for your orientation. Most are conventions, and worth
following because consistency is valued here, but don't agonise over
theem. The things that do real work are marked, carry their reason, so
you can tell a constraint from a preference. If a rule fights the work
in front of you, say so and back your judgement: that's a signal about
the rule, not a transgression.

## Architecture

**Layered manager pattern.** Each layer transforms data from the layer
below and propagates changes upward via callbacks.

*Load-bearing:* go through the public API of the adjacent layer rather
than reaching past it. The callback protocol is what keeps the layers
agreeing about what's true; a reach-through skips the propagation and
leaves them holding different pictures of the same state.

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
   `.lua`. Read it first: it answers "where does X live" in one
   screen. A post-edit hook regenerates these, so hand edits are
   silently overwritten — change the source, not the map.
4. **`docs/<file>.md`** — prose, and the only layer with room for WHY:
   the model, the history, the incident that motivated a shape, the
   concern that spans files. It doesn't restate API surface or repeat
   a `--KIND:` annotation, because the reader already has those.

**Length caps.** Annotations earn their place by being scannable. So
`--invariant:` / `--contract:` / `--emits:` / `--reaper:` are one
line, ≤100 chars (aim 90), and inline comments run to two. `--shape:`
is exempt from the line cap for *describing the shape*: field names,
types, nesting.

If something won't fit, it means you're holding rationale, history or
an example, and those live in `docs/<file>.md`. Leave a one-line
pointer at the site (`-- see docs/<file>.md § <section>`).

`docs/CONVENTIONS.md` carries the contract/annotation/doc boundary
guidelines, section-divider grammar, and the reasoning behind the
caps. `docs/timing.md`, `docs/tuning.md` and `docs/configManager.md`
are good models.

## Programme plans

Big programmes compile their next steps out of `design/<doc>.md` into
`plan/<programme>.md`. Work too big for a couple of commits but too
small for a design doc gets the same plan file with no Phases section,
compiled from conversation and standing as its own record.
`plan/CURRENT` is a stack, newest first — the top line is live and the
rest are parked, so a one-off can push in front of a running programme
and pop back off when it closes.

For implementation work, read the plan file first — it carries what
just landed and a self-contained brief for what's next, so you rarely
need the design doc. One command per granularity: `/plan-new` opens a
plan, `/plan-phase` splits the in-flight phase into commit-sized queued
items, `/plan-next` promotes the top one into the brief, `/plan-close`
archives and pops. The commit skill's pre-agent steps handle landing
bookkeeping. Design docs stay pure model.

## How to work

Mostly a map of what's available and what each thing is good for. The
one item that can hurt something real is marked.

- **Live REAPER — `mcp__reaper__reaper_eval`.** *Load-bearing.* It
  runs a Lua chunk inside the running Continuum instance, so a chunk
  that doesn't terminate freezes REAPER. Confirm with me before
  anything destructive, and route undoable edits through mm/tm with an
  `undo_label`. It needs Continuum open in REAPER or it times out.
  Reach for it when the harness and REAPER disagree, or to watch a
  change behave for real; `docs/bridge-cookbook.md` has the recipes
  (read state, add/edit/delete notes, units) and `docs/bridge.md` the
  model.

- **Maps before source.** `map/<file>.map` is cheap, current, and
  answers "where does X live" in one screen, which is why it's worth
  opening even for a file you know well; `docs/<file>.md` for the WHY.
  Specs are mapped too — `map/specs/<spec>.map` outlines each
  `tests/specs/*_spec.lua` (intent, cases, harness surface) and
  `map_query`'s `usedby` includes them, so "which specs exercise X" is
  a question you can ask before reading spec source. The harness
  surface (`tests/*.lua`: harness, fakeReaper, …) maps alongside the
  modules.

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

- **Tests** — `mcp__readium_tests__lua_test_run`. Specs live in
  `tests/specs/` and register in `tests/run.lua`. Bugfixes go
  red-first; refactors pin the invariant.

- **Wired-behaviour specs** — commands, hooks, lifetime, the UI path —
  only earn their keep if they exercise the **real** production
  wiring, so stub ImGui and REAPER at the surface and leave the
  behaviour under test alone.

- **On the `trackerManager`/`trackerView`/`midiManager` stack**, read
  the target fixture before the code. `configManager` tier shadowing
  and fake-mm-only methods are where red tests usually come from here,
  and both are visible in the fixture.

## Coding style

Aim for limpid elegance: whatever paradigm is most expressive and
direct, compact but clear. The items below are the house dialect
rather than rules with teeth — matching them keeps the codebase
reading as one voice.

- The repo is closures-over-state, not objects-with-methods, and it
  carries none of the OO furniture: no underscore-prefixed "private"
  names, no `setmetatable` inheritance or metatable-as-class, no
  `ClassName` UpperCamelCase for modules or constructors.
- Tables that cross a function or pass boundary — layout plans,
  geometry, results — get role-named fields: `xLo/xHi`, `chanLeft`,
  `pitchWidth` rather than `x1/x2/hW`. Bare coordinate names are for
  tight local math, where the role is visible a line away.
- Scope tightly: wrap private helpers in `local fn do ... end`.
- Section banners: `----- Name`. Major: `----------- PUBLIC`.
- Comments carry the code's state, not the session's — no in-progress
  work context.
- Screen-space drawlist work goes through `chrome.screenPainter()`
  (identity painter, chrome's palette) rather than raw
  `GetWindowDrawList` + `DrawList_Add*`, which keeps colours named and
  lines crisp. Build one per draw fn, inside the target window. See
  docs/decisions.md § 2026-07-10.

## Committing

When a change lands and the suite is green, stop and remind me to
commit before moving on. Once is enough — a nag rather than an offer,
and not a repeated one. The `/commit` skill handles the mechanics.
