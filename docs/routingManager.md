# routingManager

A thin record abstraction over REAPER's audio/MIDI graph. Callers deal in
`track` / `fx` / `send` records and opaque `id`s; the warts of the
underlying API stay private.

## The boundary

routingManager was built ground-up, not relocated from wiringManager. The
point of the rewrite is the boundary itself: everything REAPER makes ugly —
`Get/SetMediaTrackInfo` string keys, `TrackFX_*` 0-indexing and GUID
enumeration, param name→index scans, pin-mapping bit math, the base64
state-chunk surgery for per-FX MIDI routing, audio-vs-midi send detection,
the id→track/slot sweep — lives behind the module. A caller never sees a
guid, slot index, MediaTrack, named-config-parm string, pin-mapping bit, or
state-chunk byte.

The surface is modelled on midiManager: clean record shapes and an
`add`/`assign`/`delete` triad. `assign`-shaped methods dispatch on the
fields present, so `assignFx{params}`, `assignFx{midi}`, and the
cross-track move `assignFx{track}` are one method, not three.

## id is the only handle

There is exactly one way to name a thing: its `id`, a track-or-fx GUID
string. It is opaque (never parsed by callers), stable across reload, and
guid-backed — which is what lets the module be **stateless**. Nothing is
minted, numbered, or reset; resolution is a live sweep (`locateTrack` /
`locateFx`) keyed on the guid, so it survives reordering and project
reload with no bookkeeping. There is no `load` and no lifecycle.

The one piece of retained state is `installedFx`: REAPER's installed-plugin
set is fixed for the lifetime of the process, so the first `rm:installedFx()`
enumerates it and memoises. This is a runtime constant cached, not mutable
state — it never invalidates.

## Sends are a track attribute, not an entity

A send has no stable handle in REAPER: it is addressed by a `(category,
index)` pair that shifts the moment any send is created or removed. A send
`id` would therefore be forged, not guid-backed like every other id — and
that breaks the "exactly one way to name a thing" invariant. A send is also,
conceptually, the track's output routing, the same kind of thing as
`mainSend`. So sends live in `track.sends` with no id, and are set wholesale:
`assignTrack{sends}` carries the *full desired set*, and the module diffs it
against the live sends internally.

The reconcile is two passes by necessity, not preference. Sends are matched
by an identity tuple (`sendKey`: destination, kind, channels, position) that
deliberately **excludes** gain, because gain is the mutable value a match is
allowed to carry forward. Drops run right-to-left so REAPER's post-remove
index shift can't invalidate a not-yet-applied index; creates follow. Only
then, once indices have settled, does a separate pass write `D_VOL` for
every wanted send — the index a gain belongs to isn't knowable until the
add/remove churn is done.

## Wire-format surgery worth knowing

Two private corners encode REAPER quirks dense enough to mislead:

**Per-FX MIDI routing.** REAPER exposes no ReaScript accessor for a plugin's
MIDI input bus, output bus, or output-passthrough flag — they live inside
the `<VST ...>` block of the track's FXCHAIN state chunk. The module patches
the chunk directly: decode base64 line, mutate one byte, re-encode iff
changed (a no-op preserves the line byte-for-byte). The output-disable flag
is the trap — REAPER keeps it in **two** places it reads from separately,
the trailer flag byte and a mirror at 1-indexed offset `27 + 8 *
pinChannels` in the wrapper header, so a trailer-only write silently fails
to take. The byte-level encoding is documented in
`docs/reaper_midi_routing.md`. `fx.midi` is present (with passthrough
defaults) for every non-JS fx so callers read routing without a JS-vs-not
branch; it is nil only for JS fx, which have no routing trailer.

**Pin maps.** A port owns two pins (left/right bit masks across a 64-bit
space split into lo/hi words); a channel pair is connected when its bit is
set on the port. Read collapses adjacent set bits back to pair numbers and
drops zero-mask ports (absent ⇒ disconnected); write is full-replace per fx,
so a port absent from the supplied map is cleared. The pair/pin/bit
arithmetic is the only reason this isn't a one-liner.

## Eager reads, with a lazy escape hatch

`rm:tracks()` reads `pinMaps` and `midi` for every fx eagerly, and `midi`
decodes a state chunk per track. `rm:fx(id)` is the single-fx counterpart —
the same record for one guid, plus live `params` and the host `trackId` — for
callers that hold a guid, not a track (wm's snapshot CU read, the sampler
dive). Bulk reads stay params-free on purpose: reading every fx's params on
every `tracks()` would be wasteful for fat plugins, so params are a per-fx,
on-demand cost.

Live fader-drag gain is too hot for the wholesale `assignTrack{sends}` diff,
so `setSendGain(fromId, toId, gain)` writes one send's `D_VOL` directly,
addressed by the stable relationship rather than a forged send id. The
main-send drag rides `assignTrack{mainSend={gain}}` (a partial scalar write),
and a CU edge rides `assignFx{params}`.

## Metadata and the scratch track

Every record field REAPER itself backs is *native*; any other key on a
record is metadata rm persists on the caller's behalf, told apart by a
per-record-kind native-key set. The two kinds store differently:

- **Track-meta** rides the track's own `P_EXT` blob — it reverses with
  native undo for free, so source/master node decoration (`pos`, …) needs
  nothing more.
- **Fx-meta** has no per-fx channel (see `design/fx-metadata-spike.md`), so
  it lives in a project-extstate blob keyed by fx guid, mirrored to the
  scratch track's `P_EXT` so native undo captures it. `resyncFxMeta` pulls
  that mirror back into projext after an undo/redo, since projext alone
  does not reverse.

Writes patch-merge (a partial write never wipes a sibling; `util.REMOVE`
clears a field), and an all-native write touches no extstate at all — the
reconcile hot path stays clean. The scratch track is owned by `scratch.lua`
(`scratch.id` mints it lazily — hidden + muted — guid persisted in projext);
rm is one tenant, mirroring fx-meta onto its `P_EXT`. `rm:pollUndo` (driven
each frame by `wp:tick`) is the heartbeat that ensures the scratch exists
and, on a scratch-chunk rewind, resyncs the fx-meta mirror back into projext
— gated by a watermark so steady-state frames touch no extstate.

## Mute

`rm:setMuted` silences an fx without touching topology — same plugin, same IO,
same chain position. The mechanism splits by fx kind, because REAPER FX *replace*
the channels they output to (an in-place effect plays wet, not wet+dry):

- A **processor** (has audio inputs) is silenced by clearing its live **input**
  pins. Fed silence, it overwrites its output channels with processed silence.
  Clearing the *output* instead is useless: the dry input still sits on those
  channels and `readGraph` — modelling REAPER at `wiringManager.lua` — passes it
  straight through, so an in-place `1,2→fx→1,2` would leak its input unmuted
  (output-clear there is bypass, not mute).
- A **generator** (no audio inputs) ignores input, so it is silenced by clearing
  its live **output** pins: nothing upstream writes its output pair, so it goes
  dark.

The cleared side is recorded as `muteSide`. Either way the trap is the same:
`readGraph` reconstructs every audio edge by threading pins, so a cleared side
reads back **identical to an unwired one** — the pins are the wire's only durable
record ("read is the store"). So mute can't just clear pins. The real pinout for
the cleared side is **stashed in fx-meta** (`muteStash`, beside `muted`/`muteSide`)
and `applyMuteReport` swaps it back into every read (`rm:fx`/`tracks`/`track`), so
the snapshot — hence the differ and `readGraph` — sees the real wiring. Two
consequences fall out for free: reconcile is a no-op on a muted fx (target ==
reported snapshot, no `setPinMaps` op), and the mute round-trips a save/reload
like any other fx-meta. A pin write that *does* arrive while muted (a rewire, the
pin-grow re-assert) is diverted by `divertIfMuted` to the stash with the cleared
side kept dark, so it never relights the fx.

Bypass (`rm:setBypassed`) is the unrelated REAPER-native enable: pass-through,
not in the snapshot, never read or written by reconcile.

## Relationship to wiringManager

The wm rewire has landed. `wm:snapshot()` is `rm:tracks()` plus wm's
ownership/trackKey overlay; `wm:applyOps()` is one `rm:transaction`
dispatching to rm's add/assign/delete methods; the graph-mutation
`reaper.*` cluster (state-chunk surgery, pin-bit math, send read/write) now
lives only here. The owned-block contiguity and CU policy stay in wm,
expressed over rm methods (see `docs/wiringManager.md § The reaper seam`
for the small reaper residue wm keeps). The canonical encoding reference
for per-FX MIDI routing is `docs/reaper_midi_routing.md`.
