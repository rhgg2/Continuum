# modulation — a parameter is an input

> opened: 2026-08-28 · status: working design. The spike is done and the
> standalone automation layer is landed; the graph work is not started.
> Read `docs/wiring.md`, `docs/wiringManager.md` and `docs/DAG.md` for
> the vocabulary — user graph, source-set partition, targetTracks/allocate
> boundary, snapshot/diff/apply, merge CU, port band, chip promotion.

**Modulation is not a separate substance, not a separate page and not a
separate graph. It is the audio/MIDI graph wiring already compiles, plus
one new idea: a parameter is an input. Every modulation link delivers as
coded CC on bus 126 and decodes natively at the target, so the graph
gains an input-port family and an allocator, and nothing else.**

## A parameter is an input

1. Any FX node's parameters can be exposed as **input ports** — **param
   pins** — in the same family as the node's audio-in pins and its MIDI
   pin. Wire a source to a param pin and it modulates that parameter.
   There is no sink node kind; the sink is a pin on the target FX.

1. A param pin is **polymorphic**: it accepts an audio wire or a MIDI
   wire, per wire, so fan-in may mix them. A MIDI wire additionally
   carries a chan/CC selection, naming which CC its encoder reads off
   the stream.

1. **Param edges are connectivity-inert.** A wire into a param pin
   realizes as code traffic on the spine — a bus-126 send plus a
   source-side JSFX — never as audio pairs or a 0–125 bus. It
   contributes nothing to `srcSet`, so modulation never perturbs the
   partition, and its capacity is code space on the spine rather than
   the 64-pair / 128-bus budget.

## Two wire types, no third

1. A modulation value is a sample stream, processed by JSFX exactly as
   audio is, narrowing to block rate only at the last hop. Audio and
   MIDI are both sample-accurate streams, so no third CV wire type is
   needed; wiring's two are enough.

1. The wire type chooses authoring semantics and density, not mechanism.
   A **MIDI** wire carries authored CC — sparse shaped events, with
   REAPER interpolating between shaped points at a ~25 ms step. An
   **audio** wire carries the **plink ceiling** — one 14-bit value per
   audio block, encoded at the source.

1. `plink` reads at block rate, so one value per block is lossless
   relative to the sink: the audio wire delivers everything the native
   link can take. True audio-rate destinations, such as FM, are beyond
   `plink` under any design.

1. The choice is visible in the graph, and it is the escalation ladder
   for zipper on slow sweeps: 7-bit code, then 14-bit pair, then audio
   wire — all on the one spine.

## The bus-126 spine

1. All parameter modulation delivers as CC on **bus 126**. Wiring
   allocates buses 0–125 and parks brackets on 127 (`DAG.lua`
   `CAPACITY`, `PARK_BUS`), so 126 is modulation's.

1. A project-scoped allocator assigns each link a **code** — a chan × CC
   address on the bus, a 14-bit MSB/LSB pair where the resolution is
   wanted. That is roughly 2k mono codes or 1k pairs, which is not a
   practical bound.

1. **Encode.** A Continuum JSFX at the source turns the wire into code
   traffic. MIDI mode re-codes the authored chan/CC onto the allocated
   code; audio mode samples the pair once per block and emits a 14-bit
   value. Both emit delta-suppressed, at offset 0 within the block —
   sub-block offsets buy nothing at a block-rate sink — so a stationary
   source is silent and `plink` holds its last value.

1. **Route.** Ordinary midi-only bus-126 sends carry codes to the
   destination track. Delivery is per destination track, since the code
   must reach the target's own MIDI stream.

1. **Decode.** REAPER's native MIDI plink (`plink.effect = −100`) on the
   target parameter reads the code. No Continuum FX sits on the
   destination.

1. **Not ACS.** `param.X.acs.*` drives a parameter straight from
   sidechain audio with no encoder, but it is an envelope follower —
   attack, release, dblo, dbhi — reading audio as loudness rather than
   as a bipolar value, so it mangles a modulation signal. Encode and
   decode is the correct path.

1. The spike's reorder hazard attached to `plink.effect` as a same-chain
   source *index*. MIDI mode has no source FX to point at, so the
   re-point discipline shrinks to resolving the **target** FX by GUID
   when writing link config.

## Fan-in sums on the spine

1. A param pin accepts fan-in, but `plink` takes a single source per
   param, so summing happens on the wire, before decode. Topology
   chooses the realization at the targetTracks/allocate boundary.

1. **In-chain** — contributors serial along one track path accumulate by
   read-modify-write: each encoder consumes the upstream stream on the
   code and re-emits the sum.

1. **Cross-track** — parallel contributors' streams would interleave on
   a shared code, the last writer winning per event rather than adding.
   So each contributor takes its own code, and a synthesised **sum
   node** at the convergence maps the contributor codes onto the
   target's.

1. Contributions sum unclamped along the wire and clamp once at the
   decode boundary, so removing one term restores the others exactly.

## No special node kinds

1. **Generators are just FX.** An LFO is an FX with no input, an ADSR an
   FX with a gate input, an envelope follower an FX with an audio input.
   None earns a category, a taxonomy slot, or a palette section.

1. **Sources** are REAPER tracks, live audio or MIDI in, or authored CC.
   A source is a labelled output and nothing more.

1. Emitting modulation *as* CC is likewise no special kind: a thing that
   outputs CC is an ordinary FX with a MIDI out, wired like any MIDI
   producer. On the cheap path the modulation already is a MIDI wire, so
   there is nothing to convert.

1. A CC-to-audio converter survives only for running authored CC through
   an audio-rate processor, where it genuinely must become audio. It is
   off the common path.

1. **Carve-out: note-scoped generators are not these FX.** note-macros'
   retrig and vibrato run in Lua at flush, baking sparse CC into the
   take, precisely so they survive loop, seek and offline render
   (`docs/generators.md`). Graph generators are graph-scoped and live;
   note generators are note-scoped and baked. Same word, two scopes —
   a note vibrato is not realised as a graph LFO.

## Bindings are contracts

1. A binding is not a one-shot gesture that mints a graph fragment and
   walks away. It is a standing **contract** — stored data declaring
   what a track's content feeds — and the graph fragment is a **derived
   projection** of it, recomputed on reconcile and marked with
   provenance the way derived events carry `derived`.

1. This is the next instance of the house pattern *realisation =
   authored intent + recomputable derivation*, after the fake-pb
   absorbers, PC synthesis and the note-macro generators. The
   derived-fragment lifecycle gets named and shared rather than
   re-improvised.

1. Lifecycle falls out of the derivation. A contract dies, so its
   fragment vanishes at the next derive, and wm's standing invariant —
   delete an FX only when its owning node leaves the graph — reaps the
   FX. Nothing watches lifecycle; the derive pass is the watcher.

1. The contract is the **track's**, matching where the binding already
   lives: the code, the encoder and the `plink` are all per track, and a
   take-tier contract lets two takes on one track mint rival codes for
   one parameter (`design/decisions.md`, 2026-08-25). A take moved to
   another track therefore leaves its binding behind, and a pasted
   take's CC means whatever the destination track binds on that lane.

1. Contracts scale past the column, each rung deriving more structure:
   - an **edge** — the column: chan/CC to a param pin;
   - **edges and a split** — per-channel instrument allocation, a
     channel routed to its own instrument;
   - **nodes** — a monosynth duplicated per channel, sixteen derived
     instances of a prototype placed once.

1. The boundary that keeps this sane: contracts derive **user-graph
   structure** — edges, splits, clones, things the user could have drawn
   — while the targetTracks/allocate boundary keeps minting
   **realization** nodes — encoders, sums, filters, CUs, things the user
   never sees. A derived edge is an ordinary edge once minted, so the
   partition and connectivity-inertness stories apply unchanged. Derived
   fragments render in the graph, so collisions are visible, but they
   are owned by their contracts.

## Authored automation stays inline

1. Performance-bound authored modulation stays **inline CC in the note
   take**, as the landed layer does it, so swing, copy and paste,
   pooling and in-grid editing come free, and the data moves and dies
   with the clip.

1. **Data location encodes origin and lifetime; the graph encodes
   destination.** The take carries its notes and CC; what a CC drives is
   read in the graph, where its contract projects.

1. **Standing** automation — positioned in arrangement time,
   independent of any clip — is free items on a dedicated CV track. It
   is the only case that leaves the take.

1. **Column labels become a general feature.** trackerView's bespoke
   param-automation header migrates into a feature of every CC column:
   any column takes an arbitrary label string. Parameter automation
   applies the parameter's name as that label, so the param-first header
   is a relabelled CC column rather than a branch in `gridPane`.

## Filtering: a node by default, one sanctioned tickbox

1. A param pin **taps** its MIDI source and does not remove the CC.
   Split is free, so the synth on the same wire still sees the CC, and
   collisions are visible rather than managed behind the user's back.

1. **Strip is a filter node** on a specific downstream edge, removing CC
   *n* from that branch only. It is visible, topological and removable.
   The principle: transforming a stream is a node's job, never a wire's
   and never a side-effect on another node.

1. **The one allowed tickbox.** When a node A feeds B with both a MIDI
   wire and a param link reading a CC off it — the same endpoints twice
   — the param link's inspector row offers a *strip this CC from the
   parallel wire* tickbox. It is legitimate because config, effect and
   consumer are all the one A→B relationship: no third node, no free
   parameter, and it is scoped to that one wire rather than to A's other
   MIDI wires. It is defined as exactly a filter node on that edge, and
   if it ever needs more — a range, several CCs, a different destination
   — it explodes into an explicit filter node. The canvas marks the wire
   filtered; the inspector holds the detail.

1. The case arises naturally from the column, where note take → synth
   for the notes and note take → synth.cutoff for CC *n* are a parallel
   A→B.

1. The general rule for when a tickbox is acceptable: config, effect and
   consumer must share the same edge. A strip configured on a sink but
   affecting a different node fails this and stays a node.

## The palette

1. The **spawn region** is selection-independent and always shown:
   source tracks, kept exactly as today, plus the ordinary add-FX
   affordance. Generators are FX, so they live here with everything else.

1. The **inspector region** is selection-driven, and holds the selected
   FX node's parameters. A checkbox promotes a parameter to an input
   pin, after which it is wired like any input port; linked parameters
   sort to the top; a checked row expands to its link config — source
   (audio, or MIDI with chan and CC), scale, offset, invert.

1. The default view shows the parameters already linked, not all of a
   300-parameter plugin. Search and learn, reused from the tracker
   palette, find the rest.

1. Param promotion is by checkbox here, unlike audio ports which promote
   on-wire. The divergence is justified by discovery: audio ports are a
   bounded set wired on the canvas, while parameters are a huge set
   curated in the palette first.

1. **Right-click a parameter to add a first-party generator and wire
   it.** *Add LFO / ADSR / envelope* mints the Continuum generator,
   promotes the pin and lays the wire in one action. This is curation of
   known FX, not a node category: Continuum knows the shape of its own
   generators, so it can auto-wire them, while a third-party LFO is
   added the ordinary FX way. An LFO completes in one click; an ADSR or
   a follower still needs its own input wired, shown honestly in the
   menu rather than defaulted into the sideways binding the design
   forbids.

1. **Two doors, one graph.** The wiring palette and the tracker's
   cone-walk palette both mint into the same graph — routing context
   against musical context. Both consume `wm_param_targets`, and the
   listing and learn are already shared code. The wiring palette uses a
   narrower slice, since the selected node is the target and there is no
   cone to walk.

## Surfacing: canvas is topology, inspector is config

1. The link carries more config — scale, offset, chan and CC, invert —
   than fits in a wire's pixels, so none of it goes on the canvas.

1. **Distinguish at the port, not the wire.** A param pin renders unlike
   an audio pin or the MIDI keyboard, so a wire landing on it reads as a
   modulation link rather than signal into processing. The wire itself
   stays an ordinary audio or MIDI wire, which is what lets either type
   feed a param pin. A filtered parallel wire gets a small marker.

1. **Config lives in the inspector's expanded row.** Selecting a link's
   wire or its port focuses that same row. Audio against MIDI shows up
   only as which fields the row offers.

## What this shares with wiring

1. One graph and one compiler, extended with the param pin as an
   input-port family; a **`setParamLink`** op writing native MIDI-plink
   config; the spine's code allocator beside channel and bus allocation;
   and the encoder, sum and filter as synthesised nodes minted at the
   targetTracks/allocate boundary, like the merge CU and the brackets.

1. Compile, diff and apply currently all live in `wiringManager`, over
   an eight-op full-replace vocabulary (`createTrack`, `deleteTrack`,
   `setFXChain`, `setMainSend`, `setSends`, `setNchan`, `setPinMaps`,
   `moveFxAcrossTracks`). Extracting a graph-agnostic realizer beneath
   the `targetTracks` seam is the bulk of the work and the bulk of the
   risk; it pays for itself in wiring regardless of modulation.

1. The cleanup hypothesis: master-feed and a param pin are both *what
   happens at a leaf*. If master-feed normalises to an out-wire into the
   master's input pair, wiring's terminal special-casing dissolves and
   the param pin is just another leaf. Test it during the refactor
   rather than pre-committing to it.

## What changes against the landed layer

The automation layer landed standalone in 2026-06, before any graph, and
went track-tier in 2026-08: the `paramAutomation` store and applier, the
`Ctm CC` filter and listen banks, bus 126, `ccManager`'s claims
registry, and the cone-walk palette. Under one graph it is re-founded,
not extended.

1. The binding stays a stored track-tier fact but becomes a contract,
   projected into the graph as a derived fragment. The standalone
   `paramAutomation` store-plus-applier dies, because realization
   belongs to the one compiler.

1. The **listen bank is retired**: decode is native MIDI plink. The
   filter bank splits along its two jobs — the re-code half becomes the
   encoder, the strip half the opt-in filter node — and tap, not strip,
   is the graph default.

1. `pa:setPlink` writes `plink.effect` as the CC node's same-chain
   index. That becomes `−100` with the MIDI keys the spike pinned,
   written by the shared `setParamLink` op.

1. Bus 126 is promoted from the layer's private lane to the **spine**:
   all param modulation, MIDI- or audio-sourced, delivers as coded CC on
   it under one project-scoped code allocator — the `busCode` allocator,
   formalized.

1. **`ccManager` dissolves.** Its claims registry ref-counts producers
   so the node lives iff one claims it; under the graph, a derived edge
   *is* the claim, the derive pass reaps it when its contract dies, and
   wm's standing invariant reaps the FX for free. `ccm` is deleted, not
   folded — only `pa` ever claimed it.

1. The **sum node is new code**. `Ctm CC`'s add bank was retired
   in 2026-07 when note-macro summation moved offline into the
   park-and-seat, so there is no kernel left to lift; only its clamp
   discipline carries over.

Pre-beta, no legacy data — this is a re-founding rather than a compat
layer. The inline CC in the note take is unchanged; only its binding and
realization move into the graph.

## Spike results

All green, so the architecture stands.

**The adapter leg** (2026-06-10, `tests/spikes/spike_cv.lua` with
`tests/spikes/cv/*.jsfx`):

- `plink` is same-track-only at API-shape level: `param.X.plink.*` has
  no track addressing, `effect` is a same-chain index, and −100 is MIDI.
- both legs are live and responsive by ear: a MIDI source feeding a
  slider into `plink`, and a CC take FX through a send to an adapter and
  `plink`. A `plink` source later in the chain than its target works.
- a JSFX slider assigned in `@block` is a valid `plink` source; no
  `slider_automate` is needed.
- strip: a designated lane is fully consumed, while bank select, other
  CC and notes pass untouched.
- density: the MIDI stream is sample-accurate, since events carry sample
  offsets, and ~25 ms is REAPER's CC interpolation step between shaped
  points rather than a stream-timing limit. Constant-value spans emit
  nothing, and `plink` holds the last value.
- reorder: REAPER's `plink` remap is unreliable — it followed one move,
  then read stale after the reverse, leaving the link on the wrong FX.
  Treat `plink.effect` as index-keyed, store bindings by FX GUID, and
  re-point on every reconcile.

**The plink-via-MIDI leg** (2026-07-02,
`tests/spikes/spike_cv2_plink.lua` with `tests/spikes/cv/cv2_*.jsfx`).
Every question the spine hung on decode resolved in the design's favour:

- **native decode, end to end.** A midi-only send on bus 126 into a
  track whose target FX carries `plink.effect = −100` drives the
  parameter, with no minted FX on the destination. REAPER's config for a
  14-bit CC link is `midi_msg = 0xB0`, `midi_chan = 0`, `midi_bus = 126`
  (0-based — the JSFX `midi_bus` value directly, no `+1`), and
  `midi_msg2 = cc | 0x80`. Bit 7 of `midi_msg2` is the 14-bit flag, the
  low seven bits are the MSB CC, and the LSB rides `cc + 32`; plain
  7-bit is identical with bit 7 clear. `setParamLink` writes exactly
  these keys.
- **14-bit resolution reads.** The cross-track poll saw a minimum step
  of 1/16384 rather than 1/128, so the LSB is consumed and the ladder's
  top rung delivers full pair precision natively.
- **`plink` reads the chain MIDI stream at the FX's position**, not the
  track's raw input. This is load-bearing and better than hoped: the
  whole ladder composes in chain order on one track — encoder upstream,
  optional filter node, `plink` on the target — so an upstream node
  truly shields or rewrites what the `plink` sees. A chain-head strip
  made the parameter go dead, so the filter node works by construction.
- **both fan-in realizations are viable.** A cross-track send into the
  chain head reached a mid-chain `plink`, and an encoder upstream in the
  same chain reached a downstream `plink` — both at 14-bit resolution.
- **hold across transport.** Through seeks while stopped the parameter
  held its last value on a silent wire. At play-start it took a fresh
  value equal to the encoder's base rather than the `plink` baseline of
  0: the encoder re-asserted as its phase reset, and `plink` never
  dropped its hold. An encoder that resets state re-emits at play-start
  for free, and one that does not leaves `plink` holding, which the seek
  test proved safe.

## Phases

1. **Spike** — done, both legs.

1. **Automation layer** — done, standalone; to be re-founded on the
   graph.

1. **Wiring refactor to a shared realizer.** Extract the realizer
   beneath the `targetTracks` seam; add `setParamLink` writing native
   MIDI-plink config; add the param-pin terminal, with spine code
   allocation and encoder, sum and filter synthesis. Wiring behaviour is
   unchanged and its specs stay green. This is the bulk of the risk, so
   it lands and is verified first.

1. **Unified graph front-end.** Param pins on FX nodes; the palette
   inspector, with checkbox promotion, active-sorted rows and
   expand-for-config; the right-click generator shortcuts; the filter
   node and the parallel-wire tickbox; and the re-founding of the
   automation layer on the graph via the contract derive pass.

## Open

- **One page or two lenses.** The model is one graph. Whether the wiring
  page is the sole editor with the tracker palette as a second door, or
  the graph is presented through two filtered lenses — audio-emphasis
  and modulation-emphasis — is a UX call left open.

- **Whether any contract wants to be take-tier.** Track tier is right
  for the column, and it is what landed. The per-channel-instrument and
  clone rungs are also track-shaped, but a contract that genuinely
  belongs to one clip — travelling with a moved or pasted take — has no
  home under the current tier, and would need a second carrier.

- **Derived-node identity and state.** The ×16 case derives FX
  *instances*, which need stable identity so reconcile never thrashes
  plugin state, and an owner for that state. The natural shape is a
  user-placed **prototype** whose clones share its state; whether clones
  may diverge decides whether a derived fragment is pure projection or
  carries persisted residue. Decide before the first node-deriving
  contract.

- **Write-back rule for derived fragments.** They render in the graph,
  so who edits them? Read-only with a go-to-the-owner affordance, or
  graph gestures that write through to the contract. Two doors argues
  for write-through, but that demands round-trip discipline: an edit on
  the realisation must be expressible in the contract's vocabulary or
  refused.

- **Derive churn.** Every take edit potentially re-derives the graph,
  recompiles and diffs. The differ already no-ops clean, but the derive
  pass wants content-keying — a contract hash per track — so a note edit
  that never touches a contract never wakes the compiler.

- **Cross-track alignment under the spread topology.** With decode gone
  native, no Continuum FX sits on destinations, but modulation still
  crosses tracks as sends. The audible risk is *relative* alignment
  rather than lag: a constant offset is invisible on an LFO and audible
  on an envelope follower running against its own source. If
  misalignment is audible, it revives the central-host argument as a
  hosting heuristic — concentrate encoders and sums onto fewer tracks —
  never as a separate page.

- **ADSR and follower default wiring.** Their own input, a gate or
  audio, is a wire the user draws. Confirm by use whether a sensible
  default is worth the action-at-a-distance cost; the current answer is
  no.

- **CC out as a terminal.** Writing 14-bit CC back into a lane from a
  graph terminal is sketched, not designed. Lowest priority.
