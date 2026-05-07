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
              └─ sampleManager   -- Continuum Sampler JSFX interface via gmem
slotStore                  -- sample slot persistence and file copy/move
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

## How to work

- For design, `docs/<module>.md` carries the *why*. Use for planning new features and major refactors.

- For coding, `cm/` carries the *what*. `cm/<module>.cm` maps factory, state, private functions, public API, and `--@cm:` module-local contracts. Read first — it answers "where does X live" in one screen.
  
- Framework docs: `docs/reaper_imgui_doc.html` (ReaImGui), `docs/REAPER API functions.html` (ReaScript). Grep to verify API names and signatures.

- When changing source: if it touches `docs/<file>.md`, update that section. If it changes a contract, update `--@cm:`. The cm files are tool-generated; don't hand-edit.
  
- When writing new docs for an undocumented file: follow
  `docs/CONVENTIONS.md`, but keep the file WHY-only — leave WHAT to
  annotations + `.cm`.

- All code changes run the pure-Lua test harness (`lua tests/run.lua`). All bugfixes add red-first regression tests. All refactors add tests pinning the invariant.
  
- Spec files live in `tests/specs/`, registered in `tests/run.lua`. Read only specs adjacent to your changes.

## Coding style

- Use closures extensively.
- Scope tightly: wrap private helpers in `local fn do ... end`; readers then see which belong to which function.
- Section banners: `----- Name`.
