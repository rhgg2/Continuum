# coordinator

**The coordinator holds precisely what all pages share**: the render
loop, the window and its two chrome bands, the singletons every page
is constructed with, and the registry through which pages read each
other.

## Pages

1. `register(name, moduleName, extra)` instantiates the page by module
   name, and returns the handle. The first page registered becomes
   active.

1. `STD` is the affordance set every page is constructed with: `cm`,
   `ds`, `eventMeta`, `cmgr`, `chrome`, `gui`, `modalHost`, `help`,
   `keyQueue`, `facade` and `lib`. A page needing anything else names it in
   `extra` at the registration site.

1. A page is anything answering `toolbarSegments`, `renderBody`,
   `statusSegments`, `bind` and `unbind`.

1. A page module is a controller: it builds its own stack and delegates
   every render call to a companion renderer. Where the stack has a
   view layer, the renderer is handed that and never the manager, so
   the drawing half cannot reach past the view.

## Activation

1. `setActive(name)` unbinds the outgoing page, resets the shared
   toolbar, and pops the outgoing command scope; it then pushes the
   incoming scope and binds the incoming page. Scope and binding move
   together.

1. An open menu closes first, since its scope sits above the page's
   and travel reaches its command through the walk (`docs/menu.md`
   § A modal scope).

1. `previousPage` reports the page displaced by the last switch.
   `returnToArrange` is the tracker's fixed exit, and no-ops when
   arrange is not registered.

## The frame

1. Each frame runs in a fixed order: fill the key queue, poll the undo
   mirror, poll the external commands, poll the floating-FX set,
   `tick`, then draw.

1. The key queue fills before anything is drawn, so what a reader
   claims is what arrived.

1. The fill settles which reader owns the keyboard for the frame: the
   cheat sheet, an open picker, a status cell holding an open field,
   and an open modal, in that precedence. A popup raised over a modal
   is nearer the user than the modal, so it takes the keyboard.

1. `tick` is the pre-draw beat for the pages that need one — the sample
   page, wiring's external resync while wiring is active, and the
   bridge. There is no selection bus.

1. Drawing goes toolbar band, body, the open menu's row over the body's
   last row (`docs/menu.md § The walk`), status band, then the help
   overlay and any modal above them. The band layouts belong to chrome
   — see `docs/chrome.md § Toolbar layout` and `§ Status bar layout`.

1. The body is the window less the two bands, indented by the chrome
   padding; the status band is pinned to its bottom edge. The
   parchment gap above the status band is whatever the page did not
   fill.

1. The window scrolls back to the origin every frame. An active-item
   drag — the lane strip's curve editor, for instance — otherwise
   accumulates auto-scroll on the parent window and pushes the grid
   out of view for the length of the drag.

1. `dispatch`, threaded into `renderBody`, is the route from keys to
   the command manager, and carries the page's own focus state. Behind
   an owner its claims answer nil, so no command fires — see
   `docs/keyQueue.md § Ownership`.

## Boot warm-up

1. Content is withheld until four frames have passed and the available
   width matches the frame before.

1. Both terms are needed: ReaImGui builds its font atlas over the
   first frames, and the width keeps moving until REAPER has finished
   placing the window.

1. The gate latches once satisfied and never re-arms.

## Render loop

1. The loop is a bare `reaper.defer` chain, each frame rescheduling
   itself before returning.

1. `coord:quit()` sets a flag that prevents rescheduling; REAPER then
   reclaims all Lua state on script unload.

1. There is no explicit teardown path — adding one would encode
   assumptions about destruction order that REAPER does not guarantee.

## Error surface

1. Errors in the defer loop do not reach the `xpcall` in
   `continuum.lua` that started it: `reaper.defer` drops the
   surrounding handler.

1. `coord:run` therefore takes that handler and holds it, and each
   scheduled frame calls `xpcall(frame, errHandler)` itself. A fault
   on frame 40 thus surfaces the same way as one on frame 1 — see
   `docs/continuum.md § Error handling` for what the handler does with
   it.

## Undo mid-frame

1. A mid-frame reload of the take must resync the projext mirror
   first. Hence the `cm:pollUndo()` at the head of
   `reloadAfterExternalMutation`, before it delegates to
   `pages.tracker:reloadFromReaper()`.

1. A REAPER undo rewinds two things unevenly. The take's MIDI it
   rewinds itself; the note metadata — authored tails, uuids — lives in
   projext, which undo does not touch. That metadata comes back only
   when `pollUndo` copies it from the mirror, described in
   `docs/pextStore.md § The mirror (projext undo)`.

1. `frame()` calls `cm:pollUndo()` at the top, so the everyday path is
   safe: REAPER's own Ctrl-Z lands between frames, the metadata is
   rewound first, and the tracker page's take-hash watcher then
   reloads against a coherent pair.

1. Continuum's own Ctrl-Z does not land between frames. It fires from
   inside the page's dispatch and reloads the take immediately, which
   is what `reloadAfterExternalMutation` is for.

1. Any caller mutating the take mid-frame — including the bridge's
   raw-edit path — inherits the same hazard and the same fix.

## External commands

1. Companion REAPER actions set `ExtState('Continuum', key)`.

1. `onExternalCommand(key, command)` registers the pairing. Each frame
   consumes any key that is set, deleting it and invoking its command.

1. This is the route for keys that must work while a floating FX
   window holds focus, where ImGui delivers none — see
   `docs/continuum.md § Keys`.

## Focus reclaim

1. Closing the last floating FX window leaves focus with REAPER rather
   than Continuum. While Continuum lacks focus it polls the set of
   floating FX windows across the master and every track, and reads
   the open→closed edge as the last one having been dismissed.

1. Reclaiming takes two grabs, held for two frames:
   `SetNextWindowFocus` before `Begin` for ImGui's internal focus, and
   `JS_Window_SetForeground` for the OS. The HWND is cached while
   Continuum holds focus, since `JS_Window_GetForeground` reports
   someone else's window once it does not.

1. All of this is conditional on js_ReaScriptAPI being present.
   Without it the poll never runs, and focus stays where REAPER put
   it.

## Toolbar band height

1. The toolbar row wraps when the window is too narrow to hold it; see
   `docs/chrome.md § Toolbar layout` for how the wrap is decided.

1. The band height is pinned to the standard toolbar frame height ×
   the line count, plus the spacing between lines.

## Pre-measuring a switch

1. `chrome.toolbar` counts the wrapped lines during layout, so the
   count known at the start of a frame is the previous frame's. On the
   frame the row count changes it is stale, clipping the new row and
   jumping the body.

1. On a page switch the coordinator therefore renders the row once
   into a hidden (`Alpha 0`) throwaway child at the same inner width,
   then restores the cursor. That refreshes the line count before the
   band height is computed from it.

1. Chrome runs a cold-frame pre-measure of its own, but from inside
   `toolbar()` — too late for a height computed before the draw.

1. The hidden child has its own ImGui ID scope, so the doubled widgets
   never collide with the real ones.

1. Width changes deliberately skip the pre-measure. Re-rendering the
   page's segments would re-execute any that open a popup (e.g.
   `drawPicker` with an open list) corrupting the window stack and
   asserting at the next `EndChild`.

1. On a width change the row still wraps correctly against the current
   width, so only the line count trails a frame.

## Façade registry

1. `coord` owns the wiring between pages. Each page calls
   `facade.publish` with its own interface onto the state it owns, and
   reads its peers through the same `facade`, handed to it in `STD`.

1. `getFacade(name)` resolves one by name, and an unpublished name
   raises.

1. `publishDebug` is a second registry, holding raw page stacks for
   the bridge's eval environment. It is a labelled hole in the
   layering rule — diagnostics, not a production surface. See
   `docs/bridge.md § The eval environment`.

## Test wiring

1. `register` instantiates the page by module name, so a spec stubs
   each module name to a fake page through `util._stubs`, the
   `instantiate` test seam. `register` then runs its real path.

1. The stubs are cleared as soon as the pages are constructed.
