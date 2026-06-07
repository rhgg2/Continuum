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
  is a hidden REAPER track tagged `wiringScratch='1'`, found-or-created
  lazily; it also parks FX whose `srcSet` is empty (disconnected, or
  inert `__scratch__` nodes) so they exist without polluting the audible
  topology.
- **Track change is a move, not a re-create.** When the partition
  reassigns a node to a different track, the applier issues
  `rm:assignFx{track}` (a move, not delete+add) — plugin state (params,
  presets, internal buffers) survives; a delete + re-add would lose it.
- **Delete only on departure.** wm deletes a REAPER FX instance only
  when its owning node — or the CU bridge it backs — leaves the graph.
  CU bridges arrive at the applier with a nil `fxId` and are minted by
  `reconcileFXChain`, the same path as user FX.

Where a `fxId` *currently lives* — its `(track, fxIdx)` — is derived, not
intent: the reconcile pass migrates and reorders instances, so the slot is
only authoritative right after `applyOps`. That is exactly where the
`fxLocations` index is restamped. `wm:locateFx` reads it (validating the
cached slot still holds the guid, sweeping once and repopulating on
miss/drift) so on-demand callers like `showFxWindow` never scan the project.
The index is volatile realisation state — kept in memory, never persisted onto
the graph, and rebuilt from REAPER on the next reconcile.

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
inserts a raw REAPER track immediately, bypassing clone/validate/swap.
The trackKey for source hosts is the track's own GUID (a singleton class:
one physical track per source node), so no separate `wiringTrack` ExtState
key is needed to carry it; `wm:snapshot` derives the trackKey directly
from the track's rm `id` (which is its guid).

## diff op ordering

`wm:diff` emits ops in a fixed order so the applier can apply them
without look-ahead:

1. **creates** — fresh tracks exist before any `setSends` references them.
2. **trackKey-transition drains** — old extstate cleared before the key
   moves to a new track.
3. **setFXChain / setMainSend / setSends / setExtState** — per-track state
   written after identity is stable.
4. **deletes** — tracks removed last, after sends pointing at them are gone.

snap entries absent from target, entries whose `trackKind` changed, and
`trackKind='newTrack'` entries are deleted. `sourceTrack`, `scratch`, and
`master` are project artefacts — never deleted, but drained on a trackKey
transition. `setFXChain`/`setMainSend`/`setSends` ops carry `trackKind` so
the applier can resolve master (which has no `wiringTrack` ExtState tag)
without a tagged GUID.

## pokeEdgeGain routing

`wm:pokeEdgeGain` writes the gain for a single edge on the drag hot path —
no mutate/signal/undo block. The dispatch depends on edge kind:

- **CU bridge** (edge has a materialised `cuGuid`): calls `TrackFX_SetParam`
  on the `'gain'` parameter of the CU FX instance.
- **Hosted edge** (`gainHost` path): writes `D_VOL` on the edge's native
  host — a track-to-track send for ordinary edges, or the from-track fader
  for the parent/master send.

Returns `false` when nothing hosts the edge yet; the caller
(`wv:setEdgeGain`) is responsible for materialising before the next poke.

## Merge CU

When two same-track MIDI producers fan into one consumer, the applier collapses
them to a Merge CU on the consumer's track. The CU reads the feeder buses
(`inMask`) and rewrites them to a single `outBus` the consumer reads. Its guid
is stamped onto the consumer node so reconciles are idempotent, and the CU
retracts when the fan-in drops back to a single feeder. Cross-track MIDI sends
instead coalesce onto one dest bus with no CU (see `docs/DAG.md § MIDI`).

## The reaper seam

The reconcile pipeline routes every topology read and write through rm, so
wm names tracks and FX by record `id`, never a handle. What raw `reaper.*`
remains is a small, deliberate residue — the things rm's record vocabulary
cannot express because they are wm-private:

- **`eachTrack`** — one `CountTracks`/`GetTrack`/`GetTrackGUID` scan. wm's
  trackKey↔guid↔handle addressing and the scratch/source ext-state tags
  hang off a raw `MediaTrack` handle, which rm refuses to expose, so the
  scan that resolves them stays wm's. Every other reaper enumeration folded
  into this one.
- **Scratch handle + `ValidatePtr2`** — `pollUndo` watches the scratch
  track's liveness to detect an undo past its creation. That is a handle
  identity check, not a routing op.
- **The live poke path** (`pokeEdgeGain`/`fastGainCommit`/`pokeCuParam`) —
  a fader drag writes one param or `D_VOL` per frame, too hot for the
  wholesale `rm:assignTrack{sends}` diff. It stays a direct
  `TrackFX_SetParam`/`SetTrackSendInfo` until the cost proves it needs a
  targeted rm primitive (see `docs/routingManager.md § Eager reads`).
- **`readCuParams`** — the CU's slider layout is wm/CU-private; rm reads
  generic params but not this app-specific encoding.
- **`readJsfxContent`** — reads a JSFX file off disk (via `fs`), not the
  project graph.

## wiringOp

`wiringOp` records are full-replace ops emitted by the compiler and consumed
by the applier. Each has an `op` field and additional keys depending on kind:

- **`createTrack`** / **`deleteTrack`** — carry `trackKey` and `trackKuid`.
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
- **`setExtState`** — carries `key` and `value` for track ExtState writes.
