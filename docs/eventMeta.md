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

A thin face over `pextStore`'s `project` scope, declared undoable by the
`ctm.` prefix — the engine mirrors every write onto the scratch track so
REAPER undo rewinds it (docs/pextStore.md § The mirror) — under two
slot families per pool:

- `ctm.<guid>.kb` — the bucket index: which entry buckets exist.
- `ctm.<guid>.e.<b>` — one `{ [uuid] = fields }` table per bucket
  (`b = uuid // 256`). projext has no enumerate-by-prefix, so `kb` tracks
  the buckets; the bucket itself is both the data and its enumeration.

`flush` groups edits by bucket and read-modify-writes only the touched
buckets, so a keystroke costs one bounded bucket round-trip — the
keystroke-latency budget `midiManager` cares about (see
docs/midiManager.md § Metadata I/O). The field tables are opaque here:
which fields count as metadata (the structural strip) is `midiManager`'s
alone.

## Granularity

The shape above is the fourth attempt; each predecessor died to a
measured hot path, so the lineage is worth keeping:

1. **Flat keyset + one slot per uuid.** The loader's uuid set was a
   single blob, re-parsed on every metadata flush — O(pool) per
   keystroke, ~5k entries on a saturated pool. It dominated flush time
   while the actual writes were 0–1.
2. **In-memory keyset cache.** Killed the re-parse, but the *write*
   stayed monolithic: any uuid birth or death reserialised the whole
   set (~5ms per note-entry keystroke on a ~12k-uuid pool). It also
   bought a staleness protocol: `load` as the sole re-sync point, cache
   drops on `projectRewound`.
3. **Key buckets.** Bounded the keyset write to one ~256-uuid bucket —
   but each event still held its own `u.<uuidTxt>` slot, so a saturated
   pool carried ~12k+ undoable slots. The projext-undo mirror pays 2
   scratch reads + 3 writes per undoable assign, with bucket manifests
   proportional to the pool's *slot count* (~9KB each at 14k events): a
   384-entry flush cost ~585ms, nearly all of it mirror traffic.
4. **Entry buckets** (current). The fields live in the bucket, so slots
   per pool collapse to ~pool/256 + 1: mirror manifests are near-empty
   and a flush costs O(touched buckets). With no per-flush O(pool) work
   left there is nothing to cache — the keyset cache and its staleness
   protocol are deleted outright, and an external rewrite (undo/redo)
   is simply visible to the next `load`.

The keystroke bound is one ~256-entry bucket reserialise; `BUCKET` is
tunable down if that ever shows in the perf tree.

## Pooled vs unpooled

Pooling shares; unpooling forks. A pooled clone keeps the source guid, so it
shares the metadata for free. An *unpooled* clone (REAPER's "new MIDI item"
mint, or a `rePool` chunk-clone) gets a fresh guid and would start empty —
`arrangeManager` calls `copyPool(srcGuid, dstGuid)` at each such mint to fork
the source's blob onto the new pool. The genuine forever-delete (`deleteSlot`)
calls `dropPool` to clear it; project-scoped metadata otherwise outlives the
take, since it no longer dies with the take's ext-data.
