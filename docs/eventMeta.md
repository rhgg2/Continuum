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
undo machinery carry it), under three slot families per pool:

- `ctm.<guid>.kb` — the bucket index: which key buckets exist.
- `ctm.<guid>.keys.<b>` — one uuidTxt set per bucket (`b = uuid // 256`).
  projext has no enumerate-by-prefix, so the uuids under a pool are tracked
  explicitly; the buckets are the loader's index.
- `ctm.<guid>.u.<uuidTxt>` — one `util.serialise`d field table per event.

`flush` extends the keys set only when a uuid is new, so re-stamping an
existing event stays a single-entry write — the keystroke-latency budget
`midiManager` cares about (see docs/midiManager.md § Metadata I/O). The blobs are
opaque here: which fields count as metadata (the structural strip) is
`midiManager`'s alone.

## Keyset cache

The keys set is read once per metadata-touching flush to fold in adds/deletes.
Unserialising it is O(N) in the pool's whole uuid count — for a saturated pool
(every note carries detune) that was ~5k entries re-parsed on every keystroke, to
write one slot. It dominated flush time (`meta` in the perf tree) while the actual
writes were 0–1.

So the set is held in memory (`keysCache`, keyed by guid) and only round-trips to
projext when it changes. This is safe because the cache can only go stale via an
external projext rewrite — REAPER undo/redo — and that path already re-enters
through `load`: membership changes only on structural edits, which rewrite the
MIDI take, so the tracker's take-hash watcher fires `reloadFromReaper` → `load`.
`load` clears the guid's cache and re-reads, making it the sole re-sync point. A
value-only edit (detune change on an already-keyed note) leaves membership — and
the cache — correct with no reload. Field *values* are never cached; `load`
reads each `ctm.<guid>.u.<uuidTxt>` blob fresh.

Caching killed the re-parse, but the *write* stayed monolithic: any uuid birth
or death reserialised the entire keys set — for a saturated ~12k-uuid pool,
~5ms of serialise + `SetProjExtState` per note-entry keystroke (`keys` under
`meta` in the perf tree). Hence the buckets: a birth/death rewrites one
~256-uuid bucket, and the tiny bucket index only when a bucket is born or
dies. Same re-sync rule as before: `load` drops the whole cached index and
re-reads.

## Pooled vs unpooled

Pooling shares; unpooling forks. A pooled clone keeps the source guid, so it
shares the metadata for free. An *unpooled* clone (REAPER's "new MIDI item"
mint, or a `rePool` chunk-clone) gets a fresh guid and would start empty —
`arrangeManager` calls `copyPool(srcGuid, dstGuid)` at each such mint to fork
the source's blob onto the new pool. The genuine forever-delete (`deleteSlot`)
calls `dropPool` to clear it; project-scoped metadata otherwise outlives the
take, since it no longer dies with the take's ext-data.
