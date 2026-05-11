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

- **Time** — three frames (logical / intent / realisation), connected
  by swing (logical↔intent) and delay (intent↔realisation). See
  `docs/timing.md`.
- **Pitch** — detune is intent (per-note metadata); pb is realisation
  (channel-wide stream). The view layer above the realisation line
  never touches pb directly. See `docs/tuning.md`.

Layers in the tracker stack expose a signal-keyed callback protocol
via `util.installHooks`.

## Documentation layers

Four places carry information about a module. Each holds what the
others can't.

1. **Source** (`<file>.lua`) — names and structure say WHAT.
2. **`--@map:` annotations** embedded in source — single-line
   invariants, contracts, shapes, emitted signals. Recognised kinds
   and attachment rules in `tools/map_extract.py`. Use `?:` variant
   for inferred-rather-than-doc-grounded.
3. **`.map` file** (`map/<file>.map`) — derived semantic outline,
   one per `.lua`. Lists factories, state, private fns, public API,
   signals, REAPER surface, plus the surfaced annotations. Read this
   first — it answers "where does X live" in one screen.
4. **`docs/<file>.md`** — prose. WHY only: the model, history,
   incidents that motivated a shape, cross-cut concerns that span
   files. Never repeats API surface; never restates what a `--@map:`
   annotation already says.

**Doc shape contract:** `docs/CONVENTIONS.md`. Read it before
authoring or editing a doc.

**Model docs to imitate:** `docs/timing.md`, `docs/tuning.md`,
`docs/configManager.md`. They show the right density and the right
register — model exposition without API repetition.

**When to update what:**

| Change | Update |
|---|---|
| Public method added/removed/renamed | `--@map:` (if needed); `.map` regenerates |
| Contract/shape/invariant body changes | `--@map:` annotation |
| Cross-cut invariant or model shifts | `docs/<file>.md` prose |
| New module without a doc | Stub `docs/<file>.md` (WHY only); add `--@map:` annotations |
| Pure refactor preserving documented properties | Nothing |

**Tool-generated:** `.map` files regenerate via the post-edit hook.
Never hand-edit them.

## How to work

- Always read `map/<file>.map` before fetching source ranges from
  `<file>.lua`, **including for files you've worked with before**. The
  map gives factories, public API, signals, and `@map:` annotations in
  ~3 KB. Many fetches that feel like "I need to scan the file" resolve
  to 4–5 surgical 30–50-line ranges once the map has done its work.
  Open `docs/<file>.md` when you need the WHY.

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

- Batched writes: use `mcp__readium_patches__apply_patches` whenever
  you'd otherwise issue ≥2 Edits — same search/replace semantics as
  the built-in `Edit` tool, but atomic across many paths. Single
  round-trip: every call opens a browser tab with a unified diff and
  Approve/Reject buttons (plus an optional comment textarea). The tool
  blocks until the user clicks. No dry-run flag. The user's comment,
  if any, comes back in the result — read it, they may have approved
  with a caveat or rejected with a reason. Prefer built-in `Edit` for
  single-file work where the in-chat per-file diff prompt is enough.

## Coding style

Aim for limpid elegance. Use whatever paradigm is most expressive and
direct. Compact, but clear.

- Use closures extensively.
- Scope tightly: wrap private helpers in `local fn do ... end`; readers then see which belong to which function.
- Section banners: `----- Name`.
