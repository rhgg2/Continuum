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

## Right-side palette

The body splits into two children: a variable-width grid pane on the
left and a fixed 200 px palette pane on the right. The fixed width is
deliberate — the grid is the focus, and a draggable splitter would add
mechanics (drag state, persisted width) without earning its keep at
this stage.

The palette always shows slots for the **focused track**, which is
just the track under `av:cursorCol()`. There is no separate
focused-track pointer — moving the arrange cursor left/right
re-targets the palette as a side-effect. This is the same one-pointer
discipline as the tracker view, scaled down: the cursor names "what
the user is looking at" and everything else derives.

The **focused slot** within the palette is a separate pointer
(`av:paletteSlot()`) because rename and delete need to act on a slot
even when the cursor lives in the grid. It's per-session
module-local, set by clicking a row in the palette, cleared with
`setPaletteSlot(nil)`. Same persistence model as the grid cursor —
not a project property, just a UI attention pointer.

### Rename modal

`rename` opens an `InputText` modal seeded with the slot's current
derived name. The `(trackIdx, slotIdx)` is captured at click time into
`renameRequest` so the modal acts on the slot the user pressed rename
for, even if the arrange cursor moves while the modal is open. The
modal commits on Enter (via `InputTextFlags_EnterReturnsTrue`, which
is correct here because we only consume the buffer on commit) and
dismisses on Esc or Cancel. The popup carries `WindowFlags_NoNav` so
ImGui's popup-nav doesn't steal arrow keys from the InputText — see
the reaimgui-gotchas notes.

### Stubbed buttons

`+♪` (new audio slot) and `del` (delete slot) are present but
disabled. Audio waits on a file picker — we don't add
`js_ReaScriptAPI` just for this phase; integration with the sample
page's existing tree picker is the better path. Delete waits on the
mouse/placement phase that also brings the "remove instances?"
question into focus. Both render as disabled buttons with explanatory
tooltips so the UI shape is visible and the design intent is on
screen.

## What's deferred

Phase 2 shipped the read-only grid with cursor navigation. Phase 3
adds the palette pane, slot list, new-MIDI-slot, and rename. Still
ahead: base36 placement scope (phase 4), take-edit commands (phase 5),
tracker dive hotkey (phase 6), and mouse drag (phase 7) per
`design/arrange.md`. The current `renderGrid` paints a `>` at the
cursor cell and a `|` down the focused column so navigation is
visible; that placeholder is replaced as the placement UI arrives.
