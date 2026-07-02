# cv-2 (working design — the unification)

> Working design doc. Supersedes the model in `cv.md`, which planned
> modulation as a *separate page* with its own graph and compiler sharing
> only wiring's realizer. This doc records the revision that came out of
> the design conversation: there is **one graph**, not two. `cv.md` is
> kept for its spike results (still valid) and the landed simple layer
> (still shipped); read `design/archive/wiring.md` for the vocabulary
> (user graph, source-set partition, targetPlan/allocate boundary,
> snapshot/diff/applier, merge CU, port band / chip promotion).

## The revision: one graph, not two

Modulation is not a separate substance, not a separate page, and not a
separate graph. It is the same audio/MIDI graph wiring already compiles,
plus **one new idea: a parameter is an input.**

The old plan named a `cvSource | processor | paramSink` taxonomy, a CC→CV
converter, a separate cv page, and a separate compiler — all parallel to
wiring. Every one of those dissolves under the principle the conversation
kept applying: *don't add a type when an existing one stretches.* What
survives is wiring's existing world — tracks, FX, audio wires, MIDI wires
— with parameters made wirable.

## CV is audio — and MIDI is a stream too

The old load-bearing decision stands: a modulation value is a sample
stream, processed by JSFX exactly as audio is, narrowing to block rate
only at the last hop. Taken to its conclusion: **audio and MIDI are both
sample-accurate streams, so we need no third "CV/CC" wire type.** The two
wire kinds wiring already has are enough.

Both wire types deliver to a parameter through the same spine (below);
the wire type chooses **authoring semantics and density**, not a
mechanism:

- a **MIDI** wire carries authored CC — sparse shaped events, REAPER's
  ~25 ms interpolation grain between shaped points (spike);
- an **audio** wire carries the **plink ceiling** — encoded at one
  14-bit value per audio block, every value a block-rate sink can
  consume. plink reads at block rate, so one CC per block is lossless
  *relative to the sink*: "CV is audio" survives as *the audio wire
  delivers everything the native link can take*. (True audio-rate
  destinations — FM — are beyond plink under any design.)

The choice is visible in the graph, and it is the escalation ladder for
zipper on slow sweeps: 7-bit code → 14-bit pair → audio wire — all on
the spine.

**No REAPER automation envelopes, anywhere.** The only native mechanism
touched is parameter-modulation *linking* (`plink`) — distinct from the
envelope/automation system. Hard constraint, unchanged from `cv.md`.

## A parameter is an input

The single new concept. Any FX node's parameters can be exposed as
**input ports** — *param pins* — in the same family as the node's
audio-in pins and its MIDI keyboard. Three input-port families now:

- **audio pins** feed the FX's audio processing;
- the **MIDI pin** feeds its events;
- a **param pin** feeds a control value to one parameter.

Wire a source to a param pin and it modulates that parameter. There is
**no `paramSink` node kind** — the sink is a pin on the target FX itself.

**Polymorphic input.** A param pin accepts an **audio _or_ a MIDI** wire
— per wire, so fan-in may mix them (each wire gets its own encoder). A
MIDI wire additionally carries a chan/CC selection (which CC its encoder
reads off the stream).

**Realization — the bus-126 spine.** All parameter modulation delivers
as CC on **bus 126** (wiring allocates buses 0–125 and parks on 127;
126 is the modulation spine). A project-scoped allocator assigns each
link a **code** — a chan × CC address on the bus, a 14-bit MSB/LSB pair
where needed; ~2k mono codes (~1k pairs) of capacity, not a practical
bound. Three steps:

- **encode** — a Continuum JSFX at the *source* turns the wire into
  code traffic. MIDI mode re-codes the authored chan/CC onto the
  allocated code; audio mode samples the pair once per block and emits
  a 14-bit value. Both emit delta-suppressed — no event while the
  quantised value holds, at offset 0 within the block (sub-block
  offsets buy nothing at a block-rate sink) — so a stationary source
  is silent and plink holds the last value (the spike's density
  finding).
- **route** — ordinary midi-only bus-126 sends carry codes to the
  destination track; delivery stays per-destination-track, since the
  code must reach the target track's own MIDI stream.
- **decode** — REAPER's **native MIDI plink** (`plink.effect = −100`)
  on the target parameter reads the code. **No minted FX on the
  destination** in the simple case: the listen bank is retired (R5).

The spike's reorder hazard attached to `plink.effect` as a same-chain
source *index*; MIDI mode has no source FX to point at, so the re-point
discipline shrinks to resolving the **target** FX by GUID when writing
link config.

**Fan-in sums on the spine.** A param pin accepts fan-in, but `plink`
is single-source-per-param, so summing happens on the wire, before
decode. Two realizations, chosen by topology at the targetPlan/allocate
boundary:

- **in-chain** — contributors serial along one track path accumulate by
  read-modify-write: each encoder consumes the upstream stream on the
  code and re-emits the sum (the add-bank kernel note-macros built);
- **cross-track** — parallel contributors' streams would *interleave*
  on a shared code (last-writer-wins per event, not addition), so each
  contributor gets its own code and a synthesised **sum node** at the
  convergence maps the contributor codes onto the target's code.

Clamp discipline is note-macros': contributions sum unclamped along the
wire; clamp once at the decode boundary, so removing one term restores
the others exactly.

## No special node kinds

- **Generators** — LFO, ADSR, envelope follower, S&H, math — are **just
  FX.** An LFO is an FX with no input; an ADSR is an FX with a gate input;
  a follower is an FX with an audio input. None earns a category or a
  palette section.
- **Sources** are REAPER tracks (audio/MIDI out), live audio/MIDI in, or
  authored CC. A source is a labelled output, nothing more.

So the entire taxonomy is wiring's: **tracks, FX, wires** — plus the param
pin on FX nodes. The `cvSource | processor | paramSink` split is gone, and
the CC→CV converter is gone from the common path (authored CC rides the
spine as CC and decodes natively). The converter survives *only* for the
rare case of running a CC through an audio-rate processor — then you
genuinely need it as audio.

The reverse — emitting modulation *as* CC — is likewise no special kind
(no `ccSink`): a thing that outputs CC is an ordinary FX with a MIDI out,
wired like any MIDI producer. On the cheap path the modulation already *is*
a MIDI wire, so there is nothing to convert.

> **Carve-out — note-scoped generators are not these FX.** note-macros'
> retrig/vibrato run in **Lua at flush**, baking sparse CC into the take,
> precisely so they survive loop/seek and offline render — the live-DSP
> generator-as-FX was considered and *rejected* there
> (`design/archive/note-macros.md` §*Why the delta is its own stream*). cv-2
> generators are graph-level and live; note generators are note-scoped and
> baked. Same word, two scopes — don't realise a note vibrato as a cv-2 LFO.

### Authored automation: the column stays inline

Performance-bound authored modulation stays **inline CC in the note
take** — exactly as the landed simple layer does it — so swing, copy/paste,
pooling, and in-grid editing come free and the data moves and dies with
the clip. The binding stays take-tier too, as a **contract** (§ *Takes
are contracts*, below); what changes is where it is *realized and read*.
The column's contract derives the graph fragment

```
[note take MIDI] ──midi(chan c / cc n)──▶ [cutoff param pin on the synth]
```

The note take carries its notes-and-CC data plus the contract; what a
CC *drives* is read in the graph, where the contract projects.
**Standing** automation (independent of any clip) is free items on a
dedicated CV track — the only case that leaves the take.

**Column labels are a general feature.** trackerView's bespoke param-
automation header migrates into a feature of *every* CC column: any column
can be relabelled with an arbitrary string. Parameter automation simply
auto-applies the parameter name as that label — so the param-first header
is no special case, just a relabelled CC column.

## Takes are contracts, not gestures

The column's fast path is **not a one-shot gesture** that mints a graph
fragment and walks away. The take carries an ongoing **contract** —
take-tier data declaring what its content feeds — and the graph
fragment is a **derived projection** of that contract, recomputed on
reconcile with provenance, like derived events under `parentUuid`. This
is the next instance of the house pattern *realisation = authored
intent + recomputable derivation* (fake-pb absorbers, PC synthesis,
note-macros' derived events); the derived-fragment lifecycle gets named
and shared, not re-improvised.

What the model buys — each a hole under pure-gesture minting:

- **Lifecycle.** Take dies → contract dies → fragment vanishes at the
  next derive; wm's standing invariant then reaps the FX. Nothing
  watches take lifecycle — the derivation pass *is* the watcher.
- **Moved clip.** The contract travels in the take, so the derived edge
  re-roots to the new track's source node automatically — binding
  semantics follow the data, as they did under the simple layer.
- **Paste.** A pasted take arrives *with* its contract; derive time
  sees two takes on one track claiming one lane and surfaces or remaps
  it, instead of the CC being silently captured by an existing tap. The
  simple layer's track-scoped lane rule — allocate dodging bound lanes,
  user columns, and event-bearing lanes across **every take on the
  track** — survives as *contract validation at derive time*, not a
  property of the authoring gesture.

Contracts scale past the column; each rung derives more structure:

- **an edge** — the column: chan/CC → param pin;
- **edges + a split** — per-channel instrument allocation: a take's 16
  channels each routed to a different instrument;
- **nodes** — duplicate a monosynth per channel: 16 derived instances
  of a prototype the user placed once.

The boundary that keeps this sane: contracts derive **user-graph-level
structure** — edges, splits, clones; things the user could have drawn —
while the targetPlan/allocate boundary keeps minting
**realization-level** nodes (encoders, sums, CUs; things the user never
sees). Same graph, two derivation layers; a derived edge is an ordinary
edge once minted, so the partition and connectivity-inertness stories
apply unchanged. Derived fragments render in the graph — collisions
visible, never managed behind your back — but are owned by their
contracts.

## Filtering: a node by default, one sanctioned tickbox

A param pin **taps** its MIDI source — it does not remove the CC. Split is
free, so the synth on the same wire still sees the CC. Collisions are thus
*visible*, not managed behind your back.

**Strip = a filter node** on the specific downstream edge (removes CC _n_
from *that* branch only — strips for that consumer, not others). Visible,
topological, removable. This is the same principle that killed the CC wire
and the strip-on-sink toggle: *transforming a stream is a node's job,
never a wire's and never a side-effect on another node.*

**The one allowed tickbox.** When a node A feeds B with *both* a MIDI wire
and a param link reading a CC off it (A→B and A→B — same endpoints), offer
a **"strip this CC from the parallel wire"** tickbox on the param link's
inspector row. It is legitimate *because* config, effect, and consumer are
all the one A→B relationship — no third node, no free parameter (the CC is
fixed by the link), scoped to that one wire (not A's other MIDI wires). It
is defined as **exactly** a filter node on that edge; if it ever needs
more (a range, several CCs, a different destination) it **explodes into an
explicit filter node**. The canvas marks the wire filtered; the inspector
holds the detail. This case arises naturally from the column: note take →
synth (notes) plus note take → synth.cutoff (CC _n_) *is* a parallel A→B.

> The rule for when a tickbox is ever acceptable: config, effect, and
> consumer must share the same edge. A strip configured on a sink but
> affecting a different node fails this and stays a node.

## The palette

Two regions, by role:

- **Spawn region (selection-independent, always shown)** — things you drag
  in to create nodes: **source tracks** (kept exactly as today) + the
  **ordinary add-FX** affordance. Generators are FX, so they live here
  with everything else — no special section.
- **Inspector region (selection-driven)** — the **selected FX node's
  parameters**:
  - a **checkbox** promotes a param to an input pin on the node (then it
    is wired like any input port);
  - **active (linked) params sort to the top**;
  - a checked row **expands** to its link config —
    `source: audio | midi+chan/cc · scale · offset · invert`;
  - default view shows the params that are *already* linked, not all of a
    300-param plugin; **search / learn** (reused from the tracker palette)
    finds the rest.

  Param **promotion is by checkbox here**, unlike audio ports which
  promote on-wire — a deliberate divergence justified by discovery: audio
  ports are a bounded set wired on the canvas; params are a huge set
  curated in the palette first. Once checked, a param pin behaves like any
  input port.

- **Right-click a param → add a first-party generator and wire it.**
  `Add LFO / ADSR / envelope …` mints the Continuum generator, promotes
  the pin, and lays the wire in one action. This is **curation of known
  FX, not a node category** — Continuum knows the shape of its own
  generators, so it can auto-wire them; a third-party LFO is added the
  ordinary FX way. An LFO completes in one click (free-running); an ADSR
  (gate) or follower (audio in) still needs its own input wired — shown
  honestly in the menu rather than auto-defaulted (which would be the
  sideways binding we forbid).

**Two doors, one graph.** The wiring palette and the tracker's cone-walk
palette both mint into the same graph — routing context vs musical
context. Both consume wiringManager's existing param-target walk
(`wm_param_targets`); the listing and learn are already shared code. The
wiring palette uses a narrower slice: the selected node *is* the target,
so there is no cone to walk.

## Surfacing: canvas is topology, inspector is config

The link carries more config (scale, offset, chan/CC, invert) than fits in
a wire's pixels. So none of it goes on the canvas.

- **Distinguish at the port, not the wire.** A param pin renders unlike an
  audio pin or the MIDI keyboard — so a wire landing on it reads as a
  modulation link, not signal-into-processing. The wire itself stays an
  ordinary audio/MIDI wire (that is what lets either type feed a param
  pin). A filtered parallel wire gets a small "filtered" marker.
- **Config lives in the inspector's expanded row.** Selecting a link's
  wire or its port focuses that same row. MIDI/audio shows up only as
  which fields the row offers (chan/CC for MIDI, gone for audio).

## Relationship to wiring: a shared graph, not just a shared realizer

`cv.md` shared only the realizer beneath the `targetTracks` seam and kept
two compilers above it. This design shares the **graph and the compiler
too.** One compiler, extended with:

- the **param pin** as a new input-port family on FX nodes;
- a **`setParamLink`** op in the shared op vocabulary, writing native
  MIDI-plink config;
- the spine's **code allocator** beside channel/bus allocation, and the
  encoder, sum, and filter as synthesised nodes minted at the
  targetPlan/allocate boundary (like the merge CU and brackets).

**Param edges are connectivity-inert.** A wire into a param pin
realizes as code traffic on the spine — a bus-126 send plus a
source-side JSFX — never as audio pairs or a 0–125 bus. It contributes
nothing to `srcSet`, so modulation never perturbs the partition (two
synths sharing a track, modulated from different tracks, stay on one
track), and its capacity is code space on the spine, not the
64-pair/128-bus budget.

The cleanup hypothesis from `cv.md` still applies: master-feed and a param
pin are both "what happens at a leaf"; if master-feed normalises to an
out-wire, wiring's terminal special-casing dissolves and the param pin is
just another leaf.

## What changes vs the landed simple layer

The simple layer (landed 2026-06-10: `paramAutomation` store, the
`Continuum CC` filter+listen banks, bus 126, the cone-walk palette) shipped
**standalone**, before any graph. Under "everything builds in the graph"
it gets **re-founded**, not extended:

- the binding stays take-tier but becomes a **contract**, projected into
  the graph as a derived fragment (§ *Takes are contracts*); the
  standalone `paramAutomation` store-plus-applier dies — realization
  belongs to the one compiler;
- the `Continuum CC` **listen bank is retired** — decode is native MIDI
  plink (R5). The filter bank splits along its two jobs: the re-code
  half is the **encoder** (the realization of a MIDI wire into a param
  pin), the strip half the opt-in **filter node** — tap, not strip, is
  the graph default;
- bus 126 is promoted from the simple layer's private lane to the
  **spine**: all param modulation, MIDI- or audio-sourced, delivers as
  coded CC on it under one project-scoped code allocator (the simple
  layer's busCode allocator, formalized);
- the per-track node's **lifecycle owner** — `ccManager` (`ccm`), whose
  claims registry ref-counts producers so the node lives iff one claims it —
  **dissolves**: a derived edge *is* the claim, the derive pass reaps it
  when its contract dies, and wm's standing invariant — *delete an FX
  only when its owning node leaves the graph* (`wiringManager.lua:7`) —
  reaps the FX for free. `ccm` is **deleted, not folded**; its
  claim/release body is the derive pass plus code wm already runs.

Pre-beta, no legacy data — this is a re-founding, not a compat layer. The
column's inline-CC-in-the-note-take *data* is unchanged; only its binding
and realization move into the graph.

**The add bank (from note-macros).** note-macros added a third bank to
`Continuum CC` — a sum verb, `out = base + delta`, the additive merge
`plink` cannot express (single-source-per-param). Built there as a
self-contained sum kernel keyed by src/dst sliders, it lifts under this
re-founding into the synthesised **sum node** — the fan-in convergence
above — minted at the targetPlan/allocate boundary like the merge CU
and the filter node. **R5 (plink-via-MIDI, listen-bank retirement) is
owned here, not by note-macros** — note-macros deferred it so its add
bank landed beside the untouched listen bank; this re-founding's decode
step *is* R5.

## Spike results (from `cv.md`, still valid)

All green; architecture stands (2026-06-10, `tests/spike_cv.lua` +
`cv/*.jsfx`):

- `plink` same-track-only at API-shape level (`param.X.plink.*` has no
  track addressing; `effect` = same-chain index, −100 = MIDI). Per-
  destination adapters stand.
- both legs live and responsive by ear: a MIDI source feeding a slider →
  plink, and a CC take FX → send → adapter → plink. A plink source later
  in the chain than its target works.
- a JSFX slider assigned in `@block` is a valid plink source; no
  `slider_automate` needed.
- strip: a designated lane is fully consumed; bank select, other CC, and
  notes pass untouched.
- density: the MIDI stream is sample-accurate (events carry sample
  offsets); ~25 ms is REAPER's **CC interpolation step** between shaped
  points, not a stream-timing limit. Constant-value spans emit nothing
  (plink holds the last value).
- reorder: REAPER's plink remap is unreliable — treat `plink.effect` as
  index-keyed, store bindings by FX GUID, re-point on every reconcile.

**The plink-via-MIDI leg — green** (2026-07-02,
`tests/spikes/spike_cv2_plink.lua` + `cv/cv2_*.jsfx`). Every question
the spine hung on decode resolved in the design's favour:

- **native decode, end to end.** A midi-only send on bus 126 into a
  track whose target FX carries `plink.effect = −100` drives the param —
  no minted FX on the destination. REAPER's config for a 14-bit CC link:
  `midi_msg = 0xB0`, `midi_chan = 0`, `midi_bus = 126` (0-based — the
  JSFX `midi_bus` value directly, no `+1`), `midi_msg2 = cc | 0x80`.
  **Bit 7 of `midi_msg2` is the 14-bit flag**; low 7 bits are the MSB
  CC, the LSB rides `cc + 32`. Plain 7-bit is identical with bit 7
  clear. `setParamLink` writes exactly these keys.
- **14-bit resolution reads.** The cross-track poll saw a min step of
  1/16384, not 1/128 — the LSB is consumed, so the ladder's top rung
  delivers full pair precision natively.
- **plink reads the chain MIDI stream at the FX's position**, not the
  track's raw input. Load-bearing, and better than hoped: the whole
  ladder composes in chain order on one track — encoder upstream →
  optional filter node → plink on the target — so an upstream node truly
  shields or rewrites what the plink sees. A chain-head strip made the
  param go dead; the filter node (§ *Filtering*) works by construction.
- **both fan-in realizations viable.** A cross-track send into the chain
  head reached a mid-chain plink (cross-track sum), and an encoder
  upstream in the *same* chain reached a downstream plink (in-chain
  sum) — both at 14-bit resolution.
- **hold across transport.** Through seeks while stopped the param held
  its last value on a silent (delta-suppressed) wire. At play-start it
  took a fresh value equal to the *encoder's* base, not the plink
  baseline of 0 — the encoder re-asserted (its phase reset), plink never
  dropped its hold. Encoders that reset state re-emit at play-start for
  free; one that doesn't leaves plink holding, which the seek test
  proved safe. No stale-to-baseline failure appeared.

## Phases (revised order)

`cv.md` put the simple layer first because it had no realizer dependency.
"Everything builds in the graph" inverts that: the graph and realizer must
exist before the front-end can mint into them.

1. **Spike** — done (`cv.md`; plink-via-MIDI leg `spike_cv2_plink.lua`,
   § *Spike results*).
2. **Simple layer** — done, standalone; to be re-founded on the graph (above).
3. **Wiring refactor → shared realizer.** Unblocked — the plink-via-MIDI
   spike leg is green (above). Extract the realizer beneath the
   `targetTracks` seam; add `setParamLink` (native MIDI-plink config:
   `effect = −100`, `midi_bus`, `midi_msg2 = cc | 0x80` for 14-bit); add
   the param-pin terminal — spine code allocation, encoder/sum/filter
   synthesis. Wiring behaviour unchanged, its specs stay green.
   The bulk of the risk; lands and is verified first.
4. **Unified graph front-end.** Param pins on FX nodes; the palette
   inspector (checkbox promote, active-sorted, expand-for-config) and
   right-click generator shortcuts; the filter node and the
   parallel-wire tickbox; re-found the simple layer on the graph via
   the take-contract derive pass.

## Open questions / risks

- **One page or two lenses.** The *model* is one graph. Whether the wiring
  page is the sole editor with the tracker palette as a second door, or
  the graph is presented through two filtered lenses (audio-emphasis /
  modulation-emphasis), is a UX call left open.
- **Derived-node identity and state.** The ×16 case derives FX
  *instances*, which need stable identity (take + channel) so reconcile
  never thrashes plugin state — and an owner for that state. The natural
  shape is a user-placed **prototype** whose clones share its state;
  whether clones may diverge (per-channel tweaks) decides whether a
  derived fragment is pure projection or carries persisted residue.
  Decide before the first node-deriving contract.
- **Write-back rule for derived fragments.** They render in the graph;
  who edits them? Read-only with a go-to-the-owning-take affordance, or
  graph gestures that write *through* to the contract — two-doors says
  write-through, but that demands round-trip discipline: an edit on the
  realisation must be expressible in the contract's vocabulary or
  refused.
- **Derive churn.** Every take edit potentially re-derives graph →
  recompile → diff. The differ already no-ops clean, but the derive pass
  wants content-keying (a contract hash per take) so a note edit that
  never touches the contract never wakes the compiler.
- **Cross-track alignment under the spread topology.** With decode gone
  native, no Continuum FX sits on destinations — but modulation still
  crosses tracks as sends, and the audible risk is *relative* alignment,
  not lag per se: a constant offset is invisible on an LFO and audible on
  an envelope follower running against its own source. If misalignment is
  audible, it resurrects `cv.md`'s "central host" argument as a *hosting
  heuristic* (concentrate encoders/sums onto fewer tracks) — never as a
  separate page.
- **ADSR / follower default wiring.** Their own input (gate / audio) is a
  wire the user draws; confirm by use whether a sensible default is worth
  the action-at-a-distance cost (current answer: no).
- **`ccSink` mechanics** — writing 14-bit CC back into a lane from a graph
  terminal; lowest-priority sink, sketched not designed.
