# wiring busses v2 — one buss node at every degree; a buss track only at many-to-many

> Design note + implementation plan. **Supersedes `design/wiring-busses.md`**
> (v1: the buss as a node-anchored rail decoration). This doc has been through
> three drafts: the first folded fan busses onto neighbour tracks via
> absorption/`primary` (traced into the allocator, defective); the second
> spliced them out at compile but was rejected for its claim-era bookkeeping;
> the third dropped the node below many-to-many entirely, carrying fans first
> as port-claims, then as explicit tap sets. The final model (2026-06-12)
> returns to **a `kind='bus'` node at every degree** and un-rejects the
> compile-time splice (§ Rejected mechanisms 2): with the record's taps
> carrying the authored gains, the bookkeeping that killed it dissolves.
> Below many-to-many there is no buss in *REAPER* at all; gestures are
> degree-blind.
> Read `design/wiring-busses.md` for the starburst problem that motivated
> busses in the first place.

## The model in one paragraph

A buss is a UI object: a freely-positioned bar with input taps combing one
side and output taps the other, meaning *every input → every output*, each
crossing scaled by the product of its two gains. In the graph the buss is a
`kind='bus'` node at **every** degree; every tap is a real edge carrying its
own `ops.gain`. The degree decides only the *realization*: at **in ≥ 2 and
out ≥ 2** the products are irreducible and the node's class realizes as one
fx-less summing track — N+M sends, what an engineer would build by hand.
Below that, compile splices the node out — each in×out crossing becomes a
direct send at the product gain, what the same engineer would do without the
track (the splice synthesizes structure exactly as the merge-CU pass does).
No factor is ever recovered by division: the authored gains live on the bus
edges, persisted in the record's taps, and realization only ever multiplies.
The governing principle is unchanged: **REAPER must stay legible from its
own UI** — both realizations are what a human engineer would produce.

**Invariant: the buss *track* exists iff the buss is many-to-many; the buss
*node* exists at every degree.** Compile maintains it — the splice collapses
sub-threshold busses, the class machinery conjures the track at 2×2 — and
the track appears and disappears through the ordinary reconcile diff as the
class does. Gestures never convert anything: wiring a buss is ordinary node
wiring at any degree, and gain attribution never changes when a buss crosses
the threshold.

## Realization by degree

| buss shape | graph presence | realization | persistence |
|---|---|---|---|
| **fan-in** (N→1) | `kind='bus'` node; N in-edges, 1 out-edge | spliced: N direct sends at `inGain×outGain` | record: pos/orient + taps (with gains); the sends realize the products |
| **fan-out** (1→N) | node; 1 in-edge, N out-edges | spliced: N direct sends at products | record + taps |
| **1→1** | node; one edge each side | spliced: one send | record + taps |
| **matrix** (≥2 × ≥2) | the same node; N ins, M outs | one fx-less summing track; N in-sends, M out-sends | record + `trackId` (flagged track) |
| **degenerate** (0×n, n×0, unwired) | node + its one-sided edges | nothing — inert | record + taps; no REAPER carrier |

A fan carries N+1 gains — one per tap, both sides — and every crossing
realizes at the in×out product. The lone side's single gain is therefore a
**group fader** over the whole fan, for free, at every degree (the bar-level
fader is just UI on top of it). Reading back never factors a product: the
record's taps carry the authored gains, so the splice only ever multiplies —
the first draft's divide-out wart stays dead.

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

**Un-rejected in the final model (2026-06-12):** the warts were claim-era
bookkeeping, not splice defects. With the node present at every degree and
the record's taps carrying the authored gains, `anchor` is the node itself,
`loneGain` is an ordinary edge gain, and no read ever divides a product back
into factors. What survives is the provenance map — authored bus edge →
realized send(s) — for `gainRouting`/`pokeEdgeGain`; a many-side tap maps
1:1, a lone-side poke fans out to all its crossings' sends (the group
fader).

**3. Port-claim fan membership** (steps 3/5 as landed): membership as v1's
port-claim — the bound port's incident edges *are* the buss's wires. Rejected
2026-06-12 in step-7 review: a claim is port-wide by construction, so the
moment a bar binds a port, every other edge that port has (or later gains)
silently re-routes onto the bar (port-swallow), and per-wire add/remove is
inexpressible. Replaced by explicit per-tap membership. The objection that
killed the obvious fix — "edges have no stable identity to enlist" — was
wrong: `(type, from:port, to:port)` is unique by the duplicate-edge rule and
node ids are GUIDs, so value refs survive reloads. (Moot in the final model:
membership is structural at every degree — the record's taps are a
write-through mirror for persistence, not authored membership.)

## The model

```
userNode  = { kind='bus', pos={x,y}, orient='V'|'H' }  -- at every degree; id = stable 'bus-N'
edge      = ordinary audio edges to/from the bus node; every tap shares port 1
busRecord = { id, pos, orient, ins={{node,port,gain},…}, outs={{node,port,gain},…}, trackId? }
```

- **Buss wires** are edges with `to = bussId` / `from = bussId`; per-wire
  gain is `edge.ops.gain` as everywhere. `ports.audio = {ins=1, outs=1}` —
  a port index on a summing object is meaningless, so all taps share port 1
  (and `M.validate` needs no bus-specific rule; landed, step 2).
- **Membership is structural at every degree** — a tap is an edge incident
  on the bus node, nothing else. Wiring a port elsewhere never enlists it
  (no port-swallow; § Rejected 3), and fan-in / fan-out / 1→1 don't exist
  as stored cases. The record's `ins`/`outs` are not authored membership but
  a **write-through mirror** — `{node, port, gain}` per tap, refreshed on
  every mutate like `pos` — because below the threshold the bus edges have
  no per-edge REAPER carrier: the mirror is what mints them back on read.
  A buss keeps one identity (`bus-N`, pos, orient) for life; `trackId` is
  stamped and cleared as the track comes and goes.
- **Orientation**: `'V'`/`'H'`; arbitrary angle deferred. **MIDI**: out of
  scope (bus has `midi={ins=0,outs=0}`; validate refuses midi edges).

### Invariants

- A `kind='bus'` node exists at every degree; compile splices it out below
  2×2 (each in×out crossing → a direct conn at the product gain; one-sided
  and unwired busses splice to nothing). Only ≥2×2 busses reach classing,
  where the signal-bearing marker rule (landed, step 4) isolates them; the
  empty-srcSet degenerate rule stays as a drift backstop.
- The record's taps mirror the node's incident edges — write-through on
  every mutate, GC'd when a tapped node dies. No shape invariant exists on
  the tap counts; any degree is canonical.
- A bus class **never absorbs and is never an absorption target** — the
  summing track stays fx-less even when an output fx has the bus as its sole
  audio parent. (Mirrors the existing "a split-tagged class never absorbs",
  `DAG.lua:276`, plus the new target-side guard.)
- A bus node has no source and no fx. `trackId` lives on the *record*, not
  the node, stamped at reconcile once the track exists; the synthetic id
  never changes.

## DAG: matrix isolation — the realization mechanism

No `M.compile` signature change (so `deriveMasterSplit`'s base ctx gets
identical treatment for free).

- **Splice (new, runs first):** before `buildCtx`, sub-threshold bus nodes
  are spliced out of the working graph — each in×out edge pair becomes a
  direct edge at `inGain×outGain`; one-sided busses contribute nothing. The
  pass emits a provenance map (authored bus-edge index → realized edge
  indexes) consumed by `gainRouting`/`pokeEdgeGain`: many-side pokes ride
  1:1, lone-side pokes fan out to every crossing (or fall back to reconcile
  if fan-out pokes prove fiddly). Everything below sees the spliced graph.
- **srcSet** (reachable only by ≥2×2 busses after the splice): a bus node
  unions its parents' sets like any node, and seeds a
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
- **Sub-threshold — the carrier is the record + the spliced sends.** The
  record's taps (`node`, `port`, `gain`) mint the bus node and its edges on
  read; realized direct sends that match a tap pair are recognized as
  crossings and consumed, not read as plain wires. Taps whose node:port
  vanished are GC'd at the mutate chokepoint (the `pruneSourceTags`
  pattern). Drift policy: below the threshold the record is authoritative —
  a send volume edited REAPER-side under a crossing is overwritten at the
  next reconcile; a plain send parallel to a crossing on the same port pair
  is a tolerated read corner (attribution may shift between them).
- **Degenerate — the record carries everything.** One-sided bus edges have
  no REAPER carrier at all; they round-trip purely through the record's
  taps, and survive reload.

## Degree changes

There are no conversion mutations and no threshold gestures. Adding or
removing a tap is ordinary edge wiring on the bus node — **one gesture, one
wire**, at every degree; deleting a foreign node takes its taps with it and
leaves the rest of the buss untouched; rewires are plain edge surgery.

When an edit moves a buss across 2×2 — in either direction, from any source
(buss UI, wire deletion, fx deletion) — nothing happens in the graph beyond
that one edge. The next compile simply splices or stops splicing, the
reconcile diff demolishes or conjures the summing track, and
`stampBusTracks` clears or stamps `trackId`. Gain attribution never changes:
the same N+M tap gains exist on both sides of the threshold; only their
realization moves between product sends and physical track sends. The
buss's id, pos, and orient are never touched by degree.

## Geometry & render

Identical render for every buss — a bar at the record's/node's own
`pos`+`orient`, input taps combing one side, output taps the other,
arrowheads for direction. Reuse the `SIDE_VEC` tap/trunk construction from
v1's `busSegments`/`drawBusPass`; `busBarHit` makes the bar a fat wire-drop
target, either draft end, at any degree. The bar *is* the bus node's render
everywhere (step 6's matrix render generalizes): every tap is a real edge,
so wires, faders, and hit-tests apply uniformly; a tapless buss is a bare
bar. A node you cannot dive into, hit-tested for move/delete/wire-drop
through the existing node machinery.

## Creation & editing

- **Create**: a synthetic "Buss" entry in the FX picker (`renderFxPicker`) —
  canvas-RMB is already the "add here" path. Creation is `wm:addBusNode`:
  node + record, exactly as landed in step 3 (the record-only caveat is
  repealed — the node is correct at every degree).
- **Wire**: ordinary wire-draft; the bar is a fat drop target for either
  end at any degree. No fuse, no mint.
- **Move**: writes node pos + record `pos` (`wm:moveNodes`, landed).
- **Delete**: `wm:deleteBus` at every degree — node, incident edges, record,
  one Undo block. `wm:removeBusRecord` retires (no record-only busses
  exist).
- **Per-wire affordances** (gain fader, RMB-delete) live on each tap, which
  is a real edge at every degree, so the existing fader/poke machinery
  applies uniformly. Matrix pokes ride native send volumes; sub-threshold
  pokes route through the splice provenance map — a lone-side poke is the
  group fader (fans out to its crossings' sends, or reconciles).

## Implementation plan

> **Progress (2026-06-12):** steps 1–5 landed (steps 1–3 in commit `25c8f25`
> under the first draft's model; their DONE notes below record the decisions,
> which survive except where bracketed; the first draft's step 4 —
> anchor/loneGain bookkeeping, folded re-injection, realization-by-degree
> folds — is **superseded** by this revision). Suite green at 1398.
>
> Further revision during step-7 review (2026-06-12): fan membership moved
> from the step-5 port-claim to per-tap sets on the record (§ Rejected 3),
> and dangling taps became persisted record state.
>
> Final revision (2026-06-12, same review): the node returns at every degree
> and the compile-time splice is un-rejected — the record's taps carry the
> authored gains, so nothing is ever divided back out, and threshold
> crossings stop existing as a concept (§ Degree changes). Step 5's claim
> machinery is reworked and step 7 re-cut below.
>
> Step-7 progress (2026-06-13): the DAG half landed — sub-threshold splice +
> provenance map in `M.compile`, `gainRouting`/`pokeEdgeGain` through the map
> (lone-side group-fader pokes included). The wm half landed the same day:
> claim machinery out (`addBusRecord`/`removeBusRecord`/`pruneBusClaims`),
> record taps as the write-through mirror (`mirrorBusTaps` at the mutate
> chokepoint and in `fastGainCommit`), read minting of recordless busses with
> crossing-send consumption, and `wm:insertBus` (mint + re-point + unity
> trunk) behind the armBus commit. The wv claim plumbing fell with it —
> tagging is structural-only, so every buss renders as a bar via the matrix
> path for free; the busDraft preview keeps a synthetic claim-shaped busView
> until step 8 retires the gesture. The UI half landed 2026-06-13, closing
> step 7: a synthetic "Buss" entry in the FX picker (→ `wv:addBusNode`), and
> delete routing — RMB on a bar or node body opens the node menu, which shows
> "Delete buss" → `wm:deleteBus` for bus nodes (armBus entries suppressed
> there).

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
   [Revision: `anchor`/`loneGain` are dead. The record is
   `{id, pos, orient, ins, outs, trackId?}`. `addBusNode` minting a node is
   correct again in the final model — the step-7 caveat is repealed.]

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

5. **View projection.** *(DONE — 2026-06-12, + the fan render pulled
   forward from step 6 so the app stays coherent.)* Claim storage went to
   the bus record as decided: `claim = {node, port, dir}` (one port, one
   node — v1's multi-port `{dir,ports,side}` shape and `node.busses` are
   gone everywhere: storage, stamp, projection). `wv:busViews()` is the
   uniform bar list `{id, pos, orient, matrix?, claim?}`; `wireView.bus`
   is `{busId, bussedEnd}`, stamped structurally for bus-node endpoints
   (matrix) and via claims for fans, `to`-end precedence, matrix over
   claim. nodeView: bus kind → category `'bus'`, label `'buss'`, `orient`
   field. wm grew `addBusRecord`/`removeBusRecord`/`busRecords` (record
   ops fire `wiringChanged` directly — no graph mutate); `wm:moveNodes`
   routes record-only buss ids to record pos; `pruneBusClaims` in
   `wm:mutate` GCs a record when its claimed node dies (v1 parity: the
   buss died with its node). Render: `busSegments` anchors the bar at the
   busView's own pos/orient (taps comb away from the claimed node, trunk
   to the node edge); the v1 creation gesture commits a record via
   `busDefaultPlacement` (side → pos + orient). Specs: `wv_bus_spec`
   rewritten; record CRUD/id-space tests in `wm_bus_node_spec`; the two
   v1 node-meta round-trip tests in `wm_read_spec` retired.
   [Revision: the `claim` shape this step landed is superseded by per-tap
   membership — reworked in step 7; the projection/render decisions survive.]

6. **Render — matrix half.** *(DONE — 2026-06-12.)* The fan half landed
   with step 5. `busSegments` generalised: each busView anchors on its
   claimed node (fan: trunk, comb side away from it) or the bus nodeView
   itself (matrix: drag-live pos, no trunk, source tags comb the +normal
   side); the per-edge tap construction is shared. Rails grew
   `matrix`/`node=anchor`/`port=1`; `drawBusPass` skips matrix rails —
   the new `drawBusBar` draws them in the main node pass as the node's
   body (selection strokes a slab round the bar; a bus node with no
   record/rail falls back to the rect render). `busBarHit` takes either
   draft end on a matrix bar. No new specs — pure render, exercised at
   step 9 with the gestures.

7. **Final-model rework: splice + record gains + creation UI.**
   - *DAG*: the sub-threshold splice + provenance map; `gainRouting`/
     `pokeEdgeGain` through the map (lone-side pokes fan out to their
     crossings or fall back to reconcile).
   - *wm*: claim machinery out (`claim` field, `pruneBusClaims`,
     `addBusRecord`/`removeBusRecord`); record taps as the write-through
     mirror `{node, port, gain}` + dead-node tap GC; read minting of
     sub-threshold busses from taps, consuming their crossing sends.
   - *wv/render*: `busClaims`/`busTag` → structural membership only;
     `busSegments` uniform on the node render (bare bar for a tapless
     buss); `busBarHit` either end at any degree; the armBus commit mints
     the node and re-points the port's edges through it (audio-identical
     under the splice) until step 8 retires the gesture.
   - *UI*: "Buss" picker entry → `wm:addBusNode`; bar RMB → delete; node
     menu routes bus nodes to `wm:deleteBus`.

8. **Retire the v1 overlay gesture.** `busOverlay`/`busDraft`/`armBus`/
   `busOverlayLayout`/`drawBusOverlay`/`busNear` and the node-menu items —
   superseded by record-busses. (`wm:addBus`/`removeBus` + `wv:addBus`/
   `removeBus` already fell in step 5 — the overlay now commits records.)
   **Keep** the rail geometry helpers; they are the fan render. (`busClaims`
   falls in step 7 with the claim model.)

9. **Tests.** Splice products + provenance pokes (incl. a lone-side
   group-fader poke); degree changes across 2×2 both ways (track conjured/
   demolished, gain attribution stable, identity/pos survival);
   sub-threshold round-trip from record taps, one-sided busses included;
   matrix round-trip against the real allocator; the same-track multi-tap
   gain case.

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
- Bar-level group fader UI (the lone-side gain already scales every
  crossing; this is only a bar affordance for it).
- REAPER-side drift on sub-threshold crossings beyond record-authoritative
  overwrite (parallel-send attribution corner included).
- Live gain pokes for same-track multi-tap matrix wires (reconcile-driven
  until it matters).
- The sophisticated restack/reposition affordances v1 deferred remain
  deferred.
- Chained sub-threshold busses: n→1→m through two bars splices to n×m
  product sends — the starburst, authored by hand. A single n×m buss
  expresses the same products with N+M taps; no mid-splice re-evaluation is
  attempted, keeping each bar's realization local to its own authored degree.
