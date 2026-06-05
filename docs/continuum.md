# continuum

Entry point. Loads every module, wires the layered manager stack,
and drives the render loop via `reaper.defer`.

## Module loading

`loadModule(name)` is a thin `require` wrapper that resolves paths
relative to the script's own location (via `debug.getinfo`), so the
script loads the same way regardless of REAPER's current working
directory. Each module registers a global on load (`util`,
`newMidiManager`, etc.) — there are no return values to capture.

Load order is bottom-up through the layered stack:

```
util → configManager → midiManager → trackerManager
     → commandManager
     → editCursor → trackerView
     → sampleManager → sampleView
     → swingEditor → curveEditor
     → trackerPage → samplePage
```

`util` comes first because everything else calls `util.installHooks`
during construction. `commandManager` loads before any view layer
because views and pages self-register commands at construction time.
`editCursor` loads before `trackerView` because tv constructs ec
from `newEditCursor`. The two floating editors (`swingEditor`,
`curveEditor`) load before `trackerPage` because tp owns them.
Pages load last; they wire everything beneath them into the
coordinator.

## Two stacks, one coordinator

The script has two parallel page stacks — tracker and sample — each
with its own manager column (mm/tm/tv vs sm/sv) and its own command
scope. They share a single ImGui window, a single toolbar/status
band, and a single keychain.

The coordinator owns the shared frame. Pages register with it;
`coord:setActive(name)` swaps the cmgr scope and rebinds the
incoming page (`tracker` to the take, `sample` to the take's
track). Each frame draws the toolbar, delegates the body region to
the active page and draws the status band.

Chrome lives on the coordinator and is threaded into every page;
one chrome instance per coordinator.

## Wiring

`Main()` runs once per invocation:

1. Look up the selected media item; bail with a console message if none.
2. Take the item's active take.
3. Build managers bottom-up:
   - `mm`, `cm`, `tm`, `cmgr` — straightforward chain. `cm:setContext`
     runs after construction so the four-tier cache refreshes
     against the current take.
   - `tv = newTrackerView(tm, cm, cmgr)` — registers tv's editing
     commands; constructs `ec` and `clipboard`, which then
     self-register their own navigation / clipboard commands via
     `:registerCommands(cmgr)`.
   - `sm = newSampleManager(fileOps)` — sampler-JSFX bridge. Pure
     file ops (`copy`, `move`, `mkdir`, `exists`, `hash`) are
     injected from continuum so the manager stays REAPER-agnostic
     above the fs boundary.
   - `sv = newSampleView(cm, …)` — browser state. Slot operations
     forward to sm through closures that pass `sv:getTrack()` at
     call time, so sv never holds an sm reference.
4. Construct ImGui, then the coordinator
   (`newCoordinator(cm, cmgr, sm, take, ctx, font, uiFont)`).
5. Register global commands on cmgr root: transport
   (`play` / `playPause` / `stop`), page switching (`switchPage`,
   `togglePage`), `quit`. Living on root means every page inherits
   them unchanged.
6. Register `trackerPage` and `samplePage` with the coordinator.
   First registered becomes the initial active page.
7. `coord:run()` enters the defer loop.

## Per-frame tick

Before each page draws, the coordinator runs `tick()`:

- `sm:probeMode(take, cm)` writes `transient.trackerMode` from the
  track's FX list — true iff an FX name contains `'Continuum
  Sampler'`. The probe writes only on change so `configChanged`
  doesn't fire every frame.
- The project path is sampled. On change, `sm:setPrefix`
  republishes the prefix mailbox and `sm:migrate` runs against the
  previous path; both are no-ops on the first frame.
- `sm:tick(cm)` drains the gmem mailboxes.

The order is fixed: probe → setPrefix/migrate → tick. `setPrefix`
must precede `tick` because tick assumes the prefix is current.

## Error handling

`run(fn)` clears the REAPER console, then `xpcall`s its argument
through `err_handler`. On error: the message and traceback are
written to the console, and an empty `reaper.defer` is queued to
keep the script alive long enough for the user to read the console
before REAPER unloads it.

Errors inside the defer loop surface the same way — the
coordinator's frame runs under the same outer `xpcall`, because
each iteration schedules itself via `reaper.defer(frame)`.

## Conventions

- **One MIDI item per session.** The script binds to the take at
  startup; changing REAPER's selection mid-session does not re-bind.
  Re-invoke the action to pick up a new item.
- **No teardown.** `coord:quit()` sets a flag that the defer loop
  reads at end of frame and uses to stop scheduling further frames.
  REAPER reclaims state on script unload.

## Arrange → takeProperties delegation

Arrange's `takeProperties` and `dup-unpooled-below` commands open
the tracker page's takeProps modal on a take that may not be
tp's current bind. The handler snapshots tp's current take, points
tp at the target take for the modal's lifetime, then restores on
close. `tp:openTakeProperties` fires `onClose` exactly once after
the whole modal chain (including any truncate-confirm). `tp` is
forward-declared: coord constructs it when `'tracker'` is
registered, and `onTakeProperties` only fires at command time, by
which point `tp` is bound.
