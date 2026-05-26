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

## MIDI merge

REAPER natively merges MIDI when multiple sends land on the same
track — the FX chain receives one 16-channel stream regardless of
how many producers fed in. For most cases this is exactly what the
user wants and the wiring page does nothing special.

The case worth knowing is **semantic collision on shared
channels**: producer A puts the kick on ch 1, producer B puts the
snare on ch 1, REAPER interleaves both onto ch 1, and the result
is wrong. The model offers no automatic detection — by default the
user is trusted to keep their channel layout coherent.
**Channel-remap on a wire** is the first-class resolution gesture
when collision does happen or is anticipated: remap B's output to
free channels, the collision dissolves, and the merge reduces to
native send-to-bus. An opt-in diagnostic that scans MIDI takes on
owned source tracks for actual channel usage is available later —
see Stage 3.5 of the implementation plan.

### gmem merge — stage 2

For cases where remap isn't the right answer — both producers need
to keep their semantic channels and the user wants programmable
interleave instead of REAPER's blind one — the model offers a
compile-time **gmem merge** escape, opt-in per node. Topology:

- a **slave JSFX** on each non-primary input's track writes
  `(sample-offset, channel, status, data)` tuples for that input's
  MIDI block into a per-merge-node gmem ring at `@block`.
- a **master JSFX** on the host track reads the ring at `@block` and
  emits via `midisend(offset, …)`, interleaved with its own input.
- a **silent audio send** from each slave's track to the master's
  track pins REAPER's processing order — the fake audio dependency
  is the real execution dependency, which REAPER's scheduling layer
  is built to honour.

Cost per merge node: one slave JSFX per non-primary input, one master
JSFX, one silent audio send per slave, one gmem region. Zero extra
tracks. The mechanism is the same pattern sampleManager already uses
for its gmem mailboxes.

### PDC asymmetry

Only relevant under gmem merge. By default REAPER delay-compensates
audio but not MIDI in JSFX, so if A's chain and B's chain have
different upstream latencies, MIDI arrives at the master skewed
relative to audio time.

JSFX exposes `pdc_midi = 1` to opt MIDI into the PDC graph. Set on
the slaves and the master, it should fold MIDI into the same
compensation REAPER applies to audio — slaves see aligned events at
`@block`, master emits with claimable downstream latency. Verify
with a skeleton (deliberate latency stacked upstream of one slave,
measure event timing at the master against ground truth) before
relying on it.

Residual: PDC propagation is a chain property. A third-party FX
upstream of a merge that doesn't honor `pdc_midi` breaks alignment
at that boundary. First-party JSFX set the flag unconditionally;
for foreign plugins the wiring page either warns or refuses the
merge for that subgraph — narrow design-time restriction as the
fallback, not the default.

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

Load-bearing for the next planning round; the doc commits when these
resolve.

- **`pdc_midi` on gmem merge.** Verify mechanics with a skeleton;
  decide warn-vs-restrict for foreign FX that don't honor the flag.
  Spike happens at Stage 4 of the implementation plan below.

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
- Right-click wire menu surfaces wire-level ops (gain spinner,
  channel-remap LUT editor) and "mark as primary" toggle.
- Error overlay renders capacity overflows inline on the
  offending nodes.

**Wire creation gesture:**

Shift is the wire-creation modifier — pressing it clears any current
selection. With shift held, hovering a node highlights the whole body
and pops out a **port band** on whichever of the top or bottom face
the cursor is nearer (left and right faces are never used).

The band carries three fixed zones, left to right: a chevron **handle ▾**
on the left body corner, audio **chips** for additional ports centred on
the body, and the **MIDI keyboard slot** on the right corner. Port 1 is
not a chip — its wire endpoint is the body itself, so the common path
("just use Main") needs no aim at a tiny target.

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

- **Stage 2 — Compile to REAPER (no gmem, no absorption).** The
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
  - **Left:**
    1. **Applier** (`wm:applyOps(ops, label)`). Walks ops inside
       one `Undo_BeginBlock`; for `setFXChain` entries whose
       `fxGuid=nil` it calls `TrackFX_AddByName`, then
       `wm:mutate`s the user graph to stamp the assigned guid
       (into `node.fxGuid` for user-graph fx nodes,
       `edge._opFxGuid` for CU bridges). Op list is full-replace
       per field; applier reconciles incrementally (delete extras,
       add missing, move-by-guid) and pushes wm-owned `params`
       via `TrackFX_SetParam` (resolving slider index by name).
    2. **Live wire-up.** Subscribe to `wiringChanged` →
       `targetState` → `snapshot` → `diff` → `applyOps`. Same path
       reconciles on `wm:load`.
    3. **Sub-channel routing (deferred to Stage 3).** Current
       sends are stereo defaults (`I_SRCCHAN=0`, `I_DSTCHAN=0`).
       Channel allocation across the 64 audio / 128 MIDI per-track
       budget is the register-allocation problem we punted to
       Stage 3.

  *Spec coverage so far:* `dag_target_plan_spec` (12),
  `wm_snapshot_spec` (7), `wm_diff_spec` (14),
  `fake_reaper_sends_spec` (10).
- **Stage 3 — Primary-input optimisation (absorption).** Pure
  addition to the partition step (`DAG.absorption`); the differ
  picks it up unchanged. Wire-menu "mark as primary" override
  already shipped in Stage 1. Slot-boundary send placement
  (sidechain at FX slot N → send pre/post-FX placement) drops out
  of the same machinery.
- **Stage 3.5 — Opt-in channel-occupancy diagnostic.** A command
  (or toolbar toggle) that scans all MIDI takes on owned source
  tracks, computes each source's channel-occupancy set, propagates
  it through wire `channelMap` ops, and reports edges where two
  MIDI streams share channels at a merge. Diagnostic only —
  surfaces a report, never alters the user graph, never runs unless
  invoked. Cheaper than a permanent live check and respects the
  "user knows their channel layout" default.
- **Stage 4 — gmem-merge skeleton + `pdc_midi` spike.** Research
  shape, not feature shape. Build the slave/master JSFX pair plus
  the silent audio send as throwaway JSFX in a test project;
  stack deliberate upstream latency on one slave; measure event
  timing at the master against ground truth; confirm silent-send
  pins processing order under load. Output: decision in this
  doc's Open questions section (warn vs restrict for foreign FX
  without `pdc_midi`).
- **Stage 5 — gmem-merge production path.** Per-merge-node opt-in
  flag in the user graph; lowering emits slave JSFX per non-primary
  input, master JSFX on host, silent audio send per slave, gmem
  region assignment. Reuses the `sampleManager` gmem mailbox idioms.
- **Stage 6 — Built-in patches.** Continuum Utility grows modes
  (mid-side, bandsplit, pre/post-emphasis); node palette and
  wire-menu surface them. No new compiler work — they're plain FX
  instances of the existing host.

Deferred entirely (per the model sections above): FX containers,
user-composed sub-DAG patches.
