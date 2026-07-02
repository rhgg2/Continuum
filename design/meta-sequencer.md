# Design — Meta-sequencer (performance as composition)

Status: vague, pre-design. A vision note, not a plan. Captured because
every prerequisite is already being poured for other reasons, and the
idea is obvious in the moment and gone by Friday.

The one-line pitch: **record the live edits you make while a pattern
loops, and replay them as a sequenced, editable track — a sequencer
whose events are edits.**

## The thesis it rests on

Nothing here is a new axiom. It is what falls out when three decisions
already made are stood next to each other:

- **The document is intent, not MIDI.** Detune is intent, pb is
  realisation; the logical frame is intent, swing compiles it. So the
  document after *n* edits — call it `doc(e)` — is a meaningful,
  addressable object, and an *edit* is a delta between two of them.
- **Rebuild is (becoming) a pure function.** Step 5's
  serialise→SetAllEvts makes `doc → blob` one pure pass. A pure compile
  can be memoised, sampled, and run speculatively — which is what turns
  "replay the edits" from a re-enactment into a *sampling* problem.
- **The sequencer grid is a reusable layered component.** The editor
  for this is the note grid re-axised, not a new tool.

Build the meta-sequencer and you have built most of the [variation
tree](#relationship-to-the-variation-tree); build the variation tree
and you have built most of this. They share one primitive: the delta.

## Vocabulary

- **Edit / delta** — a named, serialisable, **context-free** mutation
  of `doc(e)`. Context-free is load-bearing: "transpose *selection*"
  must be resolved to explicit targets *at capture time*, because
  selection is transient state, not document state. Replay of an
  unresolved gesture does the wrong thing against a different context.
- **Meta-sequence** — a timeline of deltas. Document data, lives in
  `dataStore`, not `configManager` (it is not config).
- **`doc(e)`** — the pattern after the first *e* edits are folded in.
- **The two lane kinds** — see below; the split is forced by playback,
  not chosen for tidiness.

## Two kinds of delta, because scrubbing forces it

A live pattern jam mixes two things that *look* alike and replay
nothing alike:

- **Parametric edits** — macro depth, swing params, detune spread,
  group params. These are **automation lanes**: a value over time.
  State at bar 10 = sample the curve at bar 10. Order-free, idempotent,
  trivially scrubbable. The *easy* half, and free of the dependency
  hazard below.
- **Structural edits** — add/remove note or CC, mute a column, edit a
  group's membership. These are **impulse events**: discrete mutations
  that fire when the playhead crosses them. State at bar 10 = base
  folded through every impulse before bar 10, **in order**.
  Order-dependent, not samplable.

Pretending these are one type is how the design goes wrong. They are
different data with different playback math.

### Cheap scrub = fold + snapshots

Automation scrubs for free. Impulse lanes don't — reconstructing state
at *T* means folding every structural delta from the start. So snapshot
the full compiled `doc` periodically (loop boundaries are the natural
keyframe) and fold forward only from the nearest snapshot. Event
sourcing with keyframes; the same idea as "freeze = caching a compile
stage." The whole meta-player then slots in as **one stage before Step
5's compile**:

```
basePattern + metaSequence  --fold at T-->  doc(e)  --serialise-->  blob
```

It composes cleanly *because* the compile is pure.

### The hard core: movable structural edits have dependencies

The power of a sequencer is that its events are movable. The tax is
that structural deltas depend on each other. "Add note X at bar 4",
then "detune note X at bar 8" — drag the detune before the add and it
references a note that does not exist yet; delete the column a later
ghost lives in and every delta targeting it dangles. So the impulse
lane is not a flat strip — it is closer to a **dependency graph** of
deltas, and this is the place a DAG genuinely earns its rent (contrast
note-macros, pinned as "comb not DAG"). Automation lanes have none of
this, which is the other reason they are the half to build first.

## Two time axes — and the path through them

The clarifying move. There are **three clocks**, and keeping them
apart is the whole design:

- **τ — playback time.** The final timeline you render and hear.
- **s — pattern position.** Where you are *inside* the loop. Wraps.
- **e — version.** Which `doc(e)` is playing: your edits timeline.

The field **factorizes**: content at any point is `render(doc(e))`
sampled at `s`. Version and position are separable — so you never
materialise the whole 2-D field, you **sample it along a path**,
memoised by version (the fold+snapshot machinery, doing double duty).

**The live take is one specific path.** While performing, `s` sawtooths
(the loop) while `e` climbs monotonically (edits accrue). The recorded
path is a **staircase**: horizontal sweeps at a fixed version, stepping
up in `e` at each edit. And the fidelity subtlety the two-axis view
exposes: you edited row 12 while the playhead was at row 4, so `e`
**stepped mid-loop**, at the exact `s` where the edit landed — not at
the loop boundary. That mid-loop staircase is what you must capture to
reproduce what you *heard*. Snapping steps to bar lines gives a cleaner
but different take; the snap is a toggle, and it is the same
quantize-the-edit-stream question timing.md's logical/realisation split
already frames.

### The collapse: version is just an automation lane

"Map a path through the 2-D space" sounds like it needs a 2-D authoring
tool. It reduces to one thing: **`e` is an automation lane over
playback time.** Ordinary looping playback supplies `s`; the only new
master control is a curve saying *which version* to render at each
point. Every playback you'd want is a shape of that curve:

- **Faithful replay** — the recorded staircase.
- **Freeze** — a flat line at `e*`: grab the pattern as it was at one
  moment.
- **Auto-develop** — a ramp: spread the jam's whole evolution across 32
  bars, so the performance's growth *becomes the song's structure*.
- **Vamp** — hold `e` flat, then step: linger on a version, then move.
- Or draw anything.

The expressive knob this exposes is **traversal rate** — how fast `e`
climbs relative to `s`. Tempo, but for the version axis. Fast compresses
the evolution; slow gives each version many loops to breathe; holding it
vamps. Faithful replay uses the rate you performed at, and retiming it
is a first-class edit.

### The editor writes itself, and reuses the grid

A surface with **song-time horizontal and version vertical** — a piano
roll whose vertical axis is *version* instead of pitch. The live jam
appears as the staircase; you compose playback by **dragging the path**
across it: flatten a stretch to freeze, tilt it to develop, loop a band
of edit-time to repeat a phase of your own evolution. Same
sequencer-grid component, different axes — the layered `page → view →
manager` stack paying off. You don't build a new editor; you re-axis
the one you have.

## Where it sits in the architecture (reuse, don't invent)

- **Capture tap** — `commandManager` dispatch. Every live edit is
  already a named command with structured args; the recorder is a
  subscriber that stamps each dispatch with transport position and
  resolves it to a context-free delta. Command level (not the lower
  signal protocol) is right here: it preserves *intent*, which is the
  whole point.
- **Storage** — `dataStore`, as document data.
- **Player** — a new pre-compile stage, `fold at T`, feeding the Step 5
  serialise.
- **Editor** — the sequencer grid, re-axised.
- **Determinism at coincident ticks** — inherits the same-pitch /
  onset-collision ordering discipline the recent midiBlob work
  established, one level up: two deltas on the same tick need a stable
  order.

## Relationship to the variation tree

Same primitive, different topology. The variation tree branches the
delta stream (fork, diff, A/B, merge — "what if?" in parallel). The
meta-sequencer unrolls it along a time axis (record, sequence, replay —
"what I did" in series). A branch *is* a held version `e*`; a
performance *is* a path `e(τ)`. Build either and the delta vocabulary,
the fold+snapshot player, and the context-free-target discipline are
shared. Neither needs the other to ship, but they are two views of one
building.

## First brick

Prototype **automation lanes, faithful replay first.** Ride macro depth
and swing live, capture them stamped against transport, reconstruct the
recorded staircase, play it back exactly.

- It exercises the whole capture → fold → compile pipeline end to end.
- It dodges the structural-delta dependency graph entirely.
- Faithful replay is the ground truth every other path (freeze,
  develop, draw-your-own) is a deformation of — so once the staircase
  replays, those are all just *editing a curve you already have*.

## Open

- **The delta vocabulary** — the real first question. Name the closed
  set of edit-types worth sequencing (set-macro-param, set-swing-param,
  set-group-param; add/remove-note, add/remove-cc, mute-column,
  edit-group-membership), split automation vs impulse, and pin each
  one's serialisable context-free payload. That list *is* the
  instruction set, and the variation tree inherits it.
- **Mid-loop step vs quantize** — capture exact apply-moments, or snap
  to the grid? Toggle, but which is the default.
- **Does `s` ever get manipulated**, or is it always ordinary looping
  playback and only `e` is authored? (Start with the latter.)
- **How far does "meta" recurse** — is the meta-sequence itself
  recordable? Almost certainly stop at one level; note it so the
  boundary is deliberate.
