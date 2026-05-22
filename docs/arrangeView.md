# arrangeView

The arrange page's state and the operations on it — cursor, scroll,
grid density, focus, and every command that moves or edits a take. It
sits between `arrangePage` (render and input only) and `arrangeManager`
(the REAPER bridge): av builds am, holds the page state, and is the
only module that calls am.

On the tracker side `editCursor` and `trackerView` split cursor
mechanics from grid mapping across two modules. The arrange grid is
simpler and av keeps both — the split would buy nothing here.

## What persists, what doesn't

Only `arrangeBeatPerRow` rides cm (project tier). Cursor and scroll
are module-locals: re-opening a project lands the cursor at `(0, 0)`
on row `0`, and the density the user last chose is restored. Same
split as `editCursor` (transient) vs the tracker's view-state keys
(persisted) — cursor position is a per-session attention pointer; the
zoom is a project property.

This also keeps `setCursor` a pure mutation of two integers. There is
no cm round-trip on every arrow key, and no `configChanged` storm
through subscribers that have nothing to say about cursor motion.

## av owns am

av builds `arrangeManager` and is the only module that touches it.
`arrangePage` holds no am reference: every project query it draws with
and every mutation it triggers go through av.

This is the layered rule, not a preference. A page reaching past av
into am could mutate project state without av's cursor and focus
bookkeeping ever seeing it. Routing everything through av keeps one
module answerable for the page — focus adoption, the focus self-heal,
the row-box snap policy all live in the same place as the mutations
they constrain.

It costs av its REAPER independence. An earlier design kept am out so
av could be tested without a fake project behind it. That trade no
longer holds: av now *is* the operations, and the operations are
defined against project takes — there is nothing left to test in
isolation from them. The arrange specs build av over the same fake
REAPER the page specs already rely on.

## Focus: stored and resolved here

`focus` is the REAPER take handle the edit commands act on — per-session
view state beside the cursor. av stores it opaquely and resolves it on
demand: `focusedTake` turns the handle into a live take-shape through
`am:findTake`, and clears focus when the take is gone (deleted here or
in REAPER). Storing a handle rather than a grid position means a take
moved or resized under it still resolves correctly.

Cursor and focus are separate pointers, and that is deliberate. The
cursor is the keyboard caret; focus is a take. Focus persists when the
cursor moves on across empty space — a keyboard move that lands on a
take adopts it (`placeCursor`), a move across a gap leaves focus
intact. That is what makes "park the cursor, the take stays picked"
true, and what lets a nudge move the focused take while the cursor
sits elsewhere.

## Viewport follow

`followViewport` runs on every cursor mutation and on every
`setGridSize`. Bias is leading-edge: the cursor pulls the band along
with it but the band doesn't drift on its own. Shrinking the viewport
re-runs the follow in place, so a window resize never strands the
cursor off-screen.

The clamp form (`clamp(scroll, max(0, cursor − grid + 1), cursor)`)
collapses both directions into one expression: if the cursor leaves
the band on either side, scroll snaps just enough to bring it back —
otherwise it sits where the user left it.

## beatPerRow as the only QN bridge

`qnToRow` and `rowToQN` are the only places QN meets row units, and
they go through `beatPerRow` rather than threading a constant. The
arrange page draws QN labels in its gutter column by calling
`av:rowToQN(row)` per visible row; no other module needs to know the
density. Minimum is `1/4` (one row per sixteenth note) — clamped at
the setter so the inverse never divides by zero.
