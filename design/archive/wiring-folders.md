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

Capacity: the family shares REAPER's 126 usable MIDI buses as one
domain (`CAPACITY.midi`). Over-pressure uses the existing valve — evict
fx to top-level emergent tracks, where the boundary crossing is an
explicit send with controlled bus mapping, outside the domain. The
one-fx-per-track floor argument carries over.

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

> **Progress (2026-06-14).** Steps 1, 2, 3a, **3b all landed** — folder MIDI
> rides the family bus domain. 3b's first cut (`familyMidi`, `f088dc9`) was rolled
> back as a per-track bolt-on (two bus allocators fighting over bus 0) and rebuilt
> as family-domain allocation: a **read-model change** (`21a78b7`) + the
> **allocator** (`8518249`, read-bug fix `958b81b`, + bus-0 leak guard), suite
> green at 1430. Step 4 (family capacity bisection) now landed too — see below. All four steps complete.
>
> **Read model — LANDED (`21a78b7`; bus-split corrected 2026-06-14, suite green
> at 1423).** The folder parent reads MIDI as a **bus-0/bus-N split**:
> - Parent reads as `kind='source'` with **`midi={ins=1, outs=1}`** (was 0,0):
>   it accepts midi edges and emits.
> - Each conduit child's **tail** midi (`childMidi` = the child's `liveMidi`
>   *after its fx chain*, carried identity-mapped up the atomic send) splits by
>   bus. **Bus 0** is the take aggregate: each bus-0 producer wires into the
>   parent **node** (`child→sid`), which re-emits bus 0 with its own take — two
>   hops, the native folder merge, mirroring audio summing onto pair 1. **Buses
>   ≥1** are distinct streams: they pass through identity-mapped, so a parent (or
>   further ancestor) fx forms a **direct `child→fx`** edge; an unread bus carries
>   no edge. *(The first cut funneled every bus through `sid`, collapsing distinct
>   child→parent-fx routing; the specs only exercised bus 0, so it stayed green.)*
> - The parent emits **its own take on bus 0**, gated on
>   `hasMidiTake OR a child merged on bus 0` — no phantom on a media-less folder.
> - **Ports stay wirable** (`outs=1` always); only *emission* (`feedMidi`) waits
>   on a take, so you can wire the midi-out before authoring the take.
> - **`hasMidiTake`** — new REAPER-resident snapshot field; `rm` reads the active
>   take via `TakeIsMIDI`. Also retires the bare-source audio-only bus-0 phantom.
>   Roundtrip overlays it like the folder tree (a source has a take iff its midi
>   is consumed). Specs: `wm_folders_read_spec` (bus-0 aggregate, bus-N direct, own-take),
>   `wm_read_spec`, `wm_roundtrip_spec`.
>
> **Allocator — LANDED (`8518249`; roundtrip + read-bug fix `958b81b`, suite
> green at 1429).** A folder **family** — a top-level parent + all transitive
> parent-send descendants — is ONE midi bus domain (the identity pipe is n→n,
> no remap point). Two parts:
> - **Compile diversion (`buildConns`).** A foldered child's midi edge to its
>   parent / a parent-resident fx is NOT an explicit send (it would collide with
>   the un-gateable pipe). It is diverted, recording a `pipeMidi` crossing
>   `{from, consumer}` on the child track; `targetTracks` attaches `pipeMidi` to
>   the child entry.
> - **The family lift (`allocateOnce`).** Audio allocates per-track as before;
>   then a family-wide midi pass: members deepest-first, each member's slots
>   block-offset into family coordinates (stride `N+2`), all fed to **one
>   `allocStream` per family**. A single **bus-0 `sourceMidi` aggregate** (pinned,
>   placed first) collects every **merge** (a crossing whose consumer is the
>   parent *source node* — the native folder adoption no-op, no CU); each
>   **distinct** crossing (consumer is a parent *fx*) folds into a producer value
>   whose `lastUse` reaches the consuming slot, so family-uniqueness falls out of
>   the live-range allocator and the stream takes a bus ≥1. A merge co-resident
>   with a distinct stream forces the distinct one off bus 0. A **singleton
>   (non-folder) family reproduces the old per-track allocation exactly** (zero
>   regression).
>
> Specs: `dag_folder_midi_spec` (compile diversion + alloc, both fates),
> `wm_roundtrip_spec` (folder-midi `read∘compile=id`, both fates). The roundtrip
> caught a **read bug** (`958b81b`): a heard-but-mute parent fx drained its
> default `outBus` instead of the bus it consumed, wiping a co-resident bus-0
> aggregate whenever a bus-≥1 consumer was walked first. (The original design's
> out-park busRoute CUs proved unnecessary — a single live-range `allocStream`
> with a pinned bus-0 aggregate makes both the merge-vs-relocate decision and
> family uniqueness fall out structurally.)
>
> **Bus-0 leak guard — LANDED.** A conduit child's bus 0 rides the pipe up and
> read merges *every* bus-0 arrival into the parent node, so **every fx producer
> on a pipe-riding member is floored off bus 0** (`minReg=1` in `allocStream`) —
> diverted crossings AND a generator that merely sends off-track — leaving bus 0
> to the take aggregate. (This replaced the originally-envisaged corrective "nudge
> an illegitimate bus-0 occupant": the single placed-first `sourceMidi` means a
> *sid* is never blocked, so prevention at claim-time is the clean local fit.)
> Specs: `dag_folder_midi_spec` § 'never reclaims a just-freed bus 0',
> § 'sending off-track is floored off the pipe bus 0'.
>
> **Family capacity bisection — LANDED (suite green at 1441).** A folder family is one MIDI bus
> domain, so over-pressure is resolved per *family*, not per track: `splitOverCap` groups members by
> `familyRoot`, and when the shared `midiUsed > CAPACITY.midi` (126) it evicts a segment **out of the
> family** to a top-level track — its folder parent-send and any distinct pipe crossing it carries
> become **explicit sends** (`bisectOutOfFamily` cuts a deep child's chain; `evictMember` pulls a
> single-fx leaf whole), re-allocated at the receiver outside the domain. Two guardrails keep
> `read∘compile=id`: (1) a **pipe consumer fx is never relocated** out of its family — the cut is
> floored past the member's last consumer slot, so the parent's consumer chain is never cut and
> eviction always falls on the producer side; (2) an **incoming midi send into a folder family is
> floored off bus 0** (`minReg`), since a bus-0 arrival reads back as a phantom native merge. Only
> distinct (bus≥1) crossings ever convert — a bus-0 take merge stays piped (asserts otherwise).
> Specs: `dag_folder_capacity_spec` (both eviction shapes + determinism), `wm_roundtrip_spec`
> (127-child overflow round-trips exactly, with a 3-child no-overflow control).
>
> **Doc debt:** the step-2 historical text in § "Model + read" below keeps its
> pre-3b wording (parenthetical-corrected). `docs/wiringManager.md` and
> `docs/DAG.md § Folder parents` carry the landed bus-0/bus-N split and the
> family allocator.

1. **rm foundation** *(DONE — `a9e530d`)*: `readTrack` carries
   `folderDepth`; `stampParents` walks project order stamping each
   foldered track's `parent` guid (positional — set regardless of
   whether the child parent-sends; the tree is structure, the edge is
   `mainSend.on`); `rm:addTrack` pins emergent tracks top-level by
   closing any open folder on the last real track (the corruption fix);
   `parent` flows through `stateEntry` into snap entries.
   Spec: `tests/specs/rm_folders_spec.lua`.
   *(Skipped: the `'folder'` quarantine reason — step 2 does the real
   read instead of going dark.)*
2. **Model + read** *(DONE — suite green at 1413)*. The model change
   is **entirely in `readGraph`** — `M.validate` already permits an edge
   into any node with `ins ≥ 1` (the generic port check, `DAG.lua:101`);
   sources are unsinkable today only because read always mints them with
   `ins = 0`. Concretely:
   - A **folder parent is a `kind='source'` node with `audio.ins ≥ 1`**
     (no new kind). Children's parent-sends become **audio edges into
     it** (it's the pair-1-2 summing point); it emits its summing output
     on pair 1 as today. `srcSet` then unions children (`DAG.lua:280`)
     → its own composite class.
   - **MIDI is not edges.** *(Refined by 3b's read model: **bus 0** aggregates
     into the parent node as an edge (`midi.ins=1`); **buses ≥1** stay liveness
     exactly as described below — passing through to a direct `child→fx` edge. The
     first 3b cut wrongly funneled buses ≥1 through the node too; corrected
     2026-06-14. See § Plan Progress. Step-2 text kept below for history.)*
     The parent send maps all buses n→n identity,
     so `walkTrack` seeds a folder parent's `liveMidi` from each child's
     tail at identity buses (liveness through the pipe); real midi edges
     form where a child's bus-*n* producer meets a parent fx listening
     on *n*. The folder source keeps `midi.ins = 0`. The "contiguous
     allocation region" framing is the step-3/4 allocator's, not read's.
   - `mainSend.on` mints to `entry.parent or MASTER_KEY` (`~:1033`);
     `nonMasterOrder` lets `toParent` edges into the Kahn sort so parents
     walk after children (`~:1051`); source-mint condition becomes
     `(no incoming) OR folderParents[trackKey]` (`~:1100`).
   - **Scope seam**: step 2 specs assert the **read graph shape only**
     (foldered source, parent hosting fx, parent-send ∥ explicit-send,
     nested folders, child with mainSend off, + a validate spec for an
     edge into a source-with-`ins`). Roundtrip stays step 3 — until the
     allocator pins a folder parent's composite class to its existing
     track (and doesn't absorb a single-child folder), recompile is
     wrong-but-expected.
3. **Compile**. Split 3a/3b.
   - **3a (DONE)**: audio conduit rule + tie-break; folder-parent class
     pinning (`classTrackKey` → source guid) + single-child absorb guard;
     master parent-send machinery generalised to `sink`-keyed `parentFeed`.
     Roundtrip sweep extended over the audio folder fixtures in
     `wm_roundtrip_spec` (overlaying the REAPER-resident tree onto targetState).
   - **3b (DONE)** — read model (`21a78b7` + bus-split fix) + allocator
     (`8518249`, read-bug fix `958b81b`); see § Plan Progress. Read model: folder
     parent accepts midi edges (`midi.ins=1`); **bus-0** child midi aggregates
     into the node (`child→sid→fx`), **buses ≥1** pass through to a **direct
     `child→fx`** edge; parent emits its own take on bus 0 gated on `hasMidiTake`.
     Allocator: family = one bus domain, **one `allocStream` per family**; a
     pinned bus-0 aggregate carries merges, distinct crossings take family-unique
     buses ≥1 by live-range; singleton families unchanged. Deferred: bus-0 nudge,
     family capacity bisection (step 4).
4. **Capacity over domains** *(DONE — suite green at 1441)*: family midi over-pressure
   (shared `midiUsed > CAPACITY.midi`, 126) evicts a segment out of the family to a top-level
   track — `bisectOutOfFamily` (deep child) / `evictMember` (single-fx leaf); folder feed +
   distinct crossings become explicit sends, re-allocated outside the domain. Two guardrails
   preserve the roundtrip: a pipe consumer fx is never relocated (cut floored past the last
   consumer slot); an incoming send into a folder family is floored off bus 0. Specs:
   `dag_folder_capacity_spec`, `wm_roundtrip_spec` (127-child overflow).

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
