# REAPER per-FX MIDI bus routing

What an FX slot's MIDI input/output dialog actually does, and how the
state is encoded in the RPP file. Reverse-engineered against
REAPER 7.61 (macOS-arm64) — there is no documented API surface for
either reading or writing this setting. Test RPPs live in `design/`.

## Model

Each non-JSFX FX slot wraps the plugin in a REAPER frame that holds
the routing state. A plugin has **exactly one** MIDI input bus and
**exactly one** MIDI output bus — never multiple of either. The frame
exposes three knobs: which bus the input is filtered to (1..128, or
*disabled*), which bus the output is written to (1..128, or
*disabled*), and an output mode that is either **replace** (the
default) or **merge**. JSFXes bypass this entirely — they see all
128 buses via `midi_bus` and do their own routing.

The runtime semantics (derived from cases we tested with no-MIDI-out
plugins, synths, and a note filter):

1. The input filter **reads** matching events from the bus into the
   plugin's view. Reads are non-consuming — the events stay on the
   bus, available to later FX in the chain.
2. The plugin emits events on its output bus.
3. **Replace** overwrites the output bus with the emissions; **merge**
   adds them to whatever was already on that bus.
4. **No-MIDI-output fallback.** If the plugin has no declared MIDI
   output port, REAPER substitutes the plugin's emission with the
   input view. There is no separate "rebroadcast" step — the
   substituted events flow through the same output routing as a real
   emission would: replace or merge onto `out_bus`. This is why
   synths and audio effects naturally pass MIDI through to downstream
   FX (their default `in=1/out=1/replace` writes the input view back
   onto bus 1), and why `out_bus=disabled` silences a no-MIDI-out FX
   completely without any capability check — nothing is written
   anywhere when the output is disabled.

The fallback is capability-based, not runtime-based: a real MIDI
filter that emits an empty subset still silences its output, because
its declaration says it has a MIDI output port. REAPER reads this
from the plugin manifest (VST3 event bus, AU MIDI output element,
CLAP note ports) at chain-build time. The fact is internal — neither
the GUI nor the ReaScript API exposes it.

## RPP encoding

The routing lives inside each FX's `<VST ...>` block in the `FXCHAIN`,
in two places that REAPER keeps in sync. Ground-truth captures live
in `design/midi-routing-fixtures.md`; the spike that produced them is
`tests/spike_midi_routing.lua`.

**Routing record** — the **last 4 bytes of the FX block's concatenated
decoded stream** (all base64 content lines joined, then decoded):

```
<flags> <in_bus> <out_bus> 00
```

The record is *always* the stream tail. When a preset is loaded, REAPER
stores its name immediately before the record as `<name>\0`, so the last
base64 *line* is `… <name>\0 <flags> <in_bus> <out_bus> 00` — not a clean
record. Index from the **end of the decoded stream** (`flags =
stream[n-3]`, `in_bus = stream[n-2]`, `out_bus = stream[n-1]`), never
"byte 3/4/5 of the last line". The spike (`tests/spike_midi_routing.lua`)
only tested ReaEQ with no preset, whose empty name (`\0\0`) left the
record at the line's start and made it look like a clean 6-byte
`00 00 <flags> <in> <out> 00` line — a no-preset coincidence, the same
class of trap as the mirror's "first base64 line".

- `flags` byte (bits observed):
  - `0x01` — input disabled.
  - `0x02` — output disabled.
  - `0x08` — merge mode (clear ⇒ replace).
  - `0x10` — observed to toggle when the FX's preset changes. Not a
    routing flag; treat as opaque and preserve.
  - `0x40` — sticky "input-disable checkbox has been touched" marker.
    Clear on a fresh FX; REAPER sets it the first time the user
    toggles the input-disable checkbox and it stays set thereafter
    (including across reverting to defaults).
  - Other bits unobserved; treat as opaque.
- `in_bus`, `out_bus`: 0-indexed bus number, range 0..127
  (`0x00` = bus 1, `0x7F` = bus 128).
- The record's trailing 4th byte: always `0x00` in everything observed.

**Wrapper-header mirror** (a fixed offset inside REAPER's wrapper at
the head of the concatenated decoded stream — *not* "the first base64
line"; that was a ReaEQ-shaped coincidence). REAPER prepends a wrapper
of `28 + 8 * pinChannels` bytes to plugin state, where `pinChannels =
inputPins + outputPins` mono channels as reported by
`TrackFX_GetIOSize`. The wrapper ends with `<flags> 0x00`, so the
mirror flag sits at 1-indexed decoded-stream offset
`27 + 8 * pinChannels`:

```
... wrapper fillers ... <flags> 0x00 | <plugin state ...> | <trailer>
                       ^^^^^^^^
                       offset = 27 + 8*pinChannels (1-indexed)
```

Calibration against captured chunks: ReaEQ (2-in/2-out stereo = 4 mono
channels) → 59; Softube Modular (5 stereo out = 10 mono) → 107;
UVI Falcon (17 stereo out = 34 mono) → 299. Formula holds exactly.

REAPER reads from the mirror as well as the trailer — a trailer-only
write does **not** flip the MIDI I/O dialog. The mirror flag byte is
**identical** to the trailer's flag byte (including bit `0x40`); the
trailing `0x00` is opaque pad. Because pinChannels can push the
mirror's byte onto any base64 line (REAPER wraps at 280 chars / 210
decoded bytes), the surgery has to walk the FX block's content lines
accumulating decoded lengths, locate the line containing the offset,
and patch within it — not "patch the first base64 line".

## Writing the mutator

The flag byte carries bits we understand (`0x01`, `0x02`, `0x08`) and
bits we don't (`0x10` preset-state, `0x40` input-touch-sticky, anything
else). The safe surgery is **read-modify-write on the bit being
changed**, not authoring the byte from scratch — that way we never
clobber state we don't model.

A mutator that sets, say, output-disabled should:

1. Locate the FX's `<VST ...>` block in the FXCHAIN.
2. Decode the flag byte at stream offset `n-3` (`n` = decoded stream
   length). OR in `0x02`. Re-encode just the base64 line it falls in.
3. Compute the mirror offset: `27 + 8 * pinChannels`, 1-indexed in the
   concatenated decoded stream. Walk the FX block's base64 content
   lines accumulating decoded lengths to find which line contains
   that offset; decode that line, OR `0x02` into the byte at the
   within-line index, re-encode just that line.
4. Bus numbers live at stream offsets `n-2` / `n-1`; leave every other
   byte untouched.

The encoding is version-sensitive (REAPER's serialisation format is
not contractual). Re-run the spike against new REAPER versions; the
fixtures file is the regression set.

## What the API does not give you

- No `TrackFX_*` getter or setter for the MIDI input/output bus or
  replace flag. `TrackFX_GetPinMappings` is the audio pin matrix, not
  the bus filter. `TrackFX_GetNamedConfigParm` has no documented key
  for it.
- No way to ask whether a plugin has a real MIDI output port.
  `is_instrument` only distinguishes synth vs effect; `out_pin_X`
  names cover audio pins only. The capability is internal-only — if
  script needs it, the practical workarounds are an `fx_ident`
  allowlist or runtime probing.
- The pin connector dialog in the UI does not render a MIDI row
  either. The capability is genuinely hidden from both surfaces.

## Sources

- Forum thread we posted into:
  search the cockos.com forum for "Understanding REAPER MIDI bus
  semantics".
- [MIDI Buses Facts Sheet](https://forum.cockos.com/showthread.php?t=197276)
  — user-level only, no API/format detail.
- [ReaTeam State Chunk Definitions](https://github.com/ReaTeam/Doc/blob/master/State%20Chunk%20Definitions)
  — doesn't cover this corner of the FXCHAIN format.
