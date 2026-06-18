# coordinator

Mediator between the entry point and the two pages. It owns the render loop, the active take, and the active sampler track — state that neither page should poll for independently.

## Take ownership

The tracker page needs a MIDI take to render, but the take isn't known at construction time: REAPER hands it to us via selection events that arrive asynchronously. The coordinator polls `GetSelectedMediaItem` on every tracker-page frame and binds the page only when the take actually changes. Selection of a non-MIDI item or no item is silently ignored — the coordinator is sticky, holding the last valid take rather than resetting the page to an empty state. This is deliberate: working on a MIDI item, clicking elsewhere to check something, then clicking back should not disrupt the edit session.

## Sampler track

The sample page is bound to a specific sampler track. The coordinator holds the reference so `setSamplerTrack` (called by the track picker in samplePage) can re-bind without samplePage holding a self-reference to the coordinator. On first sample-page activation the coordinator seeds the default from `pages.sample:listTracks()`.

## Render loop

The loop is a bare `reaper.defer` chain. Each frame reschedules itself before returning. `coord:quit()` sets a flag that prevents rescheduling; REAPER then reclaims all Lua state on script unload. There is no explicit teardown path — adding one would encode assumptions about destruction order that REAPER does not guarantee.

## Error surface

Errors in the defer loop propagate to the same `xpcall` frame in `continuum.lua` that started the loop, because each iteration is a new closure passed to `defer` rather than a tail call. The handler in `continuum.lua` prints the traceback and schedules a no-op defer to cleanly exit the loop.

## Toolbar band height

The toolbar row (page switcher + the active page's bits) wraps to a
second line when the window is too narrow to hold it on one row. The
band is a child with `ChildFlags_AutoResizeY` so it grows to fit.
Auto-resizing windows decide their size at `BeginChild` from the
*previous* frame's content, so on the frame the wrapped row-count
changes — a page switch, or a resize crossing the wrap threshold — the
band is still the old height: it clips the new second row and holds the
body up, then catches up one frame later, so the body visibly jumps.

To land everything in place on the first frame, the coordinator
pre-measures. On a page switch it renders the row once into a hidden
(`Alpha 0`) throwaway child at the same inner width, reads the
wrapped content height from the segment rects `chrome.toolbar` recorded,
restores the cursor, and pins the visible child to that height with
`SetNextWindowContentSize`. Warm frames skip the measure and let
`AutoResizeY` carry the unchanged height. The hidden child has its own
ImGui ID scope, so the doubled widgets never collide with the real ones.
The whole row — the page switcher plus the active page's segments — is
one `chrome.toolbar` segment list, so chrome records a rect per segment.
The pinned height is the lowest segment-rect bottom minus the content
top. The switcher is always the first segment, so even a page with no
toolbar bits of its own (wiring) records a rect, and the band shrinks
(tracker → wiring) as well as grows.

Width changes deliberately skip the pre-measure. Re-rendering the page's
segments a second time re-executes any that open a popup (`drawPicker`
with an open list), beginning that popup twice in one frame — which
corrupts the window stack and asserts at the next `EndChild`. A resize
fires the measure branch every frame and would hit this; a page switch
first closes any open picker (focus loss), so its second render is
side-effect-free. On a width change the row still wraps correctly against
the current width, so only the band height trails one frame, which
`AutoResizeY` absorbs.

## Façade registry

`coord` owns the wiring between pages: each page publishes its own
domain-state interface and reads peers via the injected façade.
`STD` is the affordance set every page is constructed with;
per-page extras merge over it in `register()`. See `docs/pageFacade.md`
for the full façade contract.

## Test wiring for newCoord

`register` instantiates the page by module name. In specs, stub each
module name to the fake page via `util._stubs` (the `instantiate` test
seam) so `register` exercises its real path. Stubs are cleared
immediately after the pages are constructed.
