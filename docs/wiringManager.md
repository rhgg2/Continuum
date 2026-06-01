# wiringManager

Persistence + validation seam for the wiring page. The page edits
through wm, wm gates writes through `DAG.validate`, persists to cm.
For the graph model itself see `design/wiring.md`.

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
on disk and never broadcasts a corrupted graph downstream. The Stage 2
differ subscribing to `wiringChanged` can assume validation has
already passed.

## Master is a regular node

The master sits in `graph.nodes['master']` with `kind='master'`,
materialised by `freshGraph()` on first load of an empty project.
Not a special parallel field. The singleton constraint is enforced
by `DAG.validate` — same mechanism that would catch a buggy mutator
minting a second master, rather than two storage shapes encoding the
same rule.

## Routing intent record

The per-FX MIDI passthrough bit (`0x02` of the routing trailer; see
`docs/reaper_midi_routing.md`) has no `TrackFX_*` API — read or write
goes through `GetTrackStateChunk` / `SetTrackStateChunk`, which parse
and reserialise the entire track state. A five-FX chain is hundreds
of milliseconds per roundtrip.

Continuum owns this bit (see contract below), so it knows what value
it last applied. `appliedMidiOut[fxGuid] = bool` is that record; `nil`
means "never written" — REAPER's fresh-FX state, which is
`midiOut=true` (bit clear). Persisted as `wiringMidiOutApplied` in
the project tier and rehydrated on `wm:load`.

Snap reads `appliedMidiOut[guid]` (with `nil` ⇒ `true`) into
`fxOrder[i].midiOut` instead of decoding the chunk. `reconcileFXChain`
step 5 filters target entries to those whose desired `midiOut` differs
from the applied value; when the filter empties, the chunk is never
touched. Otherwise one `Get`+`Set` per track and the new values land
in `appliedMidiOut`, persisted at the `applyOps` tail alongside
`wiringOwnedFx`.

**User-facing contract:** Continuum owns the MIDI I/O dialog
("Send all MIDI to plugin" / "Receive MIDI from plugin") on every
FX that lives in a chain the wiring page manages. Toggling it by
hand in REAPER is invisible to snap (we no longer read REAPER's
state); the next graph edit that flips the same bit will overwrite
the manual change, but until then the chain runs with whatever the
user set.

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
