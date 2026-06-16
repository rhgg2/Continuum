# wiring

Cross-cutting model for the wiring page: how a graph of FX the user
draws maps to a REAPER track topology + send graph, and how it is read
back out again. The wiring page is the third rung after tracker and
sampler — the layer where the user composes audio and MIDI processing
graphs across a project.

This doc carries the *model* the four wiring files share. File-specific
WHYs live with their file: `docs/DAG.md` (the structural calculus,
allocator, and capacity cut), `docs/wiringManager.md` (read, the differ,
the applier, REAPER-as-store), `docs/wiringPage.md` (the canvas +
gestures), `docs/wiringView.md` (the logical projection).

## One graph, one store

The model carries a single **user graph**: nodes and wires the user
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

**There is no separate store for the graph.** REAPER *is* the store: the
track topology, FX chains, sends, and per-FX routing hold the graph, and
`read : REAPER → Graph` recovers it on demand. There is no `wiringGraph`
blob and no parallel bookkeeping to keep in sync — what's in REAPER is
the graph. A mutation reads REAPER into an in-memory draft, validates it,
and writes back the minimal delta; UI gestures never scribble raw routing
past that gate.

## The algebra

Two maps: `compile : Graph → REAPER` (what `wiringManager`'s
target/diff/apply pipeline realises) and `read : REAPER → Graph`. Let
`N = image(compile)` — the **normal forms** the allocator chooses.
`read` is total on a far larger domain than `N`: it accepts anything
REAPER allows, not just graphs the authoring UI can build. Two
invariants govern correctness:

1. **`read ∘ compile = id`** (exact, on graphs). What you author is what
   you read back — editor fidelity. This forces `compile` injective:
   the design question is purely *where `compile` would collapse distinct
   graphs*, and the model is shaped so it never does (up to view-state).

2. **`compile ∘ read` preserves sound** (off `N`). For a hand-edited,
   non-normal project, reading then recompiling produces an audibly
   identical routing — the retraction that snaps REAPER back onto `N`
   and self-heals manual edits. Its non-identity off `N` *is* the
   self-healing; a manual mixer edit is absorbed, not fought.

No-churn falls out for free: from (1), `compile ∘ read ∘ compile =
compile`, so `compile ∘ read` is already the identity *on* `N`. Byte
idempotence on our own output is a corollary, not a separate condition.

The only nodes the compiler synthesises are CUs — the **merge** node and
the non-bus-aware **bracket** — minted at the targetTracks/allocate
boundary and hosted within a consumer's equivalence class, so they never
perturb the partition. `read` strips them back out by ident, recovering
the node→node edges they bridged from their own params plus the
surrounding bus assignments. The partition invariant below runs directly
on the user graph; srcSet and class equivalence are computed on the graph
the user drew.

## What read recovers

`read` operates at the **node/edge level**; the track *partition* is not
part of graph identity:

- **Track splits, merges, and emergent tracks are invisible** — pure
  realisation, discarded like bus numbers. A cross-track send merely
  realises an edge that already exists *between two nodes*; `read`
  recovers node→node edges from channel/pin/bus routing and never asks
  which track a node sits on.
- **One track-level inference: a track with no inputs is a source.**
  Robust precisely because every emergent track (merge, split, bracket
  host) *has* inputs, so the rule only ever fires on genuine sources.
  The scratch track is the one exception — known by identity, walked as a
  source-less FX bin so a not-yet-connected island survives.
- **Synthesised FX stripped by ident** (`CU_IDENT`, brackets), their
  edges reconstructed from params — no stored provenance.

The consequence worth stating plainly: **routing is fully inferred.**
Nothing about the topology needs a stored tag. Identity follows from
this — a node is keyed by the rm id of the FX (or track) it realises,
because there is nothing else to key on; `read` *is* the authority.

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

The wiring page is the design surface; the graph it shows is `read`
back from REAPER, and every edit `compile`s forward onto REAPER tracks,
sends, per-track FX chains, and per-FX I/O routing. The master's
equivalence class does *not* spawn a new track — it IS the REAPER
master. The compile rule is the partition invariant below.

## The source-set partition

For every node N, define `srcSet(N)` = the set of source tracks
reachable as ancestors of N (transitive closure over input edges). Two
nodes share an equivalence class iff their source-sets are equal. Each
class compiles to **one REAPER track** (modulo capacity bisection,
below):

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
unrepresentable. The partition is realisation, not graph identity —
`read` recovers the same nodes and edges regardless of how they were
spread across tracks.

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

MIDI absorbs too, but only where audio summing leaves the host
unconstrained: a class with **no** audio parents and a single
*source-direct* MIDI parent — a wire leaving a source node, not an
intermediate FX — absorbs onto that source's track. So a source feeding
the one instrument that also merges other streams hosts the instrument
rather than spawning a parallel track. The source-direct test is the
derived equivalent of "mark as primary", needing no stored flag because
`node.kind == 'source'` is structural. Two source-direct parents, or
none, leave the consumer on its own track — the same "no tiebreak"
stance as the audio case.

Soundness needs no per-edge-type special-casing: absorption only ever
hosts a class on one of its *parents*, whose srcSet is a strict subset
(A' ⊊ A), so the host's pure signal is always available at the top of
the chain and the extra sources land as sends. That holds whether the
hosting wire is audio or MIDI, which is why the rule extends without a
guard.

The hosting mechanism is REAPER's receive: a track sums its own signal
with incoming sends at the top of its chain — or at a specific FX-slot
boundary via the send's pre/post-FX placement. So "primary passes
through" really means "the track's chain runs around the merge
point", which generalises cleanly: a midstream sidechain on FX slot 5
of A's chain compiles to a send landing at slot 5 of A.

## Capacity — compile's job, not a quarantine

REAPER's 64-channel / 16-bus caps are a *resource*, not an
expressiveness limit. An over-cap partition class is **bisected across
tracks along a min-cut** — cut where the crossing stream traffic is
smallest, carry the boundary on an inter-track send, recurse until each
side fits. Always feasible (in the limit one FX per track), so capacity
never reaches the quarantine list. The cut is min-crossing-weight
*subject to each side fitting*, with a deterministic tie-break so ties
don't reintroduce churn across passes. The emergent split track is the
same shape as a merge newTrack — which `read` already ignores. Mechanism
and the cut objective live in `docs/DAG.md § Capacity`.

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

## Quarantine

Two states the DAG model genuinely *cannot express* are quarantined at
**whole-track-set** granularity (the connected, bus-sharing component):

- **Feedback loops** — not a DAG; `compile` needs a topological order.
- **Bus-aware JSFX in a feeder cone** — it scans `midi_bus` itself,
  escaping the allocator, so it corrupts the bus space of the whole
  upstream MIDI cone, not just its own track.

Whole-track-set granularity is load-bearing: no track is ever
half-managed, so `compile`'s full-replace writes stay safe and there is
no surgical-splice case. "Left alone by compile" then falls out of the
differ for free — a quarantined component is invisible to *both* target
and snapshot, so the diff emits zero ops for it. A quarantined component
**vanishes from the wiring view** and is fixable only in raw REAPER, so
the view must say *why* a region went dark ("feedback loop", "bus-aware
FX") rather than silently omit it.

This is what `validate` became. It is no longer a pre-commit gate (in
the store model the commit already happened in REAPER) but a **post-hoc
classifier** on `read`'s domain: managed vs quarantine. Its rule count
stays tiny, but its input domain is now "anything REAPER allows", so the
loop and bus-aware checks are the actual boundary of the system.

## Decoration — positions only

Because routing is fully inferred, the *only* thing that needs storing
is state `compile` never realises: **node positions** (and names,
colours). That is the entire scope of metadata: where the dot sits,
never routing semantics. The substrate is one GUID-keyed store in
project ext — FX GUID for fx-nodes, track GUID for source/master, the
durable per-node identity that survives save/reload (compile *moves* a
resident FX rather than delete+add, so its GUID is stable across
recompiles). Position is orthogonal to routing, so a pos-only move
changes no routing, skips reconcile entirely, and never touches
`read ∘ compile = id`. A read-derived node with no stored position — an
adopted foreign track, a never-placed source — defaults to `(0,0)` and
stacks at the origin until auto-layout lands. (See
`design/fx-metadata-spike.md` for why positions can't live on the FX.)

## Compile lifecycle

Three facts shape every stage and don't recur as questions inside it:

- **Live on every change.** Each user gesture recompiles and applies.
  The differ has to be good — minimal operation lists, no churn on no-op
  edits. Every apply is wrapped in one `Undo_BeginBlock`/`Undo_EndBlock`
  so a single REAPER undo step reverses the gesture, with the gesture
  name as the undo label.
- **External mutations re-read.** A project-state-count watcher (gated to
  the active wiring page) rereads the graph from routing on *any*
  external mutation — undo/redo or a manual mixer edit — while every wm
  write rebaselines the count so our own edits never trigger it. This is
  invariant 2 in practice: a hand edit is read in, then snapped back onto
  `N` on the next compile.
- **Adoption is free.** The wiring page does not import. A bare project
  track simply *is* a source the moment `read` sees it (no inputs ⇒
  source); there is no opt-in step, no ownership tag, and no parallel
  ledger. The live recompile rewrites adopted routing into canonical
  form in the same breath. Sources are referenced by GUID; deletion of a
  referenced source surfaces as a design-time error, never silent.

## History

This model landed in stages. The committed two-map redesign — **REAPER
as the only store**, the `read`/`compile` algebra, free adoption,
quarantine, and capacity-by-min-cut — is recorded with its per-step
status in `design/archive/wiring-implicit-graph.md`; the earlier staged
compile plan is in `design/archive/wiring.md`.

Three designs it replaced, worth knowing so they aren't reinvented:

- the **two-store reconcile** — a `wiringGraph` cm blob (intent) kept in
  sync with REAPER (realisation) by a per-track `P_EXT` ownership marker
  and an `ownedSubsequence` splice. Collapsed once `read` was shown to
  recover the whole graph from routing: one store, no desync bug-class,
  no ownership bookkeeping.
- the **lowered two-graph model** (`DAG.lower`) — removed once the
  equivalence-class calculus was shown to run directly on the user graph
  with CUs hosted inertly inside a consumer's class.
- the **gmem-ring MIDI merge** — removed once it was clear a single JSFX
  can read every converging MIDI bus at `@block`.
