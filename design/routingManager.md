# routingManager — design & build plan

> Design document; the durable WHY now lives in `docs/routingManager.md`
> (rationale only, no API dump — per CONVENTIONS).
>
> **Status: all build phases (1–7) landed and green.** routingManager is
> standalone. wiringManager rewiring: chunks 1–3 landed (rm wired in; snapshot
> read on `rm:tracks()`; simple write ops routed through rm). Remaining: chunks
> 4–6 below. Kept (not deleted) until that lands.

## Goal

A thin, pleasant abstraction over REAPER's audio/MIDI graph calls, built
from the ground up — **not** a relocation of wiringManager internals.
Modelled on `midiManager`: clean record shapes, opaque handles, an
`add`/`assign`/`delete` triad. Callers deal only in records and opaque
`id`s — never a guid, slot index, MediaTrack, named-config-parm string,
pin-mapping bit, or state-chunk byte. Exactly one way to name a thing:
its `id`.

Stateless: `id`s are guid-backed, so nothing needs minting or resetting;
`installedFx` memoises a runtime-fixed list. No `load`/lifecycle.

## Public surface

Closures-over-state module `rm`. Three record shapes:

```
track = { id, name, isMaster, nchan,
          mainSend = { on, gain, tgtOffset, nchan },
          fx    = { fx, ... },     -- chain order; position IS list order
          sends = { send, ... } }

fx    = { id, ident, name,
          params  = { [name] = value },
          pinMaps = { ins = {...}, outs = {...} },
          midi    = { inBus, outBus, outDisabled } }   -- nil for JS fx

send  = { to, kind='audio'|'midi', gain, srcChan, dstChan, pos='preFx'|'preFader'|'postFader' }   -- no id; a value on the track
```

`id` is opaque (guid-backed), stable across reload, never parsed by callers.

Methods:

- Read — `rm:tracks()` → all `track` records, fx + sends nested; master is a
  track with `isMaster=true`.
- Tracks — `rm:addTrack(t)`→id · `rm:assignTrack(id, t)` · `rm:deleteTrack(id)`
  - `assignTrack` t may carry `name` / `nchan` / `mainSend` / `sends`. `sends`
    is the full desired set; rm diffs it against the live sends internally.
- FX — `rm:addFx(trackId, t)`→id · `rm:assignFx(id, t)` · `rm:deleteFx(id)`
  - `addFx` t = `{ ident, index?, params? }`; appends unless `index`.
  - `assignFx` t may carry `params` / `pinMaps` / `midi` / `index` (reorder)
    / `track` (move across tracks — `moveFx` is just assigning a new `track`).
- `rm:showFx(id)` · `rm:installedFx()` → `{ {ident, name}, ... }`
- `rm:transaction(label, fn)` — runs `fn` in one Undo block + UI-refresh guard.

`assign`-shaped methods dispatch on the fields present, like `mm:assign`.

**Sends are a track attribute, not an entity.** REAPER gives a send no stable
handle — it's addressed by a shifting `(category, index)` — so a send `id` would
be forged, unlike the guid-backed track/fx ids. And a send is the track's output
routing, the same kind of thing as `mainSend`. So sends live in `track.sends`
(no `id`) and are set wholesale via `assignTrack{sends}`; the index-shifting
`Create`/`Remove`/`SetTrackSendInfo` ops stay private.

## Private (the warts it hides)

`Get/SetMediaTrackInfo` string-key accessors; `TrackFX_*` 0-indexing and the
GetTrack/GUID enumeration; param name→index scan (`GetParamName`); pin-mapping
bit math (`Get/SetPinMappings`); the entire base64 / state-chunk surgery for
`midi` routing (`Get/SetTrackStateChunk`, block-walk, mirror-bit patching);
audio-vs-midi send detection (`I_MIDIFLAGS`/`I_SRCCHAN`); the id→track/slot
resolution (sweep, self-healing).

## Build order

Each phase: red-first spec, then green, before the next. New specs registered
in `tests/run.lua`; run via `mcp__readium_tests__lua_test_run`. All specs
inject `tests/fakeReaper.lua` as the `reaper` global (existing pattern).

1. ✅ **Skeleton + track read/write.** `rm:tracks()` (tracks, names, nchan,
   mainSend; empty fx/sends), `addTrack`/`assignTrack`/`deleteTrack`,
   `transaction`. Spec: `rm_tracks_spec.lua`.
2. ✅ **FX read.** Populate `track.fx` (ident, name, io→pin counts) in `tracks()`;
   `locateFx` resolution private. Spec: `rm_fx_read_spec.lua`.
3. ✅ **FX write.** `addFx`/`deleteFx`/`assignFx{index, track, params}` incl. the
   append-then-CopyToTrack(move) reorder. Spec: `rm_fx_write_spec.lua`.
4. ✅ **Pin maps.** `pinMaps` in read + `assignFx{pinMaps}`; bit math private.
   Spec: `rm_pinmaps_spec.lua`.
5. ✅ **MIDI routing.** `fx.midi` in read + `assignFx{midi}`; port the base64 /
   state-chunk surgery in as private. Spec: `rm_midi_routing_spec.lua`.
6. ✅ **Sends.** `track.sends` in read + `assignTrack{sends}` reconcile (internal
   `Create`/`Remove`/`SetTrackSendInfo`), audio/midi detection. Spec:
   `rm_sends_spec.lua`.
7. ✅ **installedFx / showFx.** Spec: `rm_installed_fx_spec.lua`.

routingManager is fully green and standalone at the end of step 7. wm is
untouched so far.

## wiringManager rewiring (after rm is green) — NEXT PHASE

### Principles

- **The snapshot/target/diff vocabulary agrees with rm's record shape.** This
  was the load-bearing call in chunk 2: rather than a name-mapping shim over
  `rm:tracks()`, `wm:snapshot()` *is* an rm record + a thin overlay, so the
  shapes nest the same way (`mainSend={on,gain,tgtOffset,nchan}`, per-fx
  `pinMaps`/`midi`, sends `{kind,pos}`, `id` not `trackGuid`, `fx` not
  `fxOrder`). Because `wm:diff` compares snapshot and target symmetrically,
  `projectEntry`/`targetState` and the eq-helpers moved to the same shape in
  lockstep — they are **not** "unchanged". `pinMapsByOrigin` is gone:
  an unmaterialised target fx carries its `pinMaps` inline.
- **The op payloads stay pre-rm; `wm:diff` bridges new→old at op construction.**
  Three small mappers (`opFxOrder`/`opSends`/`opPinMaps`) emit the old op shape
  so `applyOps`/`reconcileFXChain`/`reconcileSends` are untouched by chunk 2.
  The bridges are the temporary seam: chunks 3–4 delete each one alongside the
  consumer it feeds (`opSends`+`reconcileSends` in 3, `opFxOrder`/`opPinMaps`+
  `reconcileFXChain` in 4).
- `wm:snapshot()` → `rm:tracks()` + wm's ownership filter + trackKey re-keying.
  Master falls out of `rm:tracks()` (no special `GetMasterTrack` branch).
- `wm:applyOps()` → one `rm:transaction(label, fn)`; each op dispatches to
  `rm:addFx`/`assignFx`/`deleteFx`/`assignTrack`/etc. `addFx` returns
  the new id synchronously, so the minted-guid stamp-back is a direct call —
  the `origin`/tag/`within`-callback machinery (`stamps[]`, the post-loop
  `realising` mutate, `originKey`, the bracket/merge sweep) is **deleted**, not
  ported.
- `reconcileFXChain`'s *policy* stays in wm (owned-block contiguity: foreign FX
  hold their slots, owned FX is a contiguous block), re-expressed over rm
  methods. `reconcileSends` is **deleted** — `rm:assignTrack{sends}` already
  owns the full send reconcile (phase 6); wm only computes the desired set.
- `DAG.*` unchanged (the allocator still speaks the wm spec vocabulary —
  `type`/`preFx`/`fxOrder`; `projectEntry` translates spec → rm record).
- **The addressing seam is wm's job throughout.** rm speaks guid `id`s; wm
  speaks `trackKey` (a `sourceTrack` key *is* a guid, a `newTrack` key is a
  synthetic ext-state tag) and `fxGuid`. Every op must translate trackKey→id
  (via `buildTrackKeyToTrack`, kept) before calling rm — including remapping
  each `send.to` from trackKey to the destination guid.
- **Scratch, `fxLocations`, live mode, `pollUndo`, ext-state tags
  (`wiringTrack*`, `wiringGraph`, `wiringOwnedFx`) stay wm-native** — rm is
  stateless and knows nothing of wm's scratch/persistence concepts.
- The shared base64 / pin-bit / send helpers are exercised by *both* snapshot
  (read) and applyOps (write), so the dead-`reaper.*` sweep is a single final
  chunk — earlier chunks let orphaned helpers sit until both paths are off them.

### Commit chunks

Each chunk lands green against the existing `wm_*` specs (the regression net);
no chunk needs new specs unless it exposes a gap.

1. ✅ **Wire rm in + leaf swaps.** Inject `rm` into wm (continuum wiring +
   harness). Repoint `wm:listInstalledFX` → `rm:installedFx()` and
   `wm:showFxWindow` → `rm:showFx`; drop wm's `installedFx` cache and its
   `EnumInstalledFX`/`TrackFX_Show` calls. Smallest possible diff — proves rm
   is reachable from the wm stack before anything load-bearing moves.

2. ✅ **snapshot read → `rm:tracks()`, reshaped to rm records.** `wm:snapshot()`
   is now an rm record + ownership/trackKey/`__master__` overlay. Went further
   than a field-name map (see Principles): the whole snapshot/target/diff
   vocabulary adopts rm's nesting, so `projectEntry`/`targetState`/the
   eq-helpers moved too, and `pinMapsByOrigin` was eliminated. Op payloads keep
   the pre-rm shape via the `opFxOrder`/`opSends`/`opPinMaps` bridges, so
   `applyOps` is untouched. Orphans the read-only helpers (`ownedChain`,
   `readSendsClass`, `readPinMapsForFx`, `decodePairList`) — left for the
   chunk-5 sweep. Net: `wm_snapshot_spec` + reshaped `wm_diff_spec`,
   `wm_target_alloc_spec`, `wm_diff_midi_bus_spec`, `wm_fx_routing_apply_spec`.

3. ✅ **Simple write ops → rm.** In the applyOps loop, convert the non-fx-chain
   ops: `createTrack` → `rm:addTrack` (returns guid; map trackKey→guid
   directly, dropped `createNewTrack`+`scratchIndex`); `deleteTrack` →
   `rm:deleteTrack`; `setMainSend`/`setNchan` → `rm:assignTrack{mainSend,nchan}`;
   `setSends` → `rm:assignTrack{sends}` after remapping `.to` trackKey→guid
   (deleted wm `reconcileSends` **and the `opSends` bridge** — the op carries
   rm-shaped sends directly); `setPinMaps` → `rm:assignFx{pinMaps}` per fx (op
   still carries byGuid/byOrigin via `opPinMaps`; only the write moved);
   `moveFxAcrossTracks` → `rm:assignFx{track}` (rm locates the fx by guid, so
   the fromTrack scan is gone). `setExtState` stays wm (cm:writeTrackKey).
   Addressing seam added inside applyOps: `keyToId`/`resolveId` translate
   trackKey/trackGuid → rm guid id. Orphans `sendType`, `writePinMapsForFx`,
   `pinMaskFor` — left for the chunk-5 sweep. Green against the full `wm_*`
   suite (`wm_apply_ops_spec` covers the converted ops).

4. **setFXChain → rm + kill the stamp-back.** The heart. Re-express
   `reconcileFXChain` over `rm:addFx`/`assignFx{index}`/`deleteFx`/
   `assignFx{params}`/`assignFx{midi}`, keeping only the contiguity policy.
   Because `rm:addFx` returns the guid synchronously, stamp the user graph
   *inline* as each fx materialises — deleting `stamps[]`, the deferred
   `realising` mutate, `originKey`, `pushParams`/`resolveParamIdx`, and the
   wm-side midi/param writers. The merge/bracket-guid sweep folds into the same
   inline path. Deletes the `opFxOrder`/`opPinMaps` bridges — the op carries
   rm-shaped fx entries directly. Net: `wm_apply_spec`, `wm_fx_routing_spec`,
   `wm_merge_spec`.

5. **transaction + dead-code sweep.** Wrap applyOps' body in
   `rm:transaction(label, fn)` (Undo/PreventUIRefresh now rm's); the ownedFx
   persist + scratch mirror stay inside `fn` as wm concepts. Delete the now-dead
   `reaper.*` cluster from wm — base64 (`b64*`, chunk split/join, `findFxBlock`,
   the byte/bit patchers, `setFXMidiRouting`, `readFXMidiRouting`), pin-bit math
   (`decodePairList`, `pinMaskFor`, `writePinMapsForFx`), send read/write
   (`sendType`, `readSendsClass`), and the `TrackFX_*`/`GetSet*Info` writers rm
   now owns. Confirm the only `reaper.*` left in wm are scratch/live/pollUndo
   infra. Full `wm_*` suite green.

6. **Docs + closeout.** Update `docs/wiringManager.md` (the surgery moved to rm;
   point its Per-FX MIDI routing § at `docs/routingManager.md` +
   `docs/reaper_midi_routing.md`); archive this plan.

**`pokeEdgeGain` / `fastGainCommit` stay wm-native** through all six chunks —
they are the concrete hot path the Open knob below anticipates. Only if the
wholesale `assignTrack{sends}` diff proves too slow under a live fader drag do
we add `rm:setSendGain`; don't pre-build it.

## Open knob (don't pre-optimise)

`rm:tracks()` reads `params`/`pinMaps`/`midi` for every fx eagerly; `midi`
decodes a state chunk per track. If a reconcile-loop hotspot appears, make
those three fields lazy. Clean first.

Live send gain (a fader drag writing one send's volume per frame) is too hot for
the `assignTrack{sends}` diff. Deferred: add one targeted primitive —
`rm:setSendGain(fromId, toId, gain)`, addressed by the stable relationship, not a
send id — only when the hot path is concrete during wm rewiring.

## Closeout

- ✅ `--KIND:` annotations moved with their code; `map/routingManager.map`
  regenerated by the post-edit hook.
- ✅ `docs/routingManager.md` written (the boundary, the id-as-handle choice,
  the stateless decision, the wire-format corners).
- ⬜ Update `docs/wiringManager.md` once the rewiring lands.
- ⬜ Archive this plan once the rewiring lands.
