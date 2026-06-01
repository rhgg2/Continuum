# wiring

Cross-cutting reference for the wiring page: how a user-drawn graph
of FX compiles to a REAPER track topology + send graph. The wiring
page is the third rung after tracker and sampler — the layer where
the user composes audio and MIDI processing graphs across a project.

## Two graphs

The model carries two graph shapes that share most of their structure
but operate at different levels of granularity.

The **user graph** is what the user draws and edits. Its edges are
**wires**:

- an **audio wire** is uniformly stereo: always present, always full.
- a **MIDI wire** is 16 channels of data.

Wires carry user-level metadata — gain on audio, channel-remap on
MIDI, "mark as primary" — and they're the unit on which routing
gestures land in the UI.

The **compile graph** is the lowered form that drives the REAPER
projection. Its edges are **connections** — port-to-port for audio,
node-to-node for MIDI. The lowering inserts a Continuum Utility
node for every wire-level op (gain becomes a gain node;
channel-remap becomes a remap node) but otherwise preserves the
shape of the user graph: each wire is one connection.

REAPER tracks are uniformly stereo, so the model carries integer
stereo-port counts on `audio.ins / outs` rather than channel names.
The pre-beta "channels vs ports" distinction — mono adapters,
trailing-odd channels, per-channel splits — dissolved once that
assumption landed; the model is simpler for it.

The partition invariant below operates on the compile graph. srcSet
and class equivalence are stable under lowering — every Continuum
Utility insertion is single-input single-output, so parent srcSets
flow through unchanged — and capacity counts intra-class wires
directly (64 stereo audio / 128 MIDI), checked after lowering.

## Sources, sinks, master

Sources are REAPER tracks; each contributes one audio wire (stereo)
and one MIDI wire. The sink is the **master node** — a singleton in
every user graph, `kind='master'`, carrying an explicit
`audio.ins` integer (default `1`, the one stereo bus; scales up if
the REAPER master exposes more hardware-output pairs). The master
has no audio outs and no MIDI; it is the terminal node for any
audio chain the user wants audible. FX with no outgoing audio wire are simply not routed to
speakers — explicit beats implicit. Nodes between sources and master
are FX instances. Built-in patches (mid-side, bandsplit,
pre/post-emphasis, wire-level gain) are implemented by a single
dedicated JSFX, the **Continuum Utility**.

The wiring page is design-time only. At compile time the compile
graph projects onto REAPER tracks, REAPER sends, per-track FX chains,
and per-FX I/O routing. The master's equivalence class does *not*
spawn a new track — it IS the REAPER master. The compile rule is
the partition invariant below.

## The source-set partition

For every compile-graph node N, define `srcSet(N)` = the set of
source tracks reachable as ancestors of N (transitive closure over
input edges). Two nodes share an equivalence class iff their
source-sets are equal. Each class compiles to **one REAPER track**:

- intra-class connections become **internal port routing** on the
  track (REAPER tracks carry up to 64 stereo audio ports and 128
  MIDI ports, accessed via per-FX I/O routing).
- intra-class topo order becomes the **per-track FX chain order**.
- inter-class connections — connections where `srcSet` changes —
  become **sends to a new track**, and *only* those connections do.

The partition falls out of the graph; it isn't declared. Two
consequences worth naming:

- **It's the minimum REAPER track count** given the topology.
  Anything fewer would have to merge distinct source-sets onto one
  track, and REAPER's per-track signal summing makes that
  unrepresentable.
- **The 64/128 budgets are within-class capacity.** A pathological
  class with >64 distinct intra-class audio wires has to be split
  manually — exposed as a design-time error on the wiring page
  after lowering, not silently routed.

## Primary-input optimisation

The partition gives the floor on track count. One optimisation lifts
it slightly: a class C₂ with srcSet A can **absorb** into a class
C₁ with srcSet A' (A' ⊊ A) by hosting on C₁'s REAPER track rather
than spawning a new one. Connections from C₁ into C₂ become
intra-track continuation; connections from other parent classes feed
in as sends.

The default: auto-absorb iff C₂ has exactly one audio-parent class
in the class-quotient graph. No tiebreak, no heuristic. Override is
per-wire — right-click "mark as primary" forces absorption along
that wire's parent class. Discoverability lives in the wire menu;
no preemptive graph marker is needed.

The hosting mechanism is REAPER's receive: a track sums its own
signal with incoming sends at the top of its chain — or at a
specific FX-slot boundary via the send's pre/post-FX placement. So
"primary passes through" really means "the host track's chain runs
around the merge point", which generalises cleanly: a midstream
sidechain on FX slot 5 of A's chain compiles to a send landing at
slot 5 of A.

## Wire-level operators

Wire-level operators live on the wire in the user graph and lower
into Continuum Utility nodes in the compile graph:

- **gain** (audio wires)
- **channel-remap** (MIDI wires, e.g. `{1→3, 5→9, …}`)

The compile-graph node is the same Continuum Utility JSFX in
different modes. One mechanism doing two jobs: built-in patches
(below) and wire-level operators share a host.

These are the unit that makes routing decisions surface as UI
gestures on a wire rather than as new nodes in the user graph.

**Gain folds to native volume when a send can host it.** A gain on a
wire that compiles to a REAPER send (track→track) or the parent/master
send needs no Continuum Utility — the send's own `D_VOL` carries it
(`DAG`'s `gainSinks` names the sink). The fold fires only when that
send is the *sole* audio contributor (one `D_VOL` can't encode two
wires' gains) and only for a gain sitting on the boundary wire itself
(you can't move a gain across an intervening FX without changing the
sound). Intra-class gain, several wires collapsing onto one send, and
channel-remap all stay Continuum Utility nodes. Wiring sends are
post-FX (pre-fader, `I_SENDMODE=3`) so the from-track fader is free to
be the parent-send gain without also scaling the track→track sends.

## Merge and split

A wire carries one signal occupying one resource: a stereo channel
pair (audio) or a MIDI bus (midi). Merge — several producers into one
input — and split — one producer to several consumers — are where
wires share an endpoint. The compile graph treats audio and MIDI
identically except at the single point REAPER forces apart.

**Split is free and uniform.** Every consumer reads the producer's one
resource — one pair, one bus — and nothing is copied. Source-out,
fx-out, and MIDI all behave the same.

**Merge is one node.** Gain, channel-remap, and summation collapse into
one **Continuum Utility merge node** bound to a consuming FX's input
side — a single `Merge` mode carrying both the FX's audio-pin gains and
its MIDI-bus merge:

- **audio is a per-wire gain bank** wherever a downstream pin matrix
  exists (every normal FX consumer): its inputs are every producer pair
  feeding that FX (unity wires included, at gain 1.0); it scales each
  1:1 — `out[i] = in[i] × gain[i]` — and leaves summation to the
  consuming FX's pin matrix, which sums every pair routed to a pin for
  free. The one matrix-less audio sink, the master parent send (a single
  contiguous range), has no pins to sum, so there the CU sums internally
  to one pair (`audioSum`), exactly as MIDI does.
- **MIDI is an internal N→1 collapse.** No consumer-side matrix exists
  on the MIDI path (REAPER's per-FX filter exposes one bus), so the CU
  reads its input buses at `@block` and re-emits them on one output bus.
  Master MIDI fan-in is this same collapse feeding the parent send.

A single gained wire is this node with `nPairs=1`. One `Merge` mode does
both audio and MIDI, so one node carries both an FX's audio-pin gains and
its MIDI-bus merge; it replaces the legacy `gain` mode and the reserved
`channelRemap`.

**The audio unity fast-path.** A REAPER FX audio input pin sums every
pair routed to it for free *and selectively* — `P→A`, `P+Q→B` coexist
because pins pick subsets. So an FX whose input pins are all unity-gain
(or whose gain folds onto a send's `D_VOL`) needs **no CU**: the pin
matrix is the summing point. The choice is **binary per consuming FX** —
all-unity ⇒ matrix-fed (free, selective); any non-unity gain ⇒ one
merge CU carrying *every* feeder wire of that FX as a 1:1 gain (unity
wires at 1.0). The pins still sum, but every feeder now arrives through
the CU, so no pin mixes a raw producer pair with a gained one —
selectivity stays simple, at the cost of one CU per gained-input FX
rather than one per distinct subset (the right pre-beta trade).

**No consumer-side matrix ⇒ always a CU.** MIDI (REAPER's per-FX filter
exposes one input bus) and the master parent send (one contiguous
channel range) have no free path: any fan-in there is a merge CU. The
CU is an ordinary `ext_midi_bus` JSFX — it reads the converging buses
at `@block` and emits one stream; cross-track producers reach it as
sends arriving on distinct buses on the host track, which REAPER
delivers to the same `@block`, so no gmem ring and no processing-order
hack. (This is why the earlier gmem-merge design is gone: a JSFX can
read every MIDI bus.)

**One consequence drives the rest of the compiler:** because every MIDI
fan-in is a merge node with a single output bus, **every MIDI consumer
has exactly one input stream.** Bus allocation, the non-bus-aware
bracket pass, and the differ never meet a multi-input MIDI node.

**There is no lowered graph.** The merge node is the only node the
compile graph has that the user graph lacks, and it is synthesised at
the targetPlan/allocate boundary — where the partition reveals whether
a gain folds to a send, rides the matrix, or needs a CU — exactly as
the non-bus-aware brackets already are (host-local `fxOrder` entries).
Wire-level ops are no longer spliced into nodes ahead of time; they
ride the connection as metadata (`gain`, `channelMap`) and the merge
node realises them. A CU bridge was always connectivity-inert
(one-in/one-out, inheriting its parent's class), so with splicing gone
the equivalence-class calculus (`srcSet`, `classes`, `quotient`,
`absorption`) runs directly on the user graph. `DAG.lower` is deleted
and the "two graph shapes" invariant collapses to one.

**Master is this rule, not a special case.** ≥2 wires to master (audio
or MIDI) converge through a CU-merge whose single output feeds the
parent send via `C_MAINSEND_OFFS`; one audio wire to master needs no
CU — the parent send reads the producer's pair directly. Gain-folding
to `D_VOL` composes: a sole-contributor wire folds onto the parent
send, multi-wire cases route gains through the CU-merge params instead.
`master.audio.ins > 1` stays deferred — REAPER's contiguous-range
constraint on the parent send makes multi-pair representable only with
silent padding channels, and the cleaner alternatives (per-pair bus
tracks) want their own pass; a class addressing more than one master
pair surfaces as a design-time error.

**Semantic collision stays the user's call.** A CU-merge interleaves
streams but does not separate events that share a MIDI channel: if
producer A puts the kick on ch 1 and B the snare on ch 1, the merged
result is still wrong. The model offers no automatic detection —
**channel-remap on a wire** is the first-class resolution (remap B to
free channels and the collision dissolves). An opt-in diagnostic that
scans owned source tracks for actual channel usage lands later
(Stage 3.5).

## FX containers

REAPER's native FX containers are a UI/CPU-affinity affordance, not
a semantic input to the partition. They compile downstream of the
DAG-to-tracks projection, never upstream. Deferred until a concrete
need (CPU bucketing, per-container freeze) earns the bridge.

## Patches

Deferred. When added, a **patch** is a named, reusable sub-DAG of
FX instances; at wiring time it flattens into the user graph, so
the partition operates uniformly on flat FX instances rather than
descending into a hierarchy. Patches don't carry their own
source-set scope. The same model applies to user-composed chains.

Built-in patches with specific UI affordances — mid-side, bandsplit,
pre/post-emphasis, level adjustments on wires — are a separate
construct: not user-composed sub-DAGs but single FX instances of
Continuum Utility parameterised by mode. The shared host means
built-in patches and wire-level operators run on the same JSFX,
one mechanism doing two jobs.

## Open questions

- **MIDI PDC alignment at a merge.** A CU-merge reading sends whose
  upstream chains differ in latency may see MIDI skewed against audio,
  since REAPER doesn't delay-compensate MIDI by default. `pdc_midi=1`
  on the merge CU is the likely fix; verify with a skeleton if skew
  shows up in practice. (Not gmem-specific — the gmem machinery this
  question used to hang on is gone.)

## Implementation plan

### Anchor decisions

These four shape every stage and don't recur as questions inside
them.

- **Authority direction: reconcile.** The user graph is the source
  of truth for the topology *we own*. Compile lowers it, diffs the
  result against the current REAPER project snapshot, and applies
  the minimal operation list. Tracks/FX without our ownership mark
  are untouched.
- **Compile trigger: live on every change.** Each user gesture
  recompiles and applies. The differ has to be good — minimal
  operation lists, no churn on no-op edits. Every apply is wrapped in
  one `Undo_BeginBlock`/`Undo_EndBlock` so a single REAPER undo step
  reverses the gesture, with the gesture name as the undo label.
- **Ownership marker: per-track only.** Compiled tracks carry a
  `P_EXT` key identifying their equivalence class; FX inside an
  owned track are entirely managed by the wiring page. Per-FX
  ownership is deferred — it's a Stage 6+ refinement if pain emerges.
- **Foreign track adoption: opt-in.** The wiring page starts empty
  on an existing project. The user explicitly imports tracks; the
  importer reads existing FX chains, sends, receives, and channel
  routing into a user-graph fragment, marks the tracks as ours, and
  the live recompile rewires them into canonical form in the same
  gesture. Sources (REAPER tracks) are referenced by GUID;
  deletion of a referenced source surfaces as a design-time error,
  never silent.

### Module layout

- **`DAG.lua`** — pure structural calculus. No REAPER, no cm, no
  ImGui. Both graph shapes (user + compile), the `lower` function
  that produces one from the other, validation (cycles, port-shape
  consistency), `srcSet`, equivalence-class partition, absorption
  rule, capacity-overflow checks on the compile graph. Trivially
  unit-testable.
- **`wiringManager.lua`** — persistence (cm project tier), the
  importer (REAPER state → user-graph fragment), the differ (compile
  graph + REAPER snapshot → operation list), and the applier (the
  `reaper.*` calls under `Undo_BeginBlock`). Owns the user-graph
  instance and emits hooks on mutation.
- **`wiringView.lua`** — node/edge layout, hit-testing, wire-menu
  state, in-memory cursor/selection (not persisted, mirrors how
  `trackerView`/`arrangeView` handle the same).
- **`wiringPage.lua`** — coordinator citizen exposing the standard
  page surface (`bind/unbind/renderToolbarBits/renderBody/
  renderStatusBar/focusState/handleInput/save/load`). Registered in
  `continuum.lua` alongside the other pages.

### Persistence

Only the user graph persists. The compile graph is derived on every
mutation; the differ in Stage 2+ decides whether to cache it
frame-to-frame or re-lower per gesture.

Single project-tier cm key, `wiringGraph`, holding the serialised
user graph. Default `{}`. Owned-track marker: track-level cm key,
`wiringClass` = the class key (a stable string derived from sorted
source-GUIDs of the class). Reconcile uses this to identify "ours"
without needing parallel bookkeeping.

### wiringSnapshot

`wm:snapshot` (reads REAPER) and `wm:targetState` (lowers + allocates
the user graph) emit matching shapes so `wm:diff` compares
element-wise.

- `fxOrder` entries carrying `params` are wm-owned CU bridges —
  synthesised `kind='fx'` nodes from `DAG.lower` (gain / channelRemap)
  or from the bracket post-pass (busPark / busRestore). Snapshot
  mirrors the live params back from the slider so `fxOrderEq` is
  honest; without it every reconcile would spuriously emit
  `setFXChain`.
- `origin` is stamped on every target-side fxOrder entry by
  `projectEntry` so the applier knows where to write minted guids
  back: `'node'` → `node.fxGuid`, `'edge'` →
  `edge.opFxGuid`, `'bracketIn'`/`'bracketOut'` →
  `node.midiInBracketGuid`/`midiOutBracketGuid`. Snap entries do not
  carry `origin` and `fxOrderEq` ignores it.
- `midiOut` is set on both sides only for non-JS `kind='node'`
  entries — target derives it from the user graph
  (`nodeHasMidiOut`), snap from `appliedMidiOut[fxGuid]` (`nil` ⇒
  REAPER's fresh-FX default of true). Mismatch drives `setFXChain`,
  and `reconcileFXChain` step 5 writes the 0x02 bit + records the
  new applied value.
- `pinMaps` carries pair-lists for every port with a route
  (target: allocator-touched; snap: REAPER non-empty); absent port
  ⇒ disconnected. The applier converts pair-lists to REAPER's
  lo32/hi32 bitmask at the boundary.
- `pinMapsByOrigin` carries the same shape for fxs target hasn't
  materialised yet — applier resolves origin → fxGuid via the stamps
  populated by the preceding `setFXChain`.
- `nchan` is the host track's `I_NCHAN`; `mainSendOffs` is
  `C_MAINSEND_OFFS` (only when `mainSend=true`).

### Stage 0 — Continuum Utility JSFX

One file: `wiring/Continuum Utility.jsfx`, mirroring the sampler
subdir convention. Single `mode` parameter dispatching to per-mode
`@sample`/`@block` paths. Stage-1 modes only:

- **`gain`** — stereo audio scalar.
- **`channel-remap`** — MIDI 16→16 LUT applied at `@block`.

Tests: golden buffer in/out per mode via the existing pure-Lua
harness with a stubbed JSFX surface where needed; or, where the
behaviour is trivial enough, direct unit verification of the LUT
transform in isolation. Mid-side / bandsplit / emphasis modes land
in Stage 6.

### Stage 1 — Data model + render-only page

End-to-end testable without touching REAPER topology. The page
draws, edits the user graph, persists it, and reports capacity errors
visually (capacity is read from the lowered compile graph). No
applier yet.

**User-graph schema** (the serialised shape):

```lua
{
  nodes = {
    [nodeId] = {
      kind = 'source' | 'fx' | 'master',
      pos  = { x = number, y = number },  -- wiring-page layout, persisted
      -- source nodes: implicit I/O (one stereo audio out, one MIDI out).
      trackGuid = '{...}',           -- REAPER track GUID
      -- fx nodes:
      fxIdent   = '...',             -- REAPER's stable AddByName ident
      fxDisplay = 'ReaEQ',           -- cached label; renders before any instance exists
      audio     = {                  -- integer stereo-port counts (REAPER tracks
        ins  = number,               -- are always stereo). Defaults: 0 (no audio I/O).
        outs = number,               -- Edges index ports 1..N.
      },
      -- MIDI is implicit on FX: exactly one in, one out, always rendered as ports.
      -- master nodes: id is the fixed string 'master' (outside the _nextId mint
      -- domain); singleton; auto-created in fresh graphs; cannot be deleted via
      -- wm:mutate. Carries audio.ins only (no outs, no MIDI). The ins count
      -- defaults to 1 (one stereo bus) and scales with the REAPER master's
      -- hardware-output stereo-pair count.
    },
  },
  edges = {                          -- user-graph wires
    {
      type = 'midi' | 'audio',
      -- portIdx: source nodes have only port 1 (the track's stereo);
      -- FX nodes have ports 1..N derived from audio.ins / audio.outs.
      from = nodeId, fromPort = nil | portIdx,
      to   = nodeId, toPort   = nil | portIdx,
      ops  = {                       -- wire-level operators
        gain        = number?,       -- audio wires only
        channelMap  = { [1..16] = 1..16 }?,  -- MIDI wires only
      },
      primary = true | nil,          -- "mark as primary" override
    },
  },
  _nextId = number,                  -- monotonic allocator for nodeId
}
```

`nodeId` is a stable string minted from `_nextId`; persisted, so the
importer and live edits both go through one allocator on the same
graph. A foreign-project importer bumps `_nextId` past anything it
saw.

**Pure functions in `DAG.lua`:**

- `DAG.validate(user) -> nil | err` — cycle rejection, port-shape
  consistency (every edge endpoint refers to a port the node
  actually exposes).
- `DAG.lower(user) -> compile` — materialises a Continuum Utility
  node for each wire-level op; each wire becomes one port-to-port
  (audio) or node-to-node (MIDI) connection. Single-input /
  single-output for every inserted node so the srcSet calculus is
  stable under lowering.
- `DAG.srcSet(compile, nodeId) -> set<trackGuid>` (memoised per
  compile-graph instance).
- `DAG.classes(compile) -> { [classKey] = { nodeId, ... } }` where
  `classKey = canonical(sortedSrcGuids)`.
- `DAG.quotientGraph(compile, classes) -> { [classKey] = { parents,
  children } }`.
- `DAG.absorption(quotient) -> { [classKey] = hostClassKey? }`
  applying the auto rule plus any `primary` overrides.
- `DAG.capacityErrors(compile, classes) -> [ { classKey, kind,
  count } ]` for >64 intra-class stereo audio connections or >128
  intra-class MIDI connections.

**`wiringManager` API (Stage 1 surface):**

- `wm:load()` / `wm:save()` — round-trip the user graph via cm
  project tier.
- `wm:graph()` — read access to the user graph (deep copy at
  boundary, per cm convention).
- `wm:mutate(fn)` — call `fn(graph)`, run `DAG.validate`, persist if
  it passes, fire `wiringChanged` hook. All edits go through here so
  the live recompile (Stage 2+) can subscribe to one signal.
- `wm:compile()` — derived compile graph from the current user
  graph; pure, no caching at Stage 1.
- `wm:errors()` — capacity-overflow report; runs `compile` →
  `capacityErrors` end-to-end. View calls per frame; cheap enough at
  Stage 1 scale.

**Hooks emitted (`util.installHooks` pattern):**

- `wiringChanged` — payload `{ kind = 'mutate'|'load' }`. Stage 2
  subscribes to drive the differ.

**`wiringView` / `wiringPage`:**

- Node placement is user-positioned and persisted on the node
  (`node.pos` in the schema above). Drag-to-move writes through
  `wm:mutate`. Selection and in-flight drag state stay in-memory
  on the view (mirrors how `trackerView` / `arrangeView` handle
  ephemeral cursor state).
- Audio wires expose **gain** through a mid-wire fader: **left-click
  the arrow midpoint** to open a vertical strip; the same click
  jump-sets the value to the click-y and starts a drag. Drag slews;
  release commits. Double-click resets to unity. Range −∞ … +18 dB,
  with 0 dB at 75 % of strip travel and the bottom 5 % snapping to
  −∞. The drag is hot-poked through `wm:pokeEdgeGain`
  (`TrackFX_SetParam` direct, no mutate per frame, no undo per frame);
  the bracketing mousedown materialises the CU (if absent) and
  mouseup commits the final value, both via `wv:setEdgeGain` → one
  `wm:mutate` each. (Slice 0: ≤ 2 undo entries per gesture;
  collapsing into one is follow-up.)
- **Right-click** the arrow midpoint opens a per-wire menu — an
  ImGui popup centred on the cursor, populated with chrome
  checkboxes and dismissed by clicking outside. Stage 1 surface:
  **Primary** (the absorption override above). Channel-remap will
  join the same menu later.
- Error overlay renders capacity overflows inline on the
  offending nodes.

**Wire creation gesture:**

Shift is the wire-creation modifier — pressing it clears any current
selection. With shift held, hovering a node highlights the whole body
and pops out a **port band** on whichever of the top or bottom face
the cursor is nearer (left and right faces are never used).

The band carries two fixed zones, left to right: a chevron **handle ▾**
on the left body corner and audio **chips** for additional ports centred
on the body. Port 1 is not a chip — its wire endpoint is the body
itself, so the common path ("just use Main") needs no aim at a tiny
target. The **MIDI keyboard** lives inside the node body at its middle-
right edge, not in the band: it appears under shift hover, fills the body
colour behind itself to overpaint the label, and lights up when the
gesture targets MIDI. Nodes with one audio port and no chips or handle
get no band at all — the body itself catches the default-port hover and
the body-internal keyboard catches MIDI.

For a node with 2..5 audio ports the band shows chips for ports 2..N
directly. Past five, the band shows only the handle plus chips for ports
that already carry a wire ("chip promotion"): unwired ports live
exclusively in the handle's dropdown, so a 32-out plugin starts as a
clean body with one handle and grows chips only where wires actually
land. Chips wrap at five per row, additional rows extending outward from
the body. Nodes with fewer than two audio ports show no handle and no
chips; nodes with no MIDI on the relevant side show no keyboard.

The handle, when present, hovers open a **by-name dropdown** anchored
to it: a vertical list of every audio port including "Main", in port-
index order, names taken from `nv.outs.audio` / `nv.ins.audio`. The
list stays open while the cursor is over either the handle or the list
bounds. Drag from a list row to start a wire anchored at that named
port; on commit the port promotes to a permanent chip on the body's
port band. Wired ports stay chipped until the wire is removed.

Cursor-over-body (or anywhere in the band footprint not on a specific
slot or the handle) highlights audio port 1 as the default; specific
ports including MIDI are selected by hovering the relevant slot. Each
slot draws a background patch underneath so any wire passing behind
doesn't bleed through.

Drag-start fixes the wire kind:

- body or audio chip → audio wire from that port (port 1 by default)
- keyboard slot → MIDI wire
- dropdown list row → audio wire from the named port, with that port
  promoted to a chip on commit

Shift may be released once the drag is underway. As the cursor enters
another node, the target highlights and the feedback uses the same
band affordance, filtered to the draft's type — an audio draft only
shows the target's audio zones (chips + handle), a MIDI draft only the
keyboard. Cycle-forming targets — the source itself and its transitive
ancestors (nodes that already reach the source) — are ineligible and
suppress all of this; the check uses each node's parent list, walked
transitively at drag-start. Drop completes the wire: on the body it
lands on the default slot for the draft type (audio port 1, or the
sole MIDI port); on a specific slot it lands on that port. Release
over empty canvas cancels.

Nodes with no matching ports on the relevant side — the master node's
outputs, an FX with no audio outs and no MIDI, etc. — show no band and
suppress the hover affordance entirely.

**Coordinator wiring:**

- `coord:register('wiring', wp)` in `continuum.lua`, registered
  first so the boot page is wiring (first-registered-becomes-active
  rule).
- The page is project-wide (analogous to arrange); `bind` is a
  no-op, no take/track context to seed.

**Specs (`tests/specs/wiring_*`):**

- `dag_validate_spec.lua` — cycle rejection, port-shape rejection.
- `dag_lower_spec.lua` — wire-level op materialisation; one
  port-to-port conn per wire.
- `dag_srcset_spec.lua` — adversarial compile graphs (diamonds,
  fan-in / fan-out).
- `dag_classes_spec.lua` — equivalence partition correctness.
- `dag_absorption_spec.lua` — auto-rule plus override interactions.
- `dag_capacity_spec.lua` — intra-class wire-count overflow on the
  compile graph.
- `wm_persistence_spec.lua` — round-trip via fake cm.

### Later stages

The remaining stages are framed here; each gets its own detailed
plan when its turn comes.

- **Stage 2 — Compile to REAPER (no merge nodes, no absorption).** The
  differ in `wiringManager` produces an operation list
  (createTrack / deleteTrack / setSend / setFXChain /
  setFXIORouting / setExtState); the applier executes it inside
  one `Undo_BeginBlock`. Intra-class connections → per-FX I/O
  routing. Inter-class connections → sends with channel mapping.
  Wire-level ops are already lowered to Continuum Utility nodes by
  Stage 1's `DAG.lower`, so the differ treats them as ordinary FX
  instances. Spec emphasis: "tiny user edit → tiny diff" — the
  live-recompile premise depends on the differ being surgical, not
  on worked-example coverage of full topologies.

  *Stage 2 — what's landed and what's left:*
  - **Landed (read path):** `DAG.targetPlan` partitions the compile
    graph into hosts (`sourceTrack` / `newTrack` / `master` /
    `scratch`) and emits a per-class entry carrying `fxOrder`,
    `mainSend`, collapsed `sends`. Inert (`srcSet={}`) FX park on
    the scratch track under the sentinel hostKey `'__scratch__'`.
    `wm:snapshot` reads REAPER's current state for wm-owned tracks
    + FX (gated by `node.fxGuid` ∈ user graph); `wm:targetState`
    projects `DAG.targetPlan` into the same shape;
    `wm:diff(target, snap)` is a pure WiringOp[] producer. Bridge
    identity is `fxGuid`, stamped on both user-graph fx nodes
    (`node.fxGuid`) and on edges that carry ops
    (`edge._opFxGuid` → propagated by `DAG.lower` onto the
    synthesised CU bridge's `fxGuid`). CU bridges are ordinary
    `kind='fx'` compile nodes (`fxIdent='JS:Continuum Utility'`)
    carrying a `params={ mode='gain'|'channelRemap', ... }`
    payload — they flow through snapshot/target/diff uniformly
    with user-graph fx nodes (`kind='cu'` is gone; that's what
    lowering buys us). `params` drift triggers `setFXChain` via
    deep-equal in `fxOrderEq`; snapshot never reads params back
    from REAPER, so a target entry with `params` always drives
    reconcile until the applier makes the push idempotent.
  - **Landed (apply path):** `wm:applyOps(ops, label)` walks ops
    inside one `Undo_BeginBlock`; mints fx via `TrackFX_AddByName`
    and `wm:mutate`s minted guids back into the user graph
    (`node.fxGuid` for user-graph fx, `edge._opFxGuid` for CU
    bridges). `wm:enableLive` subscribes `wiringChanged` →
    `targetState` → `snapshot` → `diff` → `applyOps`; same path
    reconciles on `wm:load`.
  - **Left:** sub-channel routing (deferred to Stage 3). Current
    sends are stereo defaults (`I_SRCCHAN=0`, `I_DSTCHAN=0`).
    Channel allocation across the 64-audio / 128-MIDI per-track
    budget is the register-allocation problem we punted to Stage 3.
- **Stage 3a — Primary-input optimisation (absorption). Landed.**
  `ctx:resolveHost(cls)` turns the absorption decision computed in
  Stage 1 into actual targetPlan output: a newTrack class with a
  sole (or primary-elected) audio-parent class folds onto that
  parent's host. Source- and master-hosted classes are exempt
  (their hosts are physical destinations). `targetPlan`, `gainSinks`,
  and `capacityErrors` all key on the resolved host; the differ and
  applier picked it up unchanged. Wire-menu "mark as primary"
  override already shipped in Stage 1. Midi-to-master folded into
  `mainSend` (REAPER's parent send carries both audio and MIDI), a
  pre-existing gap exposed by the absorption tests.

  *Caveat surfaced post-landing:* primary-override absorption with
  multiple audio parents needs 3c's sub-channel routing before it
  produces correct REAPER output — without channel allocation,
  secondary parents' sends fall back to 1/2 at the chain top and
  mix destructively with the absorbed host's intra-chain audio. The
  default-rule single-audio-parent case (srcSet asymmetry via MIDI
  fan-in only) works in isolation. Specs and fixups land with 3c.5.
- **Stage 3b — Slot-boundary send placement. Folded into 3c.**
  `I_SENDMODE` only distinguishes pre-fader / pre-FX / post-FX at
  chain boundaries, not arbitrary mid-chain slots. "Send lands at
  slot N" is actually "send arrives on channel pair K, and slot N's
  input pin map reads from K" — the same per-FX I/O routing that
  intra-class connections use. One allocator (3c) covers both.
- **Stage 3c — Channel allocation.** The register-allocation problem
  punted from Stage 2: each track has 64 stereo audio pairs and 128
  MIDI buses; each wire that crosses or terminates inside a track's
  channel space needs a pair assignment. Post-3c.0 the differ surface
  is in place — sends are keyed on the 4-tuple
  `(to, type, srcChan, dstChan)` and emitted one per wire — but the
  stub allocator assigns `srcChan=dstChan=0` everywhere, so multi-wire
  topologies between the same `(srcTrack, dstTrack)` still collapse to
  a single send at chan 1/2. 3c.1+ replaces the stub. A class has no
  "backbone": intra-class wires, incoming sends, and outgoing sends
  each consume pairs uniformly; the to-master parent send picks one of
  those pairs via `C_MAINSEND_OFFS`.

  *3c.0 — Un-collapse sends; introduce the allocator seam. Landed.*
  `DAG.targetPlan` now emits one `outWires` entry per inter-class
  wire (no collapse) carrying `{to, type, gain?}`. The new module-
  level `DAG.allocate(plan) -> plan'` consumes outWires and emits
  `sends = [{to, type, gain?, srcChan, dstChan}]` keyed uniquely on
  the 4-tuple `(to, type, srcChan, dstChan)`. The stub stamps
  `srcChan=dstChan=0` and first-write-wins on collision; 3c.1 swaps
  the body for the real channel-pair allocator with no surface
  change downstream. `wm:targetState` chains
  `DAG.allocate(cx:targetPlan())`. `wm:snapshot`'s `readSendsClass`
  reads `I_SRCCHAN`/`I_DSTCHAN` on audio sends (MIDI stays 0/0 until
  3c.3). `sendsEq` is set-equality on the 4-tuple with gain as the
  value (drift drives `setSends`). `reconcileSends` keys current and
  wanted dicts on the 4-tuple, drops unpaired current right-to-left,
  creates unpaired wanted (writes `I_SRCCHAN`/`I_DSTCHAN` for audio,
  `I_SRCCHAN=-1` for MIDI, `I_SENDMODE=3` post-FX pre-fader), then
  pushes `D_VOL` drift by 4-tuple re-locate.

  *Known interim regression until 3c.1:* multi-wire same-(from,to)
  still collapses to one send at 0/0 — the stub assigns identical
  channels to every wire so the dedup catches them. Single-wire
  cases are unchanged. Specs: `dag_allocate_spec` covers the stub
  contract; `dag_target_plan_spec` asserts per-wire `outWires`
  (no collapse); `wm_diff_spec`/`wm_snapshot_spec` updated for the
  new send shape.

  *3c.1 — Real allocator body.* Replaces the 3c.0 stub body of
  `DAG.allocate`. Walks each host's fxOrder topologically and
  assigns channel pairs to: each intra-class connection, each
  incoming send, each outgoing send, and the parent send
  (`C_MAINSEND_OFFS`). Annotates the host plan entry with per-FX
  pin maps and the track's required `I_NCHAN` (max pair index × 2).
  Deterministic ordering keyed on intra-class topo order then
  inter-class wire identity: same graph → same channel assignments.
  Pair reuse — free a pair once its last consumer's FX slot passes
  — is an optimisation flag, default off. The 64-pair budget is
  generous; reuse complicates the differ.

  *3c.2 — Audio apply path.* Extends target-state / snapshot / diff
  / apply for `I_NCHAN` and per-FX pin maps
  (`TrackFX_SetPinMappings`). Send channel routing
  (`I_SRCCHAN`/`I_DSTCHAN`) is already wired by 3c.0; 3c.1 just
  flows non-zero values through it. Subsumes the slot-boundary case
  from the original 3b.

  *3c.3 — MIDI buses.* Same allocator pattern as audio with bus
  indices, but JSFX bus-awareness shapes the lowering and applier
  surface. REAPER's per-FX MIDI in/out bus filter is undocumented
  chunk-only state on VST/AU slots and a JSFX opt-in
  (`ext_midi_bus`); see `docs/reaper_midi_routing.md` for the
  encoding. Four user-graph cases, three outcomes:

  - **VST/AU** — allocator assigns an operating bus; applier sets
    the slot's in/out bus via the documented chunk surgery (trailer
    flag byte + wrapper-header mirror). Snapshot reads the same
    bytes.
  - **Non-bus-aware JSFX on bus 0** — REAPER only exposes bus-0
    events to the FX; events on other buses pass through the slot
    untouched. Nothing to do. Allocator prefers bus 0 for these
    wires to maximise this case.
  - **Non-bus-aware JSFX on bus N≠0** — `DAG.lower` brackets the FX
    with pre-park and post-restore CU bridges that rewrite N↔0
    around it, so the FX sees bus 0 internally while external bus
    assignment is preserved. Adds two new CU modes (`bus-park`,
    `bus-restore`).
  - **`ext_midi_bus` JSFX** — refused at design-time, like capacity
    overflow. A bus-aware JSFX can mutate `midi_bus` arbitrarily and
    we can't reason about its routing. First-party CU is bus-aware
    but never user-placed; the refusal applies only at the user-
    graph mutation boundary.

  *3c.3a — JSFX path.* Allocator MIDI bus assignment, send-side
  `I_MIDIFLAGS` src/dst bus bits, CU `bus-park`/`bus-restore` modes,
  lowering brackets for non-bus-aware JSFX on bus N≠0, design-time
  refusal of `ext_midi_bus` JSFX via a static
  `parseJsfxBusAware(ident)` scan of the JSFX desc. JSFX-only chains
  end-to-end.

  *Bracket model (3c.3a.2).* The allocator's per-host post-pass walks
  `fxOrder` and, for each non-bus-aware JSFX consumer (no `busAware`,
  no outgoing midi this slice) whose `fxInputBus[fxId]` is N≠0,
  splices two synthesised CU bridges around it:
  `'bIn:'..fxId` (mode `busPark`, `bus=N`) before, `'bOut:'..fxId`
  (mode `busRestore`, `bus=N`) after. Both modes implement the same
  symmetric N↔0 swap at `@block`; the names label intent only. Bracket
  lowerNodes carry `originNode` (the consumer fx id) + `originSide`
  (`'in'|'out'`) so the applier stamps the minted guid back to
  `node.midiInBracketGuid` / `node.midiOutBracketGuid`. They hang
  under `planEntry.bracketNodes`; `projectEntry` merges that table
  alongside `compileNodes` to resolve fxOrder ids. Identity pair-1
  pin maps keep audio passing through the brackets.

  *Why terminal-only this slice.* For a consumer-producer non-bus-aware
  JSFX, the bracket model requires output bus = input bus = N (so the
  post-restore lifts the FX's bus-0 output back to N where downstream
  expects it). The allocator doesn't yet enforce that equality, so we
  emit brackets only where `hasMidiOut[fxId]` is false — terminal
  consumers, where output bus is moot.

  *Bracket stamp clearance.* `applyOps` walks the pass's `setFXChain`
  ops to build a set of `bracketClassed` consumer-node ids (any node
  named in target's fxOrder via origin `'node'`) and an
  `aliveBracketGuids` set (target's bracket entries + this pass's
  stamps). In the stamp-back mutate, any `bracketClassed` node whose
  `midiInBracketGuid` / `midiOutBracketGuid` isn't in the alive set
  is cleared — closes the lifecycle when the allocator stops emitting
  brackets for a consumer (e.g. its input bus dropped to 0).

  *3c.3a — what's left.* Consumer-producer non-bus-aware JSFX and the
  multi-feeder MIDI case are both subsumed by the Merge-and-split
  slice (3c.4 below): once every MIDI fan-in becomes a merge node,
  every consumer is single-feeder, so the bracket fold becomes
  unconditional and the `hasMidiOut[fxId]` guard simply drops. No
  separate 3c.3a.3.

  *3c.3b — Native FX path.* VST/AU per-FX in/out bus via chunk
  surgery; snapshot reads the same bytes via the same chunk walk.
  Builds on 3c.3a's allocator + send-side. The 3c.3a bracket
  post-pass is already gated by `JS:` prefix, so VST/AU falls through
  it — chunk surgery on each native FX's trailer in/out bus byte
  replaces the bracket strategy for these slots. Snapshot reads
  trailer bytes for every owned non-JS FX in `ownedChain` and
  surfaces `entry.midiBus = { inBus, outBus }` + `entry.midiOut`;
  this supersedes the `appliedMidiOut` cache in
  `docs/wiringManager.md § Routing intent record` — REAPER's chunk is
  ground truth, same as everywhere else in the differ. No brackets
  are minted for native FX.

  *3c.3b.0 — Generalised chunk mutator. Landed.*
  `wm.setFXOutputDisabled` →
  `wm.setFXMidiRouting(chunk, fxIdx, opts, pinChannels)` taking
  `{ inBus?, outBus?, inDisabled?, outDisabled? }`. Single chunk
  walk, read-modify-write per field, every other byte preserved. Bit
  and byte mutations share one `mutateByteInBase64Line` helper.
  Production caller in `reconcileFXChain`'s routing-trailer tail
  ports as `{ outDisabled = not f.midiOut }`. See
  `docs/wiringManager.md § Per-FX MIDI routing`. `wm_fx_routing_spec`
  keeps the legacy disable cases via a thin `setOutDisabled` adapter
  and adds in/out bus, combined-opts, no-op, idempotence, and
  round-trip cases.

  *3c.3b.1 — Allocator surfaces `fxMidiBus`.* Per-host
  `state.fxMidiBus[fxId] = { inBus, outBus }`, populated for non-JS,
  non-bracket fx — `inBus` from the existing `fxInputBus[fxId]`,
  `outBus` lifted from `fxMidiByProducer[fxId].applies` via a
  parallel closure. Surfaces in `allocatedPlan`. `dag_allocate_*`
  specs: single VST consumer on bus N (two senders merging), VST
  producer → VST consumer chain, mixed JS+VST hosts.

  *3c.3b.2 — Snapshot+target+diff+apply.* `wm:snapshot` decodes
  trailer bytes 3/4/5 per owned non-JS FX in `ownedChain` and
  attaches `midiBus={inBus,outBus}` plus `midiOut` to the snapshot
  entry. `projectEntry` stamps `target.midiBus` from
  `planEntry.fxMidiBus`. Diff drives a unified routing write in
  `reconcileFXChain`'s tail pass via `wm.setFXMidiRouting`. The
  `appliedMidiOut` cache (and its `wiringMidiOutApplied` persistence)
  drops — snapshot is ground truth. Specs touch `wm_diff_spec` /
  `wm_snapshot_spec` / `wm_apply_ops_spec`;
  `wm_fx_routing_apply_spec` ports onto the new shape and grows
  bus-assignment integration cases.

  *3c.3b.3 — Design-doc update.* Mirror the landed state into this
  section as each sub-slice lands.

  *3c.4 — Merge and split.* The unified merge/split model (see
  "Merge and split" above). Supersedes the old master-merge rule,
  3c.3a.3, the multi-feeder fallback, and `DAG.lower` itself — one
  slice, no special cases left. Although listed after 3c.3b, the
  lower-kill and allocator restructure here land first: 3c.3b.1/.2
  read the allocator surface they reshape. Steps, each finishing its
  own concern:

  - **CU modes (3c.4.1). Landed.** One `Merge` mode in
    `utility/Continuum Utility.jsfx`: audio is a per-wire gain bank
    (`nPairs` pairs, `out[i]=in[i]×gain{i}`, 1:1; the FX pin matrix does
    the summing), MIDI is an N→1 bus collapse (128-bit input mask, four
    32-bit lanes, → `outBus`). BusPark/BusRestore collapsed to one
    `BusSwap`; modes are now `0=Gain 1=ChannelRemap 2=BusSwap 3=Merge`
    (Gain/ChannelRemap retire with `DAG.lower` in 3c.4.2). The 32-pair
    cap is the JSFX 64-channel ceiling; gained fan-in past it (e.g. a
    large submix) is an allocate-time call in 3c.4.3/.4 — design-time
    error or a CU cascade; unity-gain fan-in of any size stays free
    (pins sum). `config:` dynamic pins are unusable — no
    `TrackFX_SetNamedConfigParm` write key, chunk-only and loses state.
    No EEL harness in-repo, so the JSFX is verified at the DAG/wm layer
    in later steps and needs one in-REAPER compile check (the header
    preprocessor generates the 64 pins + 32 gain sliders).
  - **Kill `DAG.lower`.** Delete the lower phase and the `lowerGraph`
    / `conn` shapes. Point the compile ctx (`inbound`, `srcSet`,
    `classes`, `quotient`, `absorption`) and the targetPlan
    connectivity walks at `userGraph.edges` / `.nodes` directly —
    edges carry the same `from/to/type/primary`, and the removed
    splices were connectivity-inert. Ops (`gain`, `channelMap`) ride
    the connection as metadata. `M.lower` and `ctx:graph()` go; the
    "two graph shapes" and "single-in/single-out CU" invariants
    retire. (Only spec readers of `ctx:graph()`: `dag_srcset_spec`,
    `wm_persistence_spec`.)
  - **Merge nodes at allocate.** Synthesise merge CUs at the
    targetPlan/allocate boundary as host-local `fxOrder` entries (the
    bracket machinery): binary per consuming FX — all-unity ⇒
    matrix-fed, any non-unity gain ⇒ one CU owning every used input
    port, gains as per-input params. MIDI and master fan-in are always
    a CU. The single gained wire is the degenerate one-in/one-out
    case.
  - **`DAG.allocate` unification.** One value type per
    producer-output: split shares the one resource (fx-out and
    outgoing-send stop replicating pairs); a matrix-fed pin lists the
    summed pairs at the input; a CU-fed FX routes producer resources →
    CU inputs and CU outputs → pins/buses by identity. MIDI is always
    single-feeder, so the non-bus-aware bracket fold is unconditional
    and `hasMidiOut` drops; the master CU's output drives
    `mainSendOffs`.
  - **`wm` snapshot/diff/apply.** Merge CUs ride the existing
    CU-bridge path (`fxGuid` identity, `params` deep-equal); confirm
    materialise + guid stamp-back for the master case; new modes diff
    through `params`. The gain-fold mint-then-retract path (`opFxGuid`
    on edges, `gainSinks` un-minting) is gone — the merge stage
    decides once.
  - **Specs.** Retire `dag_lower_spec`; repoint `dag_srcset_spec` /
    `wm_persistence_spec` `ctx:graph()` assertions at the user-graph
    shape; rewrite `wm_apply_ops_spec` gain-CU / `opFxGuid` cases for
    the merge node. Rewrite the MIDI merge/split and master allocate
    cases; delete the multi-feeder fallback and the `outWires` dedup
    band-aid; add audio split-share, multi-output merge, and
    audio/MIDI/master merge coverage.

  *3c.5 — Absorption multi-parent.* With channels in place, 3a's
  primary-override case starts working. Add specs covering the
  multi-audio-parent topology; fix anything the new coverage
  exposes.
- **Stage 3.5 — Opt-in channel-occupancy diagnostic.** A command
  (or toolbar toggle) that scans all MIDI takes on owned source
  tracks, computes each source's channel-occupancy set, propagates
  it through wire `channelMap` ops, and reports edges where two
  MIDI streams share channels at a merge. Diagnostic only —
  surfaces a report, never alters the user graph, never runs unless
  invoked. Cheaper than a permanent live check and respects the
  "user knows their channel layout" default.
- **Stage 6 — Built-in patches.** Continuum Utility grows modes
  (mid-side, bandsplit, pre/post-emphasis); node palette and
  wire-menu surface them. No new compiler work — they're plain FX
  instances of the existing host.

Deferred entirely (per the model sections above): FX containers,
user-composed sub-DAG patches.
