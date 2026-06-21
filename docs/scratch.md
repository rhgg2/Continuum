# scratch

One hidden, muted REAPER track that the project parks things on. Three
tenants share it:

- **`routingManager`** mirrors its fx-meta projext blobs onto the track's
  chunk, so REAPER undo reverts them (projext doesn't reverse natively).
- **`wiringManager`** parks FX that have no compile-graph track —
  disconnected nodes, lowered-parked instances.
- **`arrangeManager`** (forthcoming) parks the MIDI of emptied palette
  slots, so a slot survives losing its last grid instance.

## Why its own module

The three needs are unrelated to each other and to the modules that have
them. "Provide a shared scratch track" is not a routing concern, a wiring
concern, or a config concern — so it lives nowhere but here. rm used to
own it, which fused "I need a track for my undo mirror" with "the project
has a scratch track"; this module splits them. rm, wm, am are now equal
tenants.

## Why `require`, not injected

`scratch` holds no state. Its identity is the guid persisted in projext
(`continuum_wiring/scratch`), and it re-locates the live track by guid on
every call — REAPER track handles go stale, so there is nothing safe to
memoise. A stateless module is reached by `require`, like `util`/`DAG`/
`fs`; injection would thread a dependency that carries no state through
every rm/wm construction site (~40, mostly test scaffolds) and buy
nothing. The single-owner property comes free: one cached module table,
one persisted guid.

## Hidden and muted

Hidden keeps it out of the mixer and TCP. Muted keeps it **silent** —
distinct and necessary: wiring parks synth FX here, and a parked MIDI
item (arrange) feeds the track's FX chain, so an unmuted scratch could
sound a parked synth into master. `B_MUTE` is set once at mint.

## The folder-pin copy

Minting appends a track; if the project ends inside an open folder the
new track would join it. The ~10-line top-level pin is copied from
`rm:addTrack` rather than called, to keep this module dependency-free
(rm is a per-stack instance this module can't reach). Two instances of
the pin is within tolerance; extract only if a third appears.
