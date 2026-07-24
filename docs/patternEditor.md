# patternEditor

The fx-pattern checkout stack: a private, full mm/tm/tv tracker over a
checkout take parked on the scratch track.

## Lifecycle

`open(body, commit)` mints a take on scratch and materialises `body`
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
materialise scaled by), and hands it, `deepEq`-guarded, to the `commit`
callback taken at open — in production `tv:setFxField`, which writes the
body back onto the owning fx entry. The field pick *is* the whitelist:
nothing that leaks onto the checkout take survives readback.

`armed` gates the subscriber. Three rebuilds fire around a genuine edit whose
take isn't the body — `bindTake`, the materialise flush at open, and the
unbind at close — and each must stay silent, or open would clobber the param
with an empty take and close would overwrite it on the way out. So `open`
arms only after materialising, and `close` disarms on its first line.

Esc and Enter split accordingly: write-through already made the param track
every keystroke, so **Enter** merely closes (the param is current) and
**Esc** restores the snapshot taken at open with one guarded write. Cancel is
therefore a single write, not an undo of each edit.

The toolbar's **Commit** and **Cancel** buttons mirror Enter and Esc. The toolbar
runs inside the modal's chrome style push (`modalHost` pushes it), so its widgets
match the main toolbar with no local style block. A button click lands in `draw`,
which owns no `close` handle, so it only flags `pendingAction`; `handleInput`
(which does hold `close`) drains the flag on the same frame and routes it to the
same close/cancel path the keys use.

## The copy shelf

Save and Load put a named copy shelf on the toolbar. The shelf is the
`fxPatterns` project key, read and written through the *host* `ds` (threaded in
as `hostDs`) — not the mini stack's own `ds`, which never writes a project tier.
It is a copy shelf, not live sharing: both directions deep-copy, and a shelf edit
re-realises nothing. (The P2 design gave `fxPatterns` a `dataChanged` arm that
rebuilt every consumer; the P3.5 inline pivot made params store their own body,
so that arm and its `derivationInputs` entry are gone.)

Save writes `readbackBody()` — the same whitelisted shape write-through commits —
so a later edit `deepEq`s clean against a saved copy. Save is a `chrome.drawPicker`
like Load: its items are the existing matching-kind shelf names, so overwriting one
is an explicit pick from a visible list, and typing a fresh name fires the picker's
`onCreate` hook. There is no y/n confirm — picking from the list *is* the
confirmation, and a typed name only reaches `onCreate` when it collides with
nothing.

Both widgets stay *inside* the editor modal: `modalHost` holds one state slot, so
opening its prompt from within the editor would replace the editor itself. Both
are `chrome.drawPicker` popups, whose items are the shelf names this editor can
materialise — filtered by `kind`, and for curves by `domain` too, since the
generator is coded against the domain and a `normalized` param must never be
handed a `cc` body.

Load reopens the checkout on the picked body in place, so `open` re-runs the
loop-length, column and `pbRange` setup. This forces the snapshot split: `open`
records the modal-open body as `openSnapshot` (Esc's restore target) separately
from `editBody` (live metadata readback reads off), and a Load replaces
`editBody` while preserving `openSnapshot` — so Esc after a Load still restores
what the modal opened on, not the loaded body.

## Ownership

Owns `ps`/`cm`/`ds`/`eventMeta` plus the full `mm`/`tm`/`tv`/`cmgr`/`ccm`/`pa`
stack, wired like the harness `mk` shape. The mini stack never writes a
project/global config tier — its only outward channel is the `commit`
callback taken at open. `bind`/`unbind` pass `skipGuard` so the checkout
on scratch never touches the host's guarded track.

See `design/fx-patterns.md` § The checkout model / § The mini stack for the
fuller design and the alternatives considered.
