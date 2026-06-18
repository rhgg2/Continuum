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

The toolbar row (page switcher + the active page's segments) wraps to a
second line when the window is too narrow to hold it on one row.

The band height is pinned to `lineCount × canonicalRowHeight`, not left
to content-fit `AutoResizeY`. Content fitting made the height vary per
page: a row mixes framed widgets (`FrameHeight`) with `chrome.checkbox`/
`radio`, which run at zero `FramePadding` plus a +3px nudge — a different
height — so the tallest widget, and the band with it, shifted with each
page's widget mix. The canonical row is the standard toolbar frame height
(page-independent), so every line is exactly one frame tall and the band
reads identical across pages; wrapping still grows it by whole rows.
`chrome.toolbar` counts the wrapped lines during layout and exposes the
count.

The line count is read from the *previous* frame's draw, so on the frame
the wrapped row-count changes — a page switch, or a resize crossing the
wrap threshold — it would be stale for one frame, clipping the new row and
jumping the body. On a page switch the coordinator pre-measures: it renders
the row once into a hidden (`Alpha 0`) throwaway child at the same inner
width, which warms the segment widths and refreshes the line count, then
restores the cursor. The hidden child has its own ImGui ID scope, so the
doubled widgets never collide with the real ones. The switcher is always
the first segment, so even a page with no toolbar bits of its own (wiring)
lays out and stays the same height as the rest.

Width changes deliberately skip the pre-measure. Re-rendering the page's
segments a second time re-executes any that open a popup (`drawPicker`
with an open list), beginning that popup twice in one frame — which
corrupts the window stack and asserts at the next `EndChild`. A resize
fires every frame and would hit this; a page switch first closes any open
picker (focus loss), so its second render is side-effect-free. On a width
change the row still wraps correctly against the current width, so only
the line count trails one frame.

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
