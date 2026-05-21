# arrangePage

Page wrapper for the arrange view. Mirrors `samplePage`'s shape: owns
no persistent state, constructs its substack (`am` + `av`) internally,
exposes the standard Page interface to `coordinator`.

## Project-wide, so bind is a no-op

The tracker page rebinds whenever the user selects a different MIDI
item; the sample page rebinds whenever the picker changes track.
Arrange has neither — the page shows every track of the project, all
the time. `bind` accepts (and ignores) any argument coord chooses to
hand it; `unbind` does nothing. cm is not re-keyed, which means
switching to arrange and back never disturbs the tracker take or the
sampler track context.

The contract on `coord:setActive` documents this explicitly: tracker
binds to `currentTake`, sample binds to `samplerTrack`, arrange binds
to nothing.

## Separate cmgr scope, overlapping command names

The cursor commands live in `cmgr:scope('arrange')` and reuse the
tracker scope's names (`cursorUp` / `cursorDown` / `cursorLeft` /
`cursorRight`). This is safe because cmgr scopes don't stack — only
one scope is active at a time, and coord pushes/pops on page switch.
Reusing the names rather than coining `arrangeCursorUp` keeps the
key-binding table small and means the user's mental model ("arrow
keys move the cursor") carries unchanged across pages.

The same trick is already in use between tracker and sample.

## Render-only

All cell content the page paints is derived per-frame:

- track list and slot palette come from `am`, which reads cm and
  REAPER on each query;
- cursor position and scroll come from `av`'s module-locals;
- visible row count is computed from the live content region every
  frame and pushed back to `av:setGridSize` so `followViewport` has
  the right bounds.

The page itself caches nothing across frames. The cost is one
`projectTracks()` walk per draw — cheap, and the alternative (a cache
invalidated by some signal we'd have to choose) costs more than it
saves at this stage. If profiling later argues otherwise, the cache
belongs in am, not here.

## What's deferred

Phase 2 ships the read-only grid with cursor navigation only. The
right-side palette (phase 3), base36 placement scope (phase 4),
take-edit commands (phase 5), the tracker dive hotkey (phase 6), and
mouse drag (phase 7) all land in subsequent phases per
`design/arrange.md`. The current `renderBody` paints a `>` at the
cursor cell and a `|` down the focused column so the navigation is
visible; that placeholder is replaced as the placement and palette UI
arrive.
