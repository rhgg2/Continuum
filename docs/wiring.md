# wiring

Cross-cutting model for the wiring page: how a user-drawn graph of FX
compiles to a REAPER track topology + send graph. The wiring page is
the third rung after tracker and sampler — the layer where the user
composes audio and MIDI processing graphs across a project.

This doc carries the *model* the four wiring files share. File-specific
WHYs live with their file: `docs/DAG.md` (the structural calculus +
allocator), `docs/wiringManager.md` (reconcile, persistence, the
applier), `docs/wiringPage.md` (the canvas + gestures), `docs/wiringView.md`
(the logical projection).

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
the non-bus-aware **bracket** — minted at the targetTracks/allocate
boundary and hosted within a consumer's equivalence class, so they
never perturb the partition; srcSet and class equivalence are computed
on the graph the user drew. Capacity counts intra-class wires directly
(64 stereo audio / 128 MIDI).

## Sources, sinks, master

Sources are REAPER tracks; each contributes one audio wire (stereo)
and one MIDI wire. The sink is the **master node** — a singleton in
every user graph, `kind='master'`, carrying an explicit `audio.ins`
integer (default `1`, the one stereo bus; scales up if the REAPER
master exposes more hardware-output pairs). The master has no audio
outs and no MIDI; it is the terminal node for any audio chain the user
wants audible. FX with no outgoing audio wire are simply not routed to
speakers — explicit beats implicit. Nodes between sources and master
are FX instances.

The wiring page is design-time only. At compile time the user graph
projects onto REAPER tracks, REAPER sends, per-track FX chains, and
per-FX I/O routing. The master's equivalence class does *not* spawn a
new track — it IS the REAPER master. The compile rule is the partition
invariant below.

## The source-set partition

For every node N, define `srcSet(N)` = the set of source tracks
reachable as ancestors of N (transitive closure over input edges). Two
nodes share an equivalence class iff their source-sets are equal. Each
class compiles to **one REAPER track**:

- intra-class wires become **internal port routing** on the track
  (REAPER tracks carry up to 64 stereo audio ports and 128 MIDI ports,
  accessed via per-FX I/O routing).
- intra-class topo order becomes the **per-track FX chain order**.
- inter-class wires — wires where `srcSet` changes — become **sends to
  a new track**, and *only* those wires do.

The partition falls out of the graph; it isn't declared. One
consequence worth naming: **it's the minimum REAPER track count** given
the topology. Anything fewer would have to merge distinct source-sets
onto one track, and REAPER's per-track signal summing makes that
unrepresentable.

## Absorption — the primary-input optimisation

The partition gives the floor on track count. One optimisation lifts it
slightly: a class C₂ with srcSet A can **absorb** into a class C₁ with
srcSet A' (A' ⊊ A) by hosting on C₁'s REAPER track rather than spawning
a new one. Wires from C₁ into C₂ become intra-track continuation; wires
from other parent classes feed in as sends.

The default: auto-absorb iff C₂ has exactly one audio-parent class in
the class-quotient graph. No tiebreak, no heuristic. Override is
per-wire — right-click "mark as primary" forces absorption along that
wire's parent class. Discoverability lives in the wire menu; no
preemptive graph marker is needed.

The hosting mechanism is REAPER's receive: a track sums its own signal
with incoming sends at the top of its chain — or at a specific FX-slot
boundary via the send's pre/post-FX placement. So "primary passes
through" really means "the track's chain runs around the merge
point", which generalises cleanly: a midstream sidechain on FX slot 5
of A's chain compiles to a send landing at slot 5 of A.

## Wire-level gain

One operator lives on the wire in the user graph: **gain** (audio
wires). It is the unit that makes a routing decision surface as a UI
gesture on a wire rather than as a new node in the user graph.

Gain is realised at the targetTracks/allocate boundary — placed on a
native send's volume where one can host it, otherwise carried into the
consuming FX's merge CU (see Merge and split).

**Gain lives on native volume when a send can host it.** A gain on a
wire that compiles to a REAPER send (track→track) or the parent/master
send needs no Continuum Utility — the send's own `D_VOL` carries it
(`DAG`'s `gainHost` names the host). This applies only when that
send is the *sole* audio contributor (one `D_VOL` can't encode two
wires' gains) and only for a gain sitting on the boundary wire itself
(you can't move a gain across an intervening FX without changing the
sound). Intra-class gain and several wires collapsing onto one send
stay merge CUs. Wiring sends are post-FX (pre-fader, `I_SENDMODE=3`) so
the from-track fader is free to be the parent-send gain without also
scaling the track→track sends.

## Merge and split

A wire carries one signal occupying one resource: a stereo channel pair
(audio) or a MIDI bus (midi). Merge — several producers into one input
— and split — one producer to several consumers — are where wires share
an endpoint. The model treats audio and MIDI identically except at the
single point REAPER forces apart.

**Split is free and uniform.** Every consumer reads the producer's one
resource — one pair, one bus — and nothing is copied. Source-out,
fx-out, and MIDI all behave the same.

**Merge is one node.** Gain and summation collapse into one **Continuum
Utility merge node** bound to a consuming FX's input side — a single
`Merge` mode carrying both the FX's audio-pin gains and its MIDI-bus
merge:

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
both audio and MIDI, so one node carries both an FX's audio-pin gains
and its MIDI-bus merge.

**The audio unity fast-path.** A REAPER FX audio input pin sums every
pair routed to it for free *and selectively* — `P→A`, `P+Q→B` coexist
because pins pick subsets. So an FX whose input pins are all unity-gain
(or whose gain lands on a send's `D_VOL`) needs **no CU**: the pin
matrix is the summing point. The choice is **binary per consuming FX** —
all-unity ⇒ matrix-fed (free, selective); any non-unity gain ⇒ one merge
CU carrying *every* feeder wire of that FX as a 1:1 gain (unity wires at
1.0). The pins still sum, but every feeder now arrives through the CU,
so no pin mixes a raw producer pair with a gained one — selectivity
stays simple, at the cost of one CU per gained-input FX rather than one
per distinct subset (the right pre-beta trade).

**No consumer-side matrix ⇒ always a CU.** MIDI (REAPER's per-FX filter
exposes one input bus) and the master parent send (one contiguous
channel range) have no free path: any fan-in there is a merge CU. The
CU is an ordinary `ext_midi_bus` JSFX — it reads the converging buses at
`@block` and emits one stream; cross-track producers reach it as sends
arriving on distinct buses on the track, which REAPER delivers to
the same `@block`, so no gmem ring and no processing-order hack. (This
is why the earlier gmem-merge design is gone: a JSFX can read every MIDI
bus.)

**One consequence drives the rest of the compiler:** because every MIDI
fan-in is a merge node with a single output bus, **every MIDI consumer
has exactly one input stream.** Bus allocation, the non-bus-aware
bracket pass, and the differ never meet a multi-input MIDI node.

**There is no lowered graph.** The merge node is the only node the
compiler synthesises that the user graph lacks, minted at the
targetTracks/allocate boundary — where the partition reveals whether a
gain lands on a send, rides the matrix, or needs a CU — exactly as the
non-bus-aware brackets are (track-local `fxOrder` entries). Wire-level
ops are not spliced into nodes ahead of time; gain rides the wire as
metadata and the merge node realises it. A merge CU is
connectivity-inert (hosted on a consumer, inheriting its class), so the
equivalence-class calculus (`srcSet`, `classes`, `quotient`,
`absorption`) runs directly on the user graph.

**Master is this rule, not a special case.** ≥2 wires from one class to
the master converge through that class's `audioSum` CU-merge, whose
single output feeds the parent send via `C_MAINSEND_OFFS`; one audio
wire needs no CU — the parent send reads the producer's pair directly.
Gain-hosting composes: a sole-contributor wire lands on the parent
send's `D_VOL`, multi-wire cases route gains through the merge params.

The parent send is one pair wide, so a master-hosted FX can't pull more
than one pair from a single upstream class — a cross-boundary sidechain
would need a second. This is a hosting scope, not an error: a
pre-hosting **class-split pass** decorates the offending node so the
hosting pass puts it on its own track, where ordinary multi-pair sends
feed it and it parent-sends one pair up. The master class is the cone of
master's largest dominator whose entry crosses with ≤1 summed pair per
upstream class — the largest still-valid master class, i.e. least
eviction. A single marker on that dominator peels everything above it
(and any off-cone sibling) at once. With `master.audio.ins = 1` a clean
cone always exists, since the master node is a terminal sum — one pair
per contributor by definition. The marker it lands on a node is exactly
what the later **manual split-at-a-node gesture** writes, so the two
share one mechanism and the hosting pass never special-cases the master.
(See `docs/DAG.md § Master-minimization` for the dominator-cone rule.)

**Semantic collision stays the user's call.** A CU-merge interleaves
streams but does not separate events that share a MIDI channel: if
producer A puts the kick on ch 1 and B the snare on ch 1, the merged
result is still wrong. The model offers no automatic detection and no
automatic fix — keeping producers on distinct MIDI channels is the
user's responsibility.

## The compile model — four anchor decisions

These shape every stage of the compiler and don't recur as questions
inside it.

- **Authority direction: reconcile.** The user graph is the source of
  truth for the topology *we own*. Compile derives the REAPER topology,
  diffs it against the current REAPER project snapshot, and applies the
  minimal operation list. Tracks/FX without our ownership mark are
  untouched. (`wiringManager` owns the snapshot/target/diff/apply
  pipeline — see `docs/wiringManager.md`.)
- **Compile trigger: live on every change.** Each user gesture
  recompiles and applies. The differ has to be good — minimal operation
  lists, no churn on no-op edits. Every apply is wrapped in one
  `Undo_BeginBlock`/`Undo_EndBlock` so a single REAPER undo step
  reverses the gesture, with the gesture name as the undo label.
- **Ownership marker: per-track only.** Compiled tracks carry a `P_EXT`
  key (`wiringClass`, the class key) identifying their equivalence
  class; FX inside an owned track are entirely managed by the wiring
  page. Reconcile uses this to identify "ours" without parallel
  bookkeeping.
- **Foreign track adoption: opt-in.** The wiring page starts empty on an
  existing project. The user explicitly imports tracks; the importer
  reads existing FX chains, sends, receives, and channel routing into a
  user-graph fragment, marks the tracks as ours, and the live recompile
  rewires them into canonical form in the same gesture. Sources are
  referenced by GUID; deletion of a referenced source surfaces as a
  design-time error, never silent.

## History

This model landed in stages; the staged implementation plan and the
per-stage notes are archived at `design/archive/wiring.md`. Two earlier
designs it replaced, worth knowing so they aren't reinvented: a
**lowered two-graph model** (`DAG.lower`) — removed once the
equivalence-class calculus was shown to run directly on the user graph
with CUs hosted inertly inside a consumer's class — and a **gmem-ring
MIDI merge** — removed once it was clear a single JSFX can read every
converging MIDI bus at `@block`.
