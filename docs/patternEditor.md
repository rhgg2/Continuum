# patternEditor

The fx-pattern checkout stack: a private, full mm/tm/tv tracker over a
checkout take parked on the scratch track.

## Lifecycle

`open(name)` mints a take on scratch and materialises `name`'s stored body
onto it (notes via `mm:add`, curves as pb events scaled by `pbRange`), then
binds the mini `tm`. `close()` unbinds, deletes the checkout item, and
drops the pool metadata `eventMeta` wrote — skipping that leaks the pool's
projext blobs forever, since the item is never slot-registered to trigger
`deleteSlot`'s keeper-removal.

## The endL row

A curve body's final anchor — the envelope/LFO endpoint — sits at
`ppq = lengthPpq`, the loop boundary. `viewContext:ppqToRow` clamps any
`ppq >= length` to the phantom row `numRows`, one past the last cursorable
row, so at the true loop length the endL anchor has no grid cell: it can't be
displayed, and a keystroke on the last row creates a duplicate instead of
editing it. So `open` sets the *live* loop one ppq longer than `lengthPpq`,
making `ppq = lengthPpq` a strictly-interior position with its own row. The
stored body keeps the true `lengthPpq` (readback reads points by ppq, not by
loop length), and the checkout is discarded on close, so the extension never
escapes the mini take. The curve pane caps its span at the endL anchor, so the
extra row shows only in the grid.

## Write-through commit

Edits persist by write-through, not a discrete save. The mini `tm` fires
`rebuild` after every flush; a subscriber reads channel 1 back, rebuilds the
whitelisted body (notes drop `fx`/`chan` and fix lane 1; a curve normalises
the pb column's cents back to bipolar by the same `pbRange` factor
materialise scaled by), and `deepEq`-guards a read-modify-write into the main
`fxPatterns` — one document, so the whole map is rewritten to preserve
siblings. The field pick *is* the whitelist: nothing that leaks onto the
checkout take survives readback.

`armed` gates the subscriber. Three rebuilds fire around a genuine edit whose
take isn't the body — `bindTake`, the materialise flush at open, and the
unbind at close — and each must stay silent, or open would clobber the store
with an empty take and close would overwrite it on the way out. So `open`
arms only after materialising, and `close` disarms on its first line.

Esc and Enter split accordingly: write-through already made the store track
every keystroke, so **Enter** merely closes (the store is current) and
**Esc** restores the snapshot taken at open with one guarded write. Cancel is
therefore a single write, not an undo of each edit.

## Ownership

Owns `ps`/`cm`/`ds`/`eventMeta` plus the full `mm`/`tm`/`tv`/`cmgr`/`ccm`/`pa`
stack, wired like the harness `mk` shape. The mini stack never writes a
project/global config tier — its one shared write, the `fxPatterns`
library itself, goes through the *main* `ds` handed in at construction, not
the mini one. `bind`/`unbind` pass `skipGuard` so the checkout on scratch
never touches the host's guarded track.

See `design/fx-patterns.md` § The checkout model / § The mini stack for the
fuller design and the alternatives considered.
