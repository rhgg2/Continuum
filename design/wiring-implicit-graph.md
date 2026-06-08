# wiring: implicit graph (working design)

> Pre-design, exploratory. A direction for the wiring stack, not a
> committed plan. Sibling of `design/archive/wiring.md` and `design/cv.md`
> — read the former first; this leans on its vocabulary (user graph,
> `compile` = `targetTracks`/`allocate`, `snapshot → diff → applyOps`,
> merge CU, normal forms) and states only the delta. Implementation
> reference: `docs/wiringManager.md`.

## The one decision

**REAPER is the only store. The graph is read back from it.**

Today there are *two* persistent representations of the same logical
graph: the `wiringGraph` blob in cm (intent) and the REAPER project
(realisation). The whole reconcile loop exists to keep those two stores
from drifting. The proposal collapses them: REAPER holds the graph, and
`read : REAPER → Graph` recovers it on demand. Mutating the graph means
mutating REAPER routing (gated through a validated draft). The cm blob
retires; the desync bug-class it creates goes with it, and foreign
adoption becomes free — what's in REAPER *is* the graph.

This is the prize of **one store, not one pipeline.** The
`target/snapshot/diff/applyOps` engine survives; `snapshot` and `load`
simply collapse into the same read. (The tempting "beta-reduce
`applyOps(diff(...))`" simplification is explicitly *rejected*: the op
list is the pure-test seam and the gather→compute→mutate split, and a
richer single store needs that auditable plan *more*, not less.)

## The algebra

Two maps: `compile : Graph → REAPER` and `read : REAPER → Graph`. Let
`N = image(compile)` — the **normal forms** the allocator chooses.
`compile` is only a *section* of `read`; `read` is total on a far larger
domain than `N`. Two invariants govern correctness:

1. **`read ∘ compile = id`** (exact, on graphs). What you author is what
   you read back — editor fidelity. This forces `compile` injective, so
   the design question is purely *where `compile` collapses distinct
   graphs* and whether inference or a stored tag separates them.

2. **`compile ∘ read` preserves sound** (off `N`). For a hand-edited,
   non-normal project, reading then recompiling produces an audibly
   identical routing — the retraction that snaps REAPER back onto `N`
   and self-heals manual edits. Its non-identity off `N` *is* the
   self-healing.

No-churn needs nothing extra: from (1), `compile ∘ read ∘ compile =
compile`, so `compile ∘ read` is already the identity *on* `N`. Byte
idempotence is a corollary, not a separate condition.

## What `read` does

`read` operates at the **node/edge level**; the track *partition* is not
part of graph identity:

- **Track splits, merges, and emergent tracks are invisible** — pure
  realisation, discarded like bus numbers. A cross-track send merely
  realises an edge that already exists *between two nodes*; `read`
  recovers node→node edges from channel/pin routing and never asks which
  track a node sits on.
- **One track-level inference:** a track with no inputs is a source.
  Robust precisely because every emergent track (merge or split) *has*
  inputs, so the rule only ever fires on genuine sources.
- **Synthesised FX stripped by ident** (`CU_IDENT`, brackets). A merge
  CU's edges are recovered from its own params (`inMask`/`outBus`) plus
  the surrounding bus assignments — no stored provenance.
- **Component classification** for quarantine (below).

The consequence worth stating plainly: **routing is fully inferred.**
Nothing about the topology needs a stored tag.

## Quarantine — the only irreducible rejects

Two states the DAG model genuinely *cannot express*, quarantined at
**whole-track-set** granularity (the connected/bus-sharing component):

- **Feedback loops** — not a DAG; `compile` needs a topological order.
- **Bus-aware JSFX in a feeder cone** — it scans `midi_bus` itself,
  escaping the allocator, so it corrupts the bus space of the whole
  upstream MIDI cone, not just its own track.

Whole-track-set granularity is load-bearing: no track is ever
half-managed, so `compile`'s full-replace writes stay safe and there is
no surgical-splice case. "Left alone by compile" then falls out of the
**existing diff for free** — make a quarantined component invisible to
*both* target and snapshot, and the diff emits zero ops for it. (snapshot
already hides foreign whole-tracks; re-drive that filter by component
classification.)

A quarantined component **vanishes from the wiring view** and is fixable
only in raw REAPER — so the view must say *why* a region went dark
("feedback loop", "bus-aware FX") rather than silently omit it.

## Capacity is compile's job, not a quarantine

REAPER's 64-channel / 16-bus caps are a *resource*, not an
expressiveness limit. An over-cap partition class is **bisected across
tracks along a min-cut** — cut where the crossing stream traffic is
smallest, carry the boundary on an inter-track send, recurse until each
side fits. Always feasible (in the limit one FX per track); containers
are opaque and bounded, so there is no atomic-overflow residue. Capacity
leaves the quarantine list entirely.

Notes:

- The cut is min-crossing-weight **subject to each side fitting** —
  capacitated bisection, not plain min-cut — but class node counts are
  tiny, so exact search is cheap.
- A split materialises as an emergent `newTrack` + cross-track send: the
  *same shape* as a merge newTrack, which `read` already ignores — modulo
  one read fix the split forced, the pre-FX source tap (§ Status, step 3).
- **Net-new allocator capability.** Distinct from the existing
  *split-at-node* (a semantic boundary): this is *resource*-triggered
  with a *bandwidth* objective. Today the allocator only **reports**
  overflow (`wm:errors`); it must learn to resolve it.
- **Deterministic tie-break** required — min-cut ties picked differently
  across passes would reintroduce churn. The one concrete place
  determinism must be enforced.

## Decoration — view-state only

Since routing is fully inferred, the *only* thing that needs storing is
state `compile` never realises: **node positions** (and names/colours).
This is the entire scope of any metadata facility added to rm — it
carries "where the dot sits," never routing semantics. (Or positions
auto-layout and nothing is decorated at all.)

- **CUs need positions too**, but ride their existing special lifecycle:
  a CU is synthesised and ephemeral (minted/retracted by reconcile as a
  fan-in crosses one feeder), so its position lives and dies with it,
  stored on the instance reconcile owns rather than on a user node.
- **Substrate — one central GUID-keyed store in project ext.** The spike
  (`design/fx-metadata-spike.md`) closed the per-FX-channel question:
  REAPER has no arbitrary `SetNamedConfigParm` ext key, so positions
  cannot live *on* the FX. Instead one store maps node identity →
  `{pos, name, colour}` — FX GUID for fx-nodes, track GUID for
  source/master. The FX GUID is a durable per-node identity (survives
  save/reload), and compile relocates a resident FX by *move*
  (`moveFxAcrossTracks`), never delete+add, so the GUID is stable across
  recompiles and **no `nodeId → guid` ledger is needed** — the GUID is the
  key (in the read era; see § Identity flips with read). Positions needn't be undoable, so project ext (not the scratch
  track) is the home. Position is orthogonal to routing, so it never
  touches `read ∘ compile = id`.

## What retires

- **`wiringGraph` cm blob** — the graph is implicit.
- **`wiringOwnedFx` + `ownedSubsequence` splicing** — whole-track-set
  quarantine means no half-managed track, so the ownership-subset marker
  has no job; full-replace writes are always safe.
- **The scratch track + `pollUndo` + P_EXT mirror — on the decoration
  axis.** The spike confirmed node positions needn't be undoable, so they
  live in plain project ext and the mirror is not needed *for decoration*.
  (It may still carry an undo-coherence job elsewhere — out of scope here.)

## Validation shifts meaning

`validate` stops being a pre-commit gate (in the store model the commit
already happened in REAPER) and becomes a **post-hoc classifier** on
`read`'s domain: managed vs quarantine. Its rule count stays tiny, but
its input domain explodes from "graphs the authoring UI can build" to
"anything REAPER allows" — so the loop and bus-aware checks go from
near-vacuous belt-and-braces to the *actual* boundary of the system.

A mutation still routes through a validated in-memory **draft** (read
REAPER → draft → `validate` → write the delta). You don't escape the
graph *type*, only its *persistence*; UI gestures must not scribble raw
routing past the gate.

## Identity flips with `read`, not before it

A node's id and the rm id of the FX (or track) it realises are **the same
thing only in the read era.** Today they are deliberately decoupled: the
node id is a stable graph key, the rm id mutable. Reconcile can
re-materialise an FX with a *fresh* rm id — on the first compile after a
blob load, or after a manual REAPER delete — and the stable node id means
no incident edge has to be rewritten when it does. The stamp-back
(`origin={kind='node'}`) exists exactly to carry that fresh rm id onto the
node. Pinned by `wm_apply_ops` (bare materialise) and `wm_live`
(manual-delete → re-add).

`read` dissolves the decoupling rather than fighting it. It keys each node
by its rm id natively — there is nothing else to key on — and it removes
the churn that made decoupling necessary: a deleted FX simply isn't read,
and nothing re-materialises against an authoritative blob. So `nodeId ==
rm id` becomes consistent precisely when `read` is authoritative.

The consequence for sequencing: **the identity flip is part of the read
cutover, not a precursor to it.** Flipping ids while the blob still drives
reconcile buys an inconsistent intermediate — an id-less node has no rm id
to be keyed by yet, and re-materialisation would have to re-key the node
and rewrite its edges. `nextId`, the `n`-prefixed ids, and the
`origin={kind='node'}` stamp therefore retire *with* read (steps 1→4),
never ahead of it.

## Plan (rough)

1. **`read : snapshot → graph` by pure routing inference** — source by
   no-inputs, CU/bracket strip by ident, edges from channel/pin routing,
   splits/merges ignored, components classified for quarantine. Positions
   left as a TODO. Read-derived nodes are keyed by their rm id — the
   identity flip begins here (§ Identity flips with read), not as a
   separate precursor step. **Landed — see § Status.**
2. **`read ∘ compile = id` fixture sweep** over existing graphs (incl.
   the merge-CU and capacity-split cases). Any missing routing-decoration
   surfaces as a fibre collapse; two are already known (§ Status), and
   beyond them the prediction is that positions are the only diff. Assert
   via an audio-semantic projection (FX-by-order, stream edges with
   gain/channels, bus resolved away) plus "quarantined bytes unchanged"
   — no rendering. **Landed (invariant-1) — see § Status; the
   capacity-split case waits on step 3.**
3. **Capacity min-cut pass** in the allocator (deterministic tie-break),
   distinct from split-at-node. **Landed — see § Status.**
4. **Retire** the cm blob, the ownership machinery, and — if the
   decoration substrate holds — the scratch/`pollUndo` apparatus. With the
   blob goes the reconcile churn, so `nextId`, the `n`-prefixed ids, and
   the `origin={kind='node'}` stamp retire here too — the identity flip
   completes (§ Identity flips with read).

## Status (2026-06-08)

**Step 1 is landed** (through commit `625f787`): `read : snapshot →
graph` by pure routing inference.

- Audio recovered from channel/pin maps; CU bridges (merge + bracket)
  stripped by ident and collapsed back to node→node edges, gain folded
  onto `edge.ops.gain`.
- Full MIDI bus walk: native `inBus`/`outBus`, merge-CU mask→`outBus`
  union (fan-in), brackets transparent (the wrapped JSFX reads bus 0). An
  fx drives its *output* bus when midi-out is enabled, else clears it.
- Component classification (`DAG.classify`) at whole-track-set
  granularity, master excluded as the shared sink. Both reasons:
  `'busAware'` (snapshot stamps the `ext_midi_bus` flag; read propagates)
  and `'feedback'`.
- Feedback first needed a read-completeness fix: `readGraph`'s Kahn sort
  was *dropping* cyclic tracks. It now surfaces them (leftovers walked +
  seeded), so a loop is darkened-with-cause, not silently missing.

Nodes key by rm id — the identity flip (§ Identity flips with read) has
begun. Positions stay a TODO.

**Step 2 (invariant-1) is landed** (`tests/specs/wm_roundtrip_spec.lua`):
an eight-fixture `read ∘ compile = id` sweep where the expected is *derived
from* each authored graph via a normal form (the rm-id renaming + read's
port conventions), so it can't be hand-fudged. The sweep first surfaced the
two compile non-injectivities below as declared diffs; **both are now fixed**
(see below), so every fixture is an exact bijection and the corpus stands as
regression coverage that no collapse returns. "Routing is fully inferred up to
view-state" now has test evidence, not a bare prediction. Capacity-split is left
for step 3 (no compile image yet); quarantine is off-image (invariant 2, owned
by `wm_read_spec`).

**Step 3 is landed** (`DAG.allocate` capacity loop; `dag_capacity_split_spec` +
the `wm_roundtrip_spec` 65-wide fan fixture). An over-cap class is bisected across
emergent newTracks at its minimum-crossing gap (lowest-slot tie-break), re-allocated
to a fixpoint — `allocateOnce` returns the per-gap live profile the cut reads, so
min-crossing is the allocator's own numbers. Termination is by node count (each cut
shrinks the over-cap `fxOrder`; a lone FX never over-caps), so one-FX-per-track is
the always-feasible floor — capacity needs no quarantine. The split forced two
findings:

- **Overflow is compression-limited.** A master fan-in (`audioSum` tree) or a matrix
  consumer (cascade past 16) is progressively consumed, so `topoIntraTrack` keeps
  peak pressure low and *never* overflows. The shape that does is many producers
  live to chain-end — each leaving via a send to a different track. The fixtures use
  that shape; a sum-tree fan-in would silently not exercise the split.
- **`read` had a pre-FX gap.** A split leaves a source track with both an FX output
  and a raw-source pre-FX send on one pair; `read` tracked only the post-FX tail and
  mis-read the send as `fx→fx`. Fixed by tapping each track's pre-FX input
  (`preTails`) for `preFx`-flagged sends — also fixes the latent
  "source-through-fx + raw send elsewhere" case. The error machinery (`capacityErrors`,
  `wm:errors`, `wv:errors`, the view's error outline) retires: overflow is now always
  resolved, never reported.

**Two `compile` non-injectivities surfaced** in the process — real bugs,
reflected faithfully by read (not read workarounds). **Both are now fixed**
in `compile`:

- **bus-0 phantom** — the first fx on a source track received source MIDI
  on bus 0 even for an audio-only edge (default `inBus=0` trailer), so
  audio-only and audio+midi sources collapsed to the same REAPER state.
  *Fixed:* a symmetric `inDisabled` (mirroring `outDisabled`), threaded
  through `wiringManager`/`routingManager` — an fx with no midi-in edge
  compiles with midi input disabled, so read emits no edge.
- **master-resident midi drop** — a midi-fed fx whose only output is
  master collapsed onto the master track; sources reached it by audio
  parent-send alone, so the `source→fx` midi edge vanished. *Fixed:*
  `deriveMasterSplit` refuses the master cut for a cone that receives
  cross-cone midi (`receivesCrossConeMidi`), evicting the fx to its own
  newTrack where the source midi realises as real sends.

**Step 3.5 (floating islands) is landed** (`wm_roundtrip_spec` + the four island fixtures).
A sourceless connected component (`{A→B}` wired before any source/master) has empty
`srcSet`, so it parks on scratch — but compile emitted `intraConns={}` there and `read`
excluded scratch from its walk, so the island's edges lived *only* in the blob and would
evaporate the moment step 4 retires it. Fixed by realising the island on scratch and
reading it back:

- **compile** — `routeByTrack` now routes a fully scratch-internal (`''`→`''`) conn as a
  scratch `intraConn` (the one `''` conn that carries signal); `assembleTracks` topo-orders
  the scratch `fxOrder` and carries those `intraConns`, so the existing per-track allocator
  produces real pin maps / midi buses for island wiring.
- **read** — walks the scratch track as a *source-less fx bin*, exempt from the no-inputs⇒
  source rule (scratch is known by identity, not inferred), recovering island fx + intra
  edges. No stored discriminator needed.
- **isolation of co-resident islands** falls out of existing machinery, not new code: audio
  via `setPinMaps` full-replace (an unmapped fx → `{ins={},outs={}}`, pins cleared,
  `wiringManager.lua`); midi via `inDisabled`/`outDisabled` stamped from `nodeHasMidiIn`/
  `nodeHasMidiOut` in `projectEntry`, persisted by rm's chunk surgery and decoded by `read`.

This makes `read ∘ compile = id` total over sourceless islands — the prerequisite that lets
step 4 retire the blob without losing a half-built, not-yet-connected patch.

## Open questions / risks

- ~~**Per-FX metadata channel**~~ — *resolved* (`design/fx-metadata-spike.md`):
  no arbitrary FX named-config ext exists, and none is needed — see
  § Decoration.
- **Does the sweep come back clean?** Yes — for the current corpus (§ Status)
  every fixture is now an exact bijection: the two former collapses are fixed
  and positions are the only non-graph residue. The corpus is hand-picked, not
  exhaustive, and the capacity-split case can't be swept until step 3 gives it
  a compile image.
- ~~**Capacity bisection** is genuinely new allocator work and the bulk of
  the risk~~ — *landed* (§ Status, step 3). The surprise was not the cut but
  that overflow is compression-limited, so the test had to force a
  non-cascading shape; and a latent `read` pre-FX gap the split exposed.
- **Quarantine UX** — how a darkened component signals its cause and
  recovery path in the wiring view.
