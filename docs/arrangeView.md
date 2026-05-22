# arrangeView

Viewport for the arrange page — cursor, scroll, and grid density.
Counterpart to `trackerView`'s viewport role on the tracker side,
deliberately the same shape so the keyboard model transfers.

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

## Why am isn't a constructor dep

av speaks no REAPER and no am. Bounds — track count, project end row
— are the caller's responsibility because the same view module needs
to be testable without a fake REAPER project standing behind it. The
spec just drives `setGridSize` + `setCursor` and reads `scroll()`
back; arrange_page is the only caller that joins av to live project
data, and it does the join at the render site rather than threading
am into av's construction.

## Focus is stored here, resolved by the page

`focus` joins the cursor as per-session view state — the take the
arrange page's edit commands act on. av holds it as an opaque REAPER
take handle and never dereferences it: turning a handle back into a
grid position needs am, which av does not have. So `setFocus` is a
bare store and `focus` a bare read — the page does the resolving, and
the self-heal when the take is gone. It is the same boundary the
section above draws: av carries view *state*, not the project
knowledge needed to interpret it.

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
