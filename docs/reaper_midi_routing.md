# REAPER per-FX MIDI bus routing

What an FX slot's MIDI input/output dialog actually does, and how the
state is encoded in the RPP file. Reverse-engineered against
REAPER 7.61 (macOS-arm64) — there is no documented API surface for
either reading or writing this setting. Test RPPs live in `design/`.

## Model

Each non-JSFX FX slot wraps the plugin in a REAPER frame that holds
the routing state. The frame has three knobs: an **input bus filter**
(1..16, or *disabled*), an **output bus** (1..16, or *disabled*), and
an output mode that is either **replace** (the default) or **merge**.
JSFXes bypass this entirely — they see all 16 buses via `midi_bus` and
do their own routing.

The runtime semantics (derived from cases we tested with no-MIDI-out
plugins, synths, and a note filter):

1. The input filter **drains** matching events from the chain into the
   plugin's view. Reads are consuming, not tee'd.
2. The plugin emits events on its output bus.
3. **Replace** overwrites the output bus with the emissions; **merge**
   adds them to whatever was already on that bus.
4. **No-MIDI-output fallback.** If the plugin has no declared MIDI
   output port, REAPER rebroadcasts the input view onto the input bus
   regardless of what was emitted. This is why synths and audio
   effects naturally pass MIDI through to downstream FX, and why a
   no-output plugin set to `in=1/out=1/replace` does *not* silence
   bus 1 — the rebroadcast restores it after the overwrite wipes it.

The fallback is capability-based, not runtime-based: a real MIDI
filter that emits an empty subset still silences its output, because
its declaration says it has a MIDI output port. REAPER reads this
from the plugin manifest (VST3 event bus, AU MIDI output element,
CLAP note ports) at chain-build time. The fact is internal — neither
the GUI nor the ReaScript API exposes it.

## RPP encoding

The routing lives inside each FX's `<VST ...>` block in the `FXCHAIN`,
in two places that REAPER keeps in sync.

**Trailer line** (the last base64 line, after the plugin's own
state) decodes to six bytes:

```
00 00 <flags> <in_bus> <out_bus> 00
```

- `flags` byte: `0x10` (always set, routing-present marker)
  | `0x01` if input disabled
  | `0x02` if output disabled
  | `0x08` if merge mode (clear ⇒ replace).
- `in_bus`, `out_bus`: 0-indexed bus number (`0x00` = bus 1).
- Bytes 0, 1, and 5: always `0x00` in everything we observed.

**Plugin-state header mirror** (the last 2 chunk bytes of the first
base64 line, i.e. the bytes ending the `eXNlcu...` block):

```
<flags | (in_disabled ? 0x40 : 0)>  <n+1>
```

The mirror flag byte adds bit 6 (`0x40`) when input is disabled, but
otherwise tracks the trailer's flag byte exactly.

`n+1` is normally `0x00`. The one observed exception is `0x80` in the
specific corner `in_disabled=1, out_bus=0, replace`. Reproduced
across two saves, so it's a real bit, but its semantics aren't pinned
down from a single cell. Treat as opaque.

## Writing the mutator

A chunk-mutator that sets routing should:

1. Patch the trailer from a closed-form derivation of the four
   settings.
2. Patch the mirror flag byte using `trailer_flags | (in_disabled ?
   0x40 : 0)`.
3. **Read and preserve** the mirror `n+1` byte from the existing
   chunk rather than recomputing it — that way the corner-case `0x80`
   stays correct when present and isn't fabricated when absent.

The encoding is version-sensitive (REAPER's serialisation format is
not contractual). A future REAPER may change it; the test RPPs in
`design/` are the regression set.

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
