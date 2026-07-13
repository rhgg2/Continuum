# tests

The pure-Lua suite: how `tests/harness.lua` builds scenarios, what
`tests/fakeReaper.lua` guarantees, and where the seams are. Per-spec
outlines live in `map/specs/*.map`; this doc carries the model.

## One boundary faked

Only `reaper.*` is faked. Everything else in a scenario — midiManager,
pextStore, configManager, dataStore, trackerManager, trackerView,
commandManager, paramAutomation — is the production module, wired the
production way, and seeds are authored through the production write
path (`mm:modify` + `mm:add`), never poked into internals. A green
spec therefore certifies the code that runs live; conversely, a
REAPER-only repro usually means the spec is missing a step the live
flow performs (see Gotchas).

`realMidiManager.lua` loads midiManager via `loadfile`, sidestepping
`util._stubs`: the harness installs its own mm factory there so that
internal `util.instantiate('midiManager', …)` calls (e.g.
trackerPage's) resolve to the same real implementation, and going
through `require` would loop back into that stub. Every mm instance
gets a real eventMeta over a real pextStore, and all instances share
the live fakeReaper's project ext-state — so a second mm bound to the
same take (round-trip specs) sees the first's writes.

## Scenarios

Two entry points:

- `harness.mk(opts)` — the full tracker stack. Returns a handle
  table: `fm` (the midiManager — the key predates the move to the
  real mm), `cm`, `ds`, `ps`, `tm`, `vm`, `ec`, `gm`, `pa`, `ccm`,
  `clipboard`, `cmgr`, `reaper`. opts: `seed` (notes/ccs plus
  `resolution`, `length` in ppq, `timeSigs`), `config` (tier →
  table, applied via `cm:assign`), `data`, `take`, `groups`.
- `harness.bareMM(seed)` — a real mm with no tm/vm above it. Exists
  because mm contract specs pin behaviour on a plain cc, which a tm
  rebuild would stamp (ppqL → uuid) out from under them.

groupManager is opt-in (`opts.groups`) because it subscribes to tm
flush signals — wiring it unconditionally would perturb every
tm-unit spec's flush pipeline. paramAutomation gets a stub facade
that resolves a take's owner track to its host track; harness
scenarios only ever use live takes, where that is the right answer.
`cmgr` comes pre-pushed into the `tracker` scope.

Isolation between scenarios:

- Each `mk()`/`bareMM()` builds a fresh fakeReaper and reassigns
  `_G.reaper`. Production modules read the global at call time, so
  handles from an earlier `mk()` are dead the moment the next one
  runs — one live scenario at a time.
- configManager/dataStore global tiers do real `io.open` on
  `continuum-config.lua` / `continuum-data.lua`; the harness
  redirects those paths to temp files at require time and truncates
  them in each `mk()`, so one scenario's `cm:set('global', …)`
  can't leak into the next.

Seeding: payload notes get `evType = 'note'`; a stamped note (ppqL
present) is defaulted `lane = 1, detune = 0, delay = 0` because tm
crashes at pickStampedLane otherwise; `ppqL` falls back to `ppq`
when only `endppqL` was given. `mm.seed`/`mm.dump` are harness-only
shims on the handle — production mm has no such surface.

## fakeReaper

Call convention split: dot-call functions (`r.MIDI_GetNote(...)`)
are the REAPER API surface production sees; colon-call methods
(`r:seedMidi`, `r:bindTake`, `r:addItem`, `r:setTrackFX`, …) are
spec-side seeding/inspection helpers that don't exist in real
REAPER. All state hangs off `r._state`; prefer the helpers, and
reach into state directly only where no helper exists (e.g.
`state.lastTouched`, `state.appVersion`).

It covers only the surface production touches, but where it answers
at all it answers with REAPER's real defaults (`B_MAINSEND = 1`,
`D_VOL = 1.0`, new-send flag defaults, …), so specs never have to
seed values they don't care about.

Conventions and modelled behaviours worth knowing:

- **1 second == 1 QN.** `TimeMap2_timeToQN`/`QNToTime` are identity,
  so specs author item positions and lengths directly in QN.
  ppq↔time conversions honour tempo (default 120) and ppqPerQN
  (default 240).
- **State-change count.** Structural edits bump
  `GetProjectStateChangeCount`; ext-state writes don't — mirrors
  REAPER, and is what arrangeManager polls to notice foreign edits.
- **Defer is a queue.** `reaper.defer` pushes into `state.deferred`;
  specs drain it by hand to run a defer cycle.
- **Outward calls are logged.** Effect-only calls (`SetEditCurPos`,
  `StuffMIDIMessage`, `Main_OnCommand`, `TrackFX_SetParam` /
  `SetNamedConfigParm` / `Show`, loop-range sets) append to
  `state.calls` for assertion; `r:clearCalls()` resets between
  phases.

### The MIDI take store

Each take's MIDI lives twice: a structured store (notes/ccs/texts
plus a passthrough stream for events the store doesn't model) and a
wire blob. `MIDI_GetAllEvts` serialises the structured store;
`MIDI_SetAllEvts` deserialises the wire back into it — so the
per-event Get/Set/Count surface and whole-take blob writes stay
consistent whichever path mm takes. The two codecs mirror
`midiBlob.lua` independently; that round-trip partnership is what
keeps the fake honest, and if the on-wire format shifts, both sides
must move.

Modelled REAPER behaviours specs depend on:

- **Sort semantics.** Insertion order is preserved between
  `MIDI_DisableSort` and `MIDI_Sort`; sort is stable by ppq.
- **Notation cascade.** Deleting a note also deletes its notation
  text event, shifting the shared text stream — the desync surface
  mm's uuidIdx rescan exists for.
- **Bezier tension.** CC shape 5 emits/consumes a CCBZ meta event
  riding just after its cc on the wire.
- **All-notes-off tail.** Serialise appends it; parse excludes it —
  same as REAPER.
- **Hash.** `MIDI_GetHash` returns the serialised blob itself:
  equal content ⇔ equal hash, nothing more.

### FX and routing surface

Enough of the FX/track/send API for the wiring and sampler stacks:
per-track fx lists (bare-string entries are legacy seeds; tables
carry `ident`/`fxType`/`name`/…), guid maps that shift on delete
and move, pin mappings, param names/sections, and sends (one record
per send; receives are derived by scanning every track's sends).
`Get/SetTrackStateChunk` round-trips only the per-FX routing bytes
(`flag`/`inBus`/`outBus`) — the rest of the chunk is regenerated on
every read, so nothing else survives a chunk round-trip.

## support.lua

Assertion helpers (`eq`, `deepEq`, `bagEq`, `eventsMatch` — subset
match per event, in order), a sidecar byte codec mirroring
midiManager's (kept in sync by hand — it exists so fixtures can
plant sidecar bytes before `mm:load` without reaching into mm),
eventMeta seed/read helpers keyed by the take's POOLEDEVTS guid,
and `fakeDs`/`fakeTm` for gm unit specs. `fakeTm` records staged
intent but drives the real preflush/applyEdit/postflush path,
stamping uuids at flush the way REAPER does.

## Running and registering

`lua tests/run.lua [filter]` (plain substring match on
`spec :: test name`); in-session, `mcp__readium_tests__lua_test_run`.
A spec file returns an array of
`{ name, run = function(harness) … end }` entries
(`pending = 'reason'` parks one) and must be listed in `run.lua`'s
spec table or it never runs.

## Gotchas

- **One live scenario at a time.** `mk()` swaps `_G.reaper`; an
  earlier scenario's handles silently operate on the new fake's
  empty state.
- **Round-trips drop RAM-only state.** `h.fm:load()` +
  `h.tm:rebuild()` rebuilds from persisted bytes; tags that live
  only in RAM vanish. A bug that "only reproduces in REAPER"
  usually means the spec is missing this round-trip.
- **Config tier shadowing.** A value set at a wide tier can be
  shadowed by a fixture's narrower tier — read the target fixture's
  config before trusting a red test.
