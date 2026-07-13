# scratch

One hidden, muted REAPER track that the project parks things on. Three
tenants share it:

- **`pextStore`** mirrors every *undoable* project-scope slot (eventMeta
  tags, project-tier config, dataStore's project keys — rm's fx/bus meta
  among them) onto the track's P_EXT under `ctm_ps.*`, so REAPER undo
  rewinds them (docs/pextStore.md § The mirror).
- **`wiringManager`** parks FX that have no compile-graph track —
  disconnected nodes, lowered-parked instances.
- **`arrangeManager`** (forthcoming) parks the MIDI of emptied palette
  slots, so a slot survives losing its last grid instance.

## Why its own module

The needs are unrelated to each other and to the modules that have them.
"Provide a shared scratch track" is not a routing concern, a wiring
concern, or a config concern — so it lives nowhere but here. rm used to
own it, which fused "I need a track for my undo mirror" with "the project
has a scratch track"; this module splits them. rm has since given up its
private mirror entirely — its meta is project-scope `dataStore` data, so
pextStore mirrors it like any other undoable slot.

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
