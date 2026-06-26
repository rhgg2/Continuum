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

The block-rate-vs-audio-rate question is therefore **not** a hidden
allocator heuristic — it is *which wire type you plug into a parameter*:

- a **MIDI** wire carries 7-bit (or a 14-bit MSB/LSB pair) CC — cheap,
  coarse, the authored/slow path;
- an **audio** wire carries full resolution — fine, fast, audio-rate FM.

The choice is visible in the graph. The cheap case (a MIDI wire into a
param) realizes to exactly the landed simple layer's mechanism (below).

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

**Polymorphic input.** A param pin accepts an **audio _or_ a MIDI** wire;
the mode follows whichever you plug in. A MIDI wire additionally carries a
chan/CC selection (the param pin reads that one CC off the stream).

**Realization (per the spike, all green in `cv.md`).** A param pin
compiles to a **single adapter JSFX on the destination track** plus a
native `plink` from the adapter's slider to the target parameter. The
adapter has two source modes:

- **MIDI mode** — read chan _c_ / CC _n_ (14-bit optional), expose as a
  slider. This *is* the simple layer's listen bank.
- **audio mode** — read an audio pair, expose as a slider. This *is*
  `cv.md`'s CV→slider adapter.

One adapter subsumes both. `plink` is same-track-only (spike), so the
adapter is necessarily per-destination-track; the graph routes the source
to that track (as audio or MIDI) and the local adapter links the local
param. `plink.effect` is index-keyed and REAPER's remap is unreliable
(spike) — store bindings by FX **GUID** and re-point on every reconcile.

## No special node kinds

- **Generators** — LFO, ADSR, envelope follower, S&H, math — are **just
  FX.** An LFO is an FX with no input; an ADSR is an FX with a gate input;
  a follower is an FX with an audio input. None earns a category or a
  palette section.
- **Sources** are REAPER tracks (audio/MIDI out), live audio/MIDI in, or
  authored CC. A source is a labelled output, nothing more.

So the entire taxonomy is wiring's: **tracks, FX, wires** — plus the param
pin on FX nodes. The `cvSource | processor | paramSink` split is gone, and
the CC→CV converter is gone from the common path (a param pin reads MIDI
directly). The converter survives *only* for the rare case of running a CC
through an audio-rate processor — then you genuinely need it as audio.

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
the clip. What changes: the **binding** no longer lives in the take; it
lives in the graph. The column auto-builds the graph fragment

```
[note take MIDI] ──midi(chan c / cc n)──▶ [cutoff param pin on the synth]
```

The note take carries only notes-and-CC data; what that CC *drives* is
read in the graph. **Standing** automation (independent of any clip) is
free items on a dedicated CV track — the only case that leaves the take.

**Column labels are a general feature.** trackerView's bespoke param-
automation header migrates into a feature of *every* CC column: any column
can be relabelled with an arbitrary string. Parameter automation simply
auto-applies the parameter name as that label — so the param-first header
is no special case, just a relabelled CC column.

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
- a **`setParamLink`** op in the shared op vocabulary for `plink`;
- the adapter and filter as synthesised nodes minted at the
  targetPlan/allocate boundary (like the merge CU and brackets).

The cleanup hypothesis from `cv.md` still applies: master-feed and a param
pin are both "what happens at a leaf"; if master-feed normalises to an
out-wire, wiring's terminal special-casing dissolves and the param pin is
just another leaf.

## What changes vs the landed simple layer

The simple layer (landed 2026-06-10: `paramAutomation` store, the
`Continuum CC` filter+listen banks, bus 126, the cone-walk palette) shipped
**standalone**, before any graph. Under "everything builds in the graph"
it gets **re-founded**, not extended:

- the binding moves into the graph (a param pin), out of the
  `paramAutomation` cm store;
- the `Continuum CC` listen bank becomes the **adapter realization** of a
  param pin (MIDI mode); the filter bank becomes a **filter node**;
- bus 126 becomes the cheap **MIDI-wire realization** of a param pin;
- the per-track node's **lifecycle owner** — `ccManager` (`ccm`), whose
  claims registry ref-counts producers so the node lives iff one claims it —
  **dissolves with the store**: once the node is on-graph a wire to it *is*
  the claim, and wm's standing invariant — *delete an FX only when its owning
  node leaves the graph* (`wiringManager.lua:7`) — reaps it for free. `ccm`
  is **deleted, not folded**; its claim/release body is code wm already runs.

Pre-beta, no legacy data — this is a re-founding, not a compat layer. The
column's inline-CC-in-the-note-take *data* is unchanged; only its binding
and realization move into the graph.

**The add bank (from note-macros).** note-macros adds a third bank to
`Continuum CC` — a sum verb, `out = base + delta`, the additive merge
`plink` cannot express (single-source-per-param). Built there now as a
self-contained sum kernel keyed by src/dst sliders, it lifts under this
re-founding into a synthesised **sum node** at the targetPlan/allocate
boundary, like the merge CU and the filter node. **R5 (plink-via-MIDI,
listen-bank retirement) is owned here, not by note-macros** — note-macros
defers it so its add bank lands beside the untouched listen bank, and this
phase-2 re-founding absorbs it (R5 is a strictly weaker version of the
same dissolution).

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

## Phases (revised order)

`cv.md` put the simple layer first because it had no realizer dependency.
"Everything builds in the graph" inverts that: the graph and realizer must
exist before the front-end can mint into them.

1. **Spike** — done (`cv.md`).
2. **Simple layer** — done, standalone; to be re-founded on the graph (above).
3. **Wiring refactor → shared realizer.** Extract the realizer beneath the
   `targetTracks` seam; add `setParamLink`; add the param-pin terminal
   (adapter synthesis). Wiring behaviour unchanged, its specs stay green.
   The bulk of the risk; lands and is verified first.
4. **Unified graph front-end.** Param pins on FX nodes; the polymorphic
   adapter; the palette inspector (checkbox promote, active-sorted,
   expand-for-config) and right-click generator shortcuts; the filter node
   and the parallel-wire tickbox; re-found the simple layer on the graph.

## Open questions / risks

- **One page or two lenses.** The *model* is one graph. Whether the wiring
  page is the sole editor with the tracker palette as a second door, or
  the graph is presented through two filtered lenses (audio-emphasis /
  modulation-emphasis), is a UX call left open.
- **Cross-track CV latency under the spread topology.** The spike
  confirmed `plink` works and the adapter is per-destination, but did not
  stress cross-track CV *delivery* latency once the source-set partition
  spreads the graph across tracks. If a block of latency on a modulation
  send is audible, it resurrects `cv.md`'s "central host" argument as a
  *hosting heuristic* (concentrate CV onto fewer tracks) — never as a
  separate page.
- **ADSR / follower default wiring.** Their own input (gate / audio) is a
  wire the user draws; confirm by use whether a sensible default is worth
  the action-at-a-distance cost (current answer: no).
- **`ccSink` mechanics** — writing 14-bit CC back into a lane from a graph
  terminal; lowest-priority sink, sketched not designed.
- **Resolution** — the MIDI stream is sample-accurate; the coarseness is
  7-bit values plus REAPER's ~25 ms CC interpolation step (spike), not
  timing. Escalate a param pin's wire to 14-bit MIDI (fixes values) or
  audio (fixes both) if zipper is audible on slow sweeps. The choice is
  the wire type, visible in the graph.
