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

- Reading order on an unfamiliar module: `map/<file>.map`, then source.
  Open `docs/<file>.md` when you need the WHY.

- Framework docs: `docs/reaper_imgui_doc.html` (ReaImGui),
  `docs/REAPER API functions.html` (ReaScript). Grep to verify API
  names and signatures.

- All code changes run the pure-Lua test harness
  (`lua tests/run.lua`). All bugfixes add red-first regression tests.
  All refactors add tests pinning the invariant.

- Spec files live in `tests/specs/`, registered in `tests/run.lua`.
  Read only specs adjacent to your changes.

## Coding style

- Use closures extensively.
- Scope tightly: wrap private helpers in `local fn do ... end`; readers then see which belong to which function.
- Section banners: `----- Name`.
