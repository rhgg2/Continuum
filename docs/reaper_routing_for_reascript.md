# Tractatus Routing-Reapericus

*On what a REAPER project routes, what ReaScript can say of it, and what
it cannot. Established against REAPER 7.61, macOS-arm64. The scriptable
propositions hold; the propositions about the state chunk hold only so
long as REAPER's serialisation does not move.*

---

**1** The project is everything that is routed.

**1.1** It is a totality of tracks, not of signals.

**1.2** A track is a fixed pipeline. Signal enters from media, from MIDI,
and from receives; it crosses the FX chain; it leaves through the fader,
the sends, and the main send.

```
receives ──┐
            ▼
  [track channels: up to 128] ──► FX chain ──► fader/pan ──► sends + main send
            ▲                       │ │
   media items, MIDI ──────────────┘ └── each FX taps/writes a subset of channels
```

**1.3** Two worlds ride the pipeline and do not see each other. Audio is
carried on channels. MIDI is carried on buses.

**1.4** Where two signals meet, they are summed. There is no mixer behind
the summing; meeting *is* summing.

**1.41** Splitting is therefore free. Any number of readers tap one
channel or one bus, and nothing is copied.

**1.5** The graph terminates at the master. A track reaches it only by
its main send, summed up the chain of parents (**4**).

---

**2** Audio is what travels on channels.

**2.1** A track holds up to 128 mono channels — 64 stereo pairs. The
count is even.

**2.2** Within the chain, a plugin reads and writes channels through its
pin matrix.

**2.21** Each pin owns a 128-bit mask over the track's channels. Bit *c*
set is "this pin is wired to channel *c*." One call returns the low 64
bits, as a low-32 and a high-32 return; the pin index plus `0x1000000`
reaches the upper 64.

**2.22** A pin matrix is itself a mixer. An input pin sums every channel
routed to it, and does so selectively: `P→A` and `P+Q→B` coexist, because
distinct pins take distinct subsets. Many summing problems dissolve here
and need no plugin.

**2.23** The matrix is wholly scriptable.

```lua
local _, ins, outs = reaper.TrackFX_GetIOSize(track, fxIdx)                  -- mono pin counts
local lo,  hi  = reaper.TrackFX_GetPinMappings(track, fxIdx, isOutput, pin)              -- channels 0–63
local lo2, hi2 = reaper.TrackFX_GetPinMappings(track, fxIdx, isOutput, pin + 0x1000000)  -- channels 64–127
reaper.TrackFX_SetPinMappings(track, fxIdx, isOutput, pin, loBits, hiBits)               -- + 0x1000000 for 64–127
```

**2.231** Reading is the collapse of set bits back into pair numbers.

**2.232** Writing is full-replace per pin. A pin you do not write is
cleared, not preserved.

**2.3** Track to track, audio travels by a send.

**2.31** A send has no stable handle. It is named by `(track, category,
index)`, and the index moves the instant any send on the track is created
or removed.

**2.311** Therefore rewrite in order: remove highest-index-first, then
create, then set values once the indices have settled.

**2.32** Category `0` is sends, `-1` receives, `1` hardware outputs.

```lua
local idx = reaper.CreateTrackSend(srcTrack, dstTrack)             -- returns the new index
reaper.SetTrackSendInfo_Value(srcTrack, 0, idx, 'I_SRCCHAN', 0)    -- src pair (0,2,4,…); -1 disables audio
reaper.SetTrackSendInfo_Value(srcTrack, 0, idx, 'I_DSTCHAN', 0)    -- dst pair
reaper.SetTrackSendInfo_Value(srcTrack, 0, idx, 'D_VOL', 1.0)      -- linear gain
reaper.SetTrackSendInfo_Value(srcTrack, 0, idx, 'I_SENDMODE', 3)   -- the tap point
```

**2.33** `I_SENDMODE` is where on the source the send taps.

**2.331** `0` — post-fader: the source fader scales the send.

**2.332** `1` — pre-FX: taps before the chain.

**2.333** `3` — post-FX, pre-fader: the chain runs, the fader does not
scale the send. This is the mode wanted when the fader must mean
something else.

**2.334** `2` — a deprecated post-fader variant; read it as `0`.

**2.34** `I_SRCCHAN` carries width in its high bits; `0` is a stereo pair.
Enumerate with `GetTrackNumSends(track, 0)`, read with
`GetTrackSendInfo_Value`, follow `P_DESTTRACK` to the destination.

---

**3** MIDI is what travels on buses.

**3.1** A track holds 16 buses. Each bus is a full 16-channel MIDI stream.

**3.2** A MIDI send is a send with its audio source disabled.

```lua
local idx = reaper.CreateTrackSend(srcTrack, dstTrack)
reaper.SetTrackSendInfo_Value(srcTrack, 0, idx, 'I_SRCCHAN', -1)   -- -1: no audio ⇒ MIDI-only
local base  = math.floor(reaper.GetTrackSendInfo_Value(srcTrack, 0, idx, 'I_MIDIFLAGS'))
local flags = (base & 0x3FFF) | ((srcBus + 1) << 14) | ((dstBus + 1) << 22)
reaper.SetTrackSendInfo_Value(srcTrack, 0, idx, 'I_MIDIFLAGS', flags)
```

**3.21** The bus and channel remap hides in `I_MIDIFLAGS`, not in
`I_SRCCHAN`/`I_DSTCHAN`.

**3.211** Low 14 bits — channel filter and remap. `31` is "all channels,
no remap," and is also what a plain audio send carries to leave MIDI
untouched.

**3.212** Bits 14–21 — source bus, biased by +1. `0` means all buses;
bus 1 is stored as `2`.

**3.213** Bits 22–29 — destination bus, biased by +1.

**3.214** Read them back as `max(0, ((mf >> 14) & 0xFF) - 1)` and
`max(0, ((mf >> 22) & 0xFF) - 1)`.

**3.3** MIDI merges across tracks of itself. Point several sends at one
destination bus and REAPER delivers them in a single processing block; a
JSFX there reads every converging bus. No gmem, no contrived order.

---

**4** The main send is a send to a parent, and it is not like a send.

**4.1** Besides its ordinary sends, a track has at most **one** main send.
It is a track attribute, not an entity — `B_MAINSEND`, "track sends audio
to parent."

**4.11** The parent is the master, for a top-level track; for a track
inside a folder it is the folder track that opens the folder (positional,
by `I_FOLDERDEPTH`: `1` opens, `<0` closes |n| levels).

**4.2** The main send is asymmetric where an ordinary send is free.

**4.21** Its source is fixed: a contiguous block from channel 1. You do
not choose the source range, as you do for an ordinary send (**2.3**).

**4.22** Only the landing is yours. `C_MAINSEND_OFFS` offsets the
destination channels on the parent; `C_MAINSEND_NCH` sets the width
(`0` = all the track's channels, `1` = one channel only).

**4.3** The master cannot be addressed.

**4.31** There are no sends to the master. `CreateTrackSend` cannot target
it. The only path is each track's own main send, summed up the parent
chain.

**4.32** The master carries no MIDI. There is nowhere to send MIDI to it,
and the main send delivers audio only.

**4.4** In a folder, the main send becomes the **parent send**, landing on
the folder track instead of the master — same asymmetry (source from
channel 1, landing by `C_MAINSEND_OFFS`/`_NCH`, one per child), but now it
also carries MIDI.

**4.41** Its MIDI is all 16 buses, identity-mapped — 1→1, 2→2, … — and
**cannot be disabled** (verified empirically). Audio and MIDI are atomic:
the child takes the parent send whole, or not at all.

**4.42** The folder parent is an ordinary track, so ordinary sends *to* it
are unrestricted (any pair, any bus remap) and coexist with the parent
send — including a child's own explicit send to its parent. That is the
escape hatch when the parent send's fixed shape will not carry what you
need.

---

**5** The per-FX MIDI bus is reachable only through the state chunk.

**5.1** An FX slot filters one MIDI bus in and one bus out. The bus is one
of 1..128, or disabled. The output mode is replace (the default) or merge.

**5.11** The input filter reads matching events without consuming them;
later FX still see them.

**5.12** The plugin emits on its output bus. Replace overwrites that bus;
merge adds to it.

**5.13** A plugin with no real MIDI output does not fall silent. REAPER
passes its input view through as the emission. Hence synths and audio FX
carry MIDI downstream by default (`in=1/out=1/replace`); hence disabling
the output is what stops the passthrough.

**5.131** This is read from the plugin's manifest, not from runtime. A
true MIDI filter emitting nothing still silences its output.

**5.14** A JSFX stands outside this. It sees all 128 buses through
`midi_bus` and routes itself.

**5.2** Of this routing the API says nothing.

**5.21** `TrackFX_GetPinMappings` is the audio matrix, not the bus filter.

**5.22** `TrackFX_GetNamedConfigParm` holds no key for it.

**5.23** The pin-connector window draws no MIDI row.

**5.24** The API also will not tell you whether a plugin emits MIDI at
all. `is_instrument` distinguishes only synth from effect; to know,
allowlist by `fx_ident` or probe at runtime.

**5.3** Find the FX's `<VST …>` block in the FXCHAIN. Join its base64
content lines and decode.

**5.31** The routing record is the last four bytes of the decoded stream:

```
<flags> <in_bus> <out_bus> 00
```

**5.311** Index from the end: `flags = stream[n-3]`, `in = stream[n-2]`,
`out = stream[n-1]`. A loaded preset stores its name before the record,
so no fixed line offset is trustworthy.

**5.312** Buses are 0-indexed: `0x00` is bus 1.

**5.32** The flag byte carries bits.

**5.321** `0x01` — input disabled.

**5.322** `0x02` — output disabled.

**5.323** `0x08` — merge mode; clear is replace.

**5.324** `0x10` — flips on preset change. Not routing. Preserve it.

**5.325** `0x40` — sticky "input-disable was touched." Preserve it.

**5.33** The flag byte exists twice, and REAPER reads both.

**5.331** Besides the trailer, a mirror sits in the wrapper header at
1-indexed decoded offset `27 + 8 * pinChannels`, where `pinChannels =
inPins + outPins` from `TrackFX_GetIOSize`.

**5.332** A write to the trailer alone does nothing; the dialog does not
move. Both must be written.

**5.333** `pinChannels` can push the mirror onto any base64 line (REAPER
wraps at 210 decoded bytes). Walk the content lines, accumulating decoded
lengths, to find the line holding each offset; patch within it.

**5.34** Mutate by read-modify-write on the single bit. Never author the
byte whole — that is how the bits you do not model (`0x10`, `0x40`, the
unobserved) survive.

**5.341** Re-encode only the lines you touched. A no-op leaves the chunk
byte-for-byte identical.

**5.35** The full byte-level account and its fixtures are set down in
[`reaper_midi_routing.md`](reaper_midi_routing.md).

---

**6** A thing is named by its GUID, never by its index.

**6.1** Indices shift under every insert, delete, and reorder, and do not
survive a reload. GUIDs ride through all of it.

**6.11** Resolving a GUID is one pass: `CountTracks` → `GetTrack` →
`GetTrackGUID`, and the same shape for FX. A loop, but stateless: nothing
to keep in sync, nothing to go stale.

**6.12** The send is the exception, having no GUID. Name it by
`(destination, kind, channels, mode)`; treat the index as throwaway
(**2.31**).

**6.2** The means, by purpose:

| purpose | the calls |
|---------|-----------|
| walk tracks / FX | `CountTracks`, `GetTrack`, `GetMasterTrack`, `TrackFX_GetCount`, `TrackFX_GetFXGUID` |
| identity | `GetTrackGUID`, `TrackFX_GetFXGUID` |
| add / move / remove FX | `TrackFX_AddByName`, `TrackFX_CopyToTrack`, `TrackFX_Delete` |
| FX name & params | `TrackFX_GetNamedConfigParm` (`fx_name`/`fx_type`/`fx_ident`/`renamed_name`), `TrackFX_GetParam`/`SetParam` |
| sends | `CreateTrackSend`, `RemoveTrackSend`, `GetTrackNumSends`, `Get`/`SetTrackSendInfo_Value` |
| main send | `Get`/`SetMediaTrackInfo_Value` (`B_MAINSEND`, `C_MAINSEND_OFFS`, `C_MAINSEND_NCH`) |
| audio pins | `TrackFX_GetIOSize`, `TrackFX_Get`/`SetPinMappings` |
| track channels & folders | `Get`/`SetMediaTrackInfo_Value` (`I_NCHAN`, `I_FOLDERDEPTH`, …) |
| per-FX MIDI bus | none — `Get`/`SetTrackStateChunk`, then **5.3** |
| installed plugins | `EnumInstalledFX` — fixed for the session; enumerate once and cache |
| one undo step | `Undo_BeginBlock`/`Undo_EndBlock2`, inside `PreventUIRefresh(1)`/`(-1)` |

**6.3** Where the means run out. The API cannot express three things: the
per-FX MIDI bus and its replace/merge flag (**5**); whether a plugin emits
MIDI (**5.24**); a stable name for a send (**2.31**). Three more it permits
but will not let you reshape: the master, which no send may target
(**4.3**); the main send, whose source is fixed and whose landing alone is
yours (**4.2**); the folder parent send, whose all-bus MIDI is
identity-mapped and undisableable (**4.41**). The rest — topology, chains,
audio sends, pin matrices, MIDI sends — it does cleanly.

---

**7** Whereof the API cannot speak, thereof one must edit the chunk.
