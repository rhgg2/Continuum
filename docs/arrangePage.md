# arrangePage

Page wrapper for the arrange view: render and input only. It draws the
grid and palette, reads keyboard and mouse, and exposes the standard
Page interface to `coordinator`. It constructs `av` (which builds
`am`), holds no persistent state, and keeps no am reference — all
project data and all state operations go through av.

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

## Separate cmgr scope

The arrange commands live in `cmgr:scope('arrange')`; coord pushes the
scope when the page activates and pops it on the way out. Scopes don't
stack — exactly one is active — so the arrow keys can mean "move the
arrange cursor" here and "move the tracker cursor" elsewhere with no
collision.

The names are arrange-prefixed (`arrangeCursorUp`, not `cursorUp`)
even though the keys match the tracker scope's. `cmgr`'s command table
is flat: a shared name would overwrite the other scope's gate. Reuse
the keys, not the names.

Registration is split along the render/operation line. av registers
the command *bodies* — it owns what they do. The page registers the
*key bindings*: it holds the ImGui key constants, and mapping a key to
a command name is an input concern. The page also registers
`createSlot`, the one command whose body belongs here because it opens
the page's modal.

## Render + input only

Every cell the page paints is derived per-frame, and all of it comes
from `av` — the page holds no am reference:

- track list and slot palette come through `av`'s am proxies, which
  read cm and REAPER on each query;
- cursor position, scroll, and the focused-take handle are `av`'s
  state;
- visible row count is computed from the live content region every
  frame and pushed back to `av:setGridSize` so `followViewport` has
  the right bounds.

The page caches nothing across frames. The cost is one
`projectTracks()` walk per draw — cheap, and the alternative (a cache
invalidated by some signal we'd have to choose) costs more than it
saves at this stage. If profiling later argues otherwise, the cache
belongs in am.

Input is the page's other half. The keyboard goes through the command
scope; the mouse — clicks, drags, the wheel — is read in
`runGridMouse`, which assembles a `press` gesture and, on release,
calls the matching av operation. The page decides which gesture
happened; av decides what it does to the state.

## Cursor and focus are separate

The grid carries two independent pointers.

The **cursor** is the grid caret — a `(row, col)` position in `av`,
drawn as a horizontal I-beam on the top edge of the cursor row. Moved
only by the keyboard (arrow keys, PageUp/Down, Home/End, the wheel,
and the boot / reveal seeds). The mouse never moves it.

The **focused take** is what the edit commands — nudge, resize,
delete, dive — act on. It is a take, not a cell: `av` stores the
REAPER take handle opaquely and resolves it through `am:findTake`
whenever a command fires. It is set in three ways — a mouse click on
a take focuses it directly; each kb mutation opens with `adoptCursor`,
which reselects the take under the cursor (an empty cell clears
focus, so the mutation no-ops); and the boot / reveal seeds adopt the
take they land on. Plain cursor nav does not touch focus.

The caret shape and the adopt-on-mutate rule line up: cursor position
is a line, not a cell, so what the next command picks is decided at
command time, not at landing time. The visible focus indicator
survives across cursor nav so the user can see what the most recent
mouse click or mutation picked, but it is overwritten the moment the
next kb mutation fires.

Focus self-heals — a handle whose take has been deleted (here or in
REAPER) resolves to nil and clears on the next command.

The word "focus" does triple duty on this page: the *focused track*
is the column under `cursorCol`, the *focused slot* is
`av:paletteSlot()`, and the *focused take* is the pointer above. The
first two are cursor-derived; the take is not.

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
the create modal at the cursor position; the modal asks for a name and
a length in rows (seeded to 4). On commit it calls `av:createSlot`,
which mints the slot through am and points `paletteSlot` at the new
index so the palette highlights it.

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

Shipped: the model, the page skeleton, the right-side palette (slot
list / rename / delete / Ctrl-Enter creation), the base62 placement
scope, the hand-drawn grid, the take-edit commands, the tracker dive
hotkey, mouse drag (move / resize / Alt-duplicate), and the
cursor / focus split.

Still ahead: a *selection* — a set of focused takes, gathered by a
drag-rectangle in empty space or by shift-extending the cursor, that
the edit commands act on as a group. The single-take focus above is
the degenerate case; widening the stored handle to a list is the next
slice.
