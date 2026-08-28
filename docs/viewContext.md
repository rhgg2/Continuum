# viewContext

**A pure snapshot of the tracker's row and temperament coordinates,**
built once per `vm:rebuild` from `length`, `numRows`, `rowPerBeat`,
`ppqPerRow`, `timeSigs` and `temper`. No callbacks, no mutation, no
migration: a changed input means a new ctx, and the old one is
discarded.

## Rows and PPQ

1. Rows are uniform. `ppqToRow(ppq)` is `ppq / ppqPerRow` and
   `rowToPPQ(row)` is `row * ppqPerRow`, each saturating at the take's
   ends — 0 and `numRows` one way, 0 and `length` the other.

1. Within the take both return a float and neither rounds, so the two
   are exact inverses. `ppqPerRow` is `logPerRow(rpb, denom, res)` held
   unrounded for this reason (`docs/timing.md § Cross-frame
   invariants`).

1. An integer row is therefore a fixpoint of the round trip, and
   `snapRow(ppq)` rounds `ppqToRow` to name the nearest.

1. `ppqPerRow()` exposes the bound width, so a caller computing the
   logical ppq at a destination row — clipboard paste, for example —
   works in the same units.

1. Every conversion takes a `chan` argument and none uses it.
   viewManager sees the logical frame, where swing has not been
   applied (`docs/timing.md § Frame ownership`); the argument is
   retained so a call site reads the same at every layer.

## On the grid

1. An event is **on the grid** when its logical ppq lands on a row.
   The frame is float, so the test cannot be equality against
   `rowToPPQ(snapRow(ppq))`.

1. `PPQ_GRID_EPS` is half a ppq tick, matching the granularity of mm's
   integer raw frame: two positions within that distance of the same
   row boundary flush to one raw note.

1. `isOnGrid(ppq)` is the owner of the threshold. A caller re-deriving
   the test from `rowToPPQ` gets a different answer.

1. `placeRow(ppq)` answers the three row questions in one computation
   — the float row, the row the cell draws on, and on-grid — because
   the rebuild loop needs all three for each event.

## Bars and beats

1. `timeSigs` is the take's ordered list of signature changes, each
   carrying the ppq it takes effect at. A row's signature is the last
   one at or before it.

1. `rowBeatInfo(row)` reports whether the row starts a bar and whether
   it starts a beat, measured from the row its signature began on.

1. `barBeatSub(row)` numbers the row — bar, beat within the bar, row
   within the beat, all 1-based — and returns the governing signature.
   Bars accumulate across signature changes, so the count runs from
   the take's start.

## Temperament lenses

1. `noteLabel` and `noteDeviation` both take the note's written step
   from `tuning.noteStep`, so a note a solve moved keeps the name it
   was written with (`docs/tuning.md § The written step`). Each
   returns nil when no temperament is active.

1. `noteLabel(evt)` spells the step as the parts of a cell label:
   note, octave, and the octave's negativity
   (`docs/tuning.md § Display`).

1. `noteDeviation(evt)` returns the signed cents between where the
   note sounds and its written step. The gap may exceed the step's own
   width.

1. `activeTemper()` returns the bound temper, which viewManager reads
   for cell and octave widths.

## On the temper

1. A note is **on the temper** when it sounds at the step it was
   written on, so its deviation is zero. The cell draws the deviation
   as a readout in cents whenever it is nonzero.

1. A detune round-trips through `util.serialise`, which does not
   preserve doubles exactly, only to within around 1e-12.

1. `noteDeviation` clears any deviation below `ON_TEMPER_EPS`, around
   1e-6, so that being on the temper round-trips.

## Relationship to trackerView

1. trackerView builds the view context at the end of `vm:rebuild` and
   holds the only reference. It is internal to the tracker stack.

1. viewManager forwards the viewContext API surface to potential
   callers.

1. The exception is clipboard, which accesses viewContext directly as
   a sibling within the same layer.

1. trackerView guards its cell cache with `projectionEpoch`, a
   signature over the same values the view context is built from. The
   projection is a pure function of those, so a built cell stays valid
   exactly while the signature holds.
