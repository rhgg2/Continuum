# eventMeta

Per-event metadata (a note's detune/delay/sample, a cc's `ppqL`, the fake-pb
flag — anything `midiManager` does not store structurally) persisted across
save/load, keyed by the **pool guid** of the take that carries the event.

## Why pool-keyed, not take-keyed

A note's uuid lives in a sidecar event *inside the MIDI source* (`midiManager`'s
type-15 notation event). Pooled takes share one `POOLEDEVTS` source, so they
share every note and every uuid sidecar. The metadata blob the uuid points at,
though, used to live in per-take extension data — and a take's ext-data does
*not* ride the pool.

The two diverged. Authoring detune on the bound instance wrote that instance's
ext-data; a pooled sibling kept the uuid (shared) but a stale or empty blob (its
own ext-data). Any operation that surfaced a different instance — deleting the
authored copy and parking a sibling on the scratch track, or dropping a fresh
instance off the parked keeper — exposed the gap: the note rendered, its
metadata did not. (The reported bug: "parking a take on scratch desyncs its
notes from their metadata.")

Keying by pool guid closes it. Metadata is a property of the source content,
exactly like the notes and their uuids; it belongs with the pool, not the
instance. Every pooled take resolves the one blob.

## Storage

A thin face over `pextStore`'s `project` scope (so the engine's projext and
undo machinery carry it), under two slot families per pool:

- `ctm.<guid>.keys` — the live uuid set. projext has no enumerate-by-prefix, so
  the uuids under a pool are tracked explicitly; this is the loader's index.
- `ctm.<guid>.u.<uuidTxt>` — one `util.serialise`d field table per event.

`saveOne` extends the keys set only when a uuid is new, so re-stamping an
existing event stays a single-entry write — the keystroke-latency budget
`midiManager` cares about (see docs/midiManager.md § Metadata I/O). The blobs are
opaque here: which fields count as metadata (the structural strip) is
`midiManager`'s alone.

## Pooled vs unpooled

Pooling shares; unpooling forks. A pooled clone keeps the source guid, so it
shares the metadata for free. An *unpooled* clone (REAPER's "new MIDI item"
mint, or a `rePool` chunk-clone) gets a fresh guid and would start empty —
`arrangeManager` calls `copyPool(srcGuid, dstGuid)` at each such mint to fork
the source's blob onto the new pool. The genuine forever-delete (`deleteSlot`)
calls `dropPool` to clear it; project-scoped metadata otherwise outlives the
take, since it no longer dies with the take's ext-data.
