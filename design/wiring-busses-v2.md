# wiring busses v2 — the buss as a free-standing routing object

> Design note + implementation plan. **Supersedes `design/wiring-busses.md`**,
> which shipped the v1 *port-decoration* buss (a rail that re-draws one port's
> existing edges). v2 inverts the model: a buss becomes a first-class object you
> draw, move, delete, and wire **to and from** — every input is bussed to every
> output. The v1 rail *rendering* and its port-claim persistence survive as the
> folded-case machinery; the v1 *creation/overlay* and the "decoration only,
> never a routing object" stance are retired. Read `design/wiring-busses.md` for
> the history and the starburst problem that motivated busses at all.

## The inversion in one paragraph

v1's buss was a **rendering of a port** — pure decoration over edges the graph
already had; "never a surface you edit instead of the graph." v2's buss is a
**routing object that generates edges**: you place it, wire N inputs and M
outputs to it, and it means *every input → every output*, each crossing scaled
by the product of its two gains. The signal from input *i* reaching output *j*
is `inGain[i] × outGain[j]` — the outer product of the gained-input column and
the gained-output row. That product is rank-1, which is exactly what a single
summing track produces, and that equivalence is the whole implementation lever.

## The governing principle: REAPER must stay legible

The buss must not make the REAPER routing incomprehensible from REAPER's own
UI. That single rule decides every realization choice below, and it cuts the
same way as frugality:

- A **fan** (≤1 wire on one side) is already legible as plain routing — 30
  sends straight into master, or one source fanning out. Realize it with
  **direct sends**; no track.
- A **matrix** (≥2 in *and* ≥2 out) as direct sends would be an N×M thicket —
  illegible. Realize it as **one real, named summing track** (N+M sends). That
  is what an engineer would build by hand, and it reads cleanly in the mixer.

So: **one object, realization chosen by degree.** Rejected alternatives and why
they lose to a real track for the matrix case: N×M direct sends (illegible);
a sentinel-fx carrier on a host track (invisible/confusing in REAPER); the
audio is identical in all three, so legibility is the only tiebreak and the real
track wins.

## Realization by degree

| buss shape | realization | REAPER carrier | persistence |
|---|---|---|---|
| **fan-in** (N→1) | N direct sends into the sink; buss folds onto the sink's track | none of its own | port-anchored record (reuses v1 claim) |
| **fan-out** (1→N) | N direct sends from the source; buss folds onto the source's track | none of its own | port-anchored record |
| **matrix** (≥2 × ≥2) | one fx-less summing track; inputs send in, outputs send out | a real flagged track | the track + pos/orient decoration |
| **degenerate** (1→1, 0→n, n→0, 0→0) | pass-through / partial; folds or sits unwired | none | record only (pos/orient) |

Folding is the **existing** DAG mechanism, used literally:

- **fan-in**: the buss node has N audio parents, so it does not absorb upward;
  instead mark the **lone out-edge `primary`** so the sink absorbs the buss
  (the sink's sole/primary audio parent). The buss lands on the sink's track;
  the N inputs become sends into it. No new allocator code.
- **fan-out**: the buss node has one audio parent, so single-parent absorption
  folds it onto that source's track for free; the M outputs become sends.

The matrix case is the one that cannot fold: ≥2 parents *and* ≥2 children, so
the buss class stays its own track. That track is **fx-less** — and that is the
one genuinely new allocator surface (see Risks).

## The model

A buss is a node kind plus an authored decoration record.

```
userNode = { kind='bus', pos={x,y}, orient='V'|'H' }          -- id = a stable buss id
edge     = { type='audio', from, to, fromPort, toPort, ops?={gain?}, primary? }
```

- **In-wires** are edges with `to = bussId`; **out-wires** are `from = bussId`.
  Per-wire gain is the existing `edge.ops.gain`. The outer product is never
  computed: the summing track (real, or the absorbed host) sums the gained
  inputs and the out-sends scale by the output gains — `inGain[i] × outGain[j]`
  emerges physically. **Zero matrix code.**
- **MIDI**: out of scope for v1 (audio-only, as v1 was). A buss summing MIDI is
  deferred.
- **Orientation**: `'V'` / `'H'` for v1 (bar vertical or horizontal; taps
  perpendicular). Arbitrary angle deferred — the tap math generalizes trivially.

### Invariants to add

- A `kind='bus'` class **never absorbs and is never absorbed** *as a matrix*;
  the fold cases above are the only way a buss shares a track, and they are
  driven by ordinary absorption/`primary` on its edges, not by the buss class
  absorbing wholesale. (Mirror the existing "a split-tagged class never
  absorbs.")
- A buss node has **no source, no fx, no `trackId` until materialized**. In the
  matrix case its `trackId` (track GUID) is stamped after the track is minted,
  exactly as `fxId` is stamped onto a materialized fx.

## Persistence & round-trip — the crux

`readGraph` reconstructs nodes from **physical REAPER carriers** (source track,
fx GUID, master singleton) and edges by **tracing producer-refs through fx
chains and sends** (`wiringManager.lua` `readGraph`). It stores no topology.
Absorption round-trips for free precisely because an absorbed fx keeps its GUID
on the shared track — the carrier survives the merge. A buss has no such carrier
in the folded case, so the two realizations persist differently:

**Matrix buss — carrier present, mostly free.** It is a real track. Flag the
track as a buss in the rm meta store (keyed by GUID, like `pos`). Two read
additions: (1) a bare summing track is *transparent* today (a non-master track
with incoming sends and no fx mints no node — it just forwards its sum, like a
merge-CU track; verified in `walkTrack`, `wiringManager.lua:947` — incoming
sends + empty fx list ⇒ no node, tail forwards producer refs, the *same* rule
`wiring-folders.md`'s zero-fx relay deliberately leans on to stay invisible); a
buss-flagged track must instead **mint a `kind='bus'`
node**, emit its incoming producer→bus edges, and forward its summed tail as the
bus output. (2) `pos`/`orient` come back via `stampDecoration`. Membership is
*derived* from the track's sends — no authored edge list needed.

**Folded buss — no carrier, so it is anchored to its single side.** A fan-in
folds onto its sink: anchor the record to `(sinkNode, port, dir='in')`. A
fan-out anchors to `(sourceNode, port, dir='out')`. This is exactly v1's
port-claim (`busClaims`): the port's incident edges *are* the buss's wires, so
membership stays **derived** (claim all edges on the bound port), and v1's
`stampDecoration` round-trip works unchanged — extended only to carry the
buss's own `pos`/`orient`/id and to **re-inject a `kind='bus'` node** between
the claimed edges and the bound node, rather than merely re-rendering the star
as a rail.

So in **both** realizations membership is derived (track sends, or port claim) —
no authored edge list, no heuristic endpoint-matching, no mis-claim risk. The
buss record is small: `{ id, pos, orient, anchor?={node,port,dir} }`. `anchor`
is set when folded, nil when matrix (the track is the anchor).

### The migration at the boundary

Crossing the fan↔matrix threshold changes both carrier and persisted home, and
is the one structurally new behaviour:

- **fan → matrix** (wire the 2nd output onto a fan-in, or 2nd input onto a
  fan-out): the port anchor no longer identifies the buss (two outputs now). On
  the next compile the buss class stops folding and **materializes a real
  track**; the record drops `anchor` and gains a `trackId`.
- **matrix → fan** (remove back below threshold): the track is **demolished**
  and the buss re-folds onto its surviving single side; the record regains an
  `anchor`, loses `trackId`.

The allocator already recompiles the whole graph on any edit, so the migration
is not a special diffing path — it is just the degree-test choosing a different
realization for the buss class this compile. The only deliberate work is the
record bookkeeping (anchor ⇄ trackId) on the mutate that crosses the threshold.

### Gain factoring on fold — a known wart

A folded fan-in compiles `inGain[i] × outGain` onto each direct send; REAPER
stores only the product, so a naive read cannot recover the lone output gain
separately — it would collapse into the input gains (audibly identical, but the
fader attribution shifts on reload). Fix: store the **lone-side gain** in the
buss record and divide it back out on read. One scalar; handle it deliberately.

## Geometry & render

The render is **identical in both realizations** — a bar with input taps combing
one long side, output taps the other, arrowheads for direction. So the geometry
work is decoupled from the realization decision.

- Reuse the `SIDE_VEC` normal/along-axis math and the tap/trunk construction
  from v1's `busSegments` / `drawBusPass`. v1 drew the bar at a fixed offset
  from the *anchor node*; v2 draws it at the **buss's own `pos`**, with taps to
  each wired far-node and a trunk per side.
- `orient='V'` → vertical bar, horizontal taps; `'H'` → the transpose. Inputs
  on one side of the bar, outputs on the other (direction also disambiguated by
  arrowheads, so a buss with both is unambiguous).
- The buss node draws **as the bar**, not a node box. Hit-testing for
  move/delete/wire-drop reuses the existing node-drag, `deleteNode`, and
  wire-draft machinery — a buss is a node you cannot dive into.

## Creation & editing gesture

- **Create**: a synthetic top entry **"Buss"** in the FX picker
  (`renderFxPicker`), since canvas-RMB already is the "add a node here" path.
  Selecting it calls a new `wm:addBusNode(pos)` that mints a placed, unwired
  buss (record only; no track until it becomes a matrix) instead of adding an
  fx.
- **Wire**: ordinary wire-draft to/from the bar. Dropping a wire onto the bar
  reuses (a generalization of) v1's `busBarHit`; the bar is a fat drop target.
- **Move**: ordinary node drag writes `pos` to the record.
- **Delete**: ordinary `deleteNode` removes the buss node, its incident edges,
  and the record (and demolishes its track if matrix).
- **Per-wire affordances** (gain fader, RMB-delete) live on each **tap** as
  today — each tap is still its own edge.

## Implementation plan (ordered; resolve risk #1 first)

1. **Allocator: fx-less summing track (the primary risk).** Confirm in
   `DAG.lua` whether `targetTracks`/`allocateOnce` can emit a real `newTrack`
   for a non-master class with an empty `fxOrder`, or whether every emitted
   track currently assumes ≥1 fx (the fx-less *master* is special-cased as
   *implicit* — no entry — which is the opposite of what a buss needs). If the
   path is missing, add it: a `kind='bus'` class emits a track with empty
   `fxOrder`, `mainSend` only when an explicit edge to master exists, summing
   its incoming sends to its outgoing sends. Add the non-absorption invariant.
   *This gates everything; spike it before building UI.*

   **Verified 2026-06-12 — risk is low, the path already exists.**
   `assembleTracks` (`DAG.lua:769`) emits a spec for *any* non-master class
   unconditionally: the guard `trackKind ~= 'master' or #chain > 0` suppresses
   only the fx-less *master*. A bare `sourceTrack` (source node, no fx) already
   ships with an empty `fxOrder`, so fx-less *non-master* emission is not new.
   The allocator is **node-driven** (`classes()`, `DAG.lua:263`, partitions
   `nodes`), so the `kind='bus'` node is what conjures the track — which v2
   supplies. Two small real additions remain: (a) exclude `kind='bus'` from
   `isChainMember` (`DAG.lua:484`, today only source/master) so the bus node
   doesn't fall into `fxOrder`; (b) the non-absorption invariant is the
   *existing* split-class one verbatim — `splitClasses` (`DAG.lua:276`) classes
   "never absorb — the split exists to give them their own track"; a matrix-bus
   class wants identical treatment. mainSend/outWire routing already flows
   through `routeByTrack`. (Same node-driven fact, mirror conclusion for
   `wiring-folders.md`'s relay — which has *no* node and so needs this one.)

2. **Model + validate.** Add `kind='bus'` to the `userNode` shape and
   `M.validate` (no source/fx/trackId required; trackId stamped on
   materialization). Decide the buss id scheme (stable synthetic id; becomes the
   track GUID once matrix-materialized, or stays synthetic with trackId as a
   separate field — pick during the spike).

3. **Manager: buss record store + mutations.** A project-ext buss store keyed by
   buss id holding `{ id, pos, orient, anchor?, loneGain? }`. New API:
   `wm:addBusNode(pos)`, `wm:moveBus` (or fold into `moveNodes`),
   `wm:deleteNode` extended to clear the record. Maintain `anchor`⇄`trackId`
   bookkeeping on the mutate that crosses the fan↔matrix threshold.

4. **Read: mint buss nodes.** (a) A buss-flagged track mints a `kind='bus'`
   node and emits its in/out edges instead of being transparent. (b) Folded
   busses re-inject from `(node,port,dir)` anchor over the v1 port-claim,
   carrying `pos`/`orient` and dividing `loneGain` back out. Extend
   `stampDecoration` for the record fields.

5. **View projection.** `nodeView` gains the buss kind (orient, the bar
   geometry inputs); `wireView` already carries enough (`from`/`to`/ports/gain).
   Drop the v1 `node.busses` projection path.

6. **Render.** Generalize `busSegments`/`drawBusPass` to draw from the buss
   node's own `pos`+`orient` with input/output taps on opposite sides. Draw the
   buss node as the bar in the main node pass. Reuse `busBarHit` for wire drops.

7. **Creation UI.** "Buss" synthetic entry in `renderFxPicker` → `addBusNode`
   at the cursor.

8. **Retire v1 creation/decoration.** Remove `wm:addBus`/`removeBus`,
   `wv:addBus`/`removeBus`, the `busOverlay`/`busDraft`/`armBus`/
   `busOverlayLayout`/`drawBusOverlay`/`busNear` overlay gesture, the two node-
   menu items, and the `node.busses` shape. Keep the rail *geometry* helpers and
   the port-claim concept (now serving the folded buss).

9. **Tests.** Spec the four realizations (fan-in, fan-out, matrix, degenerate),
   both round-trips (matrix-track recovery; folded port-claim recovery with
   `loneGain` restored), and the boundary migration in both directions. Exercise
   the real allocator (the fx-less track path is the high-risk surface).

## v1 docs to update on landing

- Archive `design/wiring-busses.md` (superseded) or top-banner it pointing here.
- `docs/wiringView.md`, `docs/wiringPage.md`, `docs/wiringManager.md`,
  `docs/DAG.md`: the buss is now a routing object (a node/track), not pure
  decoration — the "never part of the routing snapshot" claims need revising for
  the matrix case.
- Update the `project_wiring_busses` memory: v1's "all three phases landed" is
  superseded by the v2 inversion.

## Deferred

- Arbitrary-angle orientation (store an angle; perpendicular-tap math
  generalizes).
- MIDI busses.
- REAPER-side edit reconciliation/drift on the folded case beyond trusting the
  derived port-claim (v1 already lives with this for `busses`).
- The sophisticated restack/reposition affordances v1 deferred remain deferred.
