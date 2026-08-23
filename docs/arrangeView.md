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
into am could mutate project state without av's cursor and selection
bookkeeping ever seeing it. Routing everything through av keeps one
module answerable for the page — action-target resolution, the
selection self-heal, the row-box snap policy all live in the same place
as the mutations they constrain.

It costs av its REAPER independence. An earlier design kept am out so
av could be tested without a fake project behind it. That trade no
longer holds: av now *is* the operations, and the operations are
defined against project takes — there is nothing left to test in
isolation from them. The arrange specs build av over the same fake
REAPER the page specs already rely on.

## Selection: a set, stored and resolved here

The selection is a per-session set of REAPER take handles the edit
commands act on — view state beside the cursor. av stores the handles
opaquely and resolves them on demand: `selectedTakes` turns each handle
into a live take-shape through `am:findTake` and prunes any whose take
is gone (deleted here or in REAPER). Storing handles rather than grid
positions means takes moved or resized under the selection still
resolve correctly. `setFocus`/`focus` are single-element conveniences
over the same set, for the mouse path and the unpooled duplicate.

Cursor and selection are separate pointers, but the caret leads. The
cursor is the keyboard caret — drawn as a horizontal I-beam on the top
edge of the cursor row; the selection is a set of highlighted takes.
Bare cursor nav — arrows, page, Home, End — clears the selection, so an
edit after an arrow key always acts where the caret is rather than on a
block left standing somewhere off-screen. Shift+arrow is the exception,
and builds the selection out of the caret's own travel.

The caret also moves as part of an edit: nudge and shrink follow the
take, a drop advances the caret, duplicate lands on the copy.
Those moves keep the selection, and go through `moveCursorBy` rather
than the `navCursorTo` the nav commands use. They are consequences of
an edit, not navigation, and clearing there would undo the focus the
unpooled duplicate has just set.

Ctrl-` picks between the two readings of that drop advance. The
default is a fixed step of `arrangeAdvanceBy` rows, set by Ctrl+digit;
armed, the caret advances by the length of the take that just landed,
so a run of drop keys lays takes end to end whatever their lengths.
That length is the clipped one — a take truncated by its downstream
neighbour advances the caret only as far as it sounds. The fixed step
survives the toggle, so Ctrl+digit still sets what the caret goes back
to.

The pooled duplicate (Ctrl-D, Alt+Shift+↓) ends with nothing selected:
the copy lands, the selection clears, and the caret advances onto the
copy. The caret alone therefore carries a run of presses down the track,
each duplicating the copy the last one made — a held selection would
pin every press to the same source and refuse for want of room.
The variant step (Alt+Shift+←/→) moves neither, the slot stepped onto
standing exactly where the source stood; the source's handle prunes
itself from the selection when the take goes.

Selection is decoupled from action. An edit command resolves its
targets through `actionTargets`: the whole selection if one is held,
otherwise the single take under the cursor — acted on without becoming
selected. With nothing selected and the cursor parked off-screen (only
a wheel-pan can strand it there), there is no target and the command
no-ops. Boot lands the cursor on REAPER's selected item but selects
nothing (`seedCursor`).

The unpooled duplicate always ends in the name prompt. Where the free
span at the append point falls short the clone parks on the scratch
track (`docs/arrangeManager.md` § The append point), and take-properties
opens on the parked item; only the focus move and the cursor advance
need it on the grid.

Single-take commands — dive, take-properties, duplicate-below, the
variant step — go
through `singleTarget` and no-op unless exactly one take is targeted:
you can't dive into five takes, and a duplicate has one copy to advance
onto. Group commands — nudge, resize, delete — act on every target in
one undo block. Nudge is all-or-nothing: it pre-checks the whole group
against `am:moveTake`'s occupied-start rule and refuses the move if any
member is blocked, then applies the moves in travel order so a
contiguous block never collides with an unmoved member.

### Keyboard selection

Shift+arrow selects by the lasso's rule, with the rect drawn by keys
rather than swept by the mouse. The first press of a run pins an anchor
at the cursor cell; each press then moves the cursor and replaces the
selection with the takes the anchor→cursor rect covers. Both end cells
are covered whole, so a run grows a block; a press back towards the
anchor drops the takes it uncovers.

The rect paints as a rubber band — the same one the lasso draws — and
it stands as long as the run does. What takes it down is cmgr's
spring-loaded dispatch rather than a list of commands kept here: arming
pushes a scope whose `keepAlive` holds just the four Shift+arrow
commands, so the first command that isn't one of them bails the scope,
and the band goes with it. The selection the band built stays behind —
unless what bailed the scope was a bare cursor move, which clears the
selection as well as the band.

The mouse never reaches dispatch, so a click or a lasso drops the
anchor itself and leaves the spent scope for the next command to pop; a
cursor move drops it the same way, whether from an arrow key or the
advance after a drop. Leaving the page takes the band down too, so the
scope never outlives the page that armed it, and the next Shift+arrow
re-anchors wherever the caret then sits.

### Lasso

A left-drag from empty grid space — including the dead space to the
right of the last track column — sweeps a rubber-band rectangle;
`lassoCandidate` returns every take whose span intersects it, and the
release replaces the selection with that set. A plain click (no drag)
on empty space moves the cursor and clears the selection; a click on a
take selects just that one. Holding Shift makes a gesture additive: a
Shift+click on a take toggles its membership, a Shift+lasso unions the
swept takes into the selection, and a Shift+click on empty space keeps
the selection (only the cursor moves). Without Shift, lasso and click
both replace — Ctrl+G clears.

Shift keeps its positioning role on a *drag*: dragging a take with Shift
held frees it from the row grid. The additive meaning applies only to
clicks and lassos, which don't snap, so the two never collide.

Grabbing any *selected* take with the mouse drags the whole selection as
a rigid block — one uniform time-shift, each take staying on its own
track, snapped by the grabbed take. Ctrl-drag duplicates the block instead
and reselects the copies. Grabbing an *unselected* take first collapses
the selection to it, so it's an ordinary single-take drag. A move refuses
if any member's destination start is occupied; a duplicate's copies must
also clear the originals that stay behind.

The caret rendering and the cursor fallback are the same idea: cursor
position is a line, not a cell. With nothing selected, what a command
picks is decided at command time from where the caret sits — and only
when the caret is actually on screen.

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

## Cursor nav: no upper bound, clamped on negatives only

Cursor nav steps by whole rows and columns — arrows ±1, PageUp/Down
±`PAGE_ROWS`, Home to row 0, End to the row of `am:projectEndQN`. Only
negative coordinates clamp (in `setCursor`), so PageDown, End, and the
wheel may park the cursor on empty rows past the last take.

Tab and Shift+Tab step between the stop rows of the cursor's own
column: the start row of each instance, and the first free row after
it. Where takes abut the two coincide and collapse to one stop, so a
solid run costs one press per take; a gap earns a stop of its own,
which is where the next drop would land.

Both ends hold rather than wrap, matching the rest of cursor nav. Only
stops strictly past the cursor row count, so Shift+Tab from inside a
take goes to that take's own start before moving on — the snap you
want when a nudge has left you mid-item.

## Nudge and resize

Nudge steps one row at a time. The only block is a head-on collision:
destination start == another take's start on the same track. Later
takes truncate earlier ones in the rendered frame, so passing through a
neighbour is fine — `am:moveTake` handles the relayout.

Resize moves one edge in the direction of the key: `arrangeEdgeDown`
walks the armed edge down the grid, `arrangeEdgeUp` walks it up. The
**armed edge** is the head when the caret stands on a target's start
row, and the tail everywhere else. A midpoint rule — nearest edge wins
— would tie on the middle row of every even-length take, which is every
power-of-two pattern; the start row ties with nothing, and Tab already
stops there, so the head costs one press to reach.

A tail move writes a numeric natural length (±1 bpr from the current
rendered length, floored at 1 bpr). The relayout pass caps it against
the source duration and the next take, and demotes any natural ≥ source
back to `util.OPEN`. This means grow-past-source is a self-healing
no-op, and grow-past-neighbour stores intent that takes effect when the
neighbour moves away.

A head move hands `am:trimHead` the absolute head ±1 bpr. Natural is
measured from the source origin, so the end holds and the rendered
length moves the other way — floored at one row, since a take rendering
nothing would leave the grid without being deleted. `am:trimHead`
refuses a head below the origin, or a start row another take occupies.

An edit never changes which edge is armed. The caret rides the head it
moved, so a run of presses keeps trimming the same edge, and a refusal
leaves the caret where it was. A tail shrink that ate the caret's row
still pulls it back a row, but stops at the take's end edge rather than
its start row, where the bottom-edge rule resolves to the same take.
With a multi-take selection the edge is decided once, from the take
whose start row the caret is on, and the caret follows that one.

## Loop to item

`arrangeLoopToItem` brackets what the page's verbs act on — the
selection where one is held, else the take under the grid cursor — from
the first start to the last end, so a block loops in one press. It goes
through `am:loopTo` (`docs/arrangeManager.md` § Transport), which turns
the repeat on and moves the transport to the start unless the play head
is already inside the span.

## Bottom-edge rule in takeAtCursor

A cursor sitting exactly on a take's end-edge row contributes zero
overlap (the box is half-open), but still resolves to that take unless
another take starts at the same QN. This ensures a chained drop
(Super-D or drop-key) immediately after placing a take still adopts
the just-placed take — `advanceCursorPastNewTake` lands the cursor on
that boundary row on purpose.

## Replace mode

Super+U arms replace mode, in which the drop keys read differently: the
next drop key stands its slot in for a take already on the grid rather
than placing an instance at the cursor. Each replacement keeps the
start of the take it displaces and arrives at its own natural length,
so the key says what should sound there without saying where or how
long.

What a replace acts on is what every edit verb here acts on: the
selection where one is held, else the take under the cursor, which the
bottom-edge rule above resolves and whose start is usually above the
cursor row. So one key replaces a whole selected block, each member in
its own place and on its own track. A held selection passes to the
replacements, so the block can be replaced again; a cursor-driven
replace selects nothing, and the cursor alone carries the next one.

Arming pushes a spring-loaded scope whose `redirect` covers all 62 drop
keys, so the drop runs in place and the mode ends with it. Anything
else bails the scope: a cursor move, an edit verb, leaving the page.
Super+U again disarms, since the mode's own command is its
`keepAlive`. A drop over empty space is a no-op that disarms all the
same.

A replacement longer than what it displaced is not stacked on its
neighbour: relayout caps it at the next take's start, the same cap
every drop gets.

The cursor holds its row, because a replace edits in place rather than
placing. A lone shorter replacement is the exception: where its end
falls above a cursor that sat on the take replaced, the cursor comes up
to the last row inside it, so a run of replaces on one item stays on
that item. A selection elsewhere never drags the cursor to it, and a
replace over several takes leaves the cursor alone, as a multi-take
resize does.

Nothing else on screen marks the mode, so the status bar carries a
REPLACE flag while it stands.

## Drag geometry: ghost length and fits

During a move or duplicate drag the ghost length equals
`take.naturalLenQN` — the take's full intended extent, ignoring
downstream truncation by a neighbour — so the in-flight preview shows
what the take would render to once dropped. During a resize drag the
ghost grows or shrinks from the current rendered length.

`fits` is false iff another take on the same track starts at the
candidate `startQN`. Under the natural-length model the only forbidden
configuration is two takes sharing a start. `exceptItem` excludes the
dragged take itself (or nothing on `press.duplicate`, where the
original stays put).

`dragCandidate` returns a `ghosts` list — one entry for a single drag,
one per member for a group drag — each `{ take, startQN, lengthQN }`,
plus a single whole-group `fits`. The renderer holds back every moving
take and repaints the ghosts at the candidate range; a duplicate leaves
the originals in place and paints the copies on top. A group's `fits`
runs the same destination-start check across all members at one
`deltaQN`, excluding the members only on a move.

## beatPerRow as the only QN bridge

`qnToRow` and `rowToQN` are the only places QN meets row units, and
they go through `beatPerRow` rather than threading a constant. The
arrange page draws QN labels in its gutter column by calling
`av:rowToQN(row)` per visible row; no other module needs to know the
density. Minimum is `1/4` (one row per sixteenth note) — clamped at
the setter so the inverse never divides by zero.
