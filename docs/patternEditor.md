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

## Ownership

Owns `ps`/`cm`/`ds`/`eventMeta` plus the full `mm`/`tm`/`tv`/`cmgr`/`ccm`/`pa`
stack, wired like the harness `mk` shape. The mini stack never writes a
project/global config tier — its one shared write, the `fxPatterns`
library itself, goes through the *main* `ds` handed in at construction, not
the mini one. `bind`/`unbind` pass `skipGuard` so the checkout on scratch
never touches the host's guarded track.

See `design/fx-patterns.md` § The checkout model / § The mini stack for the
fuller design and the alternatives considered.
