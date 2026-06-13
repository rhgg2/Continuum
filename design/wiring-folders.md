# wiring: track folders (working design)

> Direction agreed 2026-06-10, implementation not started. Child of
> `design/archive/wiring-implicit-graph.md` — leans on its vocabulary
> (user graph, `compile`/`read`, normal forms `N`, quarantine, family
> of `read ∘ compile = id` invariants, capacity-as-compile's-job) and
> states only the folder delta. Implementation reference:
> `docs/wiringManager.md`.

## The facts (REAPER)

A folder track owns the contiguous child tracks after it (membership
is positional: `I_FOLDERDEPTH` — `1` opens, `0` continues, `<0` closes
N levels). A child's `B_MAINSEND` becomes a **parent send** landing on
the parent track instead of master:

- **Audio**: one contiguous landing block — src pinned to pair 1, dst
  offset via `C_MAINSEND_OFFS`, width via `C_MAINSEND_NCH` (≥1 —
  cannot be zeroed, verified 2026-06-12; the conduit always carries an
  audio stream, there is no midi-only parent send). One stream per
  child, full stop.
- **MIDI**: all buses, identity-mapped (1→1, 2→2, …), **cannot be
  disabled** (verified empirically 2026-06-10). The parent send is
  atomic: take audio + all-bus midi, or take nothing.
- Regular sends *to* a folder track are unrestricted (any pair, any
  bus mapping) and coexist with parent sends — including a child's own
  explicit send to its parent (verified 2026-06-12), which rides
  alongside the parent send. This is the conduit-overflow path.
- There are **no sends to master** — for a foldered track, master is
  reachable only through its ancestor chain.

## What is broken today

1. **`read` hardwires mainSend → master** (`readGraph`,
   `wiringManager.lua` ~810): `mainSend.on` mints an edge to
   `MASTER_KEY` unconditionally. For a folder child the signal lands
   on the parent — read recovers the wrong sink and the parent's bus
   fx vanish from the recovered path.
2. **`compile` has the mirror bug**: an edge→master realises as
   `B_MAINSEND=on`, which on a foldered source feeds the parent.
3. **`rm:addTrack` appends at `CountTracks`** with no depth handling
   (`routingManager.lua` ~751). If the project ends inside an open
   folder, every emergent newTrack (and scratch) silently becomes a
   child — its "master send" retargets and split topology corrupts.
   Bites even projects that never wire a foldered track.

## The one decision

**Folder membership is an input to `compile`, never an output.** The
tree is user-authored structure in the TCP; compile consumes it
read-only, like the set of source tracks. The wiring page gets **no
membership affordance** — full affordance for the *edges* (a
child→parent wire deletes to `B_MAINSEND=off`, redraws to on), none
for the tree, the same split as track order itself. TCP re-folders
bump the project state count, so `wm:syncExternal` rereads and the
edges retarget live.

This works because the parent send has **no expressive power an
explicit send lacks** (audio side: arbitrary pair, gain, post-fader —
all expressible explicitly). Its privilege is organizational — TCP
nesting, folder mute/solo — exactly what belongs to the user. So
compile never needs to mint or revoke child status, and "fx feeding
two folder parents" dissolves: child of whichever parent the user
nested it under, one edge may ride the parent send, the rest are
explicit sends. The dominator-node restriction is rejected on the
same ground — it amputates legal topology (child feeding an outside
bus) to avoid machinery capacity resolution already owns.

Formally compile becomes `compile : Graph × Tree → REAPER`; the
invariants hold relative to the tree — `read(compile(g,t)) = g` for
any `t`, and `compile(read(R), tree(R))` preserves sound *and* tree.
The folder tree joins node positions as pinned realisation context:
not part of graph identity, not chosen by the allocator.

## The conduit rule (compile, local and decision-free)

Per track, given the user tree:

- Child of P, class egress includes an edge→P whose profile matches
  the conduit (see midi condition below) → that edge rides the parent
  send (deterministic pick among parallel edges; tie-break resolved
  below); remaining edges explicit.
- Child of P, no matching edge→P → `B_MAINSEND=off`, all egress
  explicit. Membership and routing decouple — a folder child feeding
  elsewhere is a normal REAPER idiom.
- Not a child → mainSend means master, as today.
- Emergent tracks → always created top-level, always explicit sends.
  They never compete for child status; the linear-order constraint
  never enters the allocator.

**Midi condition**: the parent send is atomic (one audio stream +
all-bus midi). Eligible only when the edge profile matches what it
carries — a child emitting midi at chain-end with an *audio-only*
edge→P cannot use it; compile routes an explicit audio send instead.

**Normal forms include parent sends.** If compile routed everything
explicitly, the self-healing retraction would visit a fresh user
project — children feeding their folder the native way — and rewrite
it to `B_MAINSEND=off` + explicit sends: audibly identical,
organizationally vandalism. The rule above makes adopting a foldered
project a no-op.

**Foldered child→master directly** (bypassing the parent) is
inexpressible natively but compiles via a **relay**: an emergent
top-level track, one explicit send in, mainSend on. That is the split
shape `read` already discards as realisation, so it round-trips to
the direct edge. Net: folders impose zero restrictions on expressible
topology.

> **Realisation note (updated 2026-06-13; busses now landed).** The
> allocator is node-driven — `classes()` (`DAG.lua:263`) partitions
> *nodes*, and a track exists only if some node's class lands on it;
> nothing conjures a node-less track (split markers merely relocate an
> existing node). So the relay cannot simply "appear" — it needs a
> carrier node. An earlier draft reused `wiring-busses-v2.md`'s
> `kind='bus'` node for this; **the landed buss model rules it out on
> two counts**:
> - *Splice.* Sub-2×2 busses no longer fold onto a neighbour — they are
>   spliced out of the working graph (`docs/DAG.md § bus splice`). A 1→1
>   relay buss therefore splices to a single direct child→master edge —
>   which for a foldered child is the very edge that is inexpressible
>   (mainSend lands on the parent). The carrier evaporates.
> - *Transparency.* A bus node is buss-flagged, and buss-flagging
>   deliberately **breaks** the `readGraph` transparency the relay's
>   round-trip depends on (§resolved, zero-fx relay collapse). A relay
>   realised as a buss would read back as an unauthored 1→1 buss, not as
>   the direct child→master edge — failing `read(compile(g)) = g`.
>
> So the relay carrier is **not** a bus node. What stands today: `read`
> already round-trips a *hand-built* relay — an unflagged top-level
> pass-through track (child explicit-send in, mainSend on, zero fx) — to
> the direct edge, via that same transparency (§resolved). The open part
> is compile *minting* one automatically: it needs a transparent-on-read
> carrier node (node-driven track creation without the buss flag), which
> the landed model does not yet provide. Deferred with the compile step;
> until then a hand-built relay is the escape hatch and nothing
> regresses.

## Bus domains

The parent send's all-bus identity pipe is the bus-aware-JSFX hazard
shape — un-gateable traffic escaping the allocator — but **tamer:
known, static, total**. Quarantine is for what the model cannot
express; this is expressible by widening the allocation domain:

**A folder family (parent-send-connected track set — a whole
top-level folder tree) is one bus domain.** Buses are allocated
uniquely across the family, not per-track. The pipe then flips from
leak to conduit: a child→parent-resident-fx midi edge allocates one
bus family-wide — child emits on n, the pipe carries n→n for free,
parent fx listens on n. Every bus not deliberately routed is silent
by construction: family-uniqueness means nothing listens on a leaked
bus. Leaked buses still flow upward through ancestors —
flowing-and-unheard, the state the allocator already engineers
within a single track.

Capacity: 16 buses span the family. Over-pressure uses the existing
valve — evict fx to top-level emergent tracks, where the boundary
crossing is an explicit send with controlled bus mapping, outside
the domain. The one-fx-per-track floor argument carries over.

## Read delta

- Resolve each track's parent from the `I_FOLDERDEPTH` walk;
  `mainSend.on` mints an edge to the **actual parent** (master only
  at top level). Audio landing from `tgtOffset` as today.
- Bus walk extends through the pipe: child output-bus liveness
  propagates identity-mapped into the parent. This is also what makes
  read faithful — a parent fx fed by a child's bus through the pipe
  is a real edge, recovered by modeling the pipe.
- Edges into source nodes become legal (node kinds today:
  `source|fx|master` with sources pure producers — the actual model
  change). Master stays the singleton sink; a folder parent is just a
  track node that consumes.
- Topo order (`nonMasterOrder` / the Kahn walk) must include
  parent-send edges so parents walk after children.

## Folder display (view-only, deferred)

Once `read` models parents correctly, a folder with many children draws
as a **starburst** — N parent-send edges converging on one node rect —
the exact clutter the buss bar was built to dissolve
(`design/archive/wiring-busses.md`). So a qualifying folder parent
projects onto the buss **bar** geometry: children comb the input side,
out-taps the other.

Pure view projection (`wv:busViews()` / nodeView emitting a bar shape
for the folder node) over the existing page render
(`busSegments`/`drawBusBar`). Touches neither graph nor DAG; sits on top
of correct folder `read` — a later cosmetic layer, not part of steps
1–4.

- **The bar is the folder's pair-1-2 input summing point**, uniform
  across fx-presence. The parent send pins every child to pair 1
  (`C_MAINSEND_NCH=2`), so all children land on 1-2; whatever reads 1-2
  taps out — the fx-chain head when the folder hosts fx, the onward
  send(s) when it doesn't. fx render as ordinary downstream nodes fed by
  an out-tap, so a processing folder needs no special case. This is the
  buss model's own "an fx on the summing track reads as a downstream fx
  node fed by the bus" (`docs/wiringManager.md § Busses`) — but where a
  *buss* self-heals it away (busses must be fx-less), a folder keeps it
  (folders are allowed fx).
- **Distinct skin, not a buss.** A buss is user-made, free-placed,
  deletable, fx-less; a folder is TCP-owned, named, carries mute/solo,
  and gets no membership affordance here. Same geometry, different
  render — folder name on the bar, folder colour/glyph, no
  delete-from-wiring — so the two stay tellable-apart. Legibility from
  REAPER's own UI is the standing rule.
- **Gate: multi-child.** One- or two-child folders draw as node rects —
  no starburst to fix, the bar earns nothing. *Open: automatic on child
  count, or a per-folder toggle?*

## Plan (skeleton)

1. **Stopgap — stop being wrong** (small, lands independently):
   - rm reads `I_FOLDERDEPTH`; snapshot carries each track's parent
     guid (or nil).
   - `rm:addTrack` pins new tracks to top level (close any open
     folder across the insertion point).
   - `read` routes a foldered child's mainSend edge to its actual
     parent; components containing parent-send edges **quarantine
     with reason `'folder'`** (machinery exists; view says why).
   - Result: wiring is honest-but-dark in foldered projects instead
     of confidently wrong; emergent tracks stop being corruptible.
2. **Model + read**: edges into track nodes (`DAG.validate`,
   ports/shape); full read delta above; drop the `'folder'`
   quarantine reason. Fixtures: foldered source, parent hosting fx,
   parent-send + explicit-send parallel edges, nested folders,
   child with mainSend off.
3. **Compile**: conduit rule + tie-break; midi condition; relay
   pattern for foldered→master; family bus domains in
   `DAG.allocate`. Roundtrip sweep (`wm_roundtrip_spec`) extended
   over the step-2 fixture set; adoption-no-op test (read a foldered
   project, recompile, assert zero ops).
4. **Capacity over domains**: family bus over-pressure → existing
   eviction; deterministic; fixture forcing >16 buses in one family.

## Open questions / risks

None open — all resolved 2026-06-12 (below). Remaining unknowns are
implementation-time fixture work, not design gaps.

### Resolved (2026-06-12)

- **`C_MAINSEND_NCH=0`** — not possible; audio always rides. Folded
  into §facts; the midi condition stands (no midi-only conduit).
- **Explicit send child→own-parent** — unrestricted; folded into
  §facts. The conduit-overflow path is sound.
- **Zero-fx relay collapse** — confirmed invisible (`readGraph`
  inspection, no probe). `walkTrack` (`wiringManager.lua:947`) mints a
  node only for a track with *no* incoming sends (the source rule) or
  one hosting an fx; incoming sends + empty fx list ⇒ no node, and the
  tail forwards the upstream producer refs. So a relay (child
  explicit-send in, mainSend on, zero fx) round-trips to a direct
  child→master edge. This is the *same* `readGraph` transparency that
  `wiring-busses-v2.md` §persistence deliberately **breaks** for
  buss-flagged tracks — the two sit on opposite sides of one switch (the
  rm-meta track flag), disjoint by flag, so neither disturbs the other.
- **Master-resident midi fx** — dissolved by the existing model, not a
  new constraint. The master node takes **no external midi**: it is
  seeded `midi = { ins = 0, outs = 0 }` (`readGraph`, `DAG.lua:824`),
  and the master send is audio-only for cross-cone midi
  (`receivesCrossConeMidi`, `DAG.lua:884` — "a master-resident node is
  reachable only via audio parent-send; cross-cone midi can't be
  delivered there"). So family-leaked buses flowing up the ancestor
  chain cannot enter master as a graph edge — the family domain stops at
  the top-level parent and never extends to master. A master-resident
  midi fx that wants family midi is the existing cross-cone case:
  `receivesCrossConeMidi` evicts it to its own newTrack, fed by an
  explicit controlled send outside any family domain. Folders inherit
  the allocator's master-midi model unchanged; no global reservation.
- **Tie-break for parallel child→parent edges** — mirror the master-min
  cut (`masterDominators`, `DAG.lua:852`): a primary magnitude, exact
  ties broken by a stable id. Here the eligible set is already narrow —
  only an edge whose profile matches the atomic conduit (child
  chain-end audio on pair 1; all-bus midi iff the child emits midi) can
  ride the parent send. Among the eligible, pick the minimum by the
  stable endpoint key `(toPort, fromPort)` — derived from node ports,
  not allocation order, so it is churn-free across recompiles. The
  remaining child→P edges realise as explicit sends. Genuinely
  identical edges (same from/fromPort/to/toPort/type) are deduped
  upstream; gain is a value, not identity (as `sendKey` already treats
  it), so it never enters the tie-break.
