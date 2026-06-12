# wiring busses v2 — fan as pure UI; a routing node only at many-to-many

> Design note + implementation plan. **Supersedes `design/wiring-busses.md`**
> (v1: the buss as a node-anchored rail decoration) and **revises this doc's
> own first draft**, which made the buss a free-standing routing object at
> *every* degree and folded the fan cases back into direct sends via
> absorption/`primary`. That mechanism was traced into the allocator and found
> defective; its replacement (a compile-time splice) was designed and rejected
> as needless weight (§ Rejected mechanisms). The surviving model is simpler
> than either: **below many-to-many there is no buss in the graph at all.**
> Read `design/wiring-busses.md` for the starburst problem that motivated
> busses in the first place.

## The model in one paragraph

A buss is a UI object: a freely-positioned bar with input taps combing one
side and output taps the other, meaning *every input → every output*, each
crossing scaled by the product of its two gains. Below the many-to-many
threshold the outer product degenerates to one gain per wire, so the buss is
**pure rendering**: the wires are ordinary direct edges, membership is the v1
port-claim, and the graph contains no buss vertex. At **in ≥ 2 and out ≥ 2**
the products become irreducible and the buss becomes structure: a real
`kind='bus'` node that realizes as one fx-less summing track — N+M sends,
which is what an engineer would build by hand. The governing principle is
unchanged from the first draft: **REAPER must stay legible from its own UI**,
and both realizations above are exactly what a human engineer would produce.

**Invariant: the buss node exists in the graph iff the buss is many-to-many.**
The view's gestures maintain it — the wire-drop that reaches 2×2 mints the
node and re-routes the claimed edges through it; the edit that drops below
dissolves it back to direct edges. The manager and the DAG never choose a
representation; each layer handles whichever object exists.

## Realization by degree

| buss shape | graph presence | realization | persistence |
|---|---|---|---|
| **fan-in** (N→1) | none — N direct edges into the sink port | N direct sends (existing machinery, untouched) | record (pos/orient) + v1 port-claim on the sink port |
| **fan-out** (1→N) | none — N direct edges from the source port | N direct sends | record + port-claim on the source port |
| **1→1** | none — one direct edge (a fan both ways) | one send | record + port-claim |
| **matrix** (≥2 × ≥2) | `kind='bus'` node + its in/out edges | one fx-less summing track; N in-sends, M out-sends | record + `trackId` (flagged track) |
| **degenerate** (0×n, n×0, unwired) | none | nothing | record only (pos/orient); dangling taps are view state, lost on reload by design |

A fan has exactly N gains by construction (each direct edge carries its own
`ops.gain`), so the first draft's gain-factoring wart — storing a `loneGain`
and dividing it back out on read — **does not exist** in this model. Gains
only ever split into in×out factors when the matrix node exists, and there
the track structure carries them physically (in-send volumes × out-send
volumes). The outer product is never computed anywhere.

## Rejected mechanisms (recorded so they are not re-attempted)

**1. Fold-by-absorption** (this doc's first draft): a bus node at every
degree; fan cases folded onto the lone side's track via single-parent
absorption and a derived `primary` on the lone out-edge. Traced into the
realisation pipeline 2026-06-12 and found defective three ways:

- *masterFeed clobber.* Edges `P_i→bus` have a consumer that is neither
  `'master'` nor an fx, so they bypass `buildConns`' feeder-group pre-merge
  (`DAG.lua:549`) and reach `routeByTrack` raw; when the folded bus co-classes
  with master, ≥2 conns each overwrite `route.masterFeed` (`DAG.lua:710`) —
  last writer wins, the other inputs are silently dropped. The "master fan-in
  arrives pre-merged" invariant only holds for *grouped* consumers.
- *preFx mis-tap.* A bus folded onto a mid-chain fx's track (source→F→bus→…)
  emits outwires `from = busId`; the bus is not in `fxSetOf`, so `allocateOnce`
  marks them `preFx` (`DAG.lua:1050`) — they tap the raw track input instead of
  F's output. Wrong audio.
- *Gains land on CUs, not products.* A folded bus's lone-side gain is
  same-track (`routeOf` → nil) → insoluble → rides a synthesized CU, instead
  of composing to the in×out product on each direct send that the port-claim
  persistence story requires.

**2. Compile-time splice** (second draft): non-matrix busses spliced out of
the edge list in `M.compile`, each in×out edge pair becoming a direct edge
with product gain, plus a provenance map translating spliced↔authored edge
indexes for `gainRouting`/`pokeEdgeGain`. Audio-correct and it delivers the
realization table verbatim — but it drags in `anchor`/`loneGain` record
fields, a divide-out on read with exact-compare flap risk (`sendsEq`,
`wiringManager.lua:1185`), and index translation through the live-poke path.
All of it evaporates under "no node below threshold": there is nothing to
splice.

## The model

```
userNode  = { kind='bus', pos={x,y}, orient='V'|'H' }  -- exists iff matrix; id = stable 'bus-N'
edge      = ordinary audio edges to/from the bus node; every tap shares port 1
busRecord = { id, pos, orient, trackId? }              -- rm meta store 'bus' (landed, step 3)
```

- **Matrix wires** are edges with `to = bussId` / `from = bussId`; per-wire
  gain is `edge.ops.gain` as everywhere. `ports.audio = {ins=1, outs=1}` —
  a port index on a summing object is meaningless, so all taps share port 1
  (and `M.validate` needs no bus-specific rule; landed, step 2).
- **Fan membership** is the v1 port-claim: the bound port's incident edges
  *are* the buss's wires (`busClaims`, `wiringView.lua:308`). The claim
  implementation survives unchanged; only its rendering moves from a
  node-anchored rail to a bar at the record's own `pos`. Where the claim
  binding lives — the v1 `node.busses` meta, or a `claim={node,port,dir}`
  field on the bus record — is a step-5 decision; the record is recommended,
  so a buss keeps one identity (`bus-N`, pos, orient) across threshold
  crossings and only `trackId` ⇄ `claim` swap.
- **Orientation**: `'V'`/`'H'`; arbitrary angle deferred. **MIDI**: out of
  scope (bus has `midi={ins=0,outs=0}`; validate refuses midi edges).

### Invariants

- A `kind='bus'` node in a canonical graph is many-to-many (audio in ≥ 2 and
  out ≥ 2); the view's threshold gestures maintain this. Compile stays total
  anyway: any *signal-bearing* bus node (≥1 in and ≥1 out) isolates into its
  own class; dangling/unwired ones are inert and realize to nothing.
- A bus class **never absorbs and is never an absorption target** — the
  summing track stays fx-less even when an output fx has the bus as its sole
  audio parent. (Mirrors the existing "a split-tagged class never absorbs",
  `DAG.lua:276`, plus the new target-side guard.)
- A bus node has no source and no fx. `trackId` lives on the *record*, not
  the node, stamped at reconcile once the track exists; the synthetic id
  never changes.

## DAG: matrix isolation — the realization mechanism

All inside `buildCtx`; no `M.compile` signature change (so `deriveMasterSplit`'s
base ctx gets identical treatment for free).

- **srcSet**: a bus node unions its parents' sets like any node, and seeds a
  marker `'bus:'..id` iff it has ≥1 audio in *and* ≥1 audio out. The
  parent-union loop **skips `'bus:'`-prefixed keys**, so children inherit the
  real upstream sources through the bus but never the marker — the bus sits
  alone in its class. (Contrast `'split:'` markers, which deliberately
  propagate so a cone shares its class.)
- **classes()** records `busClasses[key]` alongside `splitClasses`.
- **absorption()**: `direct[cls] = nil` when `busClasses[cls]` (never absorbs,
  same guard as split), and a `directTrackKey` result that is itself a bus
  class is discarded (never absorbed *onto* — else a sole-output fx folds onto
  the summing track and it stops being fx-less).

Realisation traced end-to-end (2026-06-12) — **zero `allocateOnce` changes**:

- Track emission is node-driven and already supports fx-less non-master
  tracks (`assembleTracks`; the `#chain > 0` guard suppresses only the fx-less
  *master*). `isChainMember` already excludes `bus` (`DAG.lua:484`). The
  first draft's step-1 verification stands.
- In-sends: edges `P_i→bus` route as ordinary outWires per producer track; on
  the bus track the incoming flows have `toSlot = nil` (bus not in any
  `fxOrder`) → no `byPin` value → `dstChan` stays 0 → **pair 1**. Each
  `(P_i-track → bus-track)` route carries one edge → gain lands **natively on
  the send volume**.
- Out-sends: `from = bus` ∉ `fxSetOf` → `preFx` tap of pair 1 = the summed
  input, which is exactly right on an fx-less track; gains native per route.
- `bus→master`: a single edge (duplicate_edge bars a second) → the ordinary
  masterFeed path, single producer, no clobber.
- `nchan = 2`; no CU is ever minted on the bus track.

One known wrinkle to handle in the same step: **two taps into one buss from
the same source track** (e.g. two co-tracked fx each wired in) share a route
key → insoluble for `gainHost` → their gains stay on the conns, and
`routeByTrack` currently drops conn-level gain for outWires. Fix: for bus
consumers, carry `conn.gain` through onto the outWire (REAPER sends are
per-srcChan, each with its own D_VOL, so the send data model supports it).
Live pokes for that niche shape fall back to reconcile. The symmetric
out-side case (two outputs into one consumer track) is already handled by the
existing feeder-group merge CU on the *consumer's* track.

## Persistence & round-trip

- **Matrix — the carrier is the track.** `record.trackId` is stamped in
  `wm:reconcile` after `applyOps` (via `ctx:trackKeyOf(busId)` →
  `newTrackIds`; cleared when the class loses its track). Read
  (`readGraph(snap, busMeta?)` — param optional, existing specs untouched): a
  track whose guid matches a record's `trackId` **mints the `kind='bus'` node
  under its synthetic id** — the accumulated incoming refs become its
  in-edges (send gains fold on, as everywhere), the track tail becomes the
  bus ref so downstream walks emit the out-edges, and the no-inputs⇒source
  rule (`walkTrack`, `wiringManager.lua:999`) is suppressed for flagged
  tracks. MIDI does not pass through. Membership is derived from the track's
  sends — no authored edge list. `pos`/`orient` come back via
  `stampDecoration` from the bus store.
  - Tolerated drift: an fx dropped onto the summing track in REAPER reads as
    a downstream fx node fed by the bus; the next reconcile moves it to its
    own track (the non-absorption guard) — self-healing toward canonical.
- **Fan — the carrier is the direct edges themselves.** The claim derives
  membership (v1, shipped, round-trips today); `pos`/`orient` from the
  record. Nothing new on read.
- **Degenerate — record only.** A dangling tap (an input wired before any
  output exists) has no producer→consumer edge to persist; it is view state
  and is lost on reload, by design.

## Threshold crossings (view gestures)

- **fan → matrix** (the wire-drop that reaches 2×2): one mutate mints the
  node (id from the record), re-points the claimed edges' bussed end to the
  bus (in-edges keep their gains; the former lone side becomes the single
  `bus→C` / `P→bus` edge carrying its gain), and adds the new tap. The claim
  is dropped; `trackId` arrives at the next reconcile.
- **matrix → fan** (the edit dropping below 2×2): one mutate removes the
  node and re-points edges direct, each crossing's gain becoming the
  `inGain×outGain` product — N+M gains collapse to N, deliberately; audibly
  identical, and the fader attribution change is inherent to the model. The
  record drops `trackId` and regains the claim; the track is demolished by
  the same reconcile (its class vanished).
- The buss's id, pos, and orient survive both directions — a buss never
  loses identity or placement at the threshold, and it does **not** snap back
  to a node-anchored rail: fans render at their own pos too.

Note the dissolution direction can be triggered by mutations that originate
outside the buss UI (e.g. deleting an fx that was the matrix's second input).
The conversion logic must therefore live where mutations are issued (the
view/page layer wrapping its mutates), not inside a render path.

## Geometry & render

Identical render for every buss — a bar at the record's/node's own
`pos`+`orient`, input taps combing one side, output taps the other,
arrowheads for direction. Reuse the `SIDE_VEC` tap/trunk construction from
v1's `busSegments`/`drawBusPass`; `busBarHit` makes the bar a fat wire-drop
target. For fans the bar projects from the record + claimed wireViews (v1
projection, repositioned); for the matrix it *is* the node's render — a node
you cannot dive into, hit-tested for move/delete/wire-drop through the
existing node machinery.

## Creation & editing

- **Create**: a synthetic "Buss" entry in the FX picker (`renderFxPicker`) —
  canvas-RMB is already the "add here" path. Creation mints a **record only**
  (no node until the threshold). *Caveat: `wm:addBusNode` as landed in step 3
  mints an unwired node — under this model that node shouldn't exist; rework
  to record-only when the creation UI lands (step 7). Harmless meanwhile:
  nothing in production reaches it, and an unwired node compiles to nothing.*
- **Wire**: ordinary wire-draft; dropping on the bar adds/re-points direct
  edges + claim below the threshold, converts at it (§ Threshold crossings).
- **Move**: writes record `pos` (`wm:moveNodes` already routes a buss there).
- **Delete**: matrix → `wm:deleteBus` (landed); fan/unwired → drop the record
  (+ claim).
- **Per-wire affordances** (gain fader, RMB-delete) live on each tap as
  today: every tap is a real edge — direct, or bus-incident — so the
  existing fader/poke machinery works unchanged; matrix tap pokes ride
  native send volumes (no index translation — nothing is spliced).

## Implementation plan

> **Progress (2026-06-12):** steps 1–4 landed (steps 1–3 in commit `25c8f25`
> under the first draft's model; their DONE notes below record the decisions,
> which survive except where bracketed; the first draft's step 4 —
> anchor/loneGain bookkeeping, folded re-injection, realization-by-degree
> folds — is **superseded** by this revision). Suite green at 1393.

1. **Allocator: fx-less summing track.** *(DONE — verified 2026-06-12.)*
   `assembleTracks` emits a spec for any non-master class unconditionally
   (the `#chain > 0` guard suppresses only the fx-less master); the allocator
   is node-driven, so the `kind='bus'` node conjures the track. Additions
   that shipped with step 2: `isChainMember` excludes `bus` (`DAG.lua:484`).
   [Revision: the non-absorption invariant lands in step 4 as the
   bus-class isolation, both directions.]

2. **Model + validate.** *(DONE.)* `kind='bus'` in the `userNode` shape
   (with `orient?`); `M.validate` needs no buss rule — a buss carries
   `ports.audio={ins=1,outs=1}` (all taps share port 1), satisfying every
   existing port/edge check. **Id scheme:** stable synthetic `bus-N`
   (`nextBusId`, max-scan); `trackId` is a separate record field so the id
   survives fold⇄matrix transitions.

3. **Manager: buss record store + mutations.** *(DONE.)* `routingManager`
   grew a generic named-store mechanism — `META_STORES = { fx=…, bus=… }`,
   each a flat `{[id]=meta}` projext blob with its own scratch-chunk undo
   mirror; `rm:meta(store[,id])` / `rm:assignMeta(store,id,meta)`.
   `wm:addBusNode(pos)`, `wm:moveNodes` routing buss pos to the store,
   `wm:deleteBus(id)`. Specs: `tests/specs/wm_bus_node_spec.lua`.
   [Revision: `anchor`/`loneGain` are dead — fans need neither. The record
   is `{id, pos, orient, trackId?}` (+ possibly `claim` from step 5).
   `addBusNode` minting a node is a model violation to rework in step 7.]

4. **DAG matrix isolation + read minting + trackId stamp.** *(DONE —
   2026-06-12.)* As specified, with one refinement: the marker rule alone
   left an **in-only** bus co-classed with its parent track, leaking a dead
   intraConn into pair-1 allocation — so the srcSet rule went total: a bus
   is either signal-bearing (seeds `'bus:'..id`, sits alone) or contributes
   an **empty** srcSet (class `''`), making all three degenerate shapes
   inert by construction. Other decisions: the multi-tap gain carry is
   `sendGain[key] or conn.gain` in `routeByTrack` (bus-bound taps are the
   only conns that reach an outWire with a CU-hosted gain); the trackId
   stamp is `stampBusTracks()` after `applyOps` in `wm:reconcile`,
   patch-merging the record (`util.REMOVE` clears). Specs:
   `dag_bus_spec.lua`, `wm_bus_read_spec.lua`, plus a live
   reconcile-stamp/read-back test in `wm_bus_node_spec.lua`.

5. **View projection.** `nodeView` gains the bus kind (matrix); fans
   project from records + claims (decide claim storage — recommend the bus
   record, retiring `node.busses`, for stable identity across the
   threshold). Drop the v1 `node.busses` projection path if storage moves.

6. **Render.** Generalize `busSegments`/`drawBusPass` to own-pos/orient
   with input/output taps on opposite sides; draw the matrix bar in the
   main node pass; reuse `busBarHit` for wire drops.

7. **Creation UI + threshold gestures.** "Buss" picker entry → record-only
   create (rework `wm:addBusNode`); wire-drop and edge-removal conversion
   mutations in both directions (§ Threshold crossings), including
   dissolution triggered by non-buss gestures (fx deletion); record-buss
   deletion.

8. **Retire the v1 overlay gesture.** `busOverlay`/`busDraft`/`armBus`/
   `busOverlayLayout`/`drawBusOverlay`/`busNear`, the node-menu items, and
   `wm:addBus`/`removeBus` + `wv:addBus`/`removeBus` *as creation surface* —
   superseded by record-busses. **Keep** the claim derivation (`busClaims`)
   and the rail geometry helpers; they are the fan implementation.

9. **Tests.** Threshold crossings both directions (gain composition,
   identity/pos survival, track demolition); fan round-trip via claims with
   free pos; matrix round-trip against the real allocator; the same-track
   multi-tap gain case.

## v1 docs to update on landing

- Archive `design/wiring-busses.md` (superseded) or top-banner it pointing
  here.
- `docs/wiringView.md`, `docs/wiringPage.md`, `docs/wiringManager.md`,
  `docs/DAG.md`: a buss is decoration below the threshold (v1's stance,
  now with free placement) and a routing node/track at many-to-many — the
  "never part of the routing snapshot" claims need the matrix carve-out.
- Update the `project_wiring_busses` memory: v1 "all three phases landed"
  and the first-draft v2 inversion are both superseded by this model.

## Deferred

- Arbitrary-angle orientation (perpendicular-tap math generalizes).
- MIDI busses.
- Dangling-tap persistence (currently view state, lost on reload).
- REAPER-side edit reconciliation/drift on claims beyond trusting the
  derived port-claim (v1 already lives with this).
- Live gain pokes for same-track multi-tap matrix wires (reconcile-driven
  until it matters).
- The sophisticated restack/reposition affordances v1 deferred remain
  deferred.
