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

**Trailer line** (the last base64 line, after the plugin's own
state) decodes to six bytes:

```
00 00 <flags> <in_bus> <out_bus> 00
```

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
- Bytes 0, 1, and 5: always `0x00` in everything we observed.

**Plugin-state header mirror** (the last 2 bytes of the first base64
line, i.e. the bytes ending the `eXNlcu...` block):

```
<flags>  0x00
```

The mirror flag byte is **identical** to the trailer's flag byte
(including bit `0x40`). The trailing byte is `0x00` in every observed
configuration, including the `in_disabled=1, out_bus=0, replace`
corner the original notes flagged as a `0x80` exception — that
exception did not reproduce on REAPER 7.61 macOS-arm64 and is dropped
from the spec. Treat the byte as opaque and read-and-preserve when
patching, in case a future REAPER reintroduces something there.

## Writing the mutator

The flag byte carries bits we understand (`0x01`, `0x02`, `0x08`) and
bits we don't (`0x10` preset-state, `0x40` input-touch-sticky, anything
else). The safe surgery is **read-modify-write on the bit being
changed**, not authoring the byte from scratch — that way we never
clobber state we don't model.

A mutator that sets, say, output-disabled should:

1. Locate the FX's `<VST ...>` block in the FXCHAIN.
2. Decode the trailer's flag byte (byte 2 of the 6-byte trailer).
   OR in `0x02`. Re-encode the trailer line.
3. Decode the mirror's flag byte (the penultimate byte of the first
   base64 line, decoded). OR in `0x02`. Re-encode the affected base64
   group.
4. Leave `in_bus`, `out_bus`, and every other byte untouched.

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
