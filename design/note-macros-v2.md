# note macros v2 — region hosts and the generator spectrum

> opened: 2026-06-26 · status: in flight — `plan/chain-surface.md`
>
> Working design doc. Supersedes the forward-looking half of
> `design/archive/note-macros.md`, now the **frozen record of v1** — the
> shipped proving pair (retrig + vibrato), plus slide and trill, the
> additive-delta mechanism, the carrier / add-bank, and the G1–G5
> invariants. Read that for the vocabulary (derived-event lifecycle,
> delta streams, the two-categories-one-mechanism model); this doc leans
> on it and states only the deltas.
>
> v1's **kind vocabulary is closed** — arp is dropped on purpose: a true
> chord arpeggiator wants a region host, and the single-note arp isn't
> worth a one-off list widget. v2 is not about new kinds. It is about the
> **substrate**: generalizing the host from a note to a **region**, so
> N=anything (chord arp N≥2, free LFO / fill N=0) falls out of one model,
> and converging macros, aliases, and group-mirror onto one generator
> spectrum over one regions substrate (R7).
>
> **Companions.** `design/archive/fx-patterns.md` — generator params whose value
> is a note pattern or a curve. `design/archive/fx-freeze.md` — committing
> generator output. `design/pipe-dreams.md` — param modulation and the
> stepped feed, the gleam this doc used to carry. What remains to build
> is queued in `plan/chain-surface.md`.

## The five roles of the host note

In v1 the host note plays five distinct roles, fused onto one object
because a note conveniently *is* all of them at once. The fusion is what
N≠1 breaks, and teasing the roles apart is most of the design:

1. **Audible note** — it plays, and may be tail-truncated. The audible
   first hit.
2. **Generator input** — the events the generator reads.
3. **Logical region** — the window the output lands in.
4. **Identity & intent** — stable uuid, `fx` metadata, provenance and PA
   binding. Where the fx is *stored*.
5. **Access seam** — the cell the user's cursor lands on to *reach and
   edit* the fx.

They don't all generalize the same way. Three collapse to one object, one
dissolves, one is the part the note hands over for free.

**(2), (3), (4) are one anchor.** Not independent — three projections of
a single thing that carries identity and occupies a region: (4) its
essence (uuid, `fx`), (3) its extent, (2) its contents. v1 fuses them
because a note is simultaneously its own identity, its own extent, and
its own sole content. Splitting them is § *The anchor generalized*.

**(1) dissolves into output.** The host-as-audible-note is the one role
that doesn't generalize, and in v1 it earned its keep for exactly one
reason: PA binding rode fxNote 1, which *was* the host. Stripped of that
it is pure liability — it forces a view-restore dance whose only job is
to sustain the fiction that the note you *see* (authored length) and the
note you *hear* (truncated to fxNote 2) are one object. Neither host has
a privileged host note now: a region's hits are all derived output
(§ *Generator output*), and a note host parks itself (§ *Note-host
replace parks*), so the dance is gone from both.

**(5) is the role the note gives away free.** (4) is where the fx is
*stored and identified*; (5) is how the user *reaches* it. A note is both
— grid addressability means landing the cursor on it both selects its
identity and opens its fx. For a region there is no cell to land on, so
(5) needs its own affordance (§ *Authoring and editing*). It is invisible
in v1 precisely because the note gives it for free, and it bites hardest
in v2.

## The anchor generalized — the region

The anchor (roles 2+3+4) generalizes to a **region**:

```lua
region = {
  chan       = <chan>,        -- (4) identity context; continuous output is channel-wide
  startppq, endppq,           -- (3) the window
  fx         = { ... },        -- (4) intent: the same ordered kind-list as note.fx
  -- (2) input is not stored — it is membership(region), computed each rebuild
}
```

A region is **channel × ppq span**, carrying an `fx` list. Not a set of
columns: continuous output is channel-wide (pb / cc are per-channel) and
its *target* is a chosen property of the fx (pb by default, or a named
cc), not inferred from a column. So a region says only *where, on what
channel*; what the fx does is the fx's business.

**The note host is the degenerate region** — the host *interface* is
always a region; the *representation* is dual. A note presents itself to
the generator as a region whose `chan`/`window` are its own and whose
`fx` is `note.fx`, but that region isn't materialized; it's just the note
carrying `fx`. Explicit region objects exist only for N≥2 and N=0. So:

- the generator path sees one uniform region interface — the producer is
  *every note-as-implicit-region ∪ every explicit region*;
- storage stays dual: `note.fx` for the single-note case (cheap, and it
  keeps riding copy / move / group propagation via `copyScalars`), an
  explicit region object otherwise;
- PA, provenance, and dirty-keying bind to whatever holds the fx — the
  note, or the region.

**Input is membership, not storage.** Roles (2) and (3) are the region's
two projections — window = its bounds, events = its membership — and the
coupling *reverses direction* between host kinds:

- **note host (N=1):** the note is primary; the window is derived from it
  (its effective interval). Input → window.
- **region host (N≥2 / N=0):** the region is primary; the input is
  derived from it by an overlap query. Window → input.

So the contract's primitive is *region + a membership rule*, with `notes
= membership(region)`: `{self}` for a note, `{overlapping notes on the
channel}` for a region, `∅` for a free LFO. One rule, three host kinds,
no special-casing below the contract.

**Replace absorbs; augment queries.** The query above is the whole story
only for *augment* — members stay in the take, sound, and feed the
generator. *Replace* cannot leave them there: a member the output stands
in for must not also sound, and it cannot be muted — a muted note still
carries a note-on/off pair that MIDI_Sort mispairs against a same-pitch
derived note, and a CC/PA has no mute bit. So replace **parks** its
members off the take into a store (`fxParked`), re-homed each rebuild
(covered → off-take, no-longer-covered → restored). The parked members
are still the membership, and — inverted from intuition — they are the
*visible, editable* surface: you see and edit the chord, the generated
arp is hidden (take-only, as v1 derived). The invariant underneath:
**creating an fx region never changes what the user sees.** Replace stops
the authored events *sounding* but keeps them *shown and editable*; the
generator's output is hidden realisation. It holds for every replace path
— the note chord, the cc source, and pb (§ *Route-by-window*). So for
replace, membership *is* storage, off-take; for augment it stays a live
query. **Whether a region parks is read from its kinds, not a
`region.mode` toggle**: a discrete-replace kind parks, a continuous kind
augments (§ *The fx chain*).

**There is no dirty tracking to design.** The rebuild regenerates and
diffs unconditionally every time, so "membership changed → regenerate" is
a non-problem. A region host just **re-queries its covered notes each
rebuild** — a fresh overlap query at expansion time, output-stable so
long as it is a pure function of current note positions (the same G4
discipline as the canon fix). The genuinely new mechanism is the
membership query itself: v1's note host never needs one because it *is*
its own membership.

## Generator output

Output is the **total realisation within the window** — every audible
event, all of it derived (the replace model). Two channels, both already
in v1; resist growing the set (PCs belong to PC-synthesis, sysex was the
rejected path):

- **notes** — absolute `{ppqL, endppqL, pitch, vel, detune}` (discrete
  kinds: retrig, trill, arp, fill);
- **deltas** — breakpoints on the chosen pb / cc target (continuous
  kinds), folded into the stream's typed channel (§ *The fx chain*).

Two constraints make it well-behaved:

- **New events only — never edits to inputs.** v1's host "truncation" is
  the tail-walk clamping *realisation*, not the generator editing a note;
  under regions even that vanishes. Output is strictly new derived
  events, which is what preserves the intent/realisation split and the
  round-trip.
- **Lane allocation resolves all overlap; output never self-clips.**
  Discrete output can be polyphonic (a chord arp, a dense fill), so its
  notes need voice allocation within the region's channel:
  - simultaneous generated notes → separate lanes;
  - sequential ones → share a lane (abutting, so nothing to clip);
  - authored notes are immovable — generated notes pack into lanes *free
    within the region's span*, appending new lanes only when none are
    free.

  This is the packing the tracker already runs on authored notes,
  re-pointed: per-channel, authored occupancy seeded as fixed, derived
  notes flowed into the gaps. There is **no tail-clipping among generator
  members** — overlaps are resolved by lane separation, not by clipping.

**Determinism is the whole ballgame.** Because lane allocation is the
sole overlap resolver, it must be a *pure function of the region's
occupancy* — lowest free lane first, deterministic append — exactly the
discipline carrier-code allocation already followed. Lean on iteration
order or a counter and flush→rebuild→flush reshuffles lanes into
permanent churn. Same lesson as the canon fix, one layer up.

**The one overlap lane separation can't fix:** two generated notes at the
*same pitch* that overlap can't be voiced apart on one channel — MIDI
collides them regardless of lane. That's a constraint on generators (don't
emit same-pitch overlap), not a bug in the allocator; it would bite a
fill or an arp folding back onto a pitch.

**PA binds to the region.** With no privileged host note, the replace
gate the v1 doc flagged ("bind to the window, or to a regenerated first
hit") resolves cleanly: PA binds to the region — channel × ppq, stable,
persisted. The degenerate note host still binds PA to its note. A PA
parks with its host note, region-parked or self-parked; what stays
deferred is PA *replace* — a generator consuming and re-emitting one —
which is a different operation (§ *Deferred — no consumer*).

## Authoring and editing the fx

Role (5), the seam that was free for notes. The editor *surface* is
substrate-neutral; what's new is **addressing**: getting to a host that
isn't a cell.

**Author by selection; note scope is the no-selection case.** A region is
*(channel, start, end)*, so the authoring gesture is "select a span on a
channel → edit its fx":

- **no selection** → **note scope**: the cursor's note is a complete
  region by itself — it supplies channel, start, and end — so its
  implicit region is edited (= v1's `note.fx`, untouched);
- **selection present** → **region**: the selected channel × ppq span
  becomes (or re-opens) an explicit region, contents irrelevant
  (N=anything).

The law underneath: *no-selection authoring works only on a cell that is
a complete region by itself, and only a note is.* A note carries its own
window; nothing else does.

**This is why "no-selection fx on a cc column" has no host.** A cc-column
cell gives the *target* for free (it's a continuous target) but **no
window** — target without extent isn't a region. So authoring fx on a cc
column *requires* a selection to supply start/end. Don't soften this with
a whole-take default: that quietly reintroduces unbounded hosts, and
"modulate this whole lane" is still expressible as select-all → fx, no
new mechanism. And don't add a third `column.fx` storage site — a
whole-lane LFO is just a region of column × take-bounds.

**Address existing regions through an fx column — not a region mode.**
Role (5) is handed back the way a note gets it: give the region a *cell*.
A per-channel **fx column** carries each region as a tailed kind-badge —
onset `startppq`, a note-style tail to `endppq`, a one-char glyph for the
primary kind; the cursor lands on it and Super-X opens the editor. No
second navigable object, no footprint mode. This is the standalone-not-gm
call extended to the UI: borrow the *column/cell/tail* machinery — the
most native thing the tracker has — not gm's region-mode. The column is
**cc-like in lifecycle** (data-derived: it materialises iff the channel
carries a region with ≥1 kind, appears when one is created/pasted, drops
when the last goes; not proximity-gated) and **note-lane-like in render**
(discrete tailed badges; overlapping regions pack into sibling columns by
storage order, § *The fx chain*).

**Indication.** Note scope keeps the v1 in-cell badge (`smallGlyph`); a
region is its column entry. The badge shows the region's *primary* kind
only — growing it into a chain signature is § *The chain surface*. A
later per-lane note-fx **pop-out** column — proximity-gated, the only
pop-down thing — earns its keep once parameter stops land and there is
inline editing the badge can't carry.

**Visibility — invisible now, ghost later.** Generated notes are
take-only, routed out of columns as v1's derived notes are: visible +
generator-owned invites editing a note the next rebuild silently
overwrites (G3). The intended later affordance is a **ghost display
mode** rendering them in the grid with the same styling as **interpolated
cc values** — a visual grammar that already says "computed, not
editable". Same idiom, no new invention; the choice turns only on whether
you want the arp *seen* or just *heard*. Unbuilt (§ *The chain surface*).

## The generator spectrum and the regions substrate (R7)

Three mechanisms in the house generate events on only one side of the
intent line, all sharing one lifecycle — *spec on a host, ephemeral
derived identity, regenerate per rebuild*:

- **macros** (`note.fx` / region.fx) — `note.fx` is `root.children` in
  miniature;
- **aliases** (the substrate, docs'd not landed) — spec tree on a root,
  materialised children, regenerated per rebuild;
- **group-mirror** (gm) — `groups.project` is already a pure function
  from spec + anchor to desired events: a generator with `group.events`
  + overrides as params and the instance anchor as the window.

They are **three points on one spectrum**, separated by **invertibility**:
the mirror generator is invertible (so its output earns stable per-slot
identity and user editability with override residue); retrig / vibrato
are lossy (so G3 makes their output generator-owned and ephemeral).
Aliases sit between. Freeze is this axis made a user-facing feature, and
is owned by `design/archive/fx-freeze.md` — where it resolved to one-way in both
directions, no unfreeze.

gm decomposes three ways:

1. **A generic `regions` substrate** — rect, anchor, instance identity,
   membership, disjointness, persistence, wash rendering, *and the region
   mode for selecting/editing them*.
2. **The mirror generator** — anchor-rebased replay, already extracted as
   the pure core (`groups.project`); also the freeze-to-group target.
3. **The bidirectional edit protocol** — classify, override transitions,
   template writeback, localMode, the flush-seam shadow machinery. Most
   of gm's mass, with no macro analogue (macros are lossy — nothing to
   write back).

Macros would use (1) only; group-mirror uses (1)+(2)+(3); aliases (1)+(2).
The original lean was to carve region hosts out of (1) rather than build
fresh. **Both tracks resolved the other way — standalone.** The generator
contract is already region-shaped and an fx-region's membership is
*simpler* than `groups.inRect`: gm's region carries a stream-map, a
replay template and per-instance override tables a bare fx-region has
none of. Authoring likewise went to an fx **column** rather than gm's
region-mode/wash, a column being more native to the tracker than a second
region object. So (1) stays unextracted, and gm is untouched; the
extraction waits for a consumer that justifies the shape.

## Generators as config — the ctx discipline

The contract is a pure `(stream, host, params, ctx) → {notes, delta}`.
The direction — *in due course, not gating* — is for the generator **set**
to become config: a kind is data, not a function. The route is a
discipline on **ctx**, the evaluation environment the body composes
against; when a body is nothing but arithmetic and named ctx operations,
it is already data.

**ctx binds what the generator can't compute itself — and only that.**
Pure arithmetic stays in the module; the moment a generator must resolve
a scale step (the temper), find a neighbour, or honour a config bound, it
reaches into ctx. The bound set is `resolution`, `pbRangeCents`,
`nextSameLaneNote`, `step(p,d,n)`, `stepsBetween(a,b)`. `interval` is the
instructive non-example — looks temper-bound, is pure note arithmetic,
lives as a module helper. **Build no interpreter**: the move costs ~nothing
if new kinds are shaped as composition and ctx accretes as named ops. The
same discipline is the contract surface a scripted kind would be written
against (§ *The chain surface*).

## Offline continuous realisation

Realisation for the continuous channels is **wholly in the take**: no
runtime component, no JSFX dependency, exportable as plain MIDI, WYSIWYG.
The earlier model summed at the node — `Continuum CC.jsfx` recomputing
`base + Σ carrier` per audio block — so the take was not what you heard
until the node ran. That summation was the node's only irreplaceable job;
the 14-bit transport is native to a seated pb (`centsToRaw` is already
14-bit) and the base-hold was incidental. The carrier, the add-bank slots
and the node's per-block summation are all retired.

**One model: park the base, seat the sum.** A continuous fx region parks
the authored automation its window covers off the take (a park sidecar),
exactly as note-replace parks the chord — bounded (authored breakpoints
only), visible and editable via re-seat. The producer emits the region's
**absolute** target curve — augment sums `parked-base + macro`, replace is
`macro` alone — and seats it on the target lane. Augment and replace
collapse to one realisation path, differing only in whether the sum folds
in the parked base. A 14-bit cc target seats its MSB/LSB pair through
`mm:wideCC`, so seated precision matches what the carrier gave.

**Summation adds points only where a curve is genuinely curved.** Two
piecewise-**linear** curves sum exactly at the *union* of their
breakpoints — no growth over the carrier, which already materialized that
density as CC. A **curved** segment (shape ≠ step / linear) has no
closed-form sum, so it is sampled onto the grid — the same CCINTERP
densification the absorber runs when a detune onset splits a curved
segment. So extra points land only on genuinely curved authored
automation under a macro, or a curved-shape macro segment; a pre-sampled
vibrato or LFO emits linear breakpoints and sums exactly. Densification
adds MIDI, never sidecar.

**The grid is time-absolute — this is what makes densification
idempotent.** Sample points snap to a global `k·gridStep` lattice in ppq,
*not* to a segment's own endpoints. A curve re-densified next rebuild
lands points at the identical ppqs, so the content-keyed reconcile sees
no churn — densification a pure function of absolute time, the G4
discipline of the canon fix and lane allocation. A segment-relative grid
would be stable only while its bounding points are authored; a summed
curve's are themselves derived, and would drift into permanent churn.

**The rule is about sums, not about curves** (2026-08-01). The
implementation sampled every curved segment, whether or not there was a
second curve to sum it against — so a lone sine or LFO, which is the
common case and the one every shipped continuous kind produces, reached
the wire as ~33 linear breakpoints where 10 `slow` ones say the same
thing exactly. A curve that is the only thing moving across a segment
*is* its own sum plus a held constant, and `mm:interpolate` is affine in
the endpoint values, so that offset shifts the curve and leaves its shape
and tension untouched. It must be the *whole* segment: the shape function
reads a normalised `t` over the segment's own span, so half a `slow`
re-fitted across its own left half is a different curve — which is why
the test is that the pair's ends coincide with the constituent's own
breakpoints, at both ends and not just the far one.

**Sparse output makes the fold's span load-bearing** (2026-08-01). While
every curved segment went onto the absolute lattice, the fold's output
was the same however its span was cut — the lattice is a global function
of time, so every decomposition landed on identical ppqs. A verbatim
segment is not: it depends on where its own ends fall relative to the
cut. That put the gated rebuild and a full re-derive in disagreement
wherever the dirt sliced a channel differently from its record edges,
which is what `tm_gate_parity_spec` exists to catch. So `foldChains`
folds over its covering records' own **extent** and treats `span` as a
selection of what to emit. The idempotence argument above is unchanged —
it simply stopped coming for free from the lattice, and the fold now pays
for it by not letting the dirt decide where segments fall.

The near miss worth marking: `sliceCurve` asks what looks like the same
question and answers it differently on purpose. It carries a cut curve's
shape *and* tension across the slice edge and accepts the re-fit, because
an authored bezier is meant to keep its tension inside an fx window
(`tm_fx_tension_spec` pins this). Summing and slicing are not one rule
waiting to be unified; teaching the slicer to densify what it cuts breaks
that spec immediately.

**Detune folds in unchanged (I1).** Each pb seat's wire raw is
`centsToRaw(curveValue + detune)`, splitting at detune onsets exactly as
the replace-pb path seats — detune stays realisation on the pb wire, the
curve rides on top. cc has no detune residual, so a cc seat is the curve
value verbatim.

Because `stream.pb` / `stream.ccs` are real summed curves a stage can
read and fold, `stream ≡ host` holds for the continuous channels too, not
just notes. Live preview (R5 / plink) may still want a runtime path
later; *committed* realisation is offline.

## Route-by-window — markerless seats via exclusive ownership

The seats carry **no per-event metadata**. A dense curve is thousands of
breakpoints; tag each with a `derived=` sidecar and the persisted data
explodes. They are recognized as generator-owned *structurally* — by the
region's **window**, not a marker: inside it every event is re-derived
each rebuild, content-reconciled, routed out of the column and kept out
of the authored value stream by the window alone. `addCC` mints a uuid +
sidecar iff a spec carries a non-structural key, so a seat written with
only `{ppq, val, shape}` (all native MIDI) carries none.

**Continuous only.** `target ∈ {pb} ∪ cc-numbers`, never a note. A note
always carries a uuid + notation sidecar for identity and round-trip
regardless, so markerless elides nothing there; only the continuous
streams — whose seats are pure realisation — win.

**The enabling invariant is exclusive ownership.** A markerless seat is
indistinguishable on the wire from an authored pb/cc, so recognition
works only if *everything on-take inside a replace window is generated*.
`parkWindows` emits a span for every continuous-replace target and the
park reconcile stashes the authored events off-take, on both wires: the
pb pass scans authored pbs straight from mm (the pb column isn't built
until the absorber runs later in the rebuild) and the cc pass scans the
column. The stash is the unified `fxParked`, one `evType`-tagged list.
Authored breakpoints stay visible via a `channels[chan].parkedPb` /
`parkedCC` render union the **view** folds in — symmetric with how it
unions the parked chord. Audibly a no-op: an authored bend already
sounded as the curve.

**Live recognition needs no standing record.** A live region recognizes
its own seats by its own current window, in hand every rebuild.
Reconciliation is churn-free against the freshly computed curve by
`(ppq, val, shape)`; the seat grid is time-absolute, so unchanged seats
keep. The absorber back-derivation must **skip** in-window pbs — a seat
has no cents and must not acquire any, or it stops looking like a seat. A
*deleted* region's orphaned seats are swept by a one-shot cleanup with
the bounds the delete site still knows — no persisted window mirror,
which would be redundant every rebuild the region lives.

**Bounds are logical; convert once, compare raw-to-raw.** A region's
`startppq/endppq` are logical; seats are raw-only (no `ppqL` — that is
the win). Convert the *bounds* to raw once per `(chan, window)` via
`fromLogical` and test raw seat ppqs against `[startRaw, endRaw)`
directly. Exact by construction: seats are placed by the same function,
so bounds converted by it have zero round-trip drift. Round-tripping each
*event* raw→logical instead — the inverse of seat placement — is the
shape to avoid. One predicate serves: `[startRaw, endRaw)`, half-open,
for recognition and for coverage, on pb and cc alike.

**The re-centre folds inward rather than the interval opening out.** A pb
window must return the channel to centre before it exits, and the
tempting place for that seat is the window end itself. That buys a closed
interval for pb alone — and the cost is not the special case but what it
does to the end row. Recognition, the sweep and the CC walk all read that
row as seat territory; coverage and the view's edit routing read it as
authored. A breakpoint landing there is claimed by both and protected by
neither: it loses its `ppqL`, drops out of the column, and goes with the
next sweep. So the re-centre seats at `endRaw - 1` instead, which is
where it was always meant to act. A stage closing its own span on the end
row folds inside as well (`foldIntoWindow`), so nothing a producer emits
can sit on the boundary. The end row belongs to whatever is authored on
it. Abutting windows are then disjoint in fact as well as in the test,
which is why the freeze gate carries no pb arm.

**A generator cannot be trusted to close its own window.** The tempting
reading is that where a curve ends is the generator's own business: it
authored the shape, so it authors the last point of the shape. Two of the
three continuous kinds behaved exactly so, and said as much in their
contracts — `sine` and `slide` each anchor zero at the window end. The
third did not. `lfo` closes on whatever phase the window happens to end
on, with `offset` added on top, so a curve LFO left the channel bent
after its region for good. That is action at a distance: an effect of the
fx legible past the span the fx owns. A promise two kinds in three keep
is not an invariant, and nothing downstream can tell which kind wrote the
breakpoint it is holding.

**So the machinery closes, and the generator does not.** The last tick of
every window — `endppq - 1` — carries the stream the stage *inherited*,
evaluated at `endppq`: what the target would read with no fx there at
all. One expression serves both fold modes, because both ask the same
question of a different stream. A replace hands back what it took over.
An augment hands back what it summed onto. The generator contracts then
stop being promises and become consequences, and `lfo` is sealed without
having to know it.

**The handback costs a tick, and the tick comes from the stage.** A
stage's own material folds into `[startppq, endppq - 1)`, and anything at
or past that line collapses onto the last tick inside it
(`foldIntoWindow`). Letting the close displace whatever already sits on
its tick looks cheaper and is not: a curve whose geometry lives in its
closing control point has that point eaten, and a lone interpolated
segment rising to its target at `endppq` flattens to a straight line at
nothing. Folding below the close keeps the control point. The price is
that the curve's geometry compresses by two ticks — `N/(N-2)`, which at
the working resolution is not a quantity anyone can hear, and would bite
only on a window a few ticks long.

**A parked value is handed back, not suppressed.** A pb region parks the
authored pbs it covers, which makes it tempting to close on centre, or on
detune alone: the parked value is not sounding, after all. But it is not
sounding *because of the fx*. To close on anything less would let the
region reach past `endppq` and silence something authored beyond it —
the same action at a distance, in the other direction. The criterion is
the counterfactual and nothing besides: past the window, the wire reads
as it would read with no region at all.

**Transitions: diff windows, don't mirror.** A markerless seat is
invisible to the park scan, so the scan cannot run every rebuild — it
would re-park the seats. It fires only at the create/remove instant, and
the mechanism is tm's own `fxRegions` observer rather than an enqueue at
the view edit site: the current windows are diffed against the last
baseline (RAM) and a one-shot transition staged for the next rebuild to
drain. A new window **parks** its authored events off-take (skipping
already-marked detune absorbers); a removed one **sweeps** its orphaned
seats. The queue is transient, consumed once, not persisted.

**cc drains earlier than pb.** The CC walk runs *before* the park, so cc
can't park-then-recognize the way pb does. The same park/sweep is staged,
but the walk drains it itself: a freshly-created window is **excluded**
from the fill-recognition set (its authored ccs stay in columns for the
following park pass to stash off-take — recognizing them as fill first
would let the reconcile delete them), and a removed window's orphaned
seats are deleted inline.

**Undo/redo needs no enqueue at all:** the take + `fxRegions` + `fxParked`
revert atomically, and REAPER's undo watcher delivers those rewinds as
`dataChanged` with `invalidate=true`; the observer reads the flag and
only resyncs the baseline, never enqueues (a stray sweep would delete the
just-restored authored pb). Reload resyncs the same way. **This is why
the diff lives in tm, not the edit site: the edit site can't see undo,
but the observer can.** On a plain remove the parked authored restores on
its own — gone from `fxRegions` → no longer covered → restored.

**Edge — swing at a boundary.** A seat is raw-only, so a swing change
moves it while its logical window is unchanged; a seat within a few ticks
of a window edge can land just outside the current-swing bounds and
escape recognition. `staleSwing[chan]` flags the case: on a swing change
the channel's replace-target seats are fully regenerated rather than
reconciled (churn on swing is acceptable).

**Edge — mixed-kind self-parked host un-parking.** A self-parked host can
chain a note-replace kind (parks the host, e.g. trill) alongside a
continuous kind targeting cc/pb. Removing the last note-replace kind
un-parks the host as a note *in the same rebuild* the surviving
continuous kind still runs — its target window must keep registering, or
the authored cc/pb it covers restores onto the take and collides with the
seats the surviving kind still derives. The self-parked-host window pass
therefore registers on any surviving `spec.fx`, not on
`generators.parksNotes(spec)` — that predicate is true only while a
note-replace kind is present, so it would drop the window on exactly this
frame. Extent is unchanged: the stash's authored ceiling.

## Continuous pb

**pb as generator input — authored breakpoints only.** A generator reads
only the *authored* (non-derived) pb breakpoints, whose logical value is
the persisted `cents` sidecar, so the pre-producer walk reads it directly
with no `cents-minus-detune` reconstruction and no absorber split. A
foreign-MIDI pb lacks the sidecar for one rebuild until the absorber
back-derives and persists it — harmless and self-healing. The heavier
path (the absorber's densified/derived logical stream as input) stays
unbuilt until a generator needs more than breakpoints.

**Replace seats an absolute curve on the base lane.** A replace-continuous
kind targeting pb emits its **absolute** curve, and the absorber seats it
on the base pb lane, reusing the value-aware seats: the producer records
the replace window with its curve, and inside the window the stream value
is the *curve* rather than the authored breakpoints. The curve's
breakpoints become derived seats carrying their shape; an authored pb
inside the window rides the curve on its wire, its column cents untouched
and visible; a curved curve-segment split by a detune onset densifies
exactly as an authored one does. Each seat's wire raw is `centsToRaw(curve
+ detune)`, so detune still seats (I1 intact). There is no carrier and no
add-bank slot — the retired path summed a detune-only base with a
separate additive carrier at the node; the seated model needs neither.

Caveats: the boundary from authored base to curve can step; a non-step
authored pb *inside* the window rides the curve in value but keeps its
own outgoing shape over the next cell (the same bounded artifact a
densified authored curve carries).

## Continuous cc

cc reaches the same place as pb by a slightly different route: no
absorber, no detune residual.

**Augment** sums offline and seats markerless exactly as pb does — the
parked authored cc is the base, the macro is summed onto it, and the
result is seated on the target lane.

**Rest — the base when nothing is authored.** When a cc-augment target
has *no* authored automation there is nothing to sum onto, so the fold
seeds from a resting value:

```
rest(target) = destProfile(target).rest
```

`destProfile` carries the per-dest defaults (`ccDefaultRest`: 64 for the
bipolar family — pan 10, balance 8, sound controllers 71–79 — 127 for
expression 11, else 0). Polarity is the controller's own, and its default
rest says it: one resting mid-scale swings both ways, one at a rail only
runs inward. The base is per target and authored in the column — inside
the window or governing from before it — deliberately not a per-region
field, so two regions over one target cannot disagree about it.

**Replace parks the authored cc and seats the curve.** Inside the window
on the target cc, the authored cc is parked off-take and the generated
curve written as literal cc events on the target lane, markerless and
recognized by the region window (§ *Route-by-window*). Like the note
chord, the parked cc is re-seated for display via
`channels[chan].parkedCC`, so it stays the visible, editable surface and
the fill never shows — creating a cc-replace region leaves the lane
looking unchanged (the invariant).

## Generator input streams

PA is not special. It was once framed as a park/re-emit/rebind problem,
but that operation can't exist generically — a generator's input→output
mapping preserves no event correspondence to carry a PA across (an arp
samples a chord and emits one stream; which input PA maps to which output
note is undefined). So PA becomes one of several **typed input streams
the generator reads over its window**. An ADSR gated by note-ons, a
CC-controlled vibrato, a pressure-aware arp all fall out of one shape.

`host` and `stream` are the same record — window+channel scoped, logical
frame, intent units:

```lua
host = { window = {startppqL, endppqL}, chan, lane, id,
  notes = { {pitch, vel, detune, ppqL, endppqL}, ... },   -- the membership
  pas   = { {ppqL, pitch, vel}, ... },
  ccs   = { [ccNum] = { {ppqL, val, shape}, ... } },      -- absolute, closed over the window
  ats   = { {ppqL, val}, ... },
  pb    = { {ppqL, val, shape}, ... } }                   -- val in cents
```

The continuous channels are **absolute closed curves** seeded from the
authored base *as parked* (the park stash authoritative in its windows,
the on-take stream elsewhere) and sliced to the window with entering and
closing edge values, so the curve is total over the closed window.

**Read the real projections, not mm.** Slice the streams from the column
projections, never reconstruct them from mm — re-deriving a view
projection at the seam is a smell, and for pb outright wrong (mm pb is
raw, not the `cents-minus-detune` the absorber computes). The streams are
cheap *because* their intent value needs no computation (note fields /
7-bit `val` verbatim) and they are projected to columns before the
producer runs. The PA projection lands *before the producer but after
externals and parking*: note columns are only settled (foreign MIDI in,
covered notes parked out) by then, and it must stay before the logical
projection so pitch-column matching still works in the raw frame.

**The stream key is `evt.ppqL or evt.ppq`,** not a bare `ppqL` slice: an
authored cc/at/pa carries `ppqL == nil` whenever raw already equals
logical (identity swing, or a swing-neutral position), so the fallback
gives the logical position with no `toLogical` round-trip.

The phasing is the structural move: **project inputs → generate →
reconcile outputs**. The generator consumes finished input projections;
its output feeds the existing later passes (tail walk, absorber).

## The fx chain

The motivation is the rigidity of bare kinds: you can arp but not shape
the arp's velocity, vibrate but not bend the rate in flight.

**The `fx` list is a series, not a fan-out.** v1 ran every kind against
the *same* host, then unioned the notes and summed the deltas — no kind
ever saw another's output, so "shape the arp's velocity" had nowhere to
live: a second kind could only read the chord, never the arp's notes. The
ordered list is instead a **series** — a `{notes, delta}` **stream**
threaded through the stages, each transforming what the last produced.
`[arp, velPattern]`: arp turns the chord into arp notes, velPattern
rewrites their velocities.

**One contract, no role.** Every stage is `expand(stream, host, params,
ctx) → {notes, delta}`, folded by the runner — a stage returns its
*output*, not the next stream. **Every kind reads `stream`**, so any kind
composes at any position (`[velPattern, arp]` arps the re-velocitied
chord; `[retrig, arp]` arps the tiles). `host` stays as the second
argument purely so a stage *can* read the untouched original — cost-free
provenance; slide's next-note lookup is the one real use, being keyed on
the original note record's identity. `mode` is the **fold**: replace
overwrites the stream's dest channel, augment adds to it; the final
output is the final folded stream.

**`mode` is a kind property; `dest` is a per-entry param.** A kind
declares `mode` in the one `generators.kinds` registry (which also
carries `expand`, `label`, `defaults`, `fields`). `dest` is chosen per fx
entry from the kind's domain profile — `destProfile(dest)` supplying
`unit`, `rest`, `bipolar`, `magScale` — so one dest-blind sine kind
serves pb and every cc rather than one kind per wire, and a param
expressed as a magnitude scales into whatever wire it lands on. The two
remain independent axes, so continuous-replace and discrete-augment are
both expressible.

**Emission is ownership — emit exactly what's been parked.** A stream
channel is emitted (and its authored base parked) iff some stage's `dest`
targets it; untouched channels stay authored and sounding. This is the
same predicate `parkWindows` applies per continuous target, extended to
notes: `parksNotes` fires on any note-dest kind, mode irrelevant. Without
it, "final output = final stream" would re-emit a vibrato-only host's
untouched membership as derived duplicates. A chain that folded nothing
re-seats its parked base, or — over an all-zero pb base — registers an
empty window so stale seats sweep.

**Order is semantic.** The list order, cosmetic in v1, is load-bearing: a
note-replacing source overwrites `notes`, an augment source adds to the
typed continuous channel, a velocity transformer reads+writes `notes` and
passes the rest through. `[replace, augment]` wobbles the replaced curve;
`[augment, replace]` overwrites the folded stream.

**Continuous emission converts at d=0.** The park scan, removal sweep and
seat recognition all convert windows at d=0, so delay-shifted seats would
orphan on removal — and doctrinally, delay is a per-note-on offset
(docs/timing.md), while a channel-wide curve has no note.

**The channel's fx region is a second note-grid; chains are its notes.** A
*chain* is a span carrying a series of stages — exactly `region.fx`'s
shape, no new storage. Multiple chains coexist on a channel as **fx
columns**, packed by overlap with the lane allocator re-pointed from
derived notes to chains: lowest-free in storage order, one grid column
per lane, disjoint regions sharing lane 1. On a note the chain is
`note.fx`, reached by in-cell badge + Super-X.

**Multiplicity resolves by the target's fold — pack, sum, or layer.**
Every output target folds overlapping contributions, and overlap is
well-behaved exactly when that fold is order-free:

- **notes** → lane-pack: any N chains flow into free lanes (two
  note-replace chains merge — they share the parked chord, pack into
  separate lanes);
- **augment continuous** (additive pb/cc) → sum — commutative, offline at
  seat time;
- **replace continuous** (overwrite pb/cc) → **layer**: no commutative
  fold exists, so **storage order is the precedence** (= the fx-column
  lane index for overlapping regions) and the later chain wins pointwise
  in the overlap (painter's algorithm) — the same left-to-right fold used
  within a chain, one level up.

So each per-chain continuous record carries a `mode` (replace if any
dest-targeting stage replaces, else augment), and a target's records fold
in storage order from the authored base: an augment record adds its
base-relative delta `(curve − base)`, a replace record overwrites. Two
replace curves on one target layer rather than sum, which is what
dissolved the old one-replace-region-per-target UI guard. Overlapping
regions with *differing* windows sub-split at every record edge — between
consecutive cuts the active set is constant, so each layer folds only
where it applies and an exclusive tail keeps its own curve. The
all-coincident case routes to the whole-span fold verbatim, so a
same-window replace emits its raw curve with no synthetic edge point.
The replace conflict is scoped per `(channel, exact target)`: distinct cc
numbers are independent wires.

**Window editing on the fx column.** The note duration/position verbs act
on the fx column too, editing a region's `(startppq, endppq)` (→
route-by-window park/sweep): `noteOff` truncates the tail to the cursor
row or grows it past the tail (the onset row is a no-op — deletion stays
the delete verb's job); grow/shrink resize from the end; nudge shifts the
whole window (fixed duration, no onset guard since regions may overlap).
The region under the cursor is found by a scan of its own column, since
fx cells sit in storage, not ppq, order. **A window edit keeps the moved
region in its lane**: when the edit adds overlapping siblings *before* it
(a lane bump), the region slides after the (lane−1)-th overlap so it
retains its lane and the newcomers fall to higher lanes; otherwise
storage is untouched (no churn on a disjoint edit). Either way the caret
re-centres on the region by uuid, so it tracks across a column
merge/split. Because lane = precedence, a lane-holding reorder slides the
moved region's precedence with it — acceptable because the
precedence-reorder verb owns that intent explicitly.

**Precedence is reordered explicitly.** `eventShiftLeft`/`eventShiftRight`
on the fx column bumps the cursor's region one badge column toward the
shift, swapping storage order (= precedence) with the overlapping sibling
beside it at the cursor row; nothing overlapping there is a no-op. The
storage swap *is* the precedence flip.

**Transformers rewrite values; rate stays a source param.** A transformer
freely rewrites event *values* and nudges *discrete* timing (velocity,
density, humanize, swing, transpose); it cannot coherently rewrite a
continuous source's **rate**, because vibrato's breakpoints are placed by
accumulated phase and resampling them loses coherence. So the line: value
and discrete-timing are chain stages; rate / period / phase stay internal
to the source as params. "Shape the arp's velocity" is a transformer;
"bend the vibrato rate in flight" is a source param, and generalizing
*that* is `design/pipe-dreams.md`.

**Sibling chains are addressed by the caret.** Overlapping chains pack
into sibling fx columns, so moving the caret between them selects the
chain — the cursor's ppq is the scope, as it is everywhere else in the
tracker, and overlap disambiguation falls out. An in-editor cycle (Tab
across siblings) was specified when the modal was the editor and the grid
could not address them; the column packing made it redundant and it is
dropped.

## Parked editing — the third backing

A parked event is the *visible, editable* surface, and it edits exactly
like any note or cc — transpose, resize, retune, delete, and type a new
one into the window — with no second editing surface.

**The shape — a third backing, keyed by position.** The view's leaf-edit
facade dispatches every edit to a `backing` strategy by `kindOf(evt)`:
`member` (gm) when the cell sits inside a group region, else `plain`
(tm). An fx-region that parks **defines a parked zone exactly like a gm
region defines a member zone**, so this is a third backing, `parked`,
that `kindOf` routes to positionally — not a branch bolted into
`tm:assignEvent`. Keeping it a backing buys two things a tm-branch can't:

- **a real, sensible `add`** — typing into the zone writes a logical spec
  straight to the stash, no mm round-trip; and
- **free move semantics** — the facade's existing cross-kind relocate
  (delete from `src` backing, add to `dst`) gives move-out
  (`parked`→`plain`) = drop-spec + take-add, and move-in
  (`plain`→`parked`) = take-delete + stash, with **no churn** on an
  in-zone value edit or ppq nudge (`parked`→`parked` stays one kind).

Parked notes/ccs stay **out of `columns.notes`/`columns.ccs`** (they are
unioned into the render only), so no sounding-walk — tail walk, PC
synthesis, lane occupancy, `fxWindow`, the flush collision scan — ever
sees them; the same-pitch collision dissolution that parking buys is
untouched.

**The forced constraint — parked edits stage, they do not write `ds`
inline.** `ds:assign` fires `dataChanged` → `tm:rebuild` **synchronously
inline**, and a rebuild reloads the um cache. So a parked edit that wrote
`ds` mid-loop during a multi-select (a transpose spanning a parked chord
and normal notes) would rebuild and **discard the still-staged mm
edits**. This is a correctness hazard, not a deferrable nicety: parked
edits ride `tm:flush` like every other staged edit, through a
`parkedEdits` buffer peer to `adds`/`assigns`/`deletes`. Flush applies
them to a cloned stash under a guard that suppresses the inline
`dataChanged` rebuild, then either rides the existing mm reload rebuild
or drives one explicit rebuild when the edit was parked-only. The stash
keys are `uuid` for notes (minted on add) and the natural `(chan, cc,
ppqL)` for ccs, which carry no uuid.

**The shared park-window predicate (the DRY cut).** The view must tag a
cell `parked` over *exactly* the spans the park pass parks over, or the
tag and the parking disagree. Both read the same pure `generators`
surface: `parksNotes(region)` and `parkWindows(regions)`, the latter
returning `{ notes = { [chan]={{s,e},..} }, ccs = { [chan]={ [cc]=... } } }`.
Any new reason a stage stops contributing — bypass, say — has to reach
these predicates too, or the runner and the tagging drift apart.

**Specs are logical-only.** The stash drops realised `ppq`/`endppq` and
derives them fresh on restore via `fromLogical` under current swing.
Parked cells carry the fields the backing addresses by (`chan` + `uuid`
for notes, `chan` + `ppqL` for ccs) plus the authored ceiling as
`endppq`, so the note move/resize machinery works on them unchanged.

**Decisions taken** (revisit if a need appears):

- *uuid stability across unpark splits by path.* A **restore** (fx
  removed / window moved off) supplies the spec's original uuid to
  `mm:addNote` under `keepUuid` — fx-editor handles survive the round
  trip. A **move-out** sheds the uuid: a relocation is a new note, not
  the old one returning.
- *`member` vs `parked` precedence* if a gm group and an fx region ever
  cover the same cell: pre-beta, `parked` wins and we assert disjoint.

**No `fxManager`.** tm is large, but fx is not a *layer* — it's phases
woven into tm's one rebuild, sharing the `fx` accumulator and the
deferred mmBatch, and the tail walk deliberately fuses authored +
external + derived notes into one atomic commit. An `fxManager` would
have to reach into tm's `channels`/`fx`/`deferred` — the cross-layer
reach the architecture forbids; size-down, coupling-up. And parked edits
must coordinate with `adds`/`assigns`/`deletes` in `flush`, so splitting
parking out is the wrong cut. Pressure-relief is instead to push **pure**
fx logic into `generators`, the ctx-discipline direction. If tm-size ever
forces a structural split, the honest seam is the **whole rebuild
pipeline** lifted to a `trackerRebuild` file with `channels`/`fx`/
`deferred` as an explicit ctx — not fx.

## Note-host replace parks

Note-host replace does what the name says: a note carrying a
discrete-replace kind **parks itself** (membership `{self}`), exactly as
a region parks its covered chord. All hits are derived output —
retrig/trill emit tile 0 — and the parked cell (carrying `fx`) is the
visible, editable surface. Dead with it: the `fxHostEnd` view-restore
dance, the tail-walk's clip-host-to-first-fxNote special case, and the
no-derived-output-at-the-host-onset constraint on generators. The two
hosts now differ only in membership and where the fx is stored — the
precondition for a chain stage behaving uniformly on both.

Mechanics. The park scan applies an identity criterion (`evt.fx` +
`generators.parksNotes`) alongside the window one, to live notes and
prior specs alike — so a region-parked note whose own fx carries a
discrete kind stays parked when the region moves off, becoming its own
host with no take round-trip. Parked specs/cells carry `fx`; restore
returns it, honouring the spec's original uuid. The producer walks parked
cells (window = the realised parked extent, which the restore pass
already bounds exactly as `fxWindow` would; cells inside a region's
note-park window stay region membership). Region lane allocation seeds
occupancy from already-emitted derived specs, so a parked host's tiles
hold its lane against an overlapping region. A parked edit dirties its
channel at flush — parked specs are producer input. The view tags only
the parked cell's **onset row** `parked` (membership `{self}` is closed:
adds elsewhere in the span stay plain, unlike a region window), and the
fx-host lookups resolve parked uuids between mm and regions. PA display
anchors to the parked cell's lane, and the PA parks off-take with the
host like any other — `rebuildRegionPark`'s PA pass keys on the host
cell, not on how it came to be parked (corrected 2026-08-04; this read
"stays take-side" from before PA parking landed).

## The chain surface

The UI and extensibility half of the chain. The through-line: **chains
shrink the kind vocabulary instead of growing it.** With series
composition most new-kind wishes are *spellings* of a few hard primitives
— strum = `[arp, humanize]`, gated arp = `[arp, densityGate]` — so the
primitive set stays small (sources: arp, retrig, trill, sine, slide, lfo,
ostinato, chordStamp; transformers: velPattern, humanize, transpose,
density, swing) and expressivity comes from composition. This is
generators-as-config one level up: a kind is data when its body is
arithmetic over ctx ops; a chain is composition-as-data.

**The editor is the fx palette tab.** A chain has two axes (stages,
params) plus siblings, and a flat modal field list showed none of that —
the modal is retired. The surface is an **fx** tab in the right-hand
palette (parameters | fx), a vertical list: stages top-to-bottom in
series order with their params under each, Up/Down walking every field
across stages as one column and Left/Right always *editing* (nudge a
field, or open a stage's kind picker). The rotation is what buys clean 1D
navigation — no axis does double duty. The tab auto-raises under the
caret and lapses when the caret leaves; the session is transactional
(snapshot on entry, commit or revert). See docs/trackerRender.md § Palette
tabs, § FX chain for the built behaviour.

**Resist the DAG.** Parallel → series with target folds is a comb, and
the comb is the model. Sibling chains give parallel; the fold gives
summing; order gives series. A node canvas (the wiring page's idiom)
invites exactly the fan-out and geometry-as-order the semantics forbid —
audio routing earns a DAG, note-fx doesn't. Borrow the wiring page's
*chrome* (bypass badges), never its canvas. Likewise no parallel blocks
*inside* a chain: sibling chains already express it.

What remains unbuilt, in `plan/chain-surface.md`:

**Per-stage bypass.** A stage that stays in the chain with its params
intact and contributes nothing — the A/B compare gesture, which today
costs you the stage. It stores like `rest`: realisation metadata riding
the fx entry, read directly and never passed through `expand`. That
storage is the whole rule — **bypass changes the realisation and never
touches the authored notes.** A chain's parked chord stays parked whether
or not its stages are bypassed, so the toggle moves nothing between take
and stash and `parksNotes`/`parkWindows` never learn about the flag; a
fully bypassed chain folds nothing and re-seats its parked base verbatim.
What the flag *does* reach is the fold: the runner runs no bypassed
stage, and `chainDestType` counts one as **augment**, so a bypassed
replace stage stops overwriting a lower-precedence chain's curve on the
same target.

*Decision taken — demote, don't remove.* This first read "bypass drops the
stage's **ownership**, so an all-bypassed chain behaves as though it isn't
there", which contradicts the realisation-only storage a sentence above
it: dropping ownership unparks, and unparking moves authored notes through
the mm round trip on a keystroke built for repetition. Demotion — inert in
the fold, augment for precedence — reaches the same neutrality with the
park machinery untouched. Inert is the per-mode identity rather than an
early skip: ownership is registered inside the fold, so a skipped stage
emits no record at all and the parked chord and parked base it left behind
are never re-seated — silence, not neutrality.

**Chain signature on the grid.** The fx-column badge shows only the
region's primary kind, so a three-stage chain and a one-stage chain look
alike. Stacking the stages' one-char glyphs in series order down the
region's tail rows makes behaviour readable without opening anything, and
matches the palette's own vertical stage order.

The vocabulary landed first, on the registry (2026-08-04). A kind's glyph
is a field on its `generators.kinds` entry, and `generators.glyphOf` is
the one place a kind resolves to a character, so the view mints the badge
already holding it and the grid renderer knows nothing of the set. The
set divides by what a kind touches: a letter for one that shapes notes
(`R` `T` `A` `O` `C` `V`), a wave mark for one that paints a continuous
stream (`∿` sine, `/` slide, `~` lfo). Case would have drawn the same
distinction and lost it, because at one cell a letter against a squiggle
survives where upper against lower does not. A kind the registry has lost
draws `?` — which is what a scripted kind that failed to load will look
like.

**Row keying is absolute, not relative.** `chainStack` addresses each stage's
row by absolute grid row rather than an offset from the badge, because the
badge row and the tail's `startRow` aren't the same kind of number —
`placeRow` snaps the badge to its integer row, but the tail's own `startRow`
keeps sub-row float precision. Keying by absolute row lets the stack and the
tail bracket share one row space without a snap-vs-float mismatch leaking
into where a glyph lands.

*Decision taken — the clip mark outranks the badge (2026-08-04).* A chain
with more stages than the region has rows gives its last drawable row to
`…`, and where the region is one row deep that row is the badge row, so the
primary kind's glyph is what `…` displaces. Keeping the badge there would
preserve today's reading at exactly the size where it lies: a one-row region
carrying `[arp, humanize]` shows `A`, which is the misreading the stack
exists to end. `…` says less and says it truthfully.

**Ghost-on-focus.** The ghost display mode of § *Authoring and editing*,
defaulted on while the fx pane holds focus — "what does this chain
actually emit" becomes a live question the moment stages compose. Note
ghosting is a new path rather than a reuse: the existing ghost mechanism
is scalar (cc curve samples between breakpoints), so derived specs need
surfacing to the view as non-editable cells sharing the ghost styling.

*Decisions taken — the gate is the caret's host, and the parked cells give
way (2026-08-05).* "Holds focus" resolves to the caret bracketing an fx host
— `tv:fxHostAtCursor`, which the view already computes for the tab's own
auto-raise — rather than keyboard focus inside the strip: with the strip
focused the arrow keys walk chain fields, so gating there would light the
ghosts only while the caret can't be moved across them. What shows is every
derived note in view, not the caret host's alone, so a sibling chain
colliding with yours is visible where the collision happens.

While the ghosts are up the parked cells drop out of their columns — showing
both is showing one span twice, and the parked chord is the picture the
ghosts exist to stand in for. The exception is a parked cell carrying a chain
of its own. A note hosting a replace chain parks itself, so hiding it would
take away both the host and the only way to edit the note; and that holds
however the cell came to be parked, not only when the caret is on it
(corrected 2026-08-06; this read "the cell the caret resolves its host from",
which hid a note host a region's window had parked and took its chain out of
reach with it). The criterion is the cell's own `fx`, so a host cell keeps
its row, and that row shows no ghost, because a real cell already outranks one.

*Decision taken — a ghost is an onset, and tm hands them over ready
(2026-08-05).* Ghost notes carry no tail. A retrig ghosted with tails paints
a wall of glyphs across the span the parked host's own tail already covers,
and the scalar ghosts this borrows its styling from are a value on a row
with no extent. That takes the end fields out of what the view needs, and
with them the reason to reconstruct a derived note at read time: the fx pass
knows every fact a ghost shows at the moment it emits the spec, so tm keeps
a per-channel list of onset records in the logical frame and the view reads
a window out of it. Two alternatives were priced first. A scan of the raw
index per read pays a whole channel's notes to find a handful, and, that
index being raw-sorted, has to carry the window into the raw frame to seek —
where a note's onset carries its producer's delay, and delay reaches 9999
millibeats, so the seek would need most of ten beats of slack to be safe. An
index of uuids resolved through `byUuid` keeps the hop without answering the
frame. Storing the logical onset makes the window query a binary search on
the field the query is about.

*Decision taken — the ghosts are derived per frame, not stored on the column
(2026-08-05).* Both of the display's inputs move without a rebuild: the gate
is the caret and the window is the viewport, where `tv:rebuild` answers only
to tm's signal, a column add or remove, and config. A table hanging off the
column would therefore be stale on the first arrow key. The view derives the
ghosts at read time instead, as it already derives the drag preview, and it
resolves the host itself — `tv:fxHostAtCursor`, the same call the fx tab's
auto-raise makes (corrected 2026-08-06; the render frame used to hand its
host in, and that host is the fx strip's, which pins to a focused editing
session and so could name a chain the caret had long since left). What the
pin bought was ghosts that survive the session in which the chain is being
edited; the price it charged was ghosts belonging to a chain the caret is
nowhere near, and the caret is what the display is answering about.

*Decision taken — the host gates the display and does not filter it
(2026-08-06; reversed below the same day, and kept for the reading it was
rejected on).* A nil host answers nil; any other host turns on every derived
onset the visible window holds, whatever produced it. The accessor never
compares a note's `derived` uuid against the host it was handed. So two
chains in view light together, from a caret on either. What the display
shows is the realisation of the window the caret is in, and where two chains
interleave their output that is one surface, not two; filtering by producer
would show half of what is about to sound. The price is that the caret says
which chain is being edited without saying which ghosts came from it.

*Decision taken — the overlay is one producer's realisation, and the caret
names which (2026-08-06, superseding the above).* The price named there is
not a price, it is the display losing its subject. A ghost says "this row is
computed", and a reader looking at one wants to know by what; a surface
lighting every chain at once answers that question for none of them. The
rule was also wider in practice than on paper. `tv:fxHostAtCursor` answers
with whatever uuid'd event sits under the caret, chain or no chain, so a
caret resting on any plain note anywhere lit every derived note in the take.
The gate is now that event's own chain, resolved through `tm:fxRealisation`:
a cell running none answers nil, and a cell running one shows that chain's
notes, the curve it claimed, and the originals it parked. Sibling collisions
are read by moving the caret onto the sibling, which is also how you would
ask which chain to edit.

The filtering is not done at read time. A `derived == host` test in the draw
loop would answer the question and leave the walks it answers it from in
place: an accessor gathering every channel's derived notes, and a suppression
pass gathering every parked cell in the document, both per frame, to discard
nearly all of it. The rebuild already holds the answer — a derived spec
carries its producer's uuid as it is emitted, a park window carries the id of
the chain that opened it, and the census names every producer on the take. So
tm keys those three outputs by producer as it builds them and gathers them
into one entry per chain at the pipeline tail. The view's whole query is then
a lookup, and what it walks is one chain's output rather than a take's.

*Decision taken — the suppression is the overlay's second half, keyed by the
cell (2026-08-06).* The read that answers the ghosts answers what they stand
in for: one call on one host gate, a `notes` half and a `hidden` half. The
placement pass was the alternative, and it is out of the caret's reach —
placement runs on rebuild, the gate moves with an arrow key. Riding the
overlay also leaves `col.cells` whole, so nothing that resolves an event
through a cell — the host lookup, the leaf-edit facade, the caret — loses
its footing while the ghosts are up: a suppressed cell is invisible, not
absent, and stepping onto one restores it, because a parked member carries
no chain for the tab to raise. `hidden` is keyed by the event table rather
than by row, because a note's tail bracket is drawn from a second list that
carries no row the cell loop would recognise (`startRow` is fractional for
an off-grid onset), and one identity then answers for the cell, its tail and
its temper tick alike. The suppression reads `channel.parked` alone, so
parked ccs, pbs and PA stand: nothing ghosts them, and hiding them would
take a picture away without offering one in its place.

*Decision taken — the ghosts land in the columns that exist, and claim no others
(2026-08-06).* A region chain that emits polyphony allocates lanes above the
authored ones: a three-voice stamp over a single note on a one-lane channel
derives lanes 1 to 3, and two thirds of its ghosts have nowhere to hang. A chain
claiming a pb or cc the channel has never carried has nowhere at all. The
tempting answer is that the grid should show the claim — a column materialised
from the data, on the fx column's model, standing empty until the ghosts are on.
It was built twice and withdrawn twice, and for the same reason both times: such
a column is not the user's, and everything the grid does with a column assumes
that it is.

Standing permanently, it cannot be put away. Hide reads a channel's lane count
off the grid, so a derived lane had to be made invisible to that count or hide
would write back a larger one and quietly stop working. A derived pb or cc column
passed hide's empty check and then cleared nothing, so it returned from the data
on the next rebuild. Every chain's claims stood open at once, addressed or not.

Gating it on the caret is worse, and worse in a way worth naming, because
`ec:col()` being an index sounds like a fact about the caret — which invites the
obvious repair, of re-finding the caret's column after each rebuild by identity:
channel, type, lane, cc. That rescues the caret only where its column survives
the rebuild, and the motions that matter are the ones where it does not. Moving
left off an fx host lands the caret on the claimed column immediately to its
left. The move de-addresses the chain, so the column just landed on collapses,
the fx column slides into the vacated index, and the caret arrives back on the
host, which puts the column back; the keypress cannot be completed. The caret is
also not the only holder of a column index. A selection is `col1, col2`, with no
identity to re-find them by, so crossing an fx host with a selection live leaves
it covering columns it was never dragged over.

So columns follow the data and the user, as `extraColumns` and the authored lanes
do, and the ghosts follow the caret within them. A derived note in a lane the
channel does not carry does not show, and neither does a curve on a target
nothing has authored. Adding the column by hand is what makes it visible, and tm
already grows a channel's columns for a note written above the count, so
authoring into the new lane is all it takes.

What this costs is the claim itself. An lfo on a cc the channel has never carried
leaves no mark on the grid, so nothing there distinguishes a chain that is
working from one that is not, and the fx tab becomes the only place the target is
written down. The glyph stack down the region's tail names the kinds in a chain
but not what they address, so it narrows the question without answering it. Two
things would close the gap and neither is taken here. The claim could add a real
column once, when it is made, in the fx edit's own undo block — no new kind of
column, hide working on it unchanged, at the price of a document write as a side
effect of an fx edit. Or the caret-gated set could be made safe by holding the
caret and the selection by column identity throughout, which is a piece of work
in its own right rather than a fix to this one. The decision is to try the plain
thing first and find out whether the invisibility bites.

One neighbouring gap this does not close. A note host's derived notes ride the
host's own lane by design, so a three-voice stamp on a *note* still shows one
ghost of three — that is lane sharing, and no column answers it.

*Decision taken — the continuous targets come off the census, not the emission
(2026-08-06).* A curve can only be ghosted where the view knows which targets the
chain claims, and over what spans. Emission is gated — a producer outside the
dirty interval is kept rather than re-run, and a kept producer emits no record —
so a column read off the emission vanishes on the first edit elsewhere in the
channel and returns with the dirt. The note case could ride the emission because
the reconcile re-adds a kept producer's specs verbatim; nothing re-adds its curve.
What does not blink is the census: `parkWindows` already walks it for a cc window
per continuous cc target and a pb window per pb target, blind to dirt and blind to
bypass, so the target set is a fold of the window set the rebuild computes for
parking anyway. One thing follows from taking the census whole: a note host claims its
targets exactly as a region does, so a note carrying an lfo ghosts into the cc
column it modulates, wherever the channel carries one.

*Decision taken — the continuous case ghosts too (2026-08-06).* Knowing that a
target is claimed is not yet seeing what the chain does to it. The note case
shows its derived notes as ghosts while the caret sits on the host; a chain's
contribution to a cc or pb column it shares with authored events is exactly as
invisible without the same treatment. So the continuous case takes the same gate
and the same styling. `tm:fxCurveAt` answers
what a chain realises on one target at one logical ppq; `tv:ghostOverlay` samples
it at every visible row of every claimed column; the draw arm renders it in the
ghost colour ahead of the interpolation ghost, which describes the authored curve
alone and whose events, inside a producer's window, have been parked out of the
way. Two things were decided against here. The source is the take, not the
emission — the seats stand whether the producer ran this rebuild or was kept,
which is the same reason the claim itself comes off the census. And the curve is
sampled per row rather than bucketed by seat, as the interpolation ghosts already
are: a curve has no onsets to bucket, and a 1/4-QN sine seated at the cc grid step
would otherwise show its zero crossings and nothing else.

**Patches.** A patch is a *named chain* — an ordered `{kind, params}`
list, pure data, no code — saved to a library and instantiated **by copy**
onto a region or note. `design/archive/fx-patterns.md` has since proved the
machinery one level down: a scoped ds shelf with Save/Load through
`chrome.drawPicker`, create and delete hooks, and load filtering on
compatibility. A chain patch is the same idiom over `fx` lists, with the
picker on the fx tab's action row. Live patch *references* (edit the
patch, instances follow) are the gm invertibility axis reappearing;
deferred until wanted.

**Scripted kinds — an editor-page pane.** `generators.kinds` is already
the seam: one registry entry per kind, user-extensible by construction. A
scripted kind is a user Lua chunk evaluating to that entry-shape, edited
in a third editor-page pane beside swing and temper. The pane rides the
existing `libraryTreeSpec` machinery whole — global/project tiers,
promote/demote, new/import/delete, dirty tracking — which already models
exactly this: named, tiered, user-authored artifacts. The ctx discipline
is the contract surface: a scripted `expand` composes stream + host +
params + named ctx ops, pure, no reach into tm. Loading is
eval-into-registry at startup / library-save; a broken script degrades to
its kind vanishing from the registry with a status-bar complaint, never a
rebuild fault.

## Known gaps and accepted quirks

- **A slide into a parked successor arrives late when the host's tail
  runs past it.** `ctx.nextSameLaneNote` reads lane occupancy as column ∪
  parked (2026-08-04, replacing the wider gap where a parked host got no
  successor at all and `[trill, slide]` gave the trill alone), so the
  target is right. The host's *window* clip is still column-only
  (`hostWindowEnd` → `nextLaneOnset`), so a host whose authored ceiling
  runs past the parked cell glides across the whole tail and arrives
  after the note it aimed at. Where the ceiling ends at the successor —
  the ordinary case — the glide is exact. That clip governs every kind's
  window, not slide's, so unioning it is its own change.
- **A member straddling a window edge is parked whole** — **accepted**
  (2026-08-04, examined against a derived-remainder design and refused).
  Membership is by onset, so the member belongs to the region entire.
  Realising the uncovered tail would mean a note-on at the window edge:
  an attack the author never wrote, standing in for a note the region
  has already spoken for. Silence is the honest realisation, and the
  authored note loses nothing by it — the parked cell is the whole of
  it, visible and editable throughout. The rule reads the same in the
  other direction: a note whose onset precedes the window is not a
  member, and sustains through it.
- **A region-parked note's own fx stays suppressed** while the region
  covers it. It survives in the spec and returns when the region moves
  off, so this is a quirk rather than data loss.
- ~~**A replace region's parked PAs stay take-side**~~ — **withdrawn**
  (2026-08-04, probed in a spike tree against `tm_fx_region_spec`'s
  harness). A PA parks exactly when its host note parks, and that holds
  for both host kinds: a region-parked chord's PAs leave the take (the
  standing case at `tm_fx_region_spec.lua:319`), and so do a self-parked
  trill host's — one parked cell, zero PAs on the wire, one PA in the
  stash. Nor is the symptom reachable from the other side: a note whose
  onset precedes the window is not parked, and a replace region's members
  *are* its parked cells (`trackerManager.lua:3620`), so it derives
  nothing to sound against. What remains is narrower and inert — a PA
  inside the window but past its host cell's end stays take-side, on a
  pitch where no derived tile reaches it.

## Deferred — no consumer

- **PA replace.** No generic park/rebind path can exist — see
  § *Generator input streams* for why the operation is undefined.
- **Note-fx hosted on a region-parked note.**
- **Bake-on-export.** Address rewrite + merge of delta streams into their
  target lanes for plain-MIDI export; densification cost paid only there.
- **The per-lane note-fx pop-out column** — earns its keep once parameter
  stops land and there is inline editing the badge can't carry.
- **The shared `regions` substrate (R7 piece 1)** — both tracks resolved
  standalone, so nothing has justified its shape.

## Owned elsewhere — not this doc's work

- **Params whose value is a pattern or a curve** → `design/archive/fx-patterns.md`.
- **Freeze** → `design/archive/fx-freeze.md`; one-way in both directions.
- **Param modulation and the stepped feed** → `design/pipe-dreams.md`.
  The obligation those leave on today's work is a writing discipline
  only: keep `dest` a clean single axis, and shape new continuous kinds
  *incrementally* — phase accumulators and step loops, never closed forms
  over the window — so the window can shrink without rewriting the body.
- **R5 — plink via MIDI; retire the listen bank**, and the **single-node
  packaging** it unblocks → `design/cv-2.md`. Do not build under
  note-macros.
- **R4 — flush-time mechanism registry (`dirtyFxHosts`).** Measured
  not-warranted; the apparent cost was a carrier-reconcile churn bug
  (fixed). Build only if a measured hotspot reappears.
- **R3 — `forEachEffectiveNote`.** Extract on its third real occurrence;
  not before.

## Open questions

- **Bake-on-export.** Address rewrite + merge of delta streams into their
  target lanes for plain-MIDI export.
- **`plink.midi_*` parms.** Exact config-parm names and automation-bus
  addressing for R5 (→ cv-2); gates the listen-bank retirement.
