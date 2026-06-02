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
4. **`wm:applyOps(ops, label)`** — executes the op list inside one
   `Undo_BeginBlock`, minting FX via `TrackFX_AddByName` and stamping
   minted guids back into the user graph.

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

The user graph holds *intent*; REAPER holds *instances*. `fxGuid` (on
fx-kind nodes, mirroring `trackGuid` on sources) is the bridge — nil
until first materialised, stamped into the node after `TrackFX_AddByName`
succeeds, and thereafter how snapshot/target match `fxOrder` entries to
graph nodes. Three rules keep instance churn minimal and state-preserving:

- **Mint on a scratch track.** `wm:addFxNode` instantiates the FX
  immediately via `instantiateFxOnScratch`, so the node has a real
  `fxGuid` (and probed I/O) before it is ever hosted. The scratch track
  is a hidden REAPER track tagged `wiringScratch='1'`, found-or-created
  lazily; it also parks FX whose `srcSet` is empty (disconnected, or
  inert `__scratch__` nodes) so they exist without polluting the audible
  topology.
- **Track change is a move, not a re-create.** When the partition
  reassigns a node to a different track, the applier uses
  `TrackFX_CopyToTrack(is_move=true)` — plugin state (params, presets,
  internal buffers) survives the move; a delete + re-add would lose it.
- **Delete only on departure.** wm deletes a REAPER FX instance only
  when its owning node — or the CU bridge it backs — leaves the graph.
  CU bridges arrive at the applier with a nil `fxGuid` and are minted by
  `reconcileFXChain`, the same path as user FX.

## Master is a regular node

The master sits in `graph.nodes['master']` with `kind='master'`,
materialised by `freshGraph()` on first load of an empty project.
Not a special parallel field. The singleton constraint is enforced
by `DAG.validate` — same mechanism that would catch a buggy mutator
minting a second master, rather than two storage shapes encoding the
same rule.

## Routing as ground truth

The per-FX MIDI passthrough bit (`0x02` of the routing trailer) and
the in/out bus bytes (4/5) have no `TrackFX_*` API — read or write
goes through `GetTrackStateChunk` / `SetTrackStateChunk` (see
`docs/reaper_midi_routing.md`). `wm:snapshot` decodes the trailer of
every owned non-JS FX via `readFXMidiRouting` into
`fxOrder[i].midiBus = { inBus, outBus }` and `midiOut`; `projectEntry`
stamps the target's `midiBus` from the allocator's `fxMidiBus` and
`midiOut` from `nodeHasMidiOut`. `fxOrderEq` compares both, so a bus or
passthrough change drives a `setFXChain`, and `reconcileFXChain`'s tail
decodes the live trailer and writes only the bytes that differ. There
is no applied-value cache — REAPER's chunk is ground truth, same as
everywhere else in the differ.

**User-facing contract:** Continuum owns the MIDI I/O dialog
("Send all MIDI to plugin" / "Receive MIDI from plugin") and the
input/output bus on every FX in a chain the wiring page manages.
Toggling either by hand in REAPER is reverted to graph intent on the
next reconcile: snapshot reads REAPER's state, so the differ sees the
drift and rewrites it.

## Per-FX MIDI routing

REAPER exposes no ReaScript getter or setter for the per-FX MIDI input
bus, output bus, or replace-merge mode encoded inside each `<VST ...>`
block of an FXCHAIN. `wm.setFXMidiRouting(chunk, fxIdx, opts, pinChannels)`
patches the chunk directly; encoding is documented in
`docs/reaper_midi_routing.md` and pinned by `wm_fx_routing_spec`.

`opts` may carry any subset of:

- `inBus` — 0..127, trailer byte 4
- `outBus` — 0..127, trailer byte 5
- `inDisabled` — bool, 0x01 of trailer flag byte + wrapper mirror
- `outDisabled` — bool, 0x02 of trailer flag byte + wrapper mirror

Read-modify-write per field; every byte the caller did not name is
preserved (including unknown flag bits). The flag byte lives in two
places REAPER keeps in sync and reads from separately — trailer byte 3
and a mirror at 1-indexed offset `27 + 8 * pinChannels` inside REAPER's
wrapper header, where `pinChannels = inputPins + outputPins` (mono
channels) as reported by `TrackFX_GetIOSize`. Trailer-only writes do
NOT take effect for the flag byte; `in_bus` / `out_bus` have no mirror,
so trailer-only suffices for them.

Idempotent: empty opts (or opts whose every value already matches the
chunk) returns the chunk byte-for-byte. Pure: no module state, no
`reaper.*` deps — `pinChannels` comes from the call site, which has the
live track + fx index.

## wiringSnapshot

The shape both `wm:snapshot` and `wm:targetState` emit (field list in
the source `--shape wiringSnapshot`). The shape is symmetric on
purpose, per *The reconcile pipeline*; the non-obvious parts are *why*
certain fields exist and which side fills them:

- **`fxOrder` entries carrying `params`** are wm-owned CU bridges —
  synthesised `kind='fx'` nodes from the targetTracks merge pass or the
  bracket post-pass. Snapshot mirrors the live params back from the
  slider so `fxOrderEq` is honest; without that mirror every reconcile
  would spuriously emit `setFXChain`.
- **`origin`** is stamped on every *target*-side entry by `projectEntry`
  so the applier knows where to write minted guids back: `{kind='node'}`
  → `node.fxGuid`; `bracketIn`/`bracketOut` → the consumer's
  `midiInBracketGuid`/`midiOutBracketGuid`; `{kind='merge',consumer,trackKey}`
  → `consumer.mergeGuids[trackKey]`. Snapshot entries carry no `origin` and
  `fxOrderEq` ignores it — it's a write-back address, not state to
  compare.
- **`midiOut` and `midiBus`** are set on both sides only for non-JS
  `kind='node'` entries: target derives them from the user graph
  (`nodeHasMidiOut`) and the allocator (`fxMidiBus`); snap decodes them
  from the FX chunk trailer (`readFXMidiRouting`). Mismatch drives
  `setFXChain`; `reconcileFXChain` writes only the trailer bytes that
  differ.
- **`pinMaps`** carries pair-lists for every port with a route (target:
  allocator-touched; snap: REAPER non-empty); an absent port means
  disconnected. **`pinMapsByOrigin`** is the same shape for FX the
  target hasn't materialised yet — the applier resolves `origin` →
  `fxGuid` via stamps from the preceding `setFXChain`. The applier
  converts pair-lists to REAPER's lo32/hi32 bitmask at the boundary.
- **`nchan`** is the track's `I_NCHAN`; **`mainSendOffs`** is
  `C_MAINSEND_OFFS`, present only when `mainSend=true`.
