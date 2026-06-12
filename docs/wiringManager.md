# wiringManager

Validation seam *and* the compile pipeline for the wiring page. The
page edits through wm, wm gates writes through `DAG.validate`; on every
change wm reconciles the derived REAPER topology against the live
project. **REAPER routing is the store** — `wm:read` reconstructs the
graph from it on load, so there is no persisted graph blob (see *Read is
the store*). For the graph model and the anchor decisions (reconcile
authority, live compile, foreign adoption) see `docs/wiring.md` and the
implicit-graph design `design/wiring-implicit-graph.md`.

## Read is the store

There is no persisted user-graph blob. REAPER routing *is* the graph;
`wm:read` reconstructs `{ nodes, edges }` from it (channel/pin maps,
MIDI buses, CU collapse — see `design/wiring-implicit-graph.md`), and
`wm:load`/`ensureLoaded` source the in-memory graph from that read.
Node identity follows: an fx node is keyed by its rm `fxId`, a source
by its track guid, so the id survives a reload (the read re-derives it,
so there is no allocator and no `nextId`). What REAPER cannot store is
**decoration** (node positions) — that rides the rm meta store, keyed by
the same guids; absent meta defaults to `(0,0)`. The only durable wiring
addressing left is each newTrack's `trackKey`, carried on its own track
meta (recovered on read) — no central cm key, no graph blob.

## The mutate transaction

Every authoring gesture funnels through `wm:mutate(fn)`:

1. clone the current graph into a draft
2. caller mutates the draft
3. `DAG.validate` checks the result
4. on pass — swap and emit `wiringChanged`; REAPER realises via the
   reconcile the signal drives (no graph is persisted — the routing
   write *is* the persistence)
5. on fail — return `false, err`; in-memory state is untouched and no
   signal fires, so nothing reaches REAPER

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

On a pure in-memory re-wire the `snapshot` read is skipped — see
*actual-state model* below.

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
fx-kind nodes, mirroring `trackId` on sources) is the bridge — set when
`addFxNode` mints the instance on scratch (never nil for a graph fx node),
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
- **Delete only on departure.** wm deletes a REAPER FX instance only when
  its owning node — or the CU bridge it backs — leaves the graph: the
  full-replace `reconcileFXChain` drops any live fx absent from target (a
  managed track holds only wm fx, so the whole chain is safe to replace).
  CU bridges are the only entries that arrive with a nil `fxId`;
  `reconcileFXChain` mints them. A user fx is already minted on scratch, so
  reconcile only moves and reorders it — it never mints a node fx.

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
materialised by `readGraph` on every load — an empty project reads back
a lone master node. Not a special parallel field. The singleton constraint is enforced
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
- **`origin`** is stamped only on CU-bridge *target* entries (brackets and
  merge CUs — the only fx minted by reconcile) so the applier knows where to
  write the minted guid back: `bracketIn`/`bracketOut` → the consumer's
  `midiInBracketGuid`/`midiOutBracketGuid`; `{kind='merge',consumer,trackKey}`
  → `consumer.mergeGuids[trackKey]`. A node entry carries its `fxId` as `id`
  (minted on scratch before compile), so it needs no origin. Snapshot entries
  carry no `origin` and `fxOrderEq` ignores it — it's a write-back address,
  not state to compare.
- **`midi`** (`{inBus,outBus,outDisabled}`) is set on both sides only for
  non-JS fx-node entries (graph fx, not CU bridges): target derives it from the user graph
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
node), so it needs no `wiringTracks` entry. Source identity is *not*
stored: `wm:snapshot` treats every non-scratch/newTrack/master project
track as a source keyed by its guid, and `readGraph` mints a source node
only for one with no incoming sends — so a hand-added track is adopted,
not foreign.

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
- **Spliced bus tap** (`product`): the tap rides one or more spliced crossings
  (`ctx.splice.parts`); each crossing's host is poked at the product of its
  taps' gains, the poked tap substituting the live drag value. A lone-side tap
  fans out to every crossing — the group fader. A crossing that can't poke
  makes the call return `false`, falling back to materialise-then-reconcile.

Each returns `false` when nothing hosts the edge yet (no guid, dead track, or
no matching send); the caller materialises before the next poke. `fastGainCommit`
wraps the same poke in one `rm:transaction` — the send's `D_VOL` write is the
store, recovered by `read` (there is no graph to persist alongside it).

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
DAG before any track exists). The bridge is a `{ trackKey → id }` map — but
nothing central persists it: **each newTrack carries its own `trackKey` on its
track meta**, and the map is recovered by scanning `rm:tracks()`. The graph
itself is not persisted either (see *Read is the store*); a newTrack's meta
`trackKey` is the only durable wiring addressing, and it reverses with native
undo because per-track P_EXT does.

- **Sources** are *not* keyed. A source is a singleton class, so its trackKey
  *is* its id; an unmapped key resolves to itself. snapshot infers source
  identity structurally — any non-scratch/newTrack/master track is a source
  keyed by its guid.
- **newTracks** are emergent merge classes with no 1:1 graph node. `applyOps`
  stamps `op.trackKey` onto the track's meta when it mints it (`rm:addTrack`);
  `snapshot`/`applyOps` recover `{ trackKey → id }` by reading that meta back.
  Why the trackKey and not the guid: target computes the trackKey from the
  graph *before any track exists*, so the guid — a realisation artefact — can't
  be the join key; the source-set composite trackKey is the one identity both
  sides compute independently. See `design/wiring-implicit-graph.md`.
- **Scratch** is rm-owned and carries no trackKey; its guid rides each scratch
  op as `op.trackId`, and every caller reads it via `rm:scratchId()`.
- **Master** is absent; resolvers special-case it to `rm:masterId()`.

The live-poke path reads the map through the module-local `newTrackIds`,
refreshed on every `snapshot`/`applyOps`. Where wm must hand a raw track to a
P_EXT writer, the id→handle bridge is `rm:reaperTrack(id)`.

## external sync

REAPER routing is the store, so anything that mutates it *outside* wm — a
Ctrl-Z, a redo, a hand edit in the mixer — must pull a fresh read.
`wm:syncExternal` watches the project state change count
(`GetProjectStateChangeCount`): when it moves and the move wasn't ours, it
drops the in-memory graph and fires `wiringChanged{kind='load'}`, which
re-reads the graph straight from routing (the routing already reversed
natively under an undo, so the read picks up the rewound state) and the live
subscriber reconciles — snapping any non-normal hand edit back onto a normal
form.

Every wm write to REAPER (`applyOps`, `fastGainCommit`, `pokeEdgeGain`,
`createSourceTrack`, `deleteSource`) calls `markState` to rebaseline the
count, so our *own* edits never trigger a reread. The watcher is gated to
when the wiring page is active (coordinator only calls `wp:syncExternal` for
the active page), so unrelated edits on another page don't churn the graph;
switching back to the wiring page after editing routing elsewhere rereads on
entry. The cost is benign: an unrelated project change while the wiring page
is active triggers one no-op reconcile (empty diff) plus a view rebuild
(layout survives via the meta store).

The scratch heartbeat is a separate, always-on job: **`rm:pollUndo`** (driven
by `wp:tick`) ensures the scratch track exists and pulls its fx-meta mirror
back into projext after an undo — the `primary`/`split` metadata isn't
recoverable from routing, so it still needs the scratch-chunk mirror that
addressing no longer does.

## actual-state model

`rm:tracks()` — decoding every FX chain and MIDI state-chunk — is the
reconcile's dominant cost (~80ms). A self-driven reconcile paid it
*twice*: once in `snapshot`, once again in `applyOps` (which re-read the
whole project only to rebuild the `{trackKey→id}` addressing `snapshot`
had already computed into `newTrackIds`). Both reads are gone from the
self-driven path:

- **`applyOps` never reads.** It seeds its `wiringTracks` from
  `newTrackIds` (set by the preceding `snapshot`, or the previous
  `applyOps`), then mutates that map as it creates/deletes tracks.
- **`reconcile` diffs against an in-memory model of REAPER's actual
  side.** After a successful apply, REAPER *equals* the target we
  applied (the `read ∘ compile = id` idempotency invariant — the same
  one that makes a second reconcile a no-op). `reconcile` stores that
  applied state in `actualState` and diffs the next target against it
  instead of re-reading. `actualState` is a post-apply `targetState()`
  (which recovers the CU-bridge guids `applyOps` stamped) with the
  realised `newTrack`/`master` track ids overlaid.

`actualState` is the diff's *actual* side, so it must stay byte-equal to
what a fresh `snapshot()` would return — otherwise `diff` emits spurious
ops. The shift from the earlier cache is that wm's own out-of-band writes
**update** the model to keep it truthful rather than dropping it. Each
does so by the cheapest faithful means:

- **mint on scratch / create source track** re-read *that one track*
  (`rm:track(id)`, the same `readTrack` path `snapshot` uses) and splice
  the entry in. A freshly-minted FX physically sits on scratch; splicing
  the scratch entry back means the next reconcile's diff sees it there
  and emits the `moveFxAcrossTracks` op that relocates it onto its real
  track — with no whole-project read. (This is the case that used to
  force a full snapshot.)
- **delete source** drops the track's entry.
- **gain poke** (`pokeEdgeGain`/`fastGainCommit`) patches the single
  gain field at the routing target — a CU param, a main-send gain, or a
  track-send gain.

These updates are sound exactly insofar as idempotency holds and the
write's effect on REAPER is local and known — which is what separates
them from a graph move, whose effect may be non-local and is therefore
left to the full diff. Only an *external* move invalidates the model
outright (`actualState = nil`): `syncExternal` (undo/redo/manual mixer
edit) and `wm:load`. There REAPER is ground truth — but the `read` that
rebuilds the graph re-seeds the model with the very snapshot it consumed,
so even the resync reconcile diffs against the model rather than taking a
second `rm:tracks()` pass.

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
