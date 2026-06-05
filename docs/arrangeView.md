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
cursor is the keyboard caret — drawn as a horizontal I-beam on the top
edge of the cursor row; focus is a take. Cursor nav never changes
focus: the caret moves on its own, the previously focused take keeps
its focus indicator. Each kb mutation (`nudgeFocused`,
`resizeFocused`, `deleteFocused`, `diveFocused`) opens with
`adoptCursor`, which reselects the take under the cursor — an empty
cell clears focus and the mutation no-ops. Mouse press on a take
focuses it directly; the focus indicator survives until the next kb
mutation reselects.

The earlier model adopted focus on every keyboard landing, so a take
"stayed picked" once the cursor crossed it even if nav carried on past.
This made park-and-mutate convenient but meant the cursor was lying
about which take the next command would hit. The caret rendering and
the adopt-on-mutate rule are the same shift: cursor position is a
line, not a cell — what it picks is decided at command time, not at
landing time.

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
