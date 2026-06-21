# note macros — generative modulation on notes

> Design note. **Retrig — the structural half of the v1 proving pair —
> has landed** (`generators.lua` + the rebuild expansion step +
> `tm_macro_spec`); vibrato, the continuous half, is next.
>
> A *macro* is per-note generative intent —
> retrig, trill, arp, vibrato, slide — expanded mechanically into
> realisation the note's own events don't contain. This note fixes the
> v1 model: the host contract and intent shape, the two output categories sharing one
> realisation mechanism, the derived-event lifecycle, and the proving
> pair (retrig + vibrato). UI is sketched only. Supersedes an earlier
> revision that realised continuous output as sysex packets interpreted
> by a dedicated JSFX — rejected below, § *Why the delta is its own
> stream*.

## The problem

Every roll, ratchet, trill, vibrato, or slide currently has to be
hand-entered as literal events — the single most tedious gap against
any tracker with an FX column. Macros differ from the splits Continuum
already has (swing, delay, detune) in one structural way: the
realisation contains **events the intent does not** — not the same
events reinterpreted, but new ones.

## Precedents — the pattern is already in the house

Three mechanisms already generate events that exist on only one side
of the intent line:

| mechanism | intent | derived realisation | lifecycle |
|---|---|---|---|
| fake-pb absorbers | lane-1 detune | pbs at note seats | `fake=true` cc metadata; bidirectional reconcile |
| PC synthesis (trackerMode) | `note.sample` | PC stream | pure `reconcilePCsForChan`; predict → diff → delta |
| aliases | spec tree on root | materialised child events | `parentUuid`; ephemeral uuids; regenerated per rebuild |

And the attribute-level splits all share one equation: **realisation =
authored base + a sum of recomputable modulation terms** (swing on
time, delay on time, detune on pitch). Macros are the closure of both
patterns at once: note-scoped, parametric, time-varying terms in that
sum — all of which materialise as new take events. By the three-times
rule, the derived-event lifecycle now gets named and shared.

## Additive, never replacing

A macro's continuous output is a **delta over the authored base**, not
a replacement stream. This buys:

- **Stacking with no policy.** Sums commute; `note.fx` is a list and
  the apparatus never arbitrates vibrato-vs-slide conflicts.
- **Orthogonality.** The user's pb/cc curve stays their property;
  editing it under an active macro keeps the macro riding the new
  curve. Replacement would make authored data dead under any macro.
- **Round-trip in the family.** `base = realised − Σ deltas(specs)` is
  the same recovery move as `logical = raw − detune`; external-edit
  residue attributes to base, per the rebuild rule's predicted-check.

Deltas are never clamped in the layers; range clamping happens once at
the summing boundary, so removing one term restores the others
exactly.

## Two categories, one mechanism

Macro output is not one kind of thing, but both kinds realise the same
way — as derived take events under one lifecycle:

| category | kinds | output | realises as |
|---|---|---|---|
| **structural** | retrig, trill, arp | new note events | derived notes baked into the take |
| **continuous** | vibrato, slide, cc-tremolo | additive delta signals | shaped cc events at reserved **delta codes**, summed into the target by the Continuum node, in DSP |

Structural fxNotes *want* to be ordinary take notes: they participate
in voice clamping, PA binding, PC synthesis, and render-to-MIDI.
Continuous deltas are ordinary take ccs at addresses the user never
sees — routed out of columns at parse, summed below the synth.

## Why the delta is its own stream

Three candidate realisations for continuous output; two rejected:

1. **Merge into the authored lane.** REAPER's CC interpolation family
   (step, linear, slow, fast-start, fast-end, bezier) is not closed
   under addition: summing a delta onto a bezier/slow segment forces
   densification of the *user's* events into micro-segments, drags in
   wire-shape vs intent-shape stashing and reconcile inside densified
   windows, and makes the authored curve unrecognisable under any
   macro. Rejected.
2. **Sysex packets + interpreter JSFX** (this note's previous
   revision: one compact packet per macro'd note-on, decoded by a
   dedicated `Continuum Mod` running the LFO in DSP). Compact wire,
   but it stands up a *second* realisation mechanism end to end: a
   packet wire format with versioning, an EEL2 interpreter with
   per-voice state, legislation for loop replay and seek (`@init`
   refires), expiry-restore emission, a causality rule — and it loses
   render-to-MIDI. The apparatus outweighed the payload. Rejected.
3. **Delta as its own wire stream; the node just adds.** Generators
   run in Lua at flush and bake each delta to sparse shaped cc events
   at reserved codes. The authored curve stays sparse and user-owned;
   the delta stream is generator-owned wholesale; the sum happens in
   the node *after* REAPER interpolates both streams, so shape
   closure never arises. Chosen.

What (3) buys for free, because deltas are ordinary take MIDI: loop
replay and seek just work (REAPER chases ccs), item edits truncate
deltas naturally, offline render works, bake-on-export is an address
rewrite + merge rather than a renderer, and generators are pure Lua
under the normal test harness instead of EEL2.

## Intent shape

One field on the note, persisted through the existing note-metadata
path (notes already carry uuid'd ext-data — persistence is free):

```lua
note.fx = {
  { kind = 'retrig',  period = {1,4}, ramp = -12 },
  { kind = 'vibrato', period = {1,2}, depth = 30, onset = 1 },
}
```

An ordered list; kinds may repeat. All periods/durations are QN per
the `periodQN` convention (scalar or `{num,den}`) — tempo-synced,
consistent with swing factors. Per-kind params, v1 vocabulary:

| kind | params | notes |
|---|---|---|
| `retrig` | `period`, `ramp` (vel Δ/fxNote) | fxNotes fill the note's logical interval |
| `trill` | `period`, `step` (signed **scale steps**) | alternation resolved through the temper → (pitch, detune) pairs |
| `arp` | `period`, `steps = {0, ...}` (scale steps) | broken chord off the single host note — a generalised trill, **not** a chord arpeggiator (that needs a region host, § *The host contract*) |
| `vibrato` | `period`, `depth` (cents), `onset` (QN ramp-in) | lane-1 only (pb is channel-wide, same doctrine as detune I3) |
| `slide` | `over` (QN), `target = 'next'` \| cents | `'next'` resolved at flush against the next lane-1 note |

## The host contract

What a generator consumes is narrower than "a note": a time
**window**, a set of **input events**, an **identity** for provenance
and dirty-tracking, and channel context:

```lua
host = {
  window = { startppqL, endppqL },  -- effective logical interval, never OPEN
  events = { note, ... },           -- inputs; v1: exactly the host note
  id     = <uuid>,                  -- provenance key (derived) + dirty key
  chan   = <chan>,
}
```

v1 has exactly one host kind — the **note**: window = its effective
logical interval, events = the note itself, id = its uuid. The
signature is fixed against the contract now because two wanted kinds
don't fit N=1: a true chord arpeggiator consumes several notes (N≥2),
and free-running generators — a fill, an LFO on a cc lane with no
note — consume none (N=0). Both are **region hosts**: something
region-shaped carrying `fx` plus a window, supplying its covered
notes as input. A gm group is the obvious candidate substrate — a
group is already a persisted, anchored window over member events, and
group-hosted `fx` would make every instance arp identically for free
— but gm-backed vs a lighter standalone region is decided when region
hosts land, not now. Nothing downstream cares about N: the derived
lifecycle, delta streams, and reconcile are host-count-blind.

## Generators

A pure module (`generators.lua`) — the lifecycle is generic, the
generator set is not (a user-facing generative language is explicitly
out of scope; nothing below precludes growing one later):

```lua
generators[kind](host, params, ctx) → {
  notes = { {ppqL, endppqL, pitch, vel, detune}, ... },   -- structural
  delta = { {ppqL, val, shape, [tension]}, ... },         -- continuous breakpoints
}
```

Generators speak **logical frame and intent units** (ppqL, cents,
scale steps, signed controller units) and know nothing of swing, raw
pb, or REAPER. The existing realise stack converts: fxNotes swing like
any authored note and inherit the host's delay; delta breakpoints map
cents → raw pb units via the resolved pbRange at flush — the same
boundary where detune realises. `ctx` carries the temper and a
next-lane-1-note lookup (for `slide.target = 'next'`).

## Structural realisation — derived notes

- **Provenance.** Each fxNote carries `derived = <hostUuid>` (R1's
  provenance field) as note metadata. The rebuild parse routes derived
  notes out of column-building (as absorbers are routed out of the pb
  column): no lane allocation, no tracker-visible events.
- **Host is fxNote 1.** The host note keeps its uuid, lane identity,
  and PA binding; its realised note-off truncates to the first fxNote
  boundary while `endppqL` keeps the authored ceiling — the existing
  `endppq ≠ endppqC` divergence surface, no new mechanism.
- **Ephemeral identity** (alias precedent). fxNotes are regenerated
  freely; mm mints fresh uuids; external edits to an fxNote are
  generator-owned territory and are overwritten at the next reconcile.
- **Realised-space citizenship.** fxNotes are ordinary realised notes:
  the universal tail walk clamps them, and under trackerMode they
  enter PC-synthesis records carrying the host's `sample` (steady
  state writes no extra PCs — the program is already in force).
- **Trill detune.** Microtonal alternation lands as per-fxNote `detune`
  on lane-1 fxNotes; the existing absorber machinery realises it. If
  absorber churn at trill rates proves ugly, the cents component can
  migrate to the delta stream (open question below) — same mechanism
  either way now.

## Continuous realisation — delta streams + the add bank

- **Carrier.** Each (channel × target) delta is shaped cc events
  seated across the host's realised interval, on the host's channel,
  at a reserved **delta code**: pitch targets use an allocated 14-bit
  msb/lsb pair (value signed around 8192, raw pb units), cc targets an
  allocated 7-bit code (signed around 64). Codes come from the same
  project-unique code space paramAutomation already allocates
  `busCode`s from. The take's MIDI already flows through the track
  chain — no bus plumbing, no sends, no lane allocation.
- **No metadata.** Unlike absorbers, delta events carry no uuid, no
  sidecar, no marker — **the code is the provenance**. Parse routes
  reserved-code events out of column-building by address; the wire
  stays at half the density a sidecar-per-event scheme would cost, and
  the reconcile is stream-level (below), so per-event identity is
  never needed.
- **The add bank.** The Continuum node grows a third bank in the
  existing src/dst slider vocabulary: src = delta code, dst = target
  (pb-on-chan or cc code), verb = *sum*. Per target: `out = latest
  base + latest delta`, emitted on change of either, clamped at
  emission only (14-bit pb / 0..127 cc). Delta-code events are
  swallowed; base events pass as the sum; delta defaults to 0, so
  non-macro traffic is value-identical.
- **Smoothness.** REAPER interpolates shaped cc events into a dense
  stream before the chain sees them, so the wire stays sparse
  (breakpoints at curve extrema, bezier/linear shapes) while the node
  sums the interpolated streams. If interpolation density or
  shape-on-14-bit-pair coherence disappoints (verify early), the
  generator densifies to square breakpoints — a generator-side knob,
  no mechanism change.
- **Regeneration.** Delta events carry raw units, so a pbRange or
  temper change regenerates them via the ordinary configChanged →
  rebuild path — the same trigger that re-realises detune.
- **Lane-1 only** for pitch-targeted kinds, mirroring detune doctrine:
  pb is channel-wide, so a higher-lane vibrato would bend the whole
  channel. Persisted intent on higher lanes stays dead data, exactly
  like higher-lane detune.

## Packaging — one stream-transform node

The add bank makes the node question concrete. `Continuum CC` today is
two unlike things bolted together: a **stream transform** (filter
bank: relocate authored automation ccs to the reserved bus) and a
**plink host** (listen bank driving 16 value sliders that bound params
plink from). The second job is dissolvable: REAPER plink can source
MIDI directly — point the bound param's `plink.midi_*` at the
relocated cc on the automation bus and the listen bank plus 48 of the
64 sliders disappear. Nothing is lost in resolution: the slider path
already quantises at `m3/127`.

Target state: **one Continuum node** — a pure MIDI stream transform,
filter bank + add bank, no value sliders, no param surface — pinned at
chain head by one reconcile idiom. Macros then pin *the same node*
paramAutomation already manages, not a sibling. The plink migration is
independent of macros (pre-beta, no compat) and not v1-gating — the
add bank can land beside the listen bank — but sequenced first it
removes the only reason the node has params at all. Verify: exact
`plink.midi_*` config parms, and that the source spec covers the
automation bus.

Relation to cv (`design/cv-2.md`, which supersedes `cv.md`): the node
is a **MIDI-stream stage on the instrument's own track** today, sharing
cv's doctrine (JSFX realises what REAPER does badly; no native
envelopes), not its topology. The convergence is now **resolved**, not
just watched: build the add bank as a **self-contained sum kernel**
(base + delta, keyed by src/dst sliders) and cv-2 lifts it verbatim
into a synthesised **sum node** — the additive merge `plink` cannot
express (single-source-per-param). **R5 defers to cv-2:** its phase-2
re-founding dissolves the listen bank and value sliders, so do not
migrate plink under note-macros — land the add bank *beside* the
untouched listen bank. The `paramAutomation` glue that places and
configures the node is interim; the sum kernel is permanent.

## Invariants

The wire invariants I1–I5 (`docs/tuning.md`) hold on the authored
events **verbatim** — delta codes live outside the user's namespace
and sum strictly below it. New, mechanism-independent:

- **G1 — Provenance.** Every derived note resolves via `derived` to a
  live host whose `fx` contains a structural kind; every event at a
  delta code matches the prediction for its channel's fx-carrying
  lane-1 notes. Both directions of both.
- **G2 — Both directions** (absorber-style). `fx` present ⇒ derived
  events match the generator's prediction after reconcile; `fx`
  removed ⇒ no derived event survives the next reconcile.
- **G3 — Ownership.** Derived events are generator-owned: external
  edits to them are overwritten, never attributed to base intent.
- **G4 — Round-trip.** flush → rebuild → flush is byte-identical
  (the I8 analogue).
- **G5 — Wire-completeness.** Delta streams carry raw target units
  resolved at flush; the node sums with no note tracking, no
  lookahead, no cents→raw knowledge.

## Pipeline placement

Mirrors PC synthesis end to end:

- **Parse:** derived notes route to a side list; delta-code ccs route
  out by address. Neither reaches columns or lane allocation.
- **Rebuild — the expansion slot is constrained, not free.** Three
  ordering constraints pin it: (a) **after** the swing-reconcile rule
  (step 4.7), so hosts touched by external edits have final ppqL/raw
  before prediction; (b) **before** the universal tail walk (4.8), so
  the tail walk clamps host raw to fxNote 2's onset and fxNote-to-fxNote
  overlaps for free — note 4.8 walks in-memory note sets, so its pitch
  groups must include the freshly staged fxNotes; (c) **before** PC
  synthesis, so fxNotes enter PC records carrying the host's `sample`
  — which moves PC synthesis (currently 4½) after expansion. Per
  channel: records = lane-1 notes carrying `fx`; run generators;
  predict fxNotes + delta streams; diff with carry-forward so steady
  state writes nothing. The delta diff is **stream-level**: a
  channel's stream at one code is a pure function of its fx-carrying
  notes — predict the whole stream, diff wholesale against the events
  at that code.
- **Flush-time reconcile** — *not yet built; v1 rides the rebuild path,
  which every flush triggers* — gated on a `dirtyFxHosts` set: any
  mutation to a host's `fx`, ppq/delay, pitch/detune, vel, or length
  dirties it; so does a pbRange/temper change. Same pure helper as the
  rebuild sweep.

## UI (sketch only)

v1: a per-note `fx` badge in the note cell and a palette-style editor
on the focused note (the param-palette focus model from tr is the
obvious chassis). A full FX-column rendering — `R16`-style codes in a
dedicated column — is deferred until the model is proven.

## v1 scope — the proving pair

`retrig` + `vibrato`, one per category. **`retrig` ✓ landed:**
`generators.lua` (pure module), the rebuild expansion step
(`reconcileFx`, mirroring `reconcilePCsForChan`), and `tm_macro_spec`
pinning G1–G4 plus tail-clamp, velocity-ramp, and PC interplay.
Flush-time reconcile (`dirtyFxHosts`) and the R2/R4 refactors are
deferred fast-follows — correctness rides the rebuild path, which every
flush triggers. **Vibrato is next:** cents→raw conversion, shaped-pair
emission, parse routing by code, and the add bank — pinning G5.
Remaining kinds are table entries afterwards. The plink migration (R5)
is sequenced independently.

## Refactor map — what unifies

Both live derived-event mechanisms are already declarative reconciles
with the same skeleton — predict desired from intent, match against
tagged existing events, write the delta with identity carry-forward —
implemented twice with different vocabularies. Macros make it four
instances. In leverage order:

- **R1 — one derived marker. ✓ Landed (`e703510`).** `fake=true` meant
  "derived, regenerable from intent" in two unrelated mechanisms; macro
  fxNotes would have needed a second marker, forcing every predicate
  to `fake or <it>`. Replaced both with one provenance field —
  `derived = 'absorber' | 'pc' | <hostUuid>` — now the single predicate
  for column routing, lane-alloc exemption, the CC-walk skip, hidden
  computation, and reconcile gathering; every read is a truthiness test,
  the two writes carry the tag. Delta-stream ccs stay outside it by
  design — their address is their provenance. The `<hostUuid>` value is
  reserved; fxNotes fill it. No migration (pre-beta): persisted `fake`
  metadata is ignored and self-cleans, since absorbers/PCs re-derive
  each rebuild. Swept the vocabulary too — `availFakes`→`availAbsorbers`,
  `notFake`→`notDerived`, gm's `copyScalars` opt-out key renamed.
- **R2 — the reconcile skeleton.** `reconcilePCsForChan`
  (keep-on-match / add / remove-unkept, loc carry-forward) and the
  absorber pass's fake-matching middle (reuse-in-place / move /
  create / delete-leftovers) are one algorithm at two levels of
  richness. Extract `reconcileDerived{existing, desired, key, make}`
  *when writing the macro reconcile* — the four-instance moment is
  when the shape is provable. **`reconcileFx` (note-shaped) has now
  landed** beside `reconcilePCsForChan`, so the skeleton is provable and
  the extraction is the next refactor. The absorber pass's other duties (cents
  back-derivation, wire-raw recompute, column projection) are not
  reconcile-shaped and stay put. gm's `reproject`/`reconcile` is a
  *third live* instance of the skeleton (predict desired from group +
  overrides, diff against shadow, emit add/set/del) — it does not
  migrate now (bidirectional, override shadowing — the richest
  instance), but it belongs in the audit so the vocabulary doesn't
  fork.
- **R3 — `forEachEffectiveNote`.** "Committed notes ∪ staged adds" is
  hand-rolled in flush's voice-legality scan and in `reconcilePcs`;
  macro flush-reconcile is the third occurrence — extract then.
- **R4 — flush-time mechanism registry.** `flush()` hard-codes the PC
  pass behind `dirtyPcChans`; macros add `dirtyFxHosts`. Ordering is
  load-bearing — fxNote reconcile must precede PC reconcile (fxNotes
  carry the host's `sample` and enter PC records) — so this is an
  ordered `{dirtySet, reconcile}` list in tm, **not** a preflush
  subscription (hook order is registration order; gm already rides
  that hook).
- **R5 — plink via MIDI; retire the listen bank.** `pa.apply` writes
  the bound param's `plink.midi_*` at the relocated automation-bus
  address instead of linking through the node's value sliders;
  `computeDesired`'s listen slots become plink specs; the listen bank
  and value sliders go. Justified on its own; unblocks the single-node
  packaging above. **Deferred to cv-2** (`design/cv-2.md` §*What
  changes vs the landed simple layer*), which re-founds this exact path
  — do not build under note-macros.
- **R6 — JSFX pinning helper.** The node's pin-at-chain-head +
  idempotent mirror is `paramAutomation`'s `ccNodeIndex`/`applyTrack`
  idiom (which already notes a dedup with `routingManager.fxIdentAt`).
  Under single-node packaging macros add no new consumer — the dedup
  with routingManager stands on its own merits.
- **R7 — aliases and groups convergence.** The alias substrate
  (docs'd, not landed) shares the lifecycle: spec on host, ephemeral
  derived identity, regenerate per rebuild — `note.fx` is
  `root.children` in miniature. And gm decomposes the same way:
  `groups.project` is already a pure function from spec + anchor to
  desired events — a generator with `group.events` + overrides as
  params and the instance anchor as the host window. The full
  decomposition is three-way: a generic **regions** substrate (rect,
  anchor, instance identity, membership, disjointness, persistence,
  wash rendering — exactly what region hosts need), the **mirror
  generator** (anchor-rebased replay, already extracted as the pure
  core), and the **bidirectional edit protocol** (classify, override
  transitions, template writeback, localMode, the flush-seam shadow
  machinery) — most of gm's mass, with no macro analogue. The axis
  separating them: the mirror generator is *invertible*
  (`toGroup`/`toInstance` are exact duals), so its output earns
  stable per-slot identity (vuid→uuid) and user editability with
  override residue; retrig/vibrato are *lossy* — no useful inverse —
  which is exactly why G3 makes their output generator-owned and
  ephemeral. Aliases, group-mirror, and macros are three points on
  one generator spectrum over one regions substrate. None of this
  sequences before macros v1 — gm is bug-hardened and re-founding it
  buys vocabulary, not capability — but when region hosts land they
  are carved from gm's regions substrate, not built fresh. Now: build
  R1's provenance field and the parse-time routing so the walker can
  later ride the same rails; don't fork the vocabulary.

Non-refactors, recorded so nobody hunts for them: `projectCC`'s
rule-based strip already passes unknown metadata through (`fx`
reaches columns unchanged), and the absorber pass's cents/raw
machinery is untouched by design — vibrato sums at the node precisely
so it never enters that domain.

## Implementation notes — read before coding

Known traps, each of which has a plausible-looking wrong
implementation. Read `docs/timing.md`, `docs/tuning.md`,
`docs/trackerManager.md` (§Rebuild, §Mutation contract),
`docs/midiManager.md` (§Mutation contract), and the tm test fixtures
before writing anything.

### Frames and rounding

- Generators emit **ppqL only**, never raw — fxNotes and delta
  breakpoints alike. Realisation is
  `round(snapshot.fromLogical(ppqL)) + delayToPPQ(delay)` — the exact
  expression the rebuild rule uses, rounded at the same point. A
  second rounding site (or float ppq in predictions) makes steady
  state diff non-empty and G4 fails as permanent churn.
- fxNotes inherit the host's `delay` verbatim — the whole figure
  nudges as one. fxNote 1 *is* the host; generate fxNotes 2..N.
- Inside rebuild, before tidyCol, `evt.ppq` is **realised**; the
  reconcile's "existing" events read pre-tidy. Never compare logical
  predictions against realised existing (or vice versa) — convert
  one side deliberately.
- `endppqL == util.OPEN` is a sentinel, not a number. `host.window`
  carries the *effective* logical end (tail-clamped `endppqC` mapped
  back via `toLogical`); no arithmetic on OPEN.
- Clamp fxNote velocity to 1..127 after ramping.
- cents→raw for delta breakpoints converts once, at flush, against
  the resolved pbRange — never inside the generator, never in the
  node.

### Mutation mechanics

- All writes stage through um; nothing touches mm outside
  `mm:modify`. Cross-rebuild note identity is **uuid** (`tm:byUuid`),
  never token or loc. For cc-family events, capture `mm:tokenOf`
  **before** mutating ppq — tokens are content-keyed (see the
  absorber pass's `origTok` discipline). Delta-stream ccs have no
  uuid by design; the stream-level diff deletes and writes by token
  within one staged batch.
- Clearing `fx` or the `derived` marker is `util.REMOVE` through
  `assignEvent`, never `= false` / `= nil`.
- Flush-side reconcile runs *inside* `flush()` before the op snapshot
  (model: `reconcilePcs`); it stages via the lowlevel helpers and
  never re-enters `tm:flush`.
- Host truncation to fxNote 2's onset is the **existing** universal
  tail walk doing its job. Write no bespoke truncation; if you find
  yourself shortening the host's raw note-off by hand, stop.

### Absorber interaction (v1 guard)

The 4.9 absorber pass gathers lane-1 notes from
`channels[*].columns.notes[1]` — derived fxNotes are routed out of
columns, so that walk **cannot see them**. v1 rule making this safe:
fxNotes carry `detune = host.detune` verbatim, so no fxNote seat is a
detune jump and no absorber is needed. Assert the inheritance.
Trill (per-fxNote detune) requires the 4.9 gather to union derived
lane-1 fxNotes first — that's the gating work item for trill, not the
generator.

### Group interaction (gm)

- **Derived events are invisible to gm.** `classifyCreate` adopts any
  fresh event inside a region footprint by rect containment alone —
  a staged fxNote under a group's footprint would be adopted into the
  group and mirrored to siblings. Every gm classify/adopt path skips
  events carrying the R1 `derived` marker, the same routing-out the
  parse does for columns.
- **`fx` crosses the group frame for free.** `copyScalars` is
  opt-out (every field except `DERIVED`), so a trill on a grouped
  note already propagates to siblings like detune. Assert it, don't
  re-plumb it; sibling regeneration is the ordinary path — reproject
  restamping a sibling's `fx` dirties that host via `dirtyFxHosts`.

### Add bank (JSFX)

- EEL2 top-level identifiers are case-insensitive **and unscoped**
  across @sections — don't shadow constants with lowercase locals.
  Code above the first `@section` is silently ignored: `ext_midi_bus`
  and friends belong in `@init`.
- `@init` refires at every play-start **and loop point** with globals
  preserved. The latest-base/latest-delta tables must survive refire
  untouched — REAPER's cc chase re-sends current values on seek/loop,
  so re-arrival re-establishes state; never zero the tables in
  `@init`.
- Swallow only delta-code events; pass every other event through
  byte-identical, except target events, which pass as the sum.
- Emit on change only (block rate); clamp at emission only. With
  delta = 0 the sum path must be value-identical to passthrough.
- Bank config rides config sliders (the src/dst metaprogrammed-bank
  idiom), written by the same apply reconcile that fills the filter
  bank.

### Test order

- Pin G1–G5 by number in a spec (model: `tm_tuning_spec`'s I1–I5).
  Write **G4 first** — flush → rebuild → flush byte-identical for a
  retrig host under a non-identity swing *and* nonzero delay. It
  catches frame and rounding mistakes before any other surface
  exists. Then the vibrato G4 under a pbRange change — it pins the
  regeneration path and the single cents→raw conversion site.
- Wired-behaviour specs exercise the real production wiring; stub
  REAPER/ImGui at the surface only, never the behaviour under test.
  Read the target fixture before the code — cm tier shadowing and
  fake-mm-only methods are the usual red-test source.

## Open questions

- **Shape interpolation — settled, green** (`tests/spikes/spike_shape_interp.lua`,
  2026-06-21). REAPER recognises an `n`/`n+32` CC pair as one 14-bit
  value and interpolates *that*, synthesising the LSB itself — it does
  not interpolate the two lanes independently. So a few **MSB-shaped**
  sparse breakpoints (LSB square) deliver smooth **full-resolution**
  14-bit downstream (~15.6 ms grain, monotonic, no wrap glitch); the
  generator never densifies. The dense-square fallback is unused. The
  wire stays sparse *and* full-res — the best case the design hoped for.
- **Delta-code allocation — banded, not flat.** The 14-bit pairing only
  exists for MIDI **CC 0–31** (MSB) paired with **CC 32–63** (LSB): a
  pitch/14-bit target must allocate MSB `n` with **`0 ≤ n < 32`**, LSB
  `n+32`, or REAPER won't interpolate the pair. So pitch targets draw
  from **32 pairs per channel** (steering clear of controllers the
  instrument reads — bank select CC0/32, mod wheel CC1/33, …), *not*
  pa's flat `chan*128+cc` busCode space; 7-bit cc targets stay flat.
  Per-channel banding (deltas already ride per-channel, lane-1 doctrine)
  is the budget. Open: collision-avoidance policy, and whether the add
  bank's 16 slots need to grow.
- **Trill cents: structural detune vs delta stream.** Structural is
  correct-by-existing-machinery but seats absorbers at trill rate;
  both ride the same wire now, so decide after watching it run.
- **Gen stack UI.** The model supports a list; v1 UI may expose a
  single entry per note.
- **Bake-on-export.** Address rewrite + merge of delta streams into
  their target lanes for plain-MIDI export; densification cost paid
  only there.
- **`plink.midi_*` parms.** Exact config-parm names and automation-bus
  addressing for R5; gates the listen-bank retirement, not v1.
