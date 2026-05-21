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

### Palette buttons

`rename` and `del` act on the focused slot (`av:paletteSlot()`).
`rename` opens an `InputText` modal seeded with the slot's current
derived name. `del` opens a confirm modal — deletion removes every
instance of the slot's source on the track, which always warrants
the extra click. There are no "new slot" buttons; minting is a
keyboard gesture (see below).

### Modal infrastructure

A single popup id (`MODAL_TITLE`) backs all three modals (rename,
create, delete). The `modal` module-local holds `{ kind, ... fields }`
or nil; `renderModal()` dispatches by `kind`. Pinning `(trackIdx,
slotIdx)` (or `(trackIdx, qnPos)` for create) into modal at open-time
means the cursor moving mid-edit can't retarget the action.

`modalOpenAtFrameStart` is captured at the top of `renderBody` and
fed into `focusState`: while a modal is open at frame start,
`acceptCmds` is false so that the Enter committing the modal's
InputText can't leak to root-scope bindings (notably quit) on the
same frame. CloseCurrentPopup deactivates the InputText same-frame,
flipping `IsAnyItemActive` to false before dispatch runs — the
frame-start capture is what closes that hole.

The popup carries `WindowFlags_NoNav` so ImGui's popup-nav doesn't
steal arrow keys from the InputText. `chrome.pushChromeWindow` wraps
Begin/End so the popup inherits parchment/chrome styles.

## Slot creation: Ctrl+Enter

`createSlot` is bound to Ctrl+Enter under the arrange scope. It opens
the create modal at the cursor position; the modal asks for a name
and a length in rows (seeded to 4). On commit, it calls
`am:createAndDropMidi(cursorCol, cursorQN, rows * beatPerRow, name)`
and sets `paletteSlot` to the new index so the palette highlights it.

This is the only slot-minting gesture. There is no separate "declare
a slot" step — a slot has no existence apart from items on the grid
that carry its id. Audio creation waits on a file picker (`del` and
the place commands still handle audio slots that pre-existing REAPER
items materialise; only the *creation* gesture is MIDI-only).

## Place commands (base62 scope)

The arrange scope registers 62 `drop<key>` commands at load — one per
slot index, named with the same base62 alphabet `am:keyForSlot`
emits. Keys map: `0..9` to digit keys, `a..z` to bare letter keys,
`A..Z` to Shift+letter. Pressing a key with no slot defined at that
index is a silent no-op (`am:dropInstance` returns nil); the user
learns the palette is empty there by trying and seeing nothing.

Drops land at `(av:cursorCol(), slotIdx, av:rowToQN(av:cursorRow()))`
with length `av:beatPerRow()` — one visible row. There is no separate
snap setting: the cursor already lives on row boundaries, so drops
are implicitly row-snapped. A real snap selector lands with the
toolbar in a later slice; until then beatPerRow is both the row
density and the default length, which keeps the visible cell and the
dropped rectangle aligned by construction.

Digit keys do not collide with the universal-argument prefix:
`cmgr:beginPrefix` is bound to Super+U and the dispatcher only feeds
digits into `appendPrefix` while `isPrefixActive()` is true. So bare
0–9 are free in any scope unless the user has just typed Super+U.

## Grid is hand-drawn

The grid is not an ImGui table — it is laid out directly into the
window draw list. ImGui tables resist shapes that span rows, which is
exactly what a take rectangle is, and we were already bypassing the
table for header text, row tints, and cursor glyphs. Hand-drawing
unifies the model: one set of screen-space coordinates feeds the
header, the gutter, the row tints, the gridlines, the cursor marker,
and the take rectangles. Mouse hit-testing (phase 7) is then a single
division per axis.

Takes are tinted by slot via golden-ratio hue rotation in HSV: 62
visually distinct hues with no hand-picked palette, and pooled
instances share a hue because they share `slotIdx`. Orphan takes
(slot not in the cm dictionary) get a neutral grey. The label inside a
rectangle is `<slot key> <take name>`, mono font, clipped at the
rectangle edge.

## What's deferred

Phases 1–5b have shipped: model, page skeleton, right-side palette
with slot list / rename / delete / Ctrl-Enter creation, the base62
placement scope, the hand-drawn grid with take rectangles, and the
take-edit commands (move / resize / delete). Still ahead per
`design/arrange.md`: trim-start, the tracker dive hotkey (6), and
mouse drag (7).
