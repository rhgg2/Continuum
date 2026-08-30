# continuum

**The entry point.** `Main` runs once per ReaScript invocation: it
builds the shared singletons, registers the pages with the
coordinator, binds the global commands, and enters the defer loop.

## Loading

1. A `do` block puts `src/` and each of its stack directories on
   `package.path`, resolved through `debug.getinfo`. The script thus
   loads the same way whatever REAPER's working directory is.

1. Module names stay flat over the nested tree, so `require 'DAG'`
   resolves wherever in the tree DAG lives. Thus, names must be
   globally unique, which `tools/map_regen.py` enforces.

1. ReaImGui's builtin path goes on next. Its absence is the one
   failure reported through a message box rather than the console.

1. A stateless module is `require`d and returns a table — `util`,
   `perf`, `manifest`.

1. A factory module's file body is its constructor, run afresh per
   call by `util.instantiate(name, deps)`, which hands `deps` to the
   chunk as its `...`. Nothing here registers a global.

## Wiring

1. `createImGui` builds the ImGui context and three fonts — the grid
   face, the UI face, and a bold UI face for wiring labels — with
   their sizes. A font attaches to a context, so all three are made
   here and threaded to the pages as `gui`.

1. Key autorepeat is set to one repeat per frame (`1/30`). Held arrows
   drive cursor navigation on every page, and ImGui's stock 20/s
   cannot land evenly on REAPER's ~30Hz defer frame: steps fall 1-2-1-2
   frames apart and read as lurching.

1. `ps` (pextStore) comes first: `cm`, `ds` and `eventMeta` all
   persist through it. `cmgr` takes `cm`, and `coord` takes all four
   plus `gui`.

1. The five pages then register with the coordinator by module name —
   wiring, arrange, tracker, sample, editor. First registered becomes
   active, so Continuum boots into wiring.

1. `wp:enableLive()` puts the wiring graph under live recompile, and
   reconciles REAPER's routing against the persisted graph once.

1. `ap:seedCursorFromReaper()` seeds arrange's cursor from the
   selected take, else REAPER's edit cursor. Arrange is inactive at
   boot, but a later switch then lands somewhere sensible.

1. Each page instantiates its own manager column, and continuum names
   the module and nothing more. Every page is constructed with the
   coordinator's `STD` affordance set — see `docs/coordinator.md §
   Pages`.

## Global commands

1. Every global command binds on cmgr's root scope, so each page
   inherits it unchanged: transport, undo and redo, page switching,
   the two editor entries, quit, the FX-window toggle, the prefix key
   and the profiler.

1. Undo refuses to rewind past an **undo fence** — the top of REAPER's
   undo stack at the moment Continuum opened, or nil if the stack was
   empty. Continuum cannot drop a sentinel of its own, since
   `Undo_OnStateChange` adds no entry without a real diff, so what is
   already there serves instead.

1. The fence guards Continuum's own Ctrl-Z only. REAPER's own undo
   bypasses it, by design.

1. Undo and redo both fire a REAPER action mid-frame and so call
   `coord:reloadAfterExternalMutation` — see `docs/coordinator.md §
   Undo mid-frame`.

1. F11 toggles the floating FX windows. The first press stashes the
   GUIDs of everything currently floating, master included, and closes
   them; the next press re-floats exactly that set.

1. Hiding what is open always wins: the restore branch runs only when
   nothing floats. A window the user opened by hand thus cannot be
   read as hidden state.

1. Root is not the only scope continuum writes to. `returnToArrange`
   binds on the tracker scope, since each page owns what Enter does —
   arrange dives, tracker returns.

## Keys

1. Labels and keys are declared per scope in `manifest.lua` — see
   `docs/commandManager.md § Manifest`.

1. `cmgr:installManifest` writes each entry's keys into its scope's
   keymap.

1. `cmgr:installTree` follows, resolving each pathed entry against the
   menu tree the manifest declares — see `docs/commandManager.md § Menu
   tree`.

1. `cmgr:loadOverrides` then overlays the persisted user rebindings,
   so a rebinding beats the declared default.

1. `cmgr:auditManifests` closes the wiring: every scope's entries and
   registrations must now correspond, and a scope that registers a
   command must declare a manifest.

1. ImGui delivers keys only while Continuum holds focus, which a
   floating FX window takes away. `toggleFxWindows` is therefore also
   registered as an external command, reachable from REAPER's own
   keymap — see `docs/coordinator.md § External commands`.

## Error handling

1. `run(fn)` clears the REAPER console, then `xpcall`s its argument
   through `err_handler`. That covers construction, wiring, and the
   first frame.

1. `err_handler` writes the message and the traceback to the console,
   then queues an empty `reaper.defer`. The empty defer keeps the
   script alive rather than letting REAPER unload it the moment the
   handler returns.

1. The defer loop cannot inherit that `xpcall`.
   `coord:run(err_handler)` threads the same handler into the
   coordinator instead — see `docs/coordinator.md § Error surface`.

## Shutdown

1. `quit` sets the flag that stops the loop rescheduling. There is no
   teardown path beyond that — see `docs/coordinator.md § Render
   loop`.

1. One thing does have to be undone first. `quit` calls the tracker
   façade's `restorePerfFlags`, which re-enables anticipative FX on
   the guarded track — see `docs/trackerManager.md § Anticipative-FX
   guard`.
