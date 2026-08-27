# trackerView

Projects tm's channel/column tree onto a 2D display grid, owns cursor /
selection / clipboard, and exposes the editing command surface. Produces
`vm.grid` for trackerPage to read each frame; does no ImGui work itself.

## viewContext

A pure, throwaway snapshot built once per `vm:rebuild`. Binds
`length`, `numRows`, `rowPerBeat`, `ppqPerRow` (the logical row
width — fractional in odd `(rpb, denom)` combinations), `timeSigs`,
`temper`. Every method is a function of the bound state plus its args —
no callbacks, no mutation. Throw it away and rebuild a new one; there
is no migration.

Two responsibilities:

- **Row ↔ PPQ projection.** `ppqToRow(ppqI)` is `ppqI / ppqPerRow`
  (saturating at 0 and `numRows`); `rowToPPQ` is the integer-rounded
  inverse. `ppqPerRow()` exposes the bound logical row width so callers
  (e.g. clipboard paste) can compute the logical ppq at the destination row. The
  `chan` argument is retained on the call signature but unused at this
  layer — column-level swing transforms happen above, when events are
  written into / read out of the column tree.
- **Temperament lenses.** `noteLabel(evt)` spells `(pitch, detune)` as the
  parts of a cell label under the bound temperament; `noteDeviation(evt)`
  reports in cents how far off its step the note sits, which the cell draws
  as a readout beside the name. Both are nil if no temperament
  is active. (Pure coordinate queries — see `docs/tuning.md` for the
  underlying model.)

Row placement and off-grid follow the swing-boundary model in
`docs/timing.md`:

```
displayRow(e) = round(ppqToRow_c(e.ppq))                  -- under current swing
offGrid(e)    = rowToPPQ_c(displayRow(e)) ≠ e.ppq
```

The unrounded-`ppqPerRow` invariant (round-trip exactness, off-grid as
clean integer compare) is owned by timing.md; vm's stake is the
display consequence — a swing slot change correctly surfaces
previously-on-grid events as off-grid, because their realised ppq
sits at the old grid's swung position and no longer matches
`rowToPPQ_c(N)` under the new swing.

The tv surface carries no `ppqL`: `evt.ppq` *is* the authoring stamp at
this layer. mm keeps the `ppqL` sidecar — the canonical stamp that
survives swing changes, which tm's stale-swing reseat rederives raw from
when a channel is marked stale — but it never reaches the columns.

## Ghost sampling

**1** For each consecutive scalar pair whose first event has a non-step
shape, `vm:rebuild` samples the curve at every row strictly between
A and B (skipping occupied rows) and writes `{ val, fromEvt, toEvt }`
into `gridCol.ghosts[y]` for rm to render. The sample point for row
`y` is `ctx:rowToPPQ(y, chan)` — so under swing the ghost reflects
the value at the row's realised time, not at "fraction of rows
traversed". Curve evaluation is delegated to `tm:interpolate` (which
forwards to `mm:interpolate`); the shape / tension / bezier-handle
table are owned by midiManager.

**2** `pa` events are not ghosted — they live inside note columns.

**3** A chain's realisation ghosts too, and the borrowed styling is the point
of the reuse: an interpolation ghost already says *computed, not editable*,
which is exactly what a derived event is. It cannot be sampled per rebuild,
though, because both of its inputs move without one — the gate is the caret
and the window is the viewport, where `vm:rebuild` answers only to tm's
signal, a column add or remove, and config. A table hanging off the column
would be stale on the first arrow key, so `tv:ghostOverlay` derives the
ghosts per frame, as the drag preview already is.

**4** The overlay is **one producer's realisation, and the caret names which**.
A ghost says this row is computed, and a reader looking at one wants to know
by what; a surface lighting every chain in view at once answers that question
for none of them. So the gate is the chain the caret's own event runs,
resolved through `tm:fxRealisation`, and a cell running none answers nil.
Sibling collisions are read by moving the caret onto the sibling, which is
also how you would ask which chain to edit. The caret on the master strip names
a chain running no producer of its own, and tm answers it with the union of the
ones it expanded into, so the overlay's own reading is unchanged.

**5** The filtering is not done at read time. A `derived == host` test in the
draw loop would answer the question and leave the walks it answers from in
place: every channel's derived notes gathered, and every parked cell in the
document gathered, per frame, to discard nearly all of it. The rebuild already
holds the answer, so tm keys those outputs by producer as it builds them
(`docs/trackerManager.md` § Realisation by producer) and the view's whole
query is a lookup.

**6** The overlay has two halves, because what the ghosts show and what they
stand in for are one question. `notes` are the chain's derived onsets, and
they carry no tail: the scalar ghosts this borrows from are a value on a row
with no extent, and a retrig ghosted with tails would paint a wall of glyphs
across the span the parked host's own tail already covers. `hidden` is the
parked cells the ghosts stand in for, showing both being showing one span
twice.

**7** `hidden` is keyed by the event table rather than by row, because a
note's tail bracket is drawn from a second list carrying no row the cell loop
would recognise — `startRow` is fractional for an off-grid onset — and one
identity then answers for the cell, its tail and its temper tick alike. A
hidden cell is invisible, not absent: `col.cells` stays whole, so the host
lookup, the leaf-edit facade and the caret keep their footing, and stepping
onto one restores it. The suppression reads `channel.parked` alone, so parked
ccs, pbs and PAs stand — nothing ghosts them, and hiding them would take a
picture away without offering one in its place.

**8** One cell is never hidden: one carrying `fx` of its own. A note hosting a
replace chain parks itself, so hiding it would take away both the host and the
only way to edit the note, and that holds however the cell came to be parked
rather than only when the caret is on it. Its row shows no ghost either, a
real cell outranking one.

**9** The continuous half asks `tm:fxCurveAt` what the chain realises on one
claimed target at one logical ppq, samples it at every visible row of every
claimed column on every channel the chain reaches, and the draw arm prefers it
to the interpolation ghost — which
describes the authored curve alone, and inside a producer's window that curve
has been parked out of the way. Sampling is per row rather than bucketed by
seat: a curve has no onsets to bucket, and a 1/4-QN LFO seated at the cc grid
step would show its zero crossings and nothing else.

**10** The overlay lands only in columns the channel already carries, and a
claim materialises none of its own. The tempting answer is the other one —
that the grid should show the claim, as a column derived from the data on the
fx column's model, standing empty until the ghosts are on. It was built twice
and withdrawn twice, for the same reason both times: such a column is not the
user's, and everything the grid does with a column assumes that it is.

**11** Standing permanently, it cannot be put away. Hide reads a channel's
lane count off the grid, so a derived lane has to be made invisible to that
count or hide writes back a larger one and quietly stops working; a derived pb
or cc column passes hide's empty check and then clears nothing, so it returns
from the data on the next rebuild.

**12** Gating it on the caret is worse, and worse in a way worth naming,
because `ec:col()` being an index sounds like a fact about the caret. Moving
left off an fx host lands the caret on the claimed column immediately to its
left; the move de-addresses the chain, so that column collapses, the fx column
slides into the vacated index, and the caret arrives back on the host, which
puts the column back — the keypress cannot be completed. Nor is the caret the
only holder of a column index: a selection is `col1, col2` with no identity to
re-find them by.

**13** So columns follow the data and the user, as `extraColumns` and the
authored lanes do, and the ghosts follow the caret within them. A derived
voice in a lane past the authored ones does not show, and neither does a curve
on a cc nothing has authored; adding the column by hand is what makes it
visible, and tm already grows a channel's columns for a note written above the
count. What that costs is `docs/oddities.md` § A chain's claim on a column the
channel lacks shows nothing.

**14** A lane's width follows the ghosts too. A note off its step draws a
deviation readout (`docs/tuning.md` § Display), and a lane whose own notes all
stand on their steps reserves no width for one, so `tv:reserveGhostReadout`
opens that width in every lane drawing an off-step ghost and closes the ones it
opened. It runs ahead of the frame's column layout, which reads the widths it
writes. The readout addresses no stop, so nothing the caret or a selection
holds moves as the width comes and goes.

## Grid shape (vm's output to rm)

```
grid.cols         = { <col>, <col>, ... }     -- flat, 1-indexed
grid.chanFirstCol = { [chan] = i }            -- dense 0..16; 0 is the master channel
grid.chanLastCol  = { [chan] = i }
grid.lane1Col     = { [chan] = <col> }        -- first note col per chan; never set for 0
grid.numRows      = <integer>
```

Each column:

```
{
  type, midiChan,
  lane      = <int>  (note only)    key = lane
  cc        = <int>  (cc only)      key = cc number
  label, events, width,
  parts, stopPos, partAt, partStart,   -- see below
  showDelay = bool,                 -- note only
  cells     = { [y] = evt },        -- y is 0-indexed row
  overflow  = { [y] = true },       -- >1 event landed on row
  offGrid   = { [y] = true },       -- cell's intent ppq is not row-centred
  ghosts    = { [y] = { val, fromEvt, toEvt } },  -- scalar types only
}
```

`events` is the column's event array from tm, sorted by intent ppq.
`cells` keeps only the first event that lands on each row; the rest
are flagged via `overflow`. `offGrid` marks cells whose snapped row
disagrees with their intent ppq (swing, delay, or both).

## Cursor & selection

The cursor is `(row, col, stop)`. **Stop** indexes into `col.stopPos`,
the list of character offsets inside the column where the caret can
sit (e.g. `{0,2,4,5}` for `C-4 30`). A column is composed of one or
more **parts** — contiguous editable axes — listed in order in
`col.parts`. `col.partAt[stop]` names the part the caret sits in;
`col.partStart[stop]` is the stop index of the first stop in that
part, and doubles as the ordering primitive (lower partStart = earlier
part within the column). `col.width` is the rendered character width.

| type             | parts                       | stopPos                | partAt                                                | partStart           |
|------------------|-----------------------------|------------------------|-------------------------------------------------------|---------------------|
| note             | `{pitch, vel}`              | `{0,2,4,5}`            | `{pitch,pitch,vel,vel}`                               | `{1,1,3,3}`         |
| note with delay  | `{pitch, vel, delay}`       | `{0,2,4,5,7,8,9}`      | `{pitch,pitch,vel,vel,delay,delay,delay}`             | `{1,1,3,3,5,5,5}`   |
| pb               | `{pb}`                      | `{0,1,2,3}`            | `{pb,pb,pb,pb}`                                       | `{1,1,1,1}`         |
| cc / at / pa / pc| `{val}`                     | `{0,1}`                | `{val,val}`                                           | `{1,1}`             |

`(col, part)` picks which typed edit a keypress performs (pitch vs
velocity vs delay) and which clipboard / nudge semantics apply. ec
owns both the part registry and the parts list per col type;
`ec:decorateCol(col)` derives all five tables (parts/stopPos/partAt/
partStart/width) from `col.type` + `col.showDelay`.

A selection extends the caret into a rectangle. Internally:

```
sel = { row1, row2, col1, col2, part1, part2 }   -- or nil
```

`part1`/`part2` are part names — `'pitch' | 'vel' | 'delay'` on note
cols, `'pb'` on pb cols, `'val'` on scalar cols. `ec:region()` returns
`row1, row2, col1, col2, part1, part2` (with cursor-degenerate fallback
to a 1×1 rect — `ec:hasSelection()` is the bit when that distinction
matters), and `ec:setSelection{ row1, row2, col1, col2, part1, part2 }`
takes a part-typed record.

`selAnchor` is the fixed end; the cursor is the moving end. Sticky
block scopes cycle orthogonally:

- **hBlockScope** `0 → col → channel → all-cols → col → …`
- **vBlockScope** `0 → beat → bar → all-rows → beat → …`

Each cycle press widens one axis; the two compose freely. `selClear`
exits block mode (drops both scopes and the anchor); `unstick` drops
the sticky flags but keeps `sel` visible for one frame of feedback
after a destructive op — the next cursor move then clears it.

`swapBlockEnds` exchanges anchor and cursor on whichever axes are not
scope-locked, letting the user drive the opposite edge.

The cursor and selection live in a `newEditCursor` factory in
`editCursor.lua`. vm constructs one ec at startup over
`{ grid, cm, rowPerBar, moveHook }`, passing `followViewport`
as the move hook. ec reads pure config (`advanceBy`, `rowPerBeat`)
straight from cm; vm only passes the derived `rowPerBar` closure.
Both vm and rm consume ec directly — rm reaches it via `vm:ec()`.
ec owns: position (`row/col/pos/setPos/clampPos`),
motion (`advance` for advance-by; `moveStop/Col/Channel` and
`cycleHBlock/VBlock/swapEnds` are command-internal), selection
(`selClear/isSticky/unstick/extendTo/setSelection/shiftSelection/selectChannel/Column/eachSelectedCol`),
part (`cursorPart/region/regionStart/selectionStopSpan`),
grid-column part decoration (`decorateCol` — stamps `parts`,
`stopPos`, `partAt`, `partStart`, `width`), lifecycle
(`reset/rescaleRow`), and command registration (`registerCommands`).
Cursor-axis clamping lives in `ec:clampPos`; viewport follow stays
vm-side because it touches scrollRow/scrollCol and runs through the
move hook.

## Logical ppq stamping

vm passes intent in the logical frame: every authoring call site
sends `evt.ppq` / `evt.endppq` as logical positions; `tm:addEvent` /
`tm:assignEvent` stamp `ppqL` / `endppqL` and derive raw via
`fromLogical` under the channel's current swing. There is no
per-event frame — the channel's swing is read from cm at realisation,
and `tm:rebuild`'s stale-swing reseat updates raw from ppqL when cm broadcasts a
swing change (see `docs/timing.md`).

**View-layer rpb override.** `matchGridToCursor` (Ctrl-G) writes
`rowPerBeat` to cm's `transient` tier; `transient` is most-specific
in the merge, so every reader (including `tm:rebuild`) sees the
override transparently. Toggling drops the key via
`cm:assign('transient', ...)` with `util.REMOVE`.
`releaseTransientFrame` peels the override on any non-`transient`
write to a `FRAME_KEYS` member (narrowed to `rowPerBeat` once
per-event frames went away) and rescales ec if rpb changed underneath.

## Rebuild & callbacks

Triggers:

- `tm` `'rebuild'` signal — always rebuilds. The take-swap flag travels
  via tm's separate `'takeSwapped'` signal, captured here into a transient
  flag and consumed by the next rebuild (tm guarantees the firing order);
- `cm` `'configChanged'` signal **except** `mutedChannels` /
  `soloedChannels` (which only push mute). Non-`transient` writes to
  any `FRAME_KEYS` member while a transient override is active are
  short-circuited into `releaseTransientFrame`, whose recursive
  `cm:assign` fires the rebuild.

Reentrancy-guarded by `rebuilding`. `vm:rebuild(takeChanged)` takes a
bool: `true` resets cursor / selection and re-reads `resolution`, `length`,
`timeSigs` from tm; the remaining work (grid cols, the viewContext,
cell/overflow/offGrid maps, ghost maps) runs unconditionally on every
rebuild. Mute is pushed to tm unconditionally at the end.

## Mute / solo

vm owns the **effective mute** = persistent-mute ∪ solo-implied mute.
When any channel is soloed, non-soloed channels are forced muted and
soloed channels are forced audible (DAW convention — solo wins over
persistent mute).

Both sets persist in cm so that on reload tm's `lastMuteSet` matches
the muted flag already on the wire; otherwise a take where solo had
silenced channels would come back unmuted. `effectiveMuted` is cached
for cheap per-cell render queries; `pushMute` recomputes it and
forwards to `tm:setMutedChannels`.

## Editing contract

All writes funnel through tm:

```
tm:addEvent / tm:assignEvent / tm:deleteEvent / tm:flush
```

vm never touches mm. `editEvent(col, evt, stop, char, half)` is the
single typed-input entry point; it dispatches on `(col.type, stop,
evt-kind)`:

- **note**, stop 1: note name → pitch + detune (temperament snap if
  active); repitch existing, wipe PA tail if replacing a PA, else
  `placeNewNote` which shortens the prior note and inherits its vel.
- **note**, stop 2: octave (on real notes only).
- **note**, stops 3–4: velocity nibble (hex); falls through to PA
  creation on a sustain row when `polyAftertouch` is on.
- **note**, stops 5–7: decimal signed delay (±999), unbounded at the
  vm layer. tm clamps raw at realisation — onset floors at 0 and
  same-pitch collisions resolve via rebuild's universal tail
  walk; divergence between authored delay and realised onset surfaces
  as `delay ≠ delayC`, which trackerPage paints as a `*` next to the
  delay digits.
- **cc / at / pc**: hex nibble on `val`.
- **pb**: decimal signed nibble on `val`, with `-` toggling sign.

An off-grid edit snaps intent time to the cursor row (`snap`); delay
survives, tm re-realises on assign. The ppqL is repinned to
the cursor row (`row · logPerRow_currentFrame`) and the frame is restamped
to current; for notes, endppqL shifts by the same delta so
logical duration is preserved exactly.

After any edit, `commit` calls `tm:flush`, advances by `advanceBy`,
and optionally auditions the new pitch.

### Value entry

**1** Shift held turns typed digits into an overwrite cursor over one
field's places. The gesture pins a column, a row and a part on its first
keystroke: each digit overwrites the place under the sub-caret and leaves
the places below it standing (`util.setDigit`'s `keepBelow`), the sub-caret
steps one place right, and the row stays put while shift is down. Releasing
shift restores the column the gesture began in and advances one row, so a
value edit costs the caret nothing.

**2** Backspace restores the place the last digit overwrote and steps the
sub-caret back onto it to be retyped. Each keystroke records a snapshot of
the fields it is about to write, rather than a stack of values: a part may
write more than one field — an octave moves `pitch`, `detune` and
`intentCents` together — and a digit that created the event has to be undone
by deleting it.

**3** Which digits a part takes follows its display: `sample`, `vel` and
`val` are hex, `delay`, `pb` and the octave decimal. The pitch part's first
stop is the note name and belongs to chord entry, so the gesture declines
there.

**4** The decimal parts also take `a`–`j` as a range extender: the letter
enters digit `0`–`9` at the caret's place and carries `+1` into the place to
its left, clamped to the field's cap. The carry is additive rather than a
literal set, so tens-`b` takes 350 to 410 and not to 110. Full scale falls
out of a carry that overflows the top place.

**5** `-` flips a signed field in place and does not advance. On a zero cell
there is nothing to flip, so it arms a transient `-0` held in the view
(`pendingFlip`) rather than in the event: the wire cannot carry a signed
zero — pb serialises `-0` as `0` — so a persisted one would die at the next
flush, taking the sign the user typed with it. The flip acts and renders
only while the cursor stays on the cell that armed it. An empty pb cell
inherits its entry sign from the ghost it displays, else from the previous
visible breakpoint, so a negative run costs one `-` and its digits; an
explicit zero inherits nothing, since it displays unsigned.

**6** Key clashes with commands resolve by the command declining in a
value-part context — Shift+8 for the octave, plain `1` for a note-off
pattern — rather than by rebinding either side.

### Chord entry

**1** Shift plus a note key arms a chord gesture: the row and channel pin
until shift releases, and each further strike places another note at that
row. A struck pitch already sounding at the pinned row is adopted into the
gesture rather than duplicated — MIDI allows one voice per `(chan, pitch,
ppq)`, and the voicing pass would eat a duplicate unpredictably — and
re-striking a pitch the gesture holds toggles it off, freeing its lane for
reuse. Backspace drops the last note struck.

**2** Plain Shift stacks the gesture's notes on lanes of the home channel.
Shift+Alt spreads instead, each strike walking up to the lowest channel the
gesture does not already hold. The choice is per strike rather than a mode
armed at entry or a config toggle: per-strike subsumes both and allows a
mixed chord. The toggle is pitch-keyed, so a unison doubled across two
channels is foreclosed.

**3** Velocity is not typed during the gesture. The upper note row *is* the
digit row — `2 3 5 6 7 9 0` are black keys — so digits stay strikeable, and
the last note struck takes its velocity from an arrow nudge
(`chordNudgeVel`) on the keys that otherwise step sample and velocity. Those
commands decline while a gesture is live, which is also why a chord cannot
*start* on a key whose Shift binding is a command: a command wins at
dispatch, and declines only once there is a gesture to decline for.

**4** The gesture is a host parameter rather than a global: gridPane takes
`chordEntry` from its host and the pattern editor passes false, a pattern
body being single-channel.

### Backings and parked cells

**1** A parked event is the visible, editable surface of an fx replace, and it
edits like any other cell — transpose, resize, retune, delete, type a new one
into the window — with no second editing surface. The leaf-edit facade
dispatches every edit to a `backing` strategy by `kindOf(evt)`: `member` (gm)
when the cell sits inside a group region, `parked` (tm's off-take stash) when
it sits in an fx region's parked zone, else `plain` (tm).

**2** That an fx region *defines* a parked zone exactly as a gm region defines
a member zone is what makes this a third backing rather than a branch bolted
into `tm:assignEvent`. Two things follow that a branch could not buy. Typing
into the zone gets a real `add` — a logical spec written straight to the
stash, with no mm round trip. And move gets its semantics free from the
facade's existing cross-kind relocate: move-out (`parked`→`plain`) is
drop-spec plus take-add, move-in is take-delete plus stash, and an in-zone
value edit or ppq nudge stays one kind and churns nothing.

**3** A move-out sheds the uuid, a relocation being a new note rather than the
old one returning. A **restore** — the fx removed, or the window moved off —
hands the spec's original uuid back to `mm:addNote` under `keepUuid` instead,
so fx-editor handles survive the round trip.

**4** The view must tag a cell `parked` over exactly the spans the park pass
parks over, or the tag and the parking disagree. Both read the same pure
`generators` surface, `parksNotes` and `parkWindows`, and any new reason a
host stops parking has to reach those predicates too, or the runner and the
tagging drift apart. Bypass is deliberately not such a reason (§ Note FX
stages). Where a gm group and an fx region ever cover the same cell, `parked`
wins and we assert disjoint.

## Clipboard

The clipboard lives in a `newClipboard` factory in `editCursor.lua`
(co-located with ec, since clipboard reads ec's region/eachSelectedCol/
cursorPart to drive collect and paste). vm constructs it once over
`{ ec, grid, tm, cm, currentFrame, getCtx, getLength }` and exposes it
via `vm:clipboard()`. Public surface: `collect`, `copy`, `paste`,
`pasteClip(clip)` (paste a given clip without touching ExtState — used
by `duplicate`), `trimTop(clip, n)`.

The persistent store is REAPER ExtState under `rdm.clipboard`,
serialised via `util.serialise` with `loc` / `sourceIdx` stripped.

Clip events encode rows in the **source column's** own swing frame;
paste decodes them into the **destination column's** frame via
`rowToPPQ`. The round-trip is consistent even when source and
destination have different effective swings, because both sides go
through `(row, chan)`.

A clip is single (one column, recording the parts its span covered) or
multi (a rectangle of channels, each entry rebased by `chanDelta`).
What a clip carries and where each part pastes is the clipboard's own
model: see docs/editCursor.md § Clipboard: single vs multi.

`duplicate(dir)` copies the selection to the adjacent block without
touching the user clipboard: it calls `clipboard:collect()` and
`clipboard:pasteClip(clip)` directly. Going up past row 0
`clipboard:trimTop`s the clip in place — the start of the block is cut
off, not the end — so selection follows and repeated invocations stack
cleanly.

### FX regions

FX regions ride the clip as `clip.fxRegions`, gathered/replayed by
trackerView through an `fx` hook injected into `clipboard`'s deps
(`gatherFxRegions`/`pasteFxRegions`) rather than by clipboard reaching
into `fxRegions` storage itself — clipboard stays column-shaped, fx
regions don't. Entries carry clip-top-relative rows and a `chanDelta`
off the rectangle's left edge, same as multi-mode cells; the whole
window rides even when it spills past the copy band, since a region's
identity is its window, not the rectangle that caught it. Capture is by
onset: a region starting inside the rectangle rides whole, exactly as a
note's tail copies past the band, and one starting above and merely passing
through is skipped. Overlap capture would make fx unlike every other
column, and clipping to the band is meaningless for a chain. The
delete-caret still takes the region under the cursor
(`cursorRegionBefore`), not the onset rule. A region whose rebased channel falls
outside 1 to 16 is dropped, which is also what refuses a paste onto the master
channel (§ Addressing a chain). Paste stacks — regions overlap by design, so unlike cell
paste there's no destination wipe.

## Quantize

vm exposes paired domain verbs `vm:quantize{Selection,All}` and
`vm:quantizeKeepRealised{Selection,All}`. The selection-vs-all-with-
confirm UX choice lives in rm, which dispatches to one or the other.

- **`quantizeScope`** — snap every event to the nearest row under the
  current swing; notes preserve logical length in rows.
- **`quantizeKeepRealisedScope`** — move intent onto the grid
  **without changing realised time**: intent shifts, delay absorbs
  the inverse. The required delay is written verbatim; tm clamps raw
  at realisation when necessary, and any residual divergence between
  authored delay and realised onset surfaces as `delay ≠ delayC` in
  the painter.

Reswing is not a vm verb. Swing changes broadcast as `configChanged`;
tm's subscriber marks affected channels via `tm:markSwingStale` and
`tm:rebuild`'s stale-swing reseat rederives raw from each event's ppqL under the
new swing. Cross-take propagation is `seqMgr:reswingAll`, which binds
each affected take through `tm:bindTake(opts.markSwingStale=true)`.

## Retune

`vm:retune(slots)` puts every note in scope — `slots.scope` is `'selection'`
or `'all'` — on its own step of the active temper. Snap sets no target — it is
the absence of one — and with no active temper the verb does nothing, there being
nothing to snap to. A note already seated is skipped:
`ctx:noteDeviation`'s `gap` clears sub-1e-6 serialisation dust before
returning, so `gap ~= 0` reads "off its step" with no second epsilon
anywhere.

Strength is how far toward that step the note actually moves: it interpolates
in cents from the pitch and detune the note carries to the pair snap computed,
so at 1 every note reaches its step and at 0.5 each closes half the distance.
A blend sits between two steps, so it is re-seated on the nearest semitone —
plain snap never needs that, `stepToMidi` handing back a seated pair already.
At 1 the computed pair therefore stands untouched, which is what keeps the
past-127 fold below; at 0 the verb returns early, since re-seating a note
carrying more than 50¢ of authored detune would rewrite `(72, +70)` as
`(73, −30)` — same sound, different notation, absorber churn — for a command
asked to do nothing. Below 1 the note is deliberately left off its step and a
second invocation halves the remainder again: the broken idempotence is the
point, not a tolerance.

With a target the verb solves rather than snaps. The scope's notes group into
strands by step-class (`sonority.strands`), `tuning.shortlist` gives each strand
the target's points its window holds, and `sonority.solveToPoints` returns the point each
strand takes; `tuning.seat` puts that point in the register of every note that
writes it, and strength blends the pair exactly as snap's is blended. Shortlists
are built before anything moves, so a step the target leaves nowhere to go
refuses the whole solve rather than half of it, and the verb answers with those
steps for its caller to name.

The caller names them in a confirm and re-enters the verb with `widen` set if the
offer is taken. Each refusing window then stretches by the smallest factor that
reaches a point of the target, which reaches the pair either side of it wherever
the target is closed under inversion, and the solve picks between them on the
sonorities they stand in. A point outside a window moves a note further from
its step than the notation's own spacing allows, which is why the widening is
offered rather than taken: no other facility the command offers does. The cell
keeps the name the note's intent carries and reports the gap in cents
(docs/tuning.md § The written step), so what widening spends is the note's
sound rather than its label.

The target reads two ways, and the facility slot says which. `'points'` is the
solve above; `'moves'` reads the same temper as intervals that may be sounded
pure between one strand and another (docs/tuning.md § A temper read as moves),
and `sonority.solveToMoves` answers with the cents each strand settles at, its
springs holding the spelled intervals as nearly pure as the purity slot asks and
its rests inheriting the share the ambient slot names (docs/sonority.md
§ The dials). Every strand is then seated at those cents,
blended by strength as the others are. The solve takes no key, a move set having
no place on the pitch line, and it states no refusal its caller could name.

Ctrl+T reaches the verb through the retune modal, whose fields are the slots
the verb takes and whose OK is the one commit point — every retuning facility
the tracker grows arrives as a field beside them. Selection is offered whether
or not there is one, `ec:region()` degenerating to the cursor cell, so it then
snaps the note under the cursor. Target, facility and key are seeded from the take
tier and written back there as OK commits, so the modal reopens on the answers
the take carries; a key past the notation's steps — the take having since
changed temper — clamps into range rather than raising. The strength, the
sonority size and the three dials are seeded at their defaults on every open:
harmonic lock at 1 under either facility, purity at 32 and the ambient at 0.25
(docs/sonority.md § The dials).

The target picker offers the library's eligible tempers, `tuning.isTarget`
filtering the rest out of the row list rather than letting one be picked and
refused, and the slots the adaptive solves own — facility, key, sonority size,
harmonic lock, purity, ambient — draw disabled while the target is Off. The
facility is a choice of its own beside the target, nothing in the object
recovering which reading was meant, and it disables three more slots between
them: under `'moves'` the key draws disabled for want of a pitch line to name a
place on, and under `'points'` purity and the ambient do, a point solve pricing
no interval against a spelling and resting a strand on its own step. The lock's
slider and purity's are both logarithmic, only the ratio of the two moving a
settled note; the ambient's is linear, a share being a share. A picker popup
consumes its own Enter and Escape where `IsKeyPressed` cannot see it, so the
modal gates OK and Cancel on `chrome.pickerIsActive()`: without it one Enter
picks a row and commits the modal behind it. Only a take with a temper bound
shows any of this — with no notation there is no window to move inside, and
the modal stands as the scope radio and the strength slider alone.

A note whose nearest step lies past MIDI 127 is a known exception.
`tuning.stepToMidi` folds that overflow into detune rather than dropping
it, so under a twelve-note meantone `(127, +40)` snaps to `(127, +72.63)`
— a pitch on no step. `nudgePitch` refuses the case; snap does not.

## Extra columns & delay sub-column

Columns beyond the data-driven ones are materialised by tm from
`cfg.extraColumns[chan]`. vm owns the user-facing add/remove:

- `addExtraCol(type, cc)` — bumps the `notes` count, sets `ccs[cc]`,
  or sets the singleton flag. Applies to every unique channel in the
  active selection, or the cursor col's channel when no selection.
- `hideExtraCol` — non-note cols: refuses unless the cursor column
  itself is empty. Note lanes: always targets the topmost lane
  regardless of cursor position, refusing unless that lane is empty.
  Lane is rebuild-only at tm (`assignNote` rejects writes), so
  interior holes can't be closed by shifting higher lanes down — a
  previous version tried and silently failed (the column reappeared
  on the next rebuild); hide from the right inwards to drop
  interior-adjacent lanes.
- `showDelay()` — turns on the delay sub-column (via
  `cfg.noteDelay[chan][lane] = true`) on every note col in the active
  selection, or on the cursor col when no selection. Idempotent.

A cc column carrying a param binding is not in that spec at all. The
binding belongs to the **track** — the filter bank, the bus code and the
plink it realises are all the track's — so tm derives the column from the
track's bindings at rebuild, and every take on the track opens with it
already there. Automating writes no column; hiding one drops the binding,
and the column goes from every take at once. What stays per take is what
the column holds: the CC events themselves. A param takes one binding,
since the target carries a single plink and a second would silently take
it over — so re-automating a bound param returns the lane it has, and
asking for it on another channel is refused.

Both refuse on the master channel (§ Addressing a chain): its only column type is fx,
and hiding its one column would leave no cell to select a global region in.

The delay sub-column is a display variant of the note column
(`noteWithDelay` in `STOPS`/`SELGROUPS`), not a separate grid column.

`addTypedCol` (Ctrl-Shift-→) prompts for a non-note column type; note
lanes get their own binding (`addNoteLane`, Ctrl-→) so the prompt's
vocabulary excludes `note`. `resolveColType` in trackerRender.lua reads
bare digits as a cc number and otherwise keys off the first letter —
`c`→pc, `a`→at, `d`→dly, `p`→pb — since those are unique among the
remaining types now that `note` and `cc`'s digit form are out of the way.

## Audition

One pending note-off at a time, keyed by `(midiChan, pitch)`, sent
via `reaper.StuffMIDIMessage`. `vm:tick` (called each frame by rm)
kills stale auditions after `AUDITION_TIMEOUT` (0.8s). MIDI chan is
0-indexed at the REAPER boundary only; everywhere else vm speaks
1-indexed.

## Addressing a chain

**1** A chain hangs on a host, and a host is a channel × ppq span carrying an
fx list (`docs/generators.md` § Hosts and membership). What authoring has to
solve is therefore not what the fx does but how you reach a host that isn't a
cell.

**2** There is one gesture, and the selection decides which host it means.
Select a span on a channel and edit its fx, and the selected channel × ppq
span becomes — or re-opens — an explicit region, its contents irrelevant.
With no selection the cursor's note is edited, because a note is a complete
region by itself: it supplies channel, start and end. That is the law
underneath, and it is the whole of it — no-selection authoring works only on a
cell that is a complete region by itself, and only a note is one.

**3** So fx on a cc column with no selection has no host. The cell gives the
target for free, being a continuous target already, but it gives no window,
and a target without extent is not a region. The tempting repair is to default
the window to the whole take, which quietly reinstates the unbounded host the
model spent its effort removing; "modulate this whole lane" is already spelled
select-all → fx. A third storage site, `column.fx`, is the same mistake in
other clothes: a whole-lane LFO is a region of column × take bounds.

**4** An existing region is addressed the way a note is — by giving it a cell.
The per-channel **fx column** carries each region as a tailed kind-badge:
onset at `startppq`, a note-style tail to `endppq`, a glyph for the primary
kind, and the caret lands on it as it lands on anything else. No second
navigable object and no region mode. The column/cell/tail machinery is the
most native thing the tracker has, so region editing borrows that rather than
the group page's footprint idiom, and the column is cc-like in lifecycle —
data-derived, materialising when the channel first carries a region with a
kind, dropping when the last goes, never proximity-gated — and note-lane-like
in render, overlapping regions packing into sibling columns in storage order,
which is also their precedence (`docs/generators.md` § Multiplicity).

**5** The badge names the primary kind only, which leaves a three-stage chain
looking like a one-stage chain, so the stages' glyphs stack in series order
down the region's tail rows — the palette's own vertical order, and behaviour
readable without opening anything. A kind's glyph is a field on its
`generators.kinds` entry and `generators.glyphOf` is the one place a kind
resolves to a character, so the view mints the badge already holding it and
the grid renderer knows nothing of the set.

**6** `chainStack` keys each stage by absolute grid row rather than by an
offset from the badge, because the badge row and the tail's `startRow` are not
the same kind of number: `placeRow` snaps the badge to its integer row while
the tail keeps sub-row float precision. Keying absolutely lets the stack and
the tail bracket share one row space with no snap-versus-float mismatch
leaking into where a glyph lands.

**7** A chain with more stages than the region has rows gives its last
drawable row to `…`, and where the region is one row deep that row is the
badge's. The clip mark outranks the badge there, because keeping the badge
would preserve today's reading at exactly the size where it lies — a one-row
region carrying `[arp, humanize]` showing `A`, which is the misreading the
stack exists to end. `…` says less and says it truthfully.

**8** Channel 0 is the **master channel**: an fx-only strip standing left of channel 1,
bannered `Gl` where a MIDI channel reads `Ch n`. It carries the **global regions**, those
stored at `chan = 0`, and nothing else — no note, cc, pb, pc or at column — and it is their only
surface, the fx columns of channels 1 to 16 showing nothing of one. Since a region is
minted from a selection, the strip keeps at least one fx column whether occupied or not,
and hide and add-column both refuse there rather than leave it with nothing to select in.
The strip is built in the view: fx columns are derived from `ds:get('fxRegions')` already,
so channel 0 needs no tm channel and gets none. What the strip holds still sounds, though:
the rebuild expands a global region into a producer on every MIDI channel
(`docs/trackerManager.md` § Channel & column model). Column 1 is therefore not where notes
are typed: a take swap opens the caret on channel 1's first note column, and brings the
scroll home in front of it, so the strip stands to the caret's left rather than off the
edge.

**9** The gestures naming a MIDI channel refuse on the master channel: mute and solo,
parameter automation, and freeze. Mute and solo refuse because channel 0 carries no wire
of its own to silence, and because solo mutes the channels it does not name — a solo on the strip
would silence all sixteen. A parameter binding names a channel and a cc lane, and the
strip has neither. Freeze is tm's refusal (`docs/trackerManager.md` § Park window census),
since a chain there realises on sixteen channels and freeze converts one. Paste needs no guard
of its own: it drops any region whose rebased channel falls outside 1 to 16 (§ FX regions).
Channel select stands, selecting the strip's columns rather than binding anything to the
wire, and clicking the `Gl` banner is the mouse route onto it. Every other fx verb is
unchanged there: a verb addresses one stored region by uuid and a global region is one
stored region, so minting, rewriting the chain, moving and resizing the window, deleting,
and adding or editing stages all read the strip as they read a channel.

**10** **Explode** is the strip's own verb, and the way through freeze's refusal: it
replaces a global region with an ordinary region on each channel its chain reaches, which
is the expansion the rebuild was already running, persisted (`docs/trackerManager.md`
§ Channel & column model). Freezing a global chain thus means exploding it and freezing
one of the sixteen, and the same holds of any divergence between channels: one stored
chain speaks for all sixteen until an explode gives each its own. A chain reaching no channel declines, since the explode would leave no
region at all and take the chain with it. Explode and freeze share one chord, Ctrl+E, and
the caret's host picks the arm: at most one of them is ever live, freeze refusing on the
strip and explode refusing off it.

## Note FX stages

**1** The fx list is an ordered series (`docs/generators.md` § The chain); the
editor addresses stages by position, not kind, so duplicate kinds are
expressible. `addFxStage` appends a seeded stage, `removeFxStage` drops the
stage at `index`, `moveFxStage` swaps it with its neighbour (`dir` -1 earlier
/ +1 later, no-op past an edge). All three write the whole list through
`setNoteFx`, which persists per host and collapses an empty list to none.

**2** `setFxBypass` delegates to `setFxField`, storing `bypass = true` or
deleting the key — never `false`, so a chain with nothing bypassed serialises
as it always did. That storage is the criterion: **bypass changes the
realisation and never touches the authored notes.** A chain's parked chord
stays parked whether or not its stages are bypassed, so the toggle moves
nothing between take and stash and `parksNotes` / `parkWindows` never learn
about the flag. What it does reach is the fold (`docs/generators.md`
§ The chain).

## Commands & wrappers

Command registration is split by ownership: ec self-registers
navigation and selection-shape commands via `ec:registerCommands(cmgr)`,
clipboard self-registers `copy/paste` via
`clipboard:registerCommands(cmgr)`, and vm registers everything else
in a single `cmgr:registerAll` at construction. Categories:

- **navigation** (ec) — `cursorDown/Up`, `pageDown/Up`,
  `goTop/Bottom/Left/Right`, `cursorLeft/Right`, `colLeft/Right`,
  `channelLeft/Right`
- **selection** (ec) — `select*` variants, `cycleBlock`, `cycleVBlock`,
  `swapBlockEnds`, `selectClear`
- **clipboard** (clipboard) — `copy`, `paste`. `cut` stays in vm
  because it composes `clipboard:copy()` with `deleteSelection`.
- **edit** (vm) — `delete`, `deleteSel`, `cut`, `duplicateUp/Down`,
  `interpolate`, `insertRow`, `deleteRow`
- **note shaping** — `growNote`, `shrinkNote`, `noteOff`,
  `nudgeForward/Back`, `nudgeCoarse/FineUp/Down`
- **transport** — `play`, `stop`, `playPause`, `playFromTop/Cursor`
- **column management** — `addNoteLane`, `addTypedCol`, `hideExtraCol`
- **display** — `doubleRPB`, `halveRPB`,
  `matchGridToCursor`, `inputOctaveUp/Down`, `inputSampleUp/Down`,
  `advBy0..9`
- **timing** — `setSwingComposite`, `setSwingSlot`, `setColSwingSlot`
- **tuning** — `setTemper`, `setTemperSlot`

`addTypedCol`, `setRPB`, `quantize`, `quantizeKeepRealised`,
`openSwingEditor`, `openTemperPicker`, `openSwingPicker`, `quit` are
owned by rm (they wrap UI orchestration around vm's domain verbs).

See `docs/commandManager.md` for the dispatch protocol and return-code
convention.

vm then applies three families of `cmgr:wrap`:

- **mark-paste cancel** — in mark mode, the first `paste` press
  clears the selection instead of pasting, so the explicit second
  press pastes at the cursor.
- **auto-unstick** — all nudge / grow / duplicate / interpolate /
  row-insert / `noteOff` commands drop sticky flags after running.
  (rm applies the same wrapper to its `quantize` /
  `quantizeKeepRealised` registrations.)
- **auto-selClear** — `delete` / `deleteSel` / `cut` clear the
  selection after running, since the affected events are gone.

The undo label sits on the verb that makes the edit, not on the command that
reaches it. `registerAll`'s tuple form wraps the command's own body in a
labelled block, so a body that only opens a confirm or a modal closes that
block before the edit arrives — in a callback frames later.

`tv:quantizeSelection/All`, `tv:quantizeKeepRealisedSelection/All`,
`tv:hideExtraCol`, and `tv:unautomateParam` each wrap themselves with
`util.atomic` instead, so the label covers every path in — key, menu, confirm
callback, and patternEditor's own registration of `hideExtraCol`.
`util.atomic` reads `Undo_BeginBlock`/`Undo_EndBlock` lazily, so a wrapped
verb invoked from inside another wrapped verb (`unautomateParam` calling
`hideExtraCol`) collapses into the outer block rather than opening a nested
one.

The retune modal keeps its label on the callback (`runRetune` in
`trackerRender.lua`) rather than on `vm:retune`: the callback is the only
place holding the slots the modal chose, so it is the only place the block
can open. A refused solve writes nothing, so its block is empty and the
widened solve the offer re-enters opens one of its own.

## Conventions

- **Rows 0-indexed, cols 1-indexed, channels 1..16, stops 1-indexed.**
- **`vm.grid` is a live handle** — rm reads it each frame; it is
  mutated in place on rebuild, never reassigned, so rm need not
  re-fetch.
- **rm is pull-only.** vm fires no render callbacks; rm queries
  `vm.grid`, `vm:ec()`, `vm:rowPerBar()` etc. each frame, and reads
  pure config (`rowPerBeat`, `currentOctave`, `advanceBy`) directly
  from cm rather than through vm.
- **Callers speak logical** — every authoring call site in vm and
  clipboard sends `evt.ppq` / `evt.endppq` in the logical frame;
  `tm:addEvent` / `tm:assignEvent` stamp `ppqL` / `endppqL` and
  derive raw via `fromLogical`.
- **Row encoding in the clipboard uses the source column's swing**;
  paste decodes into the destination column's. Round-trip is
  symmetric, not absolute-ppq.
- **Off-grid writes snap intent + ppqL** to the cursor row;
  delay survives, frame restamps to current.
