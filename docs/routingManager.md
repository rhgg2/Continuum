# routingManager

**A thin record abstraction over REAPER's audio/MIDI graph.** Callers deal
in `track` / `fx` / `send` records and opaque `id`s; the underlying API
stays private.

## The boundary

1. REAPER's routing idioms all stay behind the module:

   - `Get/SetMediaTrackInfo` string keys;
   - `TrackFX_*` 0-indexing and GUID enumeration;
   - param name→index scans, where an unknown name raises;
   - pin-mapping bit math;
   - the base64 state-chunk surgery for per-FX MIDI routing;
   - audio-vs-midi send detection;
   - folder-depth arithmetic;
   - the id→track/slot sweep.

1. Two escape hatches are deliberate. `rm:reaperTrack(id)` and
   `rm:fxTrack(id)` hand back the raw `MediaTrack` for the reaper
   operations rm does not model — an item count, a mixer query. No routing
   op uses them.

1. The surface follows `docs/midiManager.md`: record shapes and an
   `add`/`assign`/`delete` triad. `assign`-shaped methods dispatch on the
   fields present, so `assignFx{params}`, `assignFx{midi}`,
   `assignFx{pinMaps}`, `assignFx{index}` and the cross-track move
   `assignFx{track}` are all one method.

## id is the only handle

1. A track or an fx is named by an `id`, an opaque token stable across
   reordering and project reload. rm implements this via the REAPER
   guid.

1. rm is **stateless**: `locateTrack` and `locateFx` resolve an id by
   sweeping the live project for its guid, on every call.

1. Three tables persist between calls. `installedFxCache` and
   `paramIdxByIdent` memoise REAPER's installed-plugin set, and a
   plugin type's param layout. Both are fixed for the life of the
   process, so neither memo invalidates. `midiCache` caches live
   project state; see § Read cost.

## Sends are a track attribute

1. A send has no stable address: REAPER names it by a `(category, index)`
   pair that shifts the moment any send is created or removed.

1. So a send is part of its source track — the track's output routing, like
   `mainSend` — and lives in `track.sends` with no id.

1. `assignTrack{sends}` carries the full desired set, which rm diffs against
   the live sends.

1. The diff matches on an identity tuple (`sendKey`: destination, kind,
   channels, position). Gain is absent from it, being the mutable value a
   match carries forward.

1. The first pass drops and creates. Drops go right-to-left, so REAPER's
   post-remove index shift cannot invalidate an index still to be applied.

1. The second pass writes `D_VOL` for every wanted send, once the indices
   have settled.

1. Midi sends on `AUTO_BUS` — 126, a reserved Continuum automation bus — are
   exempt. paramAutomation propagates CC over it, and rm's callers never
   declare those sends.

1. `reconcileSends` keeps them out of the current set, so they are neither
   matched nor dropped: the set `assignTrack{sends}` carries is the track's
   wiring sends.

1. A fader drag writes gain far too often for the wholesale diff, so
   `rm:setSendGain(srcId, dstId, gain)` writes one send's `D_VOL` directly.
   The source/destination pair is stable where an index is not.

1. The main-send drag rides `assignTrack{mainSend={gain}}`, a partial scalar
   write; a CU edge (`docs/wiring.md`) rides `assignFx{params}`.

## Folder membership is positional

1. REAPER stores folder structure as a per-track depth (`I_FOLDERDEPTH`): 1
   opens a folder, and a negative closes that many. A track's parent is thus
   a function of its position in the track list.

1. `readTrack` records `number` and `folderDepth`. `stampParents` then walks
   the records in order and stamps `parent` from the top of the open-folder
   stack, so the parent is derived on every read.

1. A track appended while the project ends inside an open folder becomes a
   child of that folder, and its mainSend retargets to the parent rather
   than master.

1. So `rm:addTrack` closes any open folder before inserting, and a new track
   lands top-level.

## Per-FX MIDI routing

1. REAPER exposes no ReaScript accessor for a plugin's MIDI input bus, output
   bus, or output-passthrough flag. They live inside the `<VST>` / `<AU>` /
   `<CLAP>` block of the track's FXCHAIN state chunk, whose byte-level
   encoding is documented in `docs/reaper_midi_routing.md`.

1. The block's base64 content lines concatenate into one decoded stream, and
   the routing record is that stream's last four bytes. Addressing by stream
   offset finds it past a variable-length preset name.

1. A write decodes the one line the offset falls in, mutates a byte, and
   re-encodes, so a no-op preserves the line byte-for-byte.

1. REAPER holds each disable flag twice and reads both copies: the trailer's
   flag byte, and a mirror in the wrapper header at offset
   `27 + 8 * pinChannels`. A trailer-only write silently fails to take.

1. `fx.midi` is present for every VST/AU/CLAP fx, defaulting to passthrough
   when the block carries no trailer, so callers read routing without a
   per-plugin branch.

1. It is nil for the kinds with no routing record — JS, containers, video —
   and a midi write to one of those is a no-op.

## Pin maps

1. A port is two pins, left and right, each a bit mask over channels. Channel
   pair Q occupies bit 2(Q−1) of the left pin and bit 2(Q−1)+1 of the right.

1. REAPER's 128 channels (`docs/DAG.md`) span two 64-bit mapping banks, each
   returned as a lo/hi word pair, so a pin number carries its bank in a high
   bit (`BANK2`).

1. Read ORs a port's two pins, collapses adjacent set bits back to pair
   numbers, and drops zero-mask ports: absent ⇒ disconnected.

1. Write is full-replace per fx, so a port absent from the supplied map is
   cleared.

## Read cost

1. The reads form a ladder, and picking a rung is a cost decision:

   - `rm:trackLabels()` — id, name and number per track, with no fx, sends
     or chunk read;
   - `rm:fxIds(id)` — one track's fx guids and idents, with no record built;
   - `rm:tracks()` and `rm:track(id)` — full records, pin maps and midi for
     every fx;
   - `rm:fx(id)` — the single-fx counterpart, plus the host `trackId`.

1. Params sit off the ladder in `rm:params(id)`, read only when a caller asks
   for them: a plugin's param list can run to hundreds.

1. Most of that cost is the state chunk. `GetTrackStateChunk` serialises a
   track's entire state — giant-VST presets dominate it — for a payload of
   four routing bytes per fx. A giant-VST track measured ~80ms, and ~560ms
   across a seven-track project.

1. So `midiCache` keys `fx.midi` by guid, and a bulk read touches the chunk
   only when some routing fx is uncached: at boot, or for an fx added in
   REAPER outside Continuum.

1. A midi write overlays the changed fields onto the cached entry, which
   stays warm as a result. A guid that leaves the project is pruned on the
   next full `rm:tracks`.

1. The cache gates writes as well as reads. `rm:writeChainMidi` batches a
   whole chain's routing into a single Get/Set, and skips any fx whose midi
   already matches the cache.

1. One gap is left open: an external hand-edit of an fx's midi bus, through
   REAPER's pin-mapping submenu, stays stale until that fx changes
   structurally or the project reopens.

1. `rm:fx(id)` always reads the chunk, and refreshes the cache from what it
   finds.

## Metadata

1. A record field REAPER itself backs is **native**; any other key on a
   record is metadata rm persists on the caller's behalf. Each record kind
   has its own set of native keys, and rm sorts a write by it.

1. **Track-meta** rides the track's own `P_EXT` blob, so it reverses with
   native undo. Source and master node decoration (`pos`, …) needs nothing
   more.

1. **Fx-meta** and bus-meta have no per-fx channel (`docs/wiring.md §
   Decoration — positions only`), so each is one blob keyed by guid, held as
   a `dataStore` key at project scope (`fxMeta`, `busMeta`).

1. Project scope makes them undoable document data, by way of the
   project-slot mirror in `docs/pextStore.md`. rm reads and writes ds.

1. Writes patch-merge, so a partial write never wipes a sibling;
   `util.REMOVE` clears a field.

1. An all-native write touches no store at all, which matters on the
   reconcile hot path.

1. `rm:meta` and `rm:assignMeta` reach the same stores directly, for callers
   holding a guid and no record.

## Mute

1. `rm:setMuted` silences an fx without touching topology — same plugin, same
   IO, same chain position. `rm:muted` reports the flag.

1. Clearing a pin disconnects the fx from that channel and leaves whatever
   else writes the channel untouched. Which side to clear therefore depends
   on the fx kind.

1. A **processor** has audio inputs and is silenced by clearing them. Fed
   silence, it overwrites its output channels with processed silence, REAPER
   FX replacing the channels they output to: an in-place effect plays wet,
   not wet+dry.

1. A processor's output channels carry its own dry input, so clearing that
   side would leave the fx audible.

1. A **generator** has no audio inputs, so it is silenced by clearing its
   output pins: nothing else writes those channels.

1. The cleared side is recorded as `muteSide`.

## The mute stash

1. `readGraph` (`docs/wiringManager.md`) reconstructs every audio edge by
   threading pins, so a cleared side reads back identical to an unwired one.
   Pins are the wire's only durable record
   (`docs/wiringManager.md § Read is the store`).

1. So the real pinout for the cleared side is stashed in fx-meta as
   `muteStash`, beside `muted` and `muteSide`.

1. `applyMuteReport` swaps the stash back into every read (`rm:fx`,
   `rm:tracks`, `rm:track`), so the snapshot — hence the differ and
   `readGraph` — sees the real wiring.

1. Reconcile is therefore a no-op on a muted fx: the target equals the
   reported snapshot, and no `setPinMaps` op is emitted.

1. The mute also round-trips a save and reload like any other fx-meta.

1. Every pin write passes through `divertIfMuted` — the transactional
   `assignFx{pinMaps}` and the undo-free `rm:rewritePins` alike. A rewire or
   a pin-grow re-assert arriving while muted lands in the stash, and the
   cleared side stays silent.

## Bypass

1. Bypass (`rm:setBypassed` / `rm:bypassed`) is REAPER's own enable flag:
   pass-through, and absent from the snapshot, so reconcile leaves it alone.

## Transactions

1. `rm:transaction(label, fn)` brackets a batch of writes in a REAPER undo
   block, and suppresses UI refresh across it.

1. Inside that block, rm's chunk reads and writes all pass `isundo=false`:
   with the block already open, the per-call undo caching would be redundant.

1. The flag has to agree across every chunk call, for REAPER's own caches to
   stay consistent.

1. `rm:rewritePins` stands outside. It repairs a pin map REAPER stamped over
   during a same-cycle channel-count grow (`docs/wiringManager.md § Pin
   re-assert after grow`).

1. That repair should not surface as a user-visible undo step.

## Relationship to wiringManager

1. wm holds no graph-mutation `reaper.*` calls of its own.

1. `wm:snapshot()` is `rm:tracks()` plus wm's overlay of ownership and
   `trackKey`.

1. `wm:applyOps()` is one `rm:transaction`, dispatching to rm's
   add/assign/delete methods.

1. The state-chunk surgery, pin-bit math and send read/write live only in rm.
   paramAutomation's CC bus is the one graph write rm does not own (§ Sends
   are a track attribute).

1. The owned-block contiguity and CU policy stay in wm, expressed over rm
   methods. `docs/wiringManager.md § The reaper seam` covers the small reaper
   residue wm keeps.
