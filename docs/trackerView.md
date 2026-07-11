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
  (e.g. clipboard paste) can compute ppqL at the destination row. The
  `chan` argument is retained on the call signature but unused at this
  layer — column-level swing transforms happen above, when events are
  written into / read out of the column tree.
- **Temperament lens.** `noteProjection(evt)` resolves `(pitch, detune)`
  into `(label, gap, halfGap)` under the bound temperament, or nil if
  none active. (Pure coordinate query — see `docs/tuning.md` for the
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

`evt.ppqL` is not consulted by rebuild's row placement — it exists
as the canonical authoring stamp that survives swing changes (tm's
rebuild's stale-swing reseat rederives raw from ppqL when a channel is marked
stale) and for editing operations that need the unswung row position.

## Ghost sampling

For each consecutive scalar pair whose first event has a non-step
shape, `vm:rebuild` samples the curve at every row strictly between
A and B (skipping occupied rows) and writes `{ val, fromEvt, toEvt }`
into `gridCol.ghosts[y]` for rm to render. The sample point for row
`y` is `ctx:rowToPPQ(y, chan)` — so under swing the ghost reflects
the value at the row's realised time, not at "fraction of rows
traversed". Curve evaluation is delegated to `tm:interpolate` (which
forwards to `mm:interpolate`); the shape / tension / bezier-handle
table are owned by midiManager.

`pa` events are not ghosted — they live inside note columns.

## Grid shape (vm's output to rm)

```
grid.cols         = { <col>, <col>, ... }     -- flat, 1-indexed
grid.chanFirstCol = { [chan] = i }            -- dense 1..16
grid.chanLastCol  = { [chan] = i }
grid.lane1Col     = { [chan] = <col> }        -- first note col per chan
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

Two clip modes:

- **single** — one column selected. `type` ∈ `{ note, 7bit, pb }`;
  the selgrp at copy time picks `note` vs `7bit` for note columns.
- **multi** — multiple columns. Each entry carries `chanDelta`
  (relative to leftmost source channel) and a `key`: lane index for
  notes, cc number for ccs, nil for singletons.

Paste heuristics:

| clip.type | dstCol.type   | selgrp | behaviour                                      |
|-----------|---------------|--------|------------------------------------------------|
| note      | note          | 1      | wipe region, write notes with carried velocities |
| pb        | pb            | *      | wipe region, write pb stream                   |
| 7bit      | cc / at / pc  | *      | wipe region, write val stream                  |
| 7bit      | note          | 2      | `pasteVelocities` — carry-forward onto note-ons, optionally synth PAs on sustain rows |

Multi paste resolves each clip col via `chanDelta` from the cursor's
channel; destinations missing (out-of-range channel, no matching
cc/singleton column) are skipped. Notes anchor to the cursor's lane,
other clip cols shift relative.

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
identity is its window, not the rectangle that caught it (see decision
2026-07-11). Paste stacks — regions overlap by design, so unlike cell
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

## Note FX stages

The fx list is an ordered series (C1); the editor addresses stages by position, not kind, so
duplicate kinds are expressible. `addFxStage` appends a seeded stage, `removeFxStage` drops the
stage at `index`, `moveFxStage` swaps it with its neighbour (`dir` -1 earlier / +1 later, no-op
past an edge). All three write the whole list through `setNoteFx`, which persists per host and
collapses an empty list to none. See `design/note-macros-v2.md` § The fx chain, § Build progress C4.

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
