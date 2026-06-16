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
over the same set, for the mouse path and the duplicate commands.

Cursor and selection are separate pointers, and that is deliberate. The
cursor is the keyboard caret — drawn as a horizontal I-beam on the top
edge of the cursor row; the selection is a set of highlighted takes.
Cursor nav never changes the selection: the caret moves on its own, the
selected takes keep their indicator.

Selection is decoupled from action. An edit command resolves its
targets through `actionTargets`: the whole selection if one is held,
otherwise the single take under the cursor — acted on without becoming
selected. With nothing selected and the cursor parked off-screen (only
a wheel-pan can strand it there), there is no target and the command
no-ops. Boot lands the cursor on REAPER's selected item but selects
nothing (`seedCursor`).

Single-take commands — dive, take-properties, duplicate-below — go
through `singleTarget` and no-op unless exactly one take is targeted:
you can't dive into five takes, and a duplicate has one copy to advance
onto. Group commands — nudge, resize, delete — act on every target in
one undo block. Nudge is all-or-nothing: it pre-checks the whole group
against `am:moveTake`'s occupied-start rule and refuses the move if any
member is blocked, then applies the moves in travel order so a
contiguous block never collides with an unmoved member.

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

## Nudge and resize

Nudge steps one row at a time. The only block is a head-on collision:
destination start == another take's start on the same track. Later
takes truncate earlier ones in the rendered frame, so passing through a
neighbour is fine — `am:moveTake` handles the relayout.

Resize writes a numeric natural length (±1 bpr from the current rendered
length, floored at 1 bpr). The relayout pass caps it against the source
duration and the next take, and demotes any natural ≥ source back to
`util.OPEN`. This means grow-past-source is a self-healing no-op, and
grow-past-neighbour stores intent that takes effect when the neighbour
moves away.

## Bottom-edge rule in takeAtCursor

A cursor sitting exactly on a take's end-edge row contributes zero
overlap (the box is half-open), but still resolves to that take unless
another take starts at the same QN. This ensures a chained drop
(Super-D or drop-key) immediately after placing a take still adopts
the just-placed take — `advanceCursorPastNewTake` lands the cursor on
that boundary row on purpose.

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

## Palette nav: forward-first, land-empty

`gotoTrack`/`gotoTake`/`pickTrack`/`pickTake` move the cursor across the
arrange palette. The arrange façade exposes them; the tracker drives them
by delegation. They set the cursor — there is no REAPER selection.

A palette **slot** is a pooled source (one row per `POOLEDEVTS` id) with
many timeline **instances**; nav steps by slot or track but must land the
cursor on a concrete instance. `resolveInstance` scans candidates from a
reference QN: the nearest at/after it, else the nearest before
(`nearest(_, _, 1) or nearest(_, _, -1)`). On a track *landing* this is
**forward-first and fixed** — independent of the travel direction — so
stepping right then left is not hysteretic; both resolve the same instance
for a given QN. (`gotoTake` keeps travel-relative resolve within its slot
axis, where ordering, not position, is the user's intent.)

`gotoTrack` steps **exactly one** track and does **not** skip empties:
landing on a track with no MIDI takes keeps the cursor row and leaves
`currentTake()` nil, so the tracker renders an empty grid. A take with no
pooled id (raw imported MIDI, `slotIdx == nil`) can't be slot-navigated,
but track navigation still works — it is position-only.

## beatPerRow as the only QN bridge

`qnToRow` and `rowToQN` are the only places QN meets row units, and
they go through `beatPerRow` rather than threading a constant. The
arrange page draws QN labels in its gutter column by calling
`av:rowToQN(row)` per visible row; no other module needs to know the
density. Minimum is `1/4` (one row per sixteenth note) — clamped at
the setter so the inverse never divides by zero.
