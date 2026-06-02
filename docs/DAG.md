# DAG

The pure structural calculus on the user graph — no REAPER, no cm, no
ImGui. Validation, `srcSet`, the equivalence-class partition,
absorption, class-split / master-minimization, capacity checks, and the
`targetTracks` + `allocate` passes that synthesise the merge/bracket CUs
and assign channels. The graph model it implements — the source-set
partition, absorption, merge/split — lives in `docs/wiring.md`; this doc
carries the WHYs of the synthesis and allocation end, the parts the
model section states only in outline.

`M.validate`, `M.ancestors`, `M.descendants` are free-standing pure
predicates; everything derived (srcSet, classes, quotient, absorption,
splits, gainSinks, the plan) hangs off `M.compile`'s lazy-caching `ctx`,
computed once per compile and shared across passes.

## gainSinks — where a gained wire's volume lands

A folded gain on an audio wire lands either on the REAPER send that
carries it (as `mainSendGain`) or on a CU bridge synthesised for
unfoldable cases (cross-track, multi-pair). `ctx:gainSinks` is the
authoritative fold decision: it is computed once and shared by
`targetTracks` (which writes `outWires.gain` / `mainSendGain`) and
`wm:pokeEdgeGain` (which pokes the live value without a full
recompile).

## targetTracks shape — outWires, intraConns, masterFeed semantics

`outWires` are sends that leave a track. Each carries `from`, `to`,
`type`, and optionally `gain` (folded boundary gain) and `srcChan` /
`dstChan` (assigned by `M.allocate`). `intraConns` are FX-to-FX
connections within the same track: same fields but no channel
assignment. `masterFeed` is the single outWire entry that feeds the
master-hosted class; its `from` / `fromPort` identify the last node
before the boundary. When a master-hosted fx exists, its track's plan
output feeds the track's parent send to the master-hosted track; the
allocator pins that output and stamps `mainSendOffs`. Folded boundary
gains carry their value on `outWires.gain` / `mainSendGain`, not a
CU. `M.allocate(targetTracks)` turns `outWires` into sends with
per-tuple channel assignment.

## Split markers — a node as its own source

`node.split` (fx-only; `M.validate` refuses it elsewhere) makes a node
seed `'split:'..id` into its own `srcSet`. The tag propagates forward
like any source contribution, so the node and its downstream cone land
in their own equivalence class — their own REAPER track — and the cut
edge into the marked node becomes a send. A split-tagged class never
absorbs (`ctx:absorption`); otherwise its single-parent cone-top would
fold straight back. This is the per-node sibling of an edge's `primary`
override and what the (deferred) manual split-at-a-node gesture writes;
Stage 3b's master-minimization computes the same markers. A cone that
is the sole contributor to master re-merges into master's class (no
eviction) — audibly identical, and the correct "least eviction"
outcome. The split tag rides class keys (and thus the `wiringClass`
ownership string) as an opaque, stable segment; nothing downstream
parses it.

## Master-minimization — the master class is a dominator cone

`master.audio.ins = 1` means each contributing track reaches the master
through one parent send: one stereo pair. So a master-hosted fx can pull at
most one pair from any single upstream track. An fx fed ≥2 audio input ports by
the *same* track needs two pairs from one parent send — unrepresentable. (Two
ports from two *different* tracks is fine: main on one parent send, sidechain on
another.)

The master class is defined structurally: the **cone of master's largest
dominator whose entry draws ≤1 pair per upstream track**. Master's dominators —
the nodes every source→master path crosses — form a chain, and each shares
master's `srcSet`. A dominator cone is single-entry for external signal (any
source reaching a cone member must cross the entry), so the *only* member that
can pull two pairs from one track is the entry itself — counting its cross-cone
feeders by track decides a cone, read from one marker-free ctx (tracks above the
cut are marker-independent). `masterMinMarkers` (run by `M.compile`, unioned
into `srcSet` via `derivedSplits` alongside persisted `node.split`) walks the
chain largest-cone-first and takes the first capacity-clean cone, falling back
to `{master}` when none qualifies.

A single derived split marks the chosen dominator — and only when its cone is
strictly smaller than master's natural `srcSet` class, i.e. something needs
evicting. That one marker peels everything at once: nodes above the cut, *and*
any off-cone sibling that happens to share master's `srcSet`. The eviction of
off-cone siblings is by design — the master track does linear work, optionally
with single-entry parallel (a diamond from one cone entry), never a re-entrant
merge of disjoint sources. A violator that reaches no sink contributes no
dominator, so the chain stays short and the class collapses toward `{master}`
(`C_m = {master}` is the inward terminus), leaving the violator on its own
`srcSet` track.

## CU bridge invariant — edge ops and folding

An edge's gain/channelMap op rides the edge as metadata. The CU
bridge synthesised for an unfolded gain carries `originEdgeIdx` so the
applier can stamp `opFxGuid` back via `wm:mutate` after
`TrackFX_AddByName` succeeds. `channelMap` never folds onto a send
because sends carry no remap capability. `ctx:gainSinks` is the
authoritative fold decision shared by `targetTracks` and
`wm:pokeEdgeGain`.

## synthNode field roles

Each `synthNode` is a CU bridge synthesised for one of three cases:

- **Wire-level op** (`originEdgeIdx` set): cross-track audio gain or MIDI
  `channelMap` that cannot fold onto a send. The edge index lets the applier
  write `opFxGuid` back after `TrackFX_AddByName`.
- **Bus-route bracket** (`originNode` / `originSide` set): a CU inserted at the
  in- or out-side of a node to route MIDI buses around a non-bus-aware JSFX
  (`from`->0, 0->`to`). See `docs/wiring.md § Merge and split` and the
  *allocate* section below.
- **Per-consumer audio merge** (`originConsumer` / `originHost` / `inputEdges`
  set): one Merge CU per (consumer, track) pair; `inputEdges` maps each input
  pair back to its edge for live-gain pokes.

## per-consumer merge

For each FX, intra-track audio feeders are gathered; for each track, master-bound
feeders are gathered. The two sinks reduce differently. An **FX consumer** is
matrix-fed (REAPER input pins sum): all-unity ⇒ no CU; any non-unity gain ⇒ one
Merge CU spanning every feeder, unity ones at 1.0 and gained ones at their value
(a single gained feeder is the degenerate `nPairs=1` case). A **master consumer**
is a serial parent send — one source channel, no pin-summing — so fan-in ≥2 sums
to a single pair through an `audioSum` Merge CU regardless of gain; fan-in =1
writes direct. Summing at the chain end keeps an in-chain master write from
clobbering a still-live shared producer pair (see split-share). Identity is per
`(consumer, track)` via `node.mergeGuids`;
`inputEdges` maps each pair index back to its originating edge for
`wm:pokeEdgeGain`. When fan-in exceeds 16 (the CU gain-bank width), the merge
cascades into parallel CUs for a matrix consumer, or a sum-tree of `audioSum`
CUs for a matrix-less parent send; CUs past the first carry a `#N` key suffix
so each holds a stable `mergeGuids` slot. See `docs/wiring.md § Merge and split`.

Feeders reduce to fit the summing model. A *unit* groups one consumer's feeders
on one track. FX consumers reduce at the consumer track. Master consumers are
parent sends: an in-class master sums on its own track, and a producer on a
different track pre-sums on the producer track with its output as the send source.

## allocate — deterministic channel assignment

`M.allocate(targetTracks)` is the last DAG pass: it walks each track's `fxOrder`
topologically and assigns a stereo pair (audio) or a bus (MIDI) to every
connection that crosses or terminates in the track's channel space — intra-class
FX-to-FX wires, incoming and outgoing sends, the parent send
(`C_MAINSEND_OFFS`), and the merge/bracket CUs. It annotates each track with
per-FX pin maps and the required `I_NCHAN`.

**Determinism is the contract.** The same user graph must yield the same
assignment on every compile, or the differ would see channel churn on an
unrelated edit and rewrite pin maps that hadn't changed. The walk is ordered
(topological over `fxOrder`, stable iteration) so the assignment is a pure
function of graph structure, not of allocation history.

A class has **no backbone** — intra-class wires and inter-class sends consume
pairs uniformly out of one space. Sends are keyed on the 4-tuple `(to, type,
srcChan, dstChan)`, one per wire, post-FX pre-fader (`I_SENDMODE=3`) so a
from-track fader stays free as the parent-send gain. This subsumes the old
slot-boundary send case: "a send lands at slot N" is just an input-pin map
reading the pair the send arrives on.

**MIDI is the same walk over bus indices**, with one REAPER wrinkle: a
non-bus-aware JSFX on bus N≠0 is wrapped by `BusRoute` bracket CUs that swap
N↔0 around it (the bracket post-pass), while VST/AU slots take chunk surgery on
their trailer in/out bus bytes instead (see `docs/wiringManager.md § Per-FX MIDI
routing`). The allocator surfaces `state.fxMidiBus[fxId] = { inBus, outBus }` for
native FX; a bus-aware JSFX other than the first-party CU is refused at
design-time, since the allocator can't reason about a third party's bus
behaviour.
