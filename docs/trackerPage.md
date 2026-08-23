# trackerPage

ImGui rendering and input for one trackerView. Owns no tracker state; pulls
everything from `vm` each frame and routes all writes back through `vm` or
`cmgr.commands`.

## Pull-only discipline

rm caches almost nothing of what vm/tm know. Every frame it re-reads
`vm.grid`, `vm:ec()`, `vm:rowPerBar()` etc. fresh, and reads pure
config (`rowPerBeat`, `currentOctave`, `advanceBy`) directly from cm.
The only persistent local state is ephemeral UI:

- grid cell metrics (`gridX`, `gridY`) — derived once from
  `CalcTextSize('W')` and held.
- drag pin (`dragging`, `dragWinX/Y`) — see *Mouse* below.
- `modalState`, `swingEditor` — overlay lifecycle.
- `colourCache` — flushed on any cm config change.

Nothing in rm mirrors data that lives in a lower layer.

## Coordinate system

rm works in two spaces:

- **Pixel space** — what ImGui speaks.
- **Grid-cell space** — integer `(x, y)` measured in monospace character
  cells. All grid drawing goes through the `printer` helper, which folds
  the pixel conversion into one place.

Inside one column's cell text a third set of offsets applies: char stops,
`col.stopPos`, which the cursor indexes (trackerView.md § Cursor & selection).

`gridX`/`gridY` are the per-cell pixel size; `gridOriginX`/`gridOriginY`
is the per-frame pixel anchor of cell `(0, 0)`. The grid *data* starts
at `(0, 0)`; header rows sit at negative y (`-HEADER = -3`), the
row-number gutter at negative x (`-GUTTER = -4`). Every `draw:*`
method takes cell coordinates.

Visible columns are laid out afresh each frame, starting from
`scrollCol` and assigning `col.x` left-to-right until the next column
would overflow `gridWidth`. Everywhere downstream, `col.x == nil`
is the visibility predicate.

`computeLayout()` establishes char metrics, viewport dimensions, and
calls `layoutColumns`, leaving `chanX/chanW/chanOrder/totalWidth` as
factory locals shared by `drawLaneStrip` and `drawTracker`. `gridHeight`
already accounts for the lane strip's `laneStrip.rows`, so the tracker
sees the row count it actually gets to fill. It runs twice per frame,
once before the lane strip and again after it, because a lane drag can
rebuild `grid.cols` under the layout the first pass computed.

Mouse input inverts the same transform the draw pass used
(`gridPainter.fromScreen`), so a click resolves against the geometry the
frame actually painted.

## Paint order

`drawTracker` draws back-to-front:

1. Channel-label row, column labels, column sub-labels.
2. Header separator, inter-channel vertical dividers.
3. Row backgrounds (bar / beat tint) and row numbers.
4. Sustain tails — per-note continuous bars from intent `ppq` to `endppq`.
5. Cells, char by char.
6. Off-grid projection bars — only under an active temperament, only for
   notes with a non-zero `(intent − displayed)` gap.
7. Cut line, across the pane.
8. Play row caret, over the cells and across the gutter with them.
9. Selection highlight.
10. Cursor (single-cell box + re-painted cursor char).

Tails sit above the row backgrounds but below cells, so cell characters
paint over the tail pixels at the note head and foot.

## Cell painting

`renderFns[col.type]` dispatches per type. Each renderer returns
`text, colour?, overrides?`:

- `text` — the string to paint;
- `colour` — a single-colour hint for the whole cell (e.g. `negative`
  for negative pb or delay);
- `overrides` — `{ [charIdx] = colour }` for per-character colouring
  (note renderer uses it to paint negative-delay digits without tinting
  the note name; under `trackerMode`, also dims the sample digits with
  `shadowed` when `evt.sampleShadowed` is set).

Colour resolution per cell, outermost-wins:

- **`col.type` has no renderer** → cell is skipped.
- **Ghost** (no evt but `col.ghosts[row]`) → `ghost` / `ghostNegative`.
- **Overflow** (more than one event on this row) → `overflow`, ignoring
  any evt-supplied colour.
- **Off-grid** promotes the `text` default to `offGrid`; an evt-supplied
  override (`negative`) outranks it.
- **Channel effectively muted** forces `inactive` over everything else.
- **Dots `·`** are always painted `inactive`, regardless of the run's
  colour — so a single renderer output splits into multiple coloured
  runs on dot boundaries.

`pa` events inside note columns render as `··· vv`: velocity shows, the
note name is dotted out.

## Lane strip

`drawLaneStrip` renders a single horizontal envelope above the tracker
grid, mirroring its horizontal extent. Time goes left→right (decoupled
from the tracker's vertical time axis below); the y-axis is value.

The strip displays the column the cursor is currently on if its type is
`cc`, `pb`, or `at`; otherwise the strip is just a tinted background.
Anchors are circles at each event's `(ppq, val)`; segments between
consecutive events follow the shape on the *first* event of the pair —
`step` paints horizontal-then-vertical, `linear` is a straight line, and
the curved shapes (`slow`, `fast-start`, `fast-end`, `bezier`) sample
the curve via `vm:sampleCurve` (which forwards to `tm:interpolate`).
A held-flat segment extends to each viewport edge so the eye never
sees an envelope drop to zero outside the data.

Value range:

- `cc` / `at` — `[0, 127]`, bottom-up.
- `pb` — `[-pbRange*100, +pbRange*100]` cents, axis line at zero.

Bar and beat row-cells are shaded (`rowBarStart`, `rowBeat`) and a 1px
divider sits at every row boundary (`laneRowDivider`), aligned with the
tracker rows below. Anchor dots may overlap the strip's top and bottom
edges — the clip rect is padded vertically so values at the extremes
aren't half-clipped.

Strip height is `laneStrip.rows * gridY`. Visibility is controlled by
`laneStrip.visible` (toolbar checkbox "Graph"); when false, the strip
draws nothing and `computeLayout` reclaims its rows for the tracker.
A pair of `+`/`-` `SmallButton`s in the strip's gutter nudge
`laneStrip.rows` between 3 and 32 (the half-row pad on each side eats
one row, so `rows = 3` is the floor that still shows 2 rows of
envelope). Both keys live at the `global`
level. The strip inherits the window's ambient background. Colour
keys: `colour.laneAxis`, `colour.laneRowDivider`, `colour.laneEnvelope`,
`colour.laneAnchor`, `colour.laneAnchorActive`.

### Lane-strip mouse interaction

`drawLaneStrip` publishes a per-frame `laneLayout` (or `nil` when the
strip isn't showing an envelope) carrying the rect, value scale, row
window, and the active column. `handleMouse` reads it for hit-testing
and dispatch.

State:

- **`laneHover`** — index into `col.events` of the anchor under the
  cursor (within ~6 px), or `nil`. Recomputed each frame inside
  `drawLaneStrip`; suppressed while `laneDrag` is active so the
  highlight stays pinned to the dragged anchor.
- **`laneDrag`** — `{ colIdx, idx }` while a drag is in flight, else
  `nil`. The pinned `colIdx` survives a rebuild that swaps the col
  table; if the column is no longer cc/pb/at the drag aborts.

Active anchor (drag wins over hover) draws at radius 4.5 in
`colour.laneAnchorActive`; inactive anchors stay at 2.5 in
`colour.laneAnchor`.

Click on a hovered anchor starts a drag. Per held frame, rm computes:

- `mouseRow = scrollRow + (mx − x0) / w · rowSpan`
- `toVal = clamp(round(valMin + (yBot − my) / valSpan · (valMax − valMin)))`

and a `toRow` that depends on the modifier:

- **Unmodified.** Direction-aware integer snap. Let
  `currRow = vm:ppqToRow(evt.ppq, chan)`, `target = round(mouseRow)`,
  and `startRow = laneDrag.startMouseRow` (mouse row captured at
  click). The direction predicate compares `mouseRow` to `startRow` —
  *not* to `currRow`. That makes the click frame a no-op by
  construction: any click landing inside the 6 px hit-circle on
  either side of an off-grid event's exact row would otherwise snap
  the event on frame 1. The inner check `target > currRow` /
  `target < currRow` still uses `currRow` because it's a geometric
  question (which side of the event's row does the snap target land
  on?), not a direction one. Neighbour clamps: `≥ floor(prev)+1`
  going down, `≤ ceil(next)−1` going up. If the clamp pushes `target`
  back across `currRow`, `toRow = currRow` (no move) — this is what
  leaves an off-grid event sandwiched between off-grid neighbours
  stationary in time when no integer row fits.

  After any horizontal move, `startMouseRow` is re-anchored to the
  current `mouseRow`. Without this, once the event has snapped past
  `startRow`, `mouseRow > startRow` (or `<`) would stay one-sided and
  the opposite-direction branch could never fire — back-tracking
  would silently break.
- **Shift.** `toRow = mouseRow` (fractional). The result lands ppq
  off-grid; `vm:moveLaneEvent`'s `±1 ppq` clamp is the only floor.

`vm:moveLaneEvent(col, i, toRow, toVal)` is the only write surface;
identity-by-index survives the per-frame flush via the ppq clamp (see
`docs/trackerView.md`). Drag ends when the button releases.

## Input

Three independent dispatches, gated by focus:

### Mouse (`handleMouse`)

Lane-strip first: `handleLaneStrip` claims the gesture if `laneDrag`
is active or a click lands on a hovered anchor (see
*Lane-strip mouse interaction* above). When the strip claims,
`handleMouse` returns immediately and the tracker-grid path below
doesn't run.

For the tracker grid: `nearestStop(mouseX, mouseY)` converts a pixel
to `(col, stop, fracX)`. `fracX` is kept separately from `col` so
callers can tell "past the end of any column" from "inside col N".
Behaviours:

- right-click on channel-label row → toggle that channel's mute.
- click on channel-label row → `selectChannel`.
- click on column-label row → `selectColumn`.
- shift-click in grid body → extend selection (start one if absent).
- plain click in grid body → clear selection, move cursor, begin drag.
  The window position is pinned at `dragWinX/Y` for the duration of the
  drag; without the pin, a drag that clips offscreen makes ImGui
  "helpfully" reposition the window.
- held-and-moving → walk cursor/selection with the mouse. Horizontal
  excursions past a column's edge step the cursor through neighbouring
  `(col, stop)` pairs one at a time, clamped at the ends. The
  selection is lazily started on the first frame the cursor actually
  moves.

Wheel (vertical / horizontal) drives `cursorUp/Down` / `cursorLeft/Right`
one invocation per notch, via direct `cmgr.commands.*` calls —
wheel ignores command return codes.

### Keys (`handleKeys`)

Strictly ordered, one pass per frame:

1. **Command dispatch.** Iterate `cmgr.keymap`; `IsKeyPressed(key) &&
   GetKeyMods() == mods` fires the command. The command returns `false`
   to decline (keep scanning, let the char queue see the press) or
   anything else (incl. `nil`) to consume the keypress. UI effects
   (modal, swing editor, quit) are produced as side effects by commands
   rm itself registers — see `docs/commandManager.md`.
2. **Edit char queue** (unmodified, no command key held). One
   character dequeued via `GetInputQueueCharacter` per frame and
   routed to `vm:editEvent`. The `commandHeld` flag is tracked across
   the dispatch pass because `IsKeyPressed` and the character queue
   don't share auto-repeat timing; without the gate, a held command
   key leaks a character into the edit path.
3. **Shift-held gestures.** Shift plus a note key strikes a chord
   (Shift+Alt spreading it across channels); Shift plus a digit runs the
   value-entry overwrite cursor. Both are fresh-press only, each declines
   off its own context, and shift release commits. They are a dedicated
   edit path rather than character-queue entries because they need the
   modifier state. See `docs/trackerView.md` § Value entry and § Chord
   entry.

**Why KEY stream, not char queue, for `editKeys`.**
`ImGui.Key_*` is physical and `IsKeyPressed(repeat)` fires on ImGui's
own repeat timer, so every key autorepeats uniformly. The OS char queue
silently suppressed repeats for keys with a macOS press-and-hold accent
menu (e.g. `a`–`z`), making held-key entry unreliable.

Only the newest held edit key autorepeats (`lastEditKey`). Without this
guard, a held chord would re-enter all its keys interleaved on each
repeat tick — the OS char queue only ever repeated the last key, but
`IsKeyPressed` fires for every key still held.

Modal is a hard gate: `handleKeys` returns immediately if `modalState`
is set, so the popup owns the keyboard until dismissed.

## Modal

Centred on the viewport. Triggered by rm-internal commands calling
`openPrompt(title, prompt, callback)` or `openConfirm(title, callback)`,
which set `modalState` and call `ImGui.OpenPopup`. The dispatch table:

- **confirm** — Y / Enter → `callback(true)`; N / Escape →
  `callback(false)`; no text buffer.
- **text** (default) — `InputText` with enter-returns-true; Escape
  cancels without invoking the callback; focus is seized on
  appearance.

The callback runs under `pcall` — a misbehaving handler shouldn't take
the render loop down with it.

## Swing editor

Floating, non-modal overlay. Edits a named composite in `cfg.swings`
via `cmgr.commands.setSwingComposite`; the tracker grid behind it
reflows live.

State shape:

```
swingEditor = {
  name        = <slot name>,            -- nil ⇒ create mode
  snapshot    = <composite or nil>,      -- on-open state; Reset restores
  createBuf   = <string>,                -- pending name in create mode
  createError = <string or nil>,
  rpb         = <subdivisions per beat>, -- preview grid resolution; default 4
  lastCount   = <n factors last seen>,   -- auto-resize trigger
  lastW       = <remembered width>,
}
```

**Create mode** (no slot set): user types a name, we call
`setSwingComposite(name, {})` + `setSwingSlot(name)` and fall through
to edit mode in the same frame.

**Edit mode**: header (Editing/Reset/Rows-per-beat) + composite preview
+ one row per factor (atom combo, amount slider, period combo, reorder,
delete) with that factor's preview directly below + add-factor button.

**Preview (`drawSwingGrid`).** A horizontal strip — the tracker on its
side. Cells are the unswung subdivisions (`rpb` per beat); each cell
starts at an unswung tick line. Grid lines are 1px in `text` with alpha
dialled to ~0.7 (full alpha is too loud against the cream bg). A
semi-transparent black filled dot is drawn at the *swung* image of
each unswung tick (`timing.applyFactors` applied at `i/N · periodQN`).
Dots size by meter tier: bar starts and the mid-bar beat (when
`qpb/2` lands on a beat — true in 4/4 and 6/8, false in 3/4 and 2/2)
get the largest radius, other beats slightly smaller, offbeats
smallest. The atom preview (no `shadeMeter`) uses the middle size
throughout.

The composite preview passes `shadeMeter = true` and a period rounded
up to a whole number of bars (`ceil(lcmQN / qpb) · qpb`), so the
beat/bar shading actually corresponds to a meter the user can read:
cells on a beat get `rowBeat`, cells on a bar start get `rowBarStart`.
Both `qpb` and the beat unit come from `meterQN()`, which reads the
take's first time signature — so 6/8 shades on the eighth and 2/2 on
the half, not on every quarter. Per-factor previews use the factor's
own `period` and skip the shading — that period rarely aligns to bars
and the colour bands would mislead.

At a glance: the X tells you *where in time* the note actually lands;
its drift from its cell wall is the swing displacement.

**Amount-slider drag.** The slider fires every frame while held; each
frame routes through `swingWrite`, which reads the currently stored
composite as the "old" side of the delta and reswings just that
per-frame slice. Chained across the drag, those slices compose to the
same total transformation as a single press→release reswing, but the
notes physically move under the cursor as the slider drags.

All edits (slider, atom, period, reorder, add, delete, Reset) share
`swingWrite`'s `setSwingComposite` + `reswingPreset` pair.

**Periods.** Composites store periods in QN. The UI speaks
bar-fractions via `PERIOD_PRESETS` (`1/16` … `2`), converting through
`barFracToPeriod` (using the take's first time signature) and
`periodLabel`. Non-preset periods show as `N qn` or `N.NNN qn`.

**Auto-resize.** On a change in factor count, `idealSwingHeight(n)`
estimates a height that fits the whole stack (chrome + composite
preview + n × per-factor block). Width is preserved from `lastW`,
height clamped to the viewport so auto-grow stays on-screen.

## Colour

The colour table in cm is a flat keyspace with three coexisting
namespaces:

- `palette.*` — atoms for the parchment grid palette (`palette.bg`,
  `palette.shade`, `palette.mid`, `palette.highlight`, `palette.inactive`,
  `palette.danger`, `palette.caution`, `palette.positive`, `palette.amber`,
  `palette.steel`, `palette.pale`, `palette.night`, `palette.nightText`).
- `chrome.*` — atoms for the neutral toolbar/popups/modals palette
  (`chrome.bg`, `chrome.shade`, `chrome.mid`).
- `colour.*` — roles that name the *function* a colour plays
  (`colour.bg`, `colour.text`, `colour.rowBeat`, `colour.toolbar.bg`,
  etc.). Roles alias atoms, or other roles, by their full cm key.

Each entry takes one of three forms:

- `{r,g,b,a}` — atom (terminal RGBA).
- `'fullKey'` — pure alias; alpha inherited from the eventual atom.
- `{'fullKey', a}` — alias with alpha override; outermost override wins
  along a chain. (Lua treats 0 as truthy, so `override or v[i]` correctly
  lets an alpha-0 override come through.)

One-off colours that earn no good function name (the yellow editCursor,
faded steel, faded red) live inline at the role rather than as palette
atoms.

`trackerPage.resolveColour(key)` chases the chain to an atom, raising
on cycles or unknown keys. The `colour(name)` wrapper takes a bare role
name, prepends the `colour.` namespace, resolves, and caches the U32 by
role name. The cache invalidates on `'configChanged'`, so a palette edit
takes effect next frame. `pushStyles` applies ImGui-level window-chrome
colours around the main window; all grid drawing uses the cached palette
directly.

## Font

`Source Code Pro` at 15 px, attached at `rm:init` and pushed once per
`rm:loop`. Grid character metrics assume this font — `gridX`/`gridY`
are derived on the first frame and held.

## Conventions

- **rm never touches tm.** Writes go through vm or `cmgr.commands`.
- **Cell coordinates are 0-indexed**, both axes. The column axis is
  0-indexed *within the current visible window* — `col.x = 0` is the
  leftmost *visible* column, not `grid.cols[1]`.
- **`col.x == nil` means off-screen.** Every loop over `grid.cols`
  that paints must gate on it.
- **Drag pins the window position** via `SetNextWindowPos(dragWinX,
  dragWinY)` so ImGui doesn't reposition mid-drag.
- **Dots are `inactive` at the character level**, no matter what
  colour the renderer asked for on the rest of the cell.

## Selection

The tracker owns which take it edits, decoupled from the arrange cursor.
The selection is two cm keys:

- `trackerTrack` (**project** tier) — the current track's GUID.
- `trackerSlot` (**track** tier, so per-track by construction) — that
  track's last-viewed slot index.

`tv` holds the selection logic (it reads arrange's project structure
through the facade, like `pa` does for wiring); `trackerPage` only binds.
The writers — `tv:selectTrack`, `selectSlot`, `gotoTrack`, `gotoTake`,
`pickTrack`, `pickTake` — mutate cm and never touch the arrange cursor; the
renderer calls them straight on `tv`.

`renderBody` opens with `bindFromSelection`: `tv:resolveSelectionTake()`
resolves `(trackerTrack, trackerSlot)` to a live take; on change the page
rebinds (`bind`/`dropTake`), else it hash-diffs the bound take for external
edits. A writer's take-swap lags one frame (it mutates cm; the next
`bindFromSelection` binds) — except dive, which switches pages and so
triggers `bind()` on the same activation. When `trackerTrack` is unset
(fresh project) `bindFromSelection` seeds it once from the arrange cursor.

`trackerSlot` lives at the **track** tier, so `resolveSelectionTake` re-keys
the track tier to `trackerTrack` first (`cm:setTrack`, guarded on staleness).
A page switch unbinds the tier — the tracker's own `unbind` runs
`cm:setContext(nil)` — so without the re-key the next `bindFromSelection`
(re-entering the tracker, or rendering a stale frame mid-switch: `coordinator`
captures the active page before the toolbar switcher fires) writes
`trackerSlot` against no bound track and raises *No track context for config
storage*.

### Dive

Arrange's dive is the one cross-page entry: the `tracker` facade's `diveTo`
→ `tv:selectTrack(guid, slotIdx)`. It sets the track to the grid-cursor
track; if a MIDI take sits under the cursor it pins that slot, otherwise it
restores the track's last-viewed slot. Arrange's own edit cursor is left
untouched.

### The current instance

The tracker holds one instance of the bound slot (`docs/arrangeManager.md`
§ Instances of a slot), and the verbs that act on a placement act on that
one. It is session state in `tv`, held as a take handle and re-read
through the arrange facade on each access, since a rebuild restates the
start and the length. A remembered instance survives an edit, a rebind
and a page switch, where an answer recomputed from the play head or the
edit cursor would move under the verbs between one frame and the next.

`tv:resolveCurrentInstance` runs once a frame and ranks three writers. A
command that knows the placement names one through `tv:nameInstance` —
the dive hands over the instance the arrange cursor sat on — and that
outranks the rest. Failing that, the play head *entering* an instance of
the bound slot makes that instance current; entry rather than occupancy,
so a play head parked inside an instance cannot overwrite what a dive
named on the next frame. A slot change that names nothing seeks one from
the outgoing instance's start, or from REAPER's edit cursor when there is
no outgoing instance; `gotoTake(-1)` seeks backwards and every other
gesture forwards, matching the grid, where time runs down the page.

Leaving an instance writes nothing. Playback running into a gap, over
another slot's take, or off the end of the song leaves the tracker where
it was. The instance is nil only where the slot has no live one, its
single take parked on scratch.

`playFromTop` (F6) is the first consumer: it plays from the current
instance's start, where it used to play from whichever instance
`takeForSlot` resolved — with instances at bar 0 and bar 8, diving into
the second and pressing F6 played the first.

### Loop to item

**Loop to item** brackets a placement with the transport loop: the
current instance on the tracker page, the takes the verbs target on the
arrange page (`docs/arrangeView.md` § Loop to item). Moving the transport
separates it from the dive — diving changes what the tracker edits and
leaves playback alone, while the placement loop to item brackets is the
one you hear next.

`tv:bracketCurrentInstance` sets the loop to the current instance's
rendered span through `am:loopTo` (`docs/arrangeManager.md` § Transport),
so the repeat goes on and the transport moves to the start unless the
play head is already inside the span. With no current instance it writes
nothing.

The verb comes in two forms. `loopToItemNow` (Cmd+L) brackets once;
`toggleLoopToItem` (Ctrl+L) flips `trackerLoopToItem`, a global-tier cm
key beside `arrangeFollowPlay`, and repeats the act as the current
instance moves. The toolbar carries the toggle as a checkbox.

The toggle writes when a gesture moves the current instance — a dive, a
slot change — and not per frame. Play-head entry moves the instance and
writes nothing, since bracketing there would pull the transport back to
the start of a placement already sounding. A loop set by hand survives
until the next such gesture, the discipline `av:followPlay` keeps when a
manual scroll suspends the follow. Turning the toggle on brackets the
current instance at once; turning it off leaves the loop where it stands.

### The play row

A caret marks the row the play head occupies inside the current
instance. `tv:playRow` returns a fractional row, so the caret slides
rather than steps, and nil where the transport is stopped or the head is
inside no instance of the bound slot.

The caret marks metric position rather than any channel's onset. Swing
resolves per channel, so one realised instant inverts to a different
logical ppq per column and there is no single sounding row to point at.
The row therefore comes from the grid's own metric — the offset from the
instance's start, through the take's resolution, over `ctx:ppqPerRow` —
and swung notes sound around it.

A second return dims the caret. Where the head is inside a sibling
instance of the same slot the row is still the row being heard, since
the instances of a slot share one take; the mute says the placement
sounding is not the placement bound. Play-head entry carries the current
instance to whatever the head walks into, so the two part company only
where a dive or a slot change has pinned the tracker elsewhere.

### The cut

A dotted line marks where the current instance's rendered span ends,
where the source span runs on past it. The rows below the line are drawn
but never heard: the item stops there, so the song never reaches them.

`tv:cutRow` takes the instance's rendered `lengthQN` through the metric
the caret uses, and returns nil where the row falls at or past
`grid.numRows`. The grid's row count is the source span in rows, so that
one test is the whole condition — a row inside the grid is a render the
source outruns.

The line spans the pane, the gutter with the columns, and the grid
carries on below it. Those rows come back into play as soon as the
neighbour moves away, which keeps the mark a boundary and not an edge.
See `docs/arrangeManager.md` § Rendered span and source span for where
the two extents come from.

### Slot recovery and the per-track memory

A stored slot can vanish (deleted under us). `resolveSelectionTake`
recovers: walk the track's extant MIDI slots forward (lowest slot above the
stored one), then back (highest below), and **write the recovered slot
through** so storage tracks the display. A slot whose only instance is
parked on the scratch track is still a slot and still editable
(`takeForSlot` resolves live-or-parked), so recovery and the empty test
both key off *slots*, not live instances.

Changing track always restores that track's last-viewed slot — that is the
per-track memory, and the same path as dive's "no take under the cursor"
fallback.

### New take and unpooled duplicate

`newTakeBelow` grows the song from the placement the tracker is in. Its
name+length modal (the name defaults to the next-free slot's zero-padded
index) hands both answers to `am:newTakeBelow` at the current instance's
append point (`docs/arrangeManager.md` § The append point), so the new
take lands on the grid below the one being edited. The verb parks it
where the gap falls short of the length asked for, and where the
selected track holds no current instance — which is how a generator's
freshly spawned track gets its first take, the selection having outrun
the resolve.

Either way `tv:selectSlot` selects the new slot, so the tracker switches
straight to the blank take with no arrange-cursor move. A placed take is
also named as the current instance (`tv:nameInstance`), so loop to item
moves the loop onto it.

`duplicateUnpooledBelow` places nothing: it mints a slot whose only
instance is parked on the scratch track (`am:mintParkedTake`), cloning
the currently-bound take, and selects that slot the same way.

Because a parked take's only instance lives on the scratch track, binding
it would key cm's **track** tier to scratch — desyncing every per-track read.
The sharpest symptom is `trackerSlot` itself: read under the scratch tier it
resolves to nothing, so `resolveSelectionTake` recovers to the old slot and
the selection flips back every frame. `tp:bind` calls `tv:retargetTrackTier`
right after `tm:bindTake`: for a parked take (`am:isParkedTake`) it re-points
the track tier at the selection's track, before `seedSharedSlots` and the
rest read per-track config.

## External-mutation watcher

`lastHash` is a `MIDI_GetHash` baseline of the bound take, snapshotted
after each frame's draw. When `bindFromSelection` finds the take's hash
drifted from the baseline, something outside the stack wrote the take
(REAPER's MIDI editor, an undo), and the page reloads tm from REAPER.

The stack's own writes must not read as external. Draw-time edits never
did — they land between the hash check and the end-of-frame snapshot.
But a tick-time edit (the reaper bridge mutating through tm before the
page draws) lands outside that bracket, and the next check fired a
spurious `reloadFromReaper`. That reload was worse than wasted work: in
REAPER, its take re-read cleared the pending undo capture before the
defer cycle yielded, so a bridge mutation's labelled undo block
finalised *empty* — a point that reverted nothing (the 2026-07
bridge-undo incident). Hence the `flushed` subscription: mm announces
every reprojection of the take, and the page resyncs the baseline
instead of reloading, leaving the watcher to fire only on genuinely
foreign hashes.

Residue: a raw `reaper.*` edit to the bound take from a bridge chunk
still needs `coord:reloadAfterExternalMutation()`, and that explicit
reload wipes the chunk's undo capture just the same. Mutate through tm
when the edit must be undoable.

### Empty grid: one state

No resolvable take ⇒ `tv.grid.cols` is empty ⇒ the grid is replaced by
`No MIDI takes on this track.` With recovery this is the only empty state:
a track with at least one slot always resolves to a take, so the old
"No take at the cursor." state can no longer arise.
