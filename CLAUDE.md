# CLAUDE.md

Continuum is a Lua 5.4 tracker-style MIDI editor for REAPER.

## Architecture

**Layered manager pattern.** Each layer transforms data from the layer
below and propagates changes upward via callbacks. Never reach through
a layer to manipulate data belonging to another — use the public API
of the adjacent layer instead.

Two parallel stacks — tracker and sampler — share a coordinator that
owns the UI frame and switches between pages.

```
continuum.lua              -- entry point, wires everything
  coordinator              -- UI frame, toolbar/status bars, key handling, page switching
    ├─ trackerPage         -- renders tracker grid, extra key/mouse handling
    │    │  editCursor     -- cursor position, selection, movement, clipboard
    │    └─ trackerView    -- maps events onto a row/col grid, editing
    │         └─ trackerManager   -- parses MIDI into channels/columns
    │              └─ midiManager -- read/write raw MIDI events
    └─ samplePage          -- renders file tree and slot grid
         └─ sampleView     -- browser state (track, folder, selection)
              └─ sampleManager   -- Continuum Sampler JSFX bridge: cm-authoritative slot state, gmem mailboxes, audio bytes
commandManager             -- key binding + command dispatch (root + per-page scopes)
configManager              -- 5-tier config (global → project → track → take → transient)
util                       -- pure: shared utilities (serialisation, base36, assign)
timing                     -- pure: swing transforms + delay-PPQ helpers
tuning                     -- pure: temperament + (pitch, detune) ↔ (step, octave)
fs                         -- pure: filesystem utilities (path ops, audio-file detection)
```

Two critical concepts in the tracker stack:

- **Time** — two frames (logical / realisation), connected by swing.
  Delay is a per-note offset added to the raw note-on, not a frame of
  its own. See `docs/timing.md`.
- **Pitch** — detune is intent (per-note metadata); pb is realisation
  (channel-wide stream). The view layer above the realisation line
  never touches pb directly. See `docs/tuning.md`.

Layers in the tracker stack expose a signal-keyed callback protocol
via `util.installHooks`.

## Documentation layers

Four places carry information about a module. Each holds what the
others can't.

1. **Source** (`<file>.lua`) — names and structure say WHAT.
2. **`--KIND:` annotations** embedded in source — single-line
   invariants, contracts, shapes, emitted signals. Five kinds:
   `--invariant:`, `--contract:`, `--shape:`, `--emits:`,
   `--reaper:`. Prefix with `?` (`--?invariant:`) for
   inferred-rather-than-doc-grounded. Attachment rules in
   `tools/map_extract.py`.
3. **`.map` file** (`map/<file>.map`) — derived semantic outline,
   one per `.lua`. Header carries `mode=chunk` (constructor) or
   `mode=namespace` (require'd table). Lists imports, constructed
   sub-instances, state, private fns, public API, signals, REAPER
   surface, plus the surfaced annotations. Read this first — it
   answers "where does X live" in one screen.
4. **`docs/<file>.md`** — prose. WHY only: the model, history,
   incidents that motivated a shape, cross-cut concerns that span
   files. Never repeats API surface; never restates what a `--KIND:`
   annotation already says.

Layers 2 and 4 are a **pair, not alternatives**: the `--KIND:` line
states an invariant tersely; the doc explains why it exists and what
breaks without it. If a doc paragraph collapses to a one-liner with no
loss it was an annotation; if an annotation needs a paragraph to be
believed, that justification belongs in the doc. Semantic split, not a
length test — see `docs/CONVENTIONS.md` § The annotation/doc boundary.

**Doc shape contract:** `docs/CONVENTIONS.md`. Read it before
authoring or editing a doc.

**Model docs to imitate:** `docs/timing.md`, `docs/tuning.md`,
`docs/configManager.md`. They show the right density and the right
register — model exposition without API repetition.

**When to update what:**

| Change | Update |
|---|---|
| Public method added/removed/renamed | `--KIND:` (if needed); `.map` regenerates |
| Contract/shape/invariant body changes | `--KIND:` annotation |
| Cross-cut invariant or model shifts | `docs/<file>.md` prose |
| New module without a doc | Stub `docs/<file>.md` (WHY only); add `--KIND:` annotations |
| Pure refactor preserving documented properties | Nothing |

**Tool-generated:** `.map` files regenerate via the post-edit hook.
Never hand-edit them.

## How to work

- Always read `map/<file>.map` before fetching source ranges from
  `<file>.lua`, **including for files you've worked with before**. The
  map gives constructed sub-instances, public API, signals, and
  surfaced annotations in ~3 KB. Many fetches that feel like "I need
  to scan the file" resolve to 4–5 surgical 30–50-line ranges once
  the map has done its work. Open `docs/<file>.md` when you need the
  WHY.

- Cross-module navigation: use `mcp__readium_docs__map_query` instead of
  grepping `map/*.map`. It parses every map and returns
  `<src>.lua:<line>  @kind <name>` rows, ready to feed into Read with
  offset/limit. Filter by `kind` (fn, api, factory, state, const,
  invariant, contract, shape, signal/emits, reaper) and/or
  `module` (exact stem or glob like `*Manager`, `tm_*`). `name`
  supports `*` / `?` glob wildcards and is matched as a substring
  against bare symbol names for structural entries and against
  body text for annotations. Examples: `kind=signal` lists every
  emitted signal with its payload doc; `name=rebuild kind=api`
  pinpoints the two `:rebuild` methods (tm and vm).

- Framework docs: `docs/reaper_imgui_doc.html` (ReaImGui),
  `docs/REAPER API functions.html` (ReaScript). Use the
  `mcp__readium_docs__reaper_doc_lookup` tool, not raw grep — it parses
  these HTML files and returns the clean Lua signature plus prose
  for a named function/constant. Wildcards (`MIDI_*`) return a
  one-line index across both docs. Falls back to grep only if a
  name is missing from the parsed entries.

- All code changes run the pure-Lua test harness. Use the
  `mcp__readium_tests__lua_test_run` tool — it wraps `lua tests/run.lua`,
  returns failures-only by default with the failing spec line + a
  source window + condensed traceback. Pass a `filter` substring to
  scope the run (e.g. `"tm_rebuild_spec"` or `"absorber"`); the
  filter matches `<spec> :: <test name>` literally. All bugfixes
  add red-first regression tests. All refactors add tests pinning
  the invariant.

- Unit specs may fake a layer, but a spec covering a wired
  behaviour (commands, hooks, lifetime, the UI path) must exercise
  the **actual** production wiring — the real command body, the real
  doBefore/doAfter hooks, the real flush. A hand-fake that
  re-implements the production handler tests the fake, not the code:
  it stays green while production breaks. If the real path needs
  ImGui or REAPER, stub the surface, not the behaviour under test.

- Spec files live in `tests/specs/`, registered in `tests/run.lua`.
  Read only specs adjacent to your changes.

- Before changing a setter or extending a method on the
  `trackerManager` / `trackerView` / `midiManager` stack, read the
  test fixture you'll target *first* — its CFG seeds (which
  `configManager` tier the test writes to) and its fake-mm surface
  (methods that exist on the fake but not in production). Tier
  shadowing and fake-only methods are the dominant failure modes in
  this stack; reading the fixture before the code costs less than
  reverse-engineering a red test.

## Coding style

Aim for limpid elegance. Use whatever paradigm is most expressive and
direct. Compact, but clear.

- Comments and doc notes are for a future reader with no memory of
  this session. Never leave a note whose sense depends on context
  only you currently hold — "the episode above", "as we discussed",
  "the bug we just hit", "for now". If it can't be understood cold,
  state the actual constraint or delete it.

- Use closures extensively.
- Scope tightly: wrap private helpers in `local fn do ... end`; readers then see which belong to which function.
- Section banners: `----- Name`.
- Major section banners: `----------- PUBLIC`.

## Committing

Whenever a change lands — a bugfix, a refactor, a feature slice — and
the suite is green, stop and remind me to commit before moving on.
Don't commit unprompted; just nag, once, and propose the message.

The proposed message must actually describe the change: what changed
and why, in the imperative, scoped to the affected area. A reader
scanning `git log` should learn what happened from the subject line
alone.

- Good: `mirm: conform-mark instance 1 at seed so first dup copy keeps its lane`
- Good: `tv: fix off-by-one in selection rect when cursor on last row`
- Bad: `drop huge mess in the toilet`, `fixes`, `wip`, `cleanup`

If several unrelated things landed, propose separate commits, not one
catch-all.

Committing is fine once I say go; **never push**. No `Co-Authored-By`
trailer and no Claude/Anthropic tagline in the message — plain message
only.
