# wiring (archived)

> Archived planning doc. The live model now lives in `docs/wiring.md`
> (cross-cut model) and the per-file docs `docs/DAG.md`,
> `docs/wiringManager.md`, `docs/wiringView.md`, `docs/wiringPage.md`.
> Kept for the staged implementation history below.

Cross-cutting reference for the wiring page: how a user-drawn graph
of FX compiles to a REAPER track topology + send graph. The wiring
page is the third rung after tracker and sampler — the layer where
the user composes audio and MIDI processing graphs across a project.

## One graph

The model carries a single graph: the **user graph**, what the user
draws and edits. Its edges are **wires**:

- an **audio wire** is uniformly stereo: always present, always full.
- a **MIDI wire** is 16 channels of data.

Wires carry user-level metadata — gain on audio, "mark as primary" —
and they're the unit on which routing gestures land in the UI.

REAPER tracks are uniformly stereo, so the model carries integer
stereo-port counts on `audio.ins / outs` rather than channel names.
The pre-beta "channels vs ports" distinction — mono adapters,
trailing-odd channels, per-channel splits — dissolved once that
assumption landed; the model is simpler for it.

The partition invariant below runs directly on the user graph. The
only nodes the compiler synthesises are CUs — the **merge** node and
the non-bus-aware **bracket** — minted at the targetPlan/allocate
boundary and hosted within a consumer's equivalence class, so they
never perturb the partition; srcSet and class equivalence are computed
on the graph the user drew. Capacity counts intra-class wires directly
(64 stereo audio / 128 MIDI).

## Sources, sinks, master

Sources are REAPER tracks; each contributes one audio wire (stereo)
and one MIDI wire. The sink is the **master node** — a singleton in
every user graph, `kind='master'`, carrying an explicit
`audio.ins` integer (default `1`, the one stereo bus; scales up if
the REAPER master exposes more hardware-output pairs). The master
has no audio outs and no MIDI; it is the terminal node for any
audio chain the user wants audible. FX with no outgoing audio wire are simply not routed to
speakers — explicit beats implicit. Nodes between sources and master
are FX instances. The compiler also synthesises a dedicated JSFX, the
**Continuum Utility**, for merge and bus-routing (see "Merge and
split").

The wiring page is design-time only. At compile time the user graph
projects onto REAPER tracks, REAPER sends, per-track FX chains,
and per-FX I/O routing. The master's equivalence class does *not*
spawn a new track — it IS the REAPER master. The compile rule is
the partition invariant below.

## The source-set partition

For every node N, define `srcSet(N)` = the set of
source tracks reachable as ancestors of N (transitive closure over
input edges). Two nodes share an equivalence class iff their
source-sets are equal. Each class compiles to **one REAPER track**:

- intra-class wires become **internal port routing** on the
  track (REAPER tracks carry up to 64 stereo audio ports and 128
  MIDI ports, accessed via per-FX I/O routing).
- intra-class topo order becomes the **per-track FX chain order**.
- inter-class wires — wires where `srcSet` changes —
  become **sends to a new track**, and *only* those wires do.

The partition falls out of the graph; it isn't declared. One
consequence worth naming: **it's the minimum REAPER track count**
given the topology. Anything fewer would have to merge distinct
source-sets onto one track, and REAPER's per-track signal summing
makes that unrepresentable.

## Primary-input optimisation

The partition gives the floor on track count. One optimisation lifts
it slightly: a class C₂ with srcSet A can **absorb** into a class
C₁ with srcSet A' (A' ⊊ A) by hosting on C₁'s REAPER track rather
than spawning a new one. Wires from C₁ into C₂ become
intra-track continuation; wires from other parent classes feed
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

One operator lives on the wire in the user graph:

- **gain** (audio wires)

Gain is realised at the targetPlan/allocate boundary — folded onto a
native send's volume where one can host it, otherwise carried into the
consuming FX's merge CU (see "Merge and split"). It is the unit that
makes a routing decision surface as a UI gesture on a wire rather than
as a new node in the user graph.

**Gain folds to native volume when a send can host it.** A gain on a
wire that compiles to a REAPER send (track→track) or the parent/master
send needs no Continuum Utility — the send's own `D_VOL` carries it
(`DAG`'s `gainSinks` names the sink). The fold fires only when that
send is the *sole* audio contributor (one `D_VOL` can't encode two
wires' gains) and only for a gain sitting on the boundary wire itself
(you can't move a gain across an intervening FX without changing the
sound). Intra-class gain and several wires collapsing onto one send
stay Continuum Utility merge nodes. Wiring sends are
post-FX (pre-fader, `I_SENDMODE=3`) so the from-track fader is free to
be the parent-send gain without also scaling the track→track sends.

## Merge and split

A wire carries one signal occupying one resource: a stereo channel
pair (audio) or a MIDI bus (midi). Merge — several producers into one
input — and split — one producer to several consumers — are where
wires share an endpoint. The model treats audio and MIDI
identically except at the single point REAPER forces apart.

**Split is free and uniform.** Every consumer reads the producer's one
resource — one pair, one bus — and nothing is copied. Source-out,
fx-out, and MIDI all behave the same.

**Merge is one node.** Gain and summation collapse into
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
its MIDI-bus merge.

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
compiler synthesises that the user graph lacks, minted at the
targetPlan/allocate boundary — where the partition reveals whether a
gain folds to a send, rides the matrix, or needs a CU — exactly as the
non-bus-aware brackets are (host-local `fxOrder` entries). Wire-level
ops are not spliced into nodes ahead of time; gain rides the wire as
metadata and the merge node realises it. A merge CU is connectivity-
inert (hosted on a consumer, inheriting its class), so the equivalence-
class calculus (`srcSet`, `classes`, `quotient`, `absorption`) runs
directly on the user graph.

**Master is this rule, not a special case.** ≥2 wires from one class to
the master converge through that class's `audioSum` CU-merge, whose
single output feeds the parent send via `C_MAINSEND_OFFS`; one audio
wire needs no CU — the parent send reads the producer's pair directly.
Gain-folding composes: a sole-contributor wire folds onto the parent
send's `D_VOL`, multi-wire cases route gains through the merge params.

The parent send is one pair wide, so a master-hosted FX can't pull more
than one pair from a single upstream class — a cross-boundary sidechain
would need a second. This is a hosting scope, not an error: a pre-hosting
**class-split pass** decorates the offending node so the hosting pass
puts it on its own track, where ordinary multi-pair sends feed it and it
parent-sends one pair up. The split markers are the master *frontier*;
the pass moves them inward toward the master to the shallowest cut where
every upstream class crosses with ≤1 summed pair — the largest still-valid
master class, i.e. least eviction. Markers move, they don't accumulate.
With `master.audio.ins = 1` it always converges, since the master node is
a terminal sum — one pair per contributor by definition. The marker it
lands on a node is exactly what the later **manual split-at-a-node
gesture** writes, so the two share one mechanism and the hosting pass
never special-cases the master.

**Semantic collision stays the user's call.** A CU-merge interleaves
streams but does not separate events that share a MIDI channel: if
producer A puts the kick on ch 1 and B the snare on ch 1, the merged
result is still wrong. The model offers no automatic detection and no
automatic fix — keeping producers on distinct MIDI channels is the
user's responsibility.

## Implementation plan

### Anchor decisions

These four shape every stage and don't recur as questions inside
them.

- **Authority direction: reconcile.** The user graph is the source
  of truth for the topology *we own*. Compile derives the REAPER
  topology, diffs it against the current REAPER project snapshot, and
  applies the minimal operation list. Tracks/FX without our ownership
  mark are untouched.
- **Compile trigger: live on every change.** Each user gesture
  recompiles and applies. The differ has to be good — minimal
  operation lists, no churn on no-op edits. Every apply is wrapped in
  one `Undo_BeginBlock`/`Undo_EndBlock` so a single REAPER undo step
  reverses the gesture, with the gesture name as the undo label.
- **Ownership marker: per-track only.** Compiled tracks carry a
  `P_EXT` key identifying their equivalence class; FX inside an
  owned track are entirely managed by the wiring page.
- **Foreign track adoption: opt-in.** The wiring page starts empty
  on an existing project. The user explicitly imports tracks; the
  importer reads existing FX chains, sends, receives, and channel
  routing into a user-graph fragment, marks the tracks as ours, and
  the live recompile rewires them into canonical form in the same
  gesture. Sources (REAPER tracks) are referenced by GUID;
  deletion of a referenced source surfaces as a design-time error,
  never silent.

### Module layout

- **`DAG.lua`** — pure structural calculus on the user graph. No
  REAPER, no cm, no ImGui. Validation (cycles, port-shape
  consistency), `srcSet`, equivalence-class partition, absorption,
  class-split / master-minimization, capacity-overflow checks, and
  the targetPlan + allocate passes that synthesise merge and bracket
  CUs and assign channels. Trivially unit-testable.
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

Only the user graph persists. The target topology is derived on every
mutation; the differ decides whether to cache it frame-to-frame or
re-derive per gesture.

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
  synthesised `kind='fx'` nodes from the targetPlan merge pass or the
  bracket post-pass (`busRoute`). Snapshot mirrors the live params
  back from the slider so `fxOrderEq` is honest; without it every
  reconcile would spuriously emit `setFXChain`.
- `origin` is stamped on every target-side fxOrder entry by
  `projectEntry` so the applier knows where to write minted guids
  back: `{ kind='node' }` → `node.fxGuid`; `{ kind='bracketIn' |
  'bracketOut' }` → the consumer's `midiInBracketGuid` /
  `midiOutBracketGuid`; `{ kind='merge', consumer, host }` →
  `consumer.mergeGuids[host]`. Snap entries do not carry `origin` and
  `fxOrderEq` ignores it.
- `midiOut` and `midiBus = { inBus, outBus }` are set on both sides
  only for non-JS `kind='node'` entries — target derives `midiOut`
  from the user graph (`nodeHasMidiOut`) and `midiBus` from the
  allocator's `fxMidiBus`; snap decodes both from the FX chunk trailer
  (`readFXMidiRouting`). Mismatch drives `setFXChain`, and
  `reconcileFXChain` step 5 writes only the trailer bytes that differ.
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

One file: `utility/Continuum Utility.jsfx`. Single `mode` parameter
dispatching to per-mode `@sample`/`@block` paths. The compiler-
synthesised modes are `BusRoute` (bracket bus-routing) and `Merge`
(per-wire audio gain bank + N→1 MIDI bus collapse); see "Merge and
split".

No EEL harness lives in-repo, so the JSFX is verified at the DAG/wm
layer; each header change needs one in-REAPER compile check (the
preprocessor generates the pins and gain sliders).

### Stage 1 — Data model + render-only page

End-to-end testable without touching REAPER topology. The page
draws, edits the user graph, persists it, and reports capacity errors
visually (capacity is read from the partition over the user graph). No
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
- `DAG.srcSet(user, nodeId) -> set<trackGuid>` (memoised per
  compile context).
- `DAG.classes(user) -> { [classKey] = { nodeId, ... } }` where
  `classKey = canonical(sortedSrcGuids)`.
- `DAG.quotientGraph(user, classes) -> { [classKey] = { parents,
  children } }`.
- `DAG.absorption(quotient) -> { [classKey] = hostClassKey? }`
  applying the auto rule plus any `primary` overrides.
- `DAG.capacityErrors(user, classes) -> [ { classKey, kind,
  count } ]` for >64 intra-class stereo audio wires or >128
  intra-class MIDI wires.

**`wiringManager` API (Stage 1 surface):**

- `wm:load()` / `wm:save()` — round-trip the user graph via cm
  project tier.
- `wm:graph()` — read access to the user graph (deep copy at
  boundary, per cm convention).
- `wm:mutate(fn)` — call `fn(graph)`, run `DAG.validate`, persist if
  it passes, fire `wiringChanged` hook. All edits go through here so
  the live recompile (Stage 2+) can subscribe to one signal.
- `wm:compile()` — derived target plan from the current user
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
  **Primary** (the absorption override above).
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
- `dag_srcset_spec.lua` — adversarial graphs (diamonds,
  fan-in / fan-out).
- `dag_classes_spec.lua` — equivalence partition correctness.
- `dag_absorption_spec.lua` — auto-rule plus override interactions.
- `dag_capacity_spec.lua` — intra-class wire-count overflow over the
  user graph.
- `wm_persistence_spec.lua` — round-trip via fake cm.

### Later stages

Every stage has landed; the model sections above describe the resulting
design. Each entry below states a stage's contribution and the
implementation surface it left behind.

- **Stage 2 — Compile to REAPER.** `DAG.targetPlan` partitions the user
  graph into hosts (`sourceTrack` / `newTrack` / `master` / `scratch`,
  inert `srcSet={}` FX parking on `'__scratch__'`) and emits a per-class
  entry carrying `fxOrder`, `mainSend`, and `sends`. `wm:snapshot` reads
  REAPER's current state for owned tracks + FX; `wm:targetState` projects
  the plan into the same shape; `wm:diff(target, snap)` is a pure
  `WiringOp[]` producer; `wm:applyOps(ops, label)` executes inside one
  `Undo_BeginBlock`, minting FX via `TrackFX_AddByName` and stamping
  minted guids back into the user graph. `wm:enableLive` wires
  `wiringChanged → targetState → snapshot → diff → applyOps`; `wm:load`
  reconciles the same way. The differ is surgical — a tiny user edit
  yields a tiny diff.
- **Stage 3a — Primary-input optimisation (absorption).**
  `ctx:resolveHost(cls)` turns the absorption decision into targetPlan
  output: a newTrack class with a sole (or primary-elected) audio-parent
  class folds onto that parent's host. Source- and master-hosted classes
  are exempt (their hosts are physical destinations). `targetPlan`,
  `gainSinks`, and `capacityErrors` key on the resolved host. The wire-
  menu "mark as primary" override shipped in Stage 1. MIDI-to-master
  folds into `mainSend` (REAPER's parent send carries both audio and
  MIDI).
- **Stage 3c — Channel allocation.** Each track has 64 stereo audio
  pairs and 128 MIDI buses; every wire crossing or terminating inside a
  track's channel space needs a pair (or bus) assignment. `DAG.allocate`
  walks each host's `fxOrder` topologically and assigns channels to
  intra-class connections, incoming and outgoing sends, the parent send
  (`C_MAINSEND_OFFS`), and the merge/bracket CUs — deterministically, so
  the same graph yields the same assignment. It annotates each host with
  per-FX pin maps and the required `I_NCHAN`. A class has no "backbone":
  intra-class wires and inter-class sends consume pairs uniformly.

  - **Audio.** `wm:targetState` chains `DAG.allocate(ctx:targetPlan())`;
    snapshot reads `I_SRCCHAN`/`I_DSTCHAN`; the applier writes them plus
    `I_NCHAN` and per-FX pin maps (`TrackFX_SetPinMappings`). Sends are
    keyed on the 4-tuple `(to, type, srcChan, dstChan)`, one per wire,
    and are post-FX pre-fader (`I_SENDMODE=3`) so a from-track fader is
    free to be the parent-send gain. This subsumes the old slot-boundary
    send case: "send lands at slot N" is just an input-pin map reading
    the pair the send arrives on.
  - **MIDI.** Same allocator pattern with bus indices. REAPER's per-FX
    in/out bus filter is undocumented chunk-only state on VST/AU slots
    and a JSFX opt-in (`ext_midi_bus`); see `docs/reaper_midi_routing.md`.
    A non-bus-aware JSFX on bus N≠0 is bracketed by `BusRoute` CUs that
    swap N↔0 around it (see "Merge and split"); VST/AU slots take chunk
    surgery on the trailer in/out bus bytes instead, via
    `wm.setFXMidiRouting(chunk, fxIdx, opts, pinChannels)` — snapshot
    reads the same bytes, REAPER's chunk is ground truth. The allocator
    surfaces `state.fxMidiBus[fxId] = { inBus, outBus }` for native FX; a
    bus-aware JSFX other than the first-party CU is refused at design-time.
  - **Merge and split (3c.4).** The unified merge/split model — the
    "Merge and split" section above is the reference. `DAG.lower` and the
    two-graph model were removed here: the equivalence-class calculus
    runs on the user graph directly, wire-level gain rides the wire as
    metadata, and `ctx:targetPlan` synthesises a per-consumer merge CU
    (`node.mergeGuids[hostKey]`) only where a non-unity gain or a MIDI/
    master fan-in needs one. A class-split pass (`node.split` plus derived
    master-minimization markers) seeds a marked node into its own srcSet
    so it lands on its own track — the per-node sibling of the per-wire
    `primary` override, and how the master frontier is kept to ≤1 summed
    pair per contributor. `DAG.allocate` fills each merge CU's audio gain
    bank and, for MIDI, its `inMask`/`outBus`; `wm` pushes those params
    and reads them back in snapshot so reconciles stay idempotent.

- **Stage 3c.5 — Absorption multi-parent.** With channels in place, 3a's
  primary-override case across multiple audio parents is exercised end to
  end (compile → targetPlan → allocate): the primary-elected parent hosts
  the absorbed FX, its primary input reads the host's intra pair, and every
  other audio parent arrives as a channel-allocated send on a distinct
  destination pair — composing with master feed, send-folded gain, and
  multi-hop chains. The allocator needed no change; `dag_absorb_alloc_spec`
  pins the behaviour.
