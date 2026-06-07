# routingManager — design & build plan

> Design document; the durable WHY lands in `docs/routingManager.md`
> (rationale only, no API dump — per CONVENTIONS).

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

1. **Skeleton + track read/write.** `rm:tracks()` (tracks, names, nchan,
   mainSend; empty fx/sends), `addTrack`/`assignTrack`/`deleteTrack`,
   `transaction`. Spec: `rm_tracks_spec.lua`.
2. **FX read.** Populate `track.fx` (ident, name, io→pin counts) in `tracks()`;
   `locateFx` resolution private. Spec: `rm_fx_read_spec.lua`.
3. **FX write.** `addFx`/`deleteFx`/`assignFx{index, track, params}` incl. the
   append-then-CopyToTrack(move) reorder. Spec: `rm_fx_write_spec.lua`.
4. **Pin maps.** `pinMaps` in read + `assignFx{pinMaps}`; bit math private.
   Spec: `rm_pinmaps_spec.lua`.
5. **MIDI routing.** `fx.midi` in read + `assignFx{midi}`; port the base64 /
   state-chunk surgery in as private. Spec: `rm_midi_routing_spec.lua`.
6. **Sends.** `track.sends` in read + `assignTrack{sends}` reconcile (internal
   `Create`/`Remove`/`SetTrackSendInfo`), audio/midi detection. Spec:
   `rm_sends_spec.lua`.
7. **installedFx / showFx.** Spec: fold into `rm_tracks_spec` or small own spec.

routingManager is fully green and standalone at the end of step 7. wm is
untouched so far.

## wiringManager rewiring (after rm is green)

- `wm:snapshot()` → `rm:tracks()` + wm's ownership filter + trackKey re-keying.
- `wm:applyOps()` → one `rm:transaction(label, fn)`; each op dispatches to
  `rm:addFx`/`assignFx`/`deleteFx`/`assignTrack`/etc. `addFx` returns
  the new id synchronously, so the minted-guid stamp-back is a direct call —
  the `origin`/tag/`within`-callback machinery is **deleted**, not ported.
- `reconcileFXChain`/`reconcileSends` stay in wm as pure policy (owned-block
  contiguity, CU concepts), expressed over rm methods.
- Pure `diff` and `targetState` largely unchanged.
- Delete the now-dead `reaper.*` cluster from wm; existing `wm_*` specs are the
  regression net for the rewiring.

## Open knob (don't pre-optimise)

`rm:tracks()` reads `params`/`pinMaps`/`midi` for every fx eagerly; `midi`
decodes a state chunk per track. If a reconcile-loop hotspot appears, make
those three fields lazy. Clean first.

Live send gain (a fader drag writing one send's volume per frame) is too hot for
the `assignTrack{sends}` diff. Deferred: add one targeted primitive —
`rm:setSendGain(fromId, toId, gain)`, addressed by the stable relationship, not a
send id — only when the hot path is concrete during wm rewiring.

## Closeout

Move `--KIND:` annotations with their code; let the post-edit hook generate
`map/routingManager.map`; write `docs/routingManager.md` (WHY: the boundary,
the id-as-handle choice, the stateless decision); update `docs/wiringManager.md`;
delete this plan.
