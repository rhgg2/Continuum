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
