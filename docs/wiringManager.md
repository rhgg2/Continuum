# wiringManager

Persistence + validation seam *and* the compile pipeline for the
wiring page. The page edits through wm, wm gates writes through
`DAG.validate` and persists to cm; on every change wm reconciles the
derived REAPER topology against the live project. For the graph model
and the four anchor decisions (reconcile authority, live compile,
ownership marker, foreign adoption) see `docs/wiring.md`.

## One project-tier cm key

The user graph is `{ nodes, edges, _nextId }` — a small structured
value with internal cross-references. Storing nodes and edges in
separate cm keys would open a window where a partial load can yield
an edge pointing at a node that hasn't been read in yet, and where
the `_nextId` allocator can desync with the node table. One blob,
one load, one write — `wiringGraph` is welded.

## The mutate transaction

Every authoring gesture funnels through `wm:mutate(fn)`:

1. clone the current graph into a draft
2. caller mutates the draft
3. `DAG.validate` checks the result
4. on pass — swap, persist via cm, emit `wiringChanged`
5. on fail — return `false, err`; in-memory state and on-disk state
   are both untouched, no signal fired

Clone-then-validate-then-swap means a bad mutator (or a logically
inconsistent intermediate state during a multi-step edit) never lands
on disk and never broadcasts a corrupted graph downstream. The differ
subscribing to `wiringChanged` can assume validation has already
passed.

## The reconcile pipeline

`wiringChanged` (and `wm:load`) drives four pure-ish stages, each a
separate, separately-testable function:

1. **`wm:targetState`** — projects the user graph into the desired
   REAPER shape: `DAG.allocate(ctx:targetTracks())`, then `projectEntry`
   per track. The *target* side.
2. **`wm:snapshot`** — reads the current REAPER project for owned tracks
   + FX into the **same shape**. The *actual* side.
3. **`wm:diff(target, snap)`** — a pure `WiringOp[]` producer comparing
   the two element-wise.
4. **`wm:applyOps(ops, label)`** — dispatches the op list to rm
   (`rm:addFx`/`assignFx`/`assignTrack`/…) inside one `rm:transaction`.
   `rm:addFx` returns the minted guid synchronously, so wm stamps it into
   the user graph inline — no deferred stamp-back pass.

The load-bearing design choice is that **target and snapshot emit
matching shapes**, so `diff` is a structural comparison rather than two
bespoke readers reconciled by hand. Every place the two sides could
disagree — FX order, MIDI bus, pin maps, send tuples — is a field both
producers fill, so the differ stays a field-by-field walk and a tiny
user edit yields a tiny op list. The reverse pressure is real: any
field the target derives, the snapshot must decode back from REAPER, or
the differ churns forever (see *Routing as ground truth*). See
`docs/DAG.md` for the target side's allocator; the snapshot shape is in
the source `--shape wiringSnapshot` and detailed under *wiringSnapshot*
below.

## FX-instance lifecycle

The user graph holds *intent*; REAPER holds *instances*. `fxId` (on
fx-kind nodes, mirroring `trackId` on sources) is the bridge — nil
until first materialised, stamped into the node after rm mints the FX,
and thereafter how snapshot/target match `fx` entries to graph nodes.
Three rules keep instance churn minimal and state-preserving:

- **Mint on a scratch track.** `wm:addFxNode` instantiates the FX
  immediately via `instantiateFxOnScratch`, so the node has a real
  `fxId` (and probed I/O) before it is ever hosted. The scratch track
  is rm-owned (`rm:scratchId`/`scratchTrack`) — a hidden REAPER track
  minted lazily, its guid persisted in projext; it also parks FX whose
  `srcSet` is empty (disconnected, or inert `__scratch__` nodes) so they
  exist without polluting the audible topology.
- **Track change is a move, not a re-create.** When the partition
  reassigns a node to a different track, the applier issues
  `rm:assignFx{track}` (a move, not delete+add) — plugin state (params,
  presets, internal buffers) survives; a delete + re-add would lose it.
- **Delete only on departure.** wm deletes a REAPER FX instance only
  when its owning node — or the CU bridge it backs — leaves the graph.
  CU bridges arrive at the applier with a nil `fxId` and are minted by
  `reconcileFXChain`, the same path as user FX.

Where a `fxId` *currently lives* — its host track and slot — is derived, not
intent: the reconcile pass migrates and reorders instances. wm keeps no index
of its own; it asks rm. `rm:fx(id)` re-resolves the guid each call (the
single-fx counterpart to `rm:track`), returning ports, live params, midi, and
the host `trackId`. On-demand callers read through it: `wm:fxTrack` (the
sampler dive) bridges `rm:fx(id).trackId` to a handle via `rm:reaperTrack`, and
`snapFx` reads a CU bridge's live params from `rm:fx(id).params`. Nothing is
cached or persisted — realisation lives in REAPER, re-read on demand.

## Master is a regular node

The master sits in `graph.nodes['master']` with `kind='master'`,
materialised by `freshGraph()` on first load of an empty project.
Not a special parallel field. The singleton constraint is enforced
by `DAG.validate` — same mechanism that would catch a buggy mutator
minting a second master, rather than two storage shapes encoding the
same rule.

## Routing as ground truth

The per-FX MIDI passthrough flag and the in/out bus bytes have no
`TrackFX_*` API — the state-chunk surgery that reads and writes them now
lives in rm, surfaced as the `fx.midi` record (see `docs/routingManager.md`
and `docs/reaper_midi_routing.md`). wm deals only in records: `wm:snapshot`
carries `fx.midi` straight from `rm:tracks()`, `projectEntry` derives the
target's `midi` from the allocator (`fxMidiBus`) and `nodeHasMidiOut`, and
`fxOrderEq` compares both. A bus or passthrough change drives a
`setFXChain` whose `reconcileFXChain` issues `rm:assignFx{midi}`. There is
no applied-value cache — REAPER's chunk is ground truth, re-decoded by rm
on every snapshot, same as everywhere else in the differ.

**User-facing contract:** Continuum owns the MIDI I/O dialog
("Send all MIDI to plugin" / "Receive MIDI from plugin") and the
input/output bus on every FX in a chain the wiring page manages.
Toggling either by hand in REAPER is reverted to graph intent on the
next reconcile: snapshot reads REAPER's state, so the differ sees the
drift and rewrites it.

## Pre-FX source sends on read

A capacity bisection (and the "source feeds an FX *and* sends its raw
signal elsewhere" case) leaves a source track carrying both an on-track
FX output *and* a pre-FX raw-source send on the same pair. `readGraph`
tracks only the post-FX tail per pair, so a pre-FX send read off the tail
would mis-attribute to the FX (every peeled `source→fx` send round-trips
as `fx→fx`). Read therefore snapshots each track's input (pre-FX) into
`preTails` and routes a `preFx`-flagged send from that tap — the source's
raw pair 1 / bus 0 — instead of the tail.

## Per-FX MIDI routing

The chunk-level encoding of per-FX MIDI routing — input/output bus,
replace-merge mode, and the output-disable flag REAPER keeps in two
mirrored places — moved into rm when the reconcile surgery did. wm no
longer patches FXCHAIN state chunks; it reads/writes the `fx.midi` record.
See `docs/routingManager.md § Wire-format surgery worth knowing` and the
byte-level reference in `docs/reaper_midi_routing.md`.

## wiringSnapshot

The shape both `wm:snapshot` and `wm:targetState` emit (field list in
the source `--shape wiringSnapshot`). The shape is symmetric on
purpose, per *The reconcile pipeline*; the non-obvious parts are *why*
certain fields exist and which side fills them:

- **`fx` entries carrying `params`** are wm-owned CU bridges —
  synthesised `kind='fx'` nodes from the targetTracks merge pass or the
  bracket post-pass. Snapshot mirrors the live params back from the
  slider so `fxOrderEq` is honest; without that mirror every reconcile
  would spuriously emit `setFXChain`.
- **`origin`** is stamped on every *target*-side entry by `projectEntry`
  so the applier knows where to write minted guids back: `{kind='node'}`
  → `node.fxId`; `bracketIn`/`bracketOut` → the consumer's
  `midiInBracketGuid`/`midiOutBracketGuid`; `{kind='merge',consumer,trackKey}`
  → `consumer.mergeGuids[trackKey]`. Snapshot entries carry no `origin` and
  `fxOrderEq` ignores it — it's a write-back address, not state to
  compare.
- **`midi`** (`{inBus,outBus,outDisabled}`) is set on both sides only for
  non-JS `kind='node'` entries: target derives it from the user graph
  (`nodeHasMidiOut`) and the allocator (`fxMidiBus`); snap reads it from
  the rm record. Mismatch drives `setFXChain`; `reconcileFXChain` issues
  `rm:assignFx{midi}`, which writes only the bytes that differ.
- **`pinMaps`** carries pair-lists for every port with a route (target:
  allocator-touched; snap: REAPER non-empty); an absent port means
  disconnected. It rides inline on each `fx` entry — including FX the
  target hasn't materialised yet, whose id-less `setPinMaps` entry the
  applier resolves through `origin` → `fxId` via the stamps from the
  preceding `setFXChain`. rm converts pair-lists to the lo32/hi32 bitmask.
- **`nchan`** is the track's channel count; the main-send target offset
  rides on `mainSend.tgtOffset`, present only when `mainSend.on`.

## createSourceTrack

`wm:createSourceTrack` is called outside the `mutate` transaction — it
inserts a track via `rm:addTrack` immediately, bypassing
clone/validate/swap, and returns its id. The trackKey for a source host
is the track's own id (a singleton class: one physical track per source
node), so it needs no `wiringTracks` entry; `wm:snapshot` derives the
trackKey from the graph's `source` nodes (`node.trackId`), which is that id.

## diff op ordering

`wm:diff` emits ops in a fixed order so the applier can apply them
without look-ahead:

1. **creates** — fresh tracks exist before any `setSends` references them;
   the applier records each new track's id in `wiringTracks[trackKey]`.
2. **cross-track FX moves** — relocated before per-track `setFXChain`.
3. **setFXChain / setMainSend / setSends** — per-track state written after
   identity is stable.
4. **deletes** — tracks removed last (clearing their `wiringTracks` entry),
   after sends pointing at them are gone.

snap entries absent from target, entries whose `trackKind` changed, and
`trackKind='newTrack'` entries are deleted. `sourceTrack`, `scratch`, and
`master` are project artefacts — never deleted, but drained on a trackKey
transition. `setFXChain`/`setMainSend`/`setSends` ops carry `trackKind` so
the applier can resolve master (which has no `wiringTracks` entry) without
a host id.

## pokeEdgeGain routing

`wm:pokeEdgeGain` writes the gain for a single edge on the drag hot path —
no mutate/signal/undo block. `gainRouting` resolves the edge to a target;
`pokeGainTarget` dispatches by kind, each through a targeted rm write:

- **Merge CU** (`mergeCU`): `rm:assignFx(guid, {params={['gain'..slot]=gain}})`
  on the consumer's CU instance.
- **Main send** (`mainSend`): `rm:assignTrack(id, {mainSend={gain}})` — a
  partial scalar write (`assignTrack` patches the fields given; only `sends`
  is full-replace).
- **Send** (`send`): `rm:setSendGain(from, to, gain)`, the targeted send-`D_VOL`
  write reconcile's collection-replace can't serve per-frame.

Each returns `false` when nothing hosts the edge yet (no guid, dead track, or
no matching send); the caller materialises before the next poke. `fastGainCommit`
wraps the same poke plus the scratch mirror in one `rm:transaction`.

## Merge CU

When two same-track MIDI producers fan into one consumer, the applier collapses
them to a Merge CU on the consumer's track. The CU reads the feeder buses
(`inMask`) and rewrites them to a single `outBus` the consumer reads. Its guid
is stamped onto the consumer node so reconciles are idempotent, and the CU
retracts when the fan-in drops back to a single feeder. Cross-track MIDI sends
instead coalesce onto one dest bus with no CU (see `docs/DAG.md § MIDI`).

## The addressing map

wm and rm speak different names for a track. rm hands out an opaque `id`;
wm thinks in `trackKey` (the partition class a node belongs to, computed by
DAG before any track exists). `wiringTracks` is the bridge: a project-tier
`{ trackKey → id }` map persisted alongside `wiringGraph`/`wiringOwnedFx`.

- **Sources** are *not* in the map. A source is a singleton class, so its
  trackKey *is* its id; an unmapped key resolves to itself. snapshot recovers
  source identity from the graph's `source` nodes (`node.trackId`).
- **newTracks** are emergent merge classes with no 1:1 graph node, so the
  applier stamps `wiringTracks[trackKey] = id` when it mints the track and
  clears it on delete.
- **Scratch** is rm-owned and *not* in the map; its guid rides each scratch
  op as `op.trackId`, and every caller reads it via `rm:scratchId()`.
- **Master** is absent; resolvers special-case it to `rm:masterId()`.

The map is written only by `applyOps`, inside the `rm:transaction`, so the
REAPER undo that captures the FX/track ops also captures the addressing — and
it is mirrored to the scratch track's P_EXT for the same reason (project-tier
`SetProjExtState` does not reverse with native undo; see `pollUndo`). Where wm
must hand a raw track to cm's P_EXT writers, the id→handle bridge is
`rm:reaperTrack(id)`.

## pollUndo

Project-tier `SetProjExtState` does not reverse with native undo, but a
track's P_EXT chunk does — so undo-coherence for any durable-but-non-
reversing store means mirroring it onto the scratch chunk and pulling it
back when REAPER rewinds. Two stores need this, split by owner:

- **`rm:pollUndo`** (the frame heartbeat, driven by `wp:tick`) ensures the
  scratch exists and, when its fx-meta mirror diverges from rm's watermark,
  pulls it back into projext via `rm:resyncFxMeta`. This is the permanent
  job — the `primary`/`split` metadata is not recoverable from routing.
- **`wm:pollUndo`** mirrors the `wiringGraph`/`wiringOwnedFx`/`wiringTracks`
  blob (inside the apply transaction) and, when the scratch chunk diverges
  from `lastScratchRaw`, restores the cm project tier and fires
  `wiringChanged{kind='load'}`. A scratch lost to a manual delete or
  undo-past-creation is re-minted empty by the heartbeat; wm then sees the
  missing mirror and fires `load` once so reconcile rebuilds it and re-parks
  fx. This job is transitory: once the implicit-graph work retires the cm
  blob (the graph reverses natively as REAPER routing), `wm:pollUndo`
  collapses and only `rm:pollUndo` remains.

## The reaper seam

The reconcile pipeline *and* the live poke path route every topology read and
write through rm, so wm names tracks and FX by record `id`, never a handle.
Two raw `reaper.*` calls remain — neither a routing op:

- **`readJSFXContent`** — reads a JSFX file off disk (`fs.join` +
  `GetResourcePath`) to parse its bus-aware desc. A filesystem read.
- **Take guard** — `wm:deleteSource` counts a source track's media items
  (`CountTrackMediaItems`) to refuse deleting authored takes. An item-count
  query rm's track/FX vocabulary doesn't model.

Everything else goes through rm: scratch ownership
(`rm:scratchId`/`scratchTrack`), the live gain poke (above, via
`assignFx`/`assignTrack`/`setSendGain`), and CU param reads
(`rm:fx(id).params`).

## wiringOp

`wiringOp` records are full-replace ops emitted by the compiler and consumed
by the applier. Each has an `op` field and additional keys depending on kind:

- **`createTrack`** carries `trackKey`; **`deleteTrack`** carries `trackId`
  and `trackKey` (to clear its `wiringTracks` entry).
- **`setFXChain`** — carries `fxChain` (array of `snapshotFxEntry`). Entries
  with `fxId=nil` mean "instantiate `ident`, stamp GUID back to graph"
  (handled by the applier).
- **`moveFxAcrossTracks`** — relocates a live FX via `rm:assignFx{track}`
  (a move, not delete+add). Emitted before per-track `setFXChain` ops so
  subsequent reconcile sees the FX already at the destination.
- **`setNchan`** / **`setPinMaps`** — emitted between `setFXChain` and
  `setMainSend` so fxGuids are stamped before pin-map writes and channels are
  allocated before pin maps land. `setPinMaps` carries both fxId-keyed and
  origin-keyed maps so unmaterialised FXs lift through the stamps table.
- **`setMainSend`** — carries `mainSend` bool, plus `offs` (C_MAINSEND_OFFS)
  and `nch=2` (C_MAINSEND_NCH) when `mainSend=true`.
- **`setSends`** — carries `sends` (array of `snapshotSend`).
