# note macros v2 — region hosts and the generator spectrum

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

## Status at a glance

Quick board; the prose lives in **Build progress** and the per-topic sections.
Track A is the generator substrate, Track B the authoring UI. Checked = landed.

**Landed**
- [x] A1 — region producer + free LFO (N=0)
- [x] A2 — membership + chord-arp + lane allocation (N≥2)
- [x] A3 — replace mode: discrete member parking
- [x] A4 — generator input streams (notes/pas/ccs/ats/pb)
- [x] A5 — mode is a generator-kind property; one registry per kind
- [x] Continuous **pb** replace — absolute curve seated on the base lane, no carrier (§ A4)
- [x] Continuous **cc** augment — node-fork collapse + rest seat + auto-pan kind (§ Continuous cc)
- [x] Continuous **cc** replace — park authored cc off-take + write the curve direct (§ Continuous cc)
- [x] B1 — fx-region column + Super-X addressing
- [x] B2 — parked note + cc display (render only)
- [x] B3 — parked notes/ccs *editable* off-take via a third edit backing (§ B3) — all four steps landed (the `generators` extract; logical-only specs + identity capture; staging verbs + flush integration; the `parked` view backing + cell tagging)
- [x] Note-host replace parks the host — all hits derived, the `fxHostEnd` dance deleted (§ Note-host replace parks)

**Open / next**
- [ ] offline continuous realisation — park-and-seat, retire the carrier/node (design only, § Offline continuous realisation)
  - [ ] **route-by-window** — zero-eventMeta seats via exclusive-ownership parking + tag-for-deletion (§ Route-by-window; **pb parking landed** — exclusive ownership now holds for pb, markerless seats next)
- [ ] fx chain — series composition + multi-column authoring (design only, § The fx chain)
- [ ] chain surface — docked chain strip, scripted kinds pane, patch library (design only, § The chain surface)

**Deferred (no consumer / intentional)**
- [ ] **PA** replace — no generic park/rebind path (§ A4)
- [ ] Multi-chain painter-layering for replace — overlapping pb fx is UI-blocked instead
- [ ] Note-fx hosted on a parked note
- [ ] Freeze (to raw / to mirror group), ghost-note display, bake-on-export

**Owned elsewhere** — R5 plink → `design/cv-2.md`; R4 dirty-registry & R3 `forEachEffectiveNote` build on demand.

## What v1 left standing

v1 is complete and shipped. The single open frontier is the **host**: v1
has exactly one host kind — the note — and the note plays five fused
roles that N≠1 pulls apart. Everything else the v1 doc flagged is settled
(arp, trill-cents, gen-stack UI, R4 dirty-tracking) or owned by another
doc (R5 plink and single-node packaging defer to `design/cv-2.md`).
Those are listed at the end.

## The five roles of the host note

In v1 the host note plays five distinct roles, fused onto one object
because a note conveniently *is* all of them at once. The fusion is what
N≠1 breaks, and teasing the roles apart is most of the design:

1. **Audible note** — it plays, and may be tail-truncated. The audible
   first hit.
2. **Generator input** — the events the generator reads (`host.events`).
3. **Logical region** — the window the output lands in (`host.window`).
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
that doesn't generalize, and it earns its keep in v1 for exactly one
reason: PA binding rides fxNote 1, which *is* the host. Strip that and
it's pure liability — it forces the `fxHostEnd` view-restore dance, whose
only job is to sustain the fiction that the note you *see* (authored
length) and the note you *hear* (truncated to fxNote 2) are one object.
A region host has no privileged host note: all hits are derived output
(§ *Generator output*), so (1) is not a host role at all — it's output
the generator may or may not emit, and the dance disappears. **Landed
2026-07-03:** the note host parks too (§ *Note-host replace parks*) —
the dance is deleted on both hosts.

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

**The note host is the degenerate region** (the **(iii)** stance: the
host *interface* is always a region; the *representation* is dual). A
note presents itself to the generator as a region whose `chan`/`window`
are its own and whose `fx` is `note.fx` — but that region isn't
materialized; it's just the note carrying `fx`. Explicit region objects
exist only for N≥2 and N=0. So:

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
  derived from it by a containment query. Window → input.

So the contract's primitive is *region + a membership rule*, with `events
= membership(region)`: `{self}` for a note, `{covered notes on the
channel}` for a region, `∅` for a free LFO. One rule, three host kinds,
no special-casing below the contract.

**Replace absorbs; augment queries (A3).** The query above is the whole story
only for *augment* — members stay in the take, sound, and feed the generator.
*Replace* cannot leave them there: a member the output stands in for must not also
sound, and it cannot be muted — a muted note still carries a note-on/off pair that
MIDI_Sort mispairs against a same-pitch derived note, and a CC/PA has no mute bit.
So replace **parks** its members off the take into a store (`fxParked`), re-homed
each rebuild (covered → off-take, no-longer-covered → restored). The parked members
are still the membership, and — inverted from intuition — they are the *visible,
editable* surface: you see and edit the chord, the generated arp is hidden (take-only,
as v1 derived). The invariant underneath: **creating an fx region never changes what
the user sees.** Replace stops the authored events *sounding* but keeps them *shown and
editable*; the generator's output is hidden realisation. It holds for every replace path
— the note chord (`fxParked` → `channels[chan].parked`), the cc source (`fxParkedCC` →
`channels[chan].parkedCC`), and pb (authored breakpoints stay visible in-column, only
their wire contribution zeroed). So for replace, membership *is* storage, off-take; for
augment it stays a live query. **Whether a region does this is read from its kinds, not a
`region.mode` toggle** (A5): a discrete kind replaces, a continuous kind augments.

**There is no dirty tracking to design.** The rebuild regenerates and
diffs unconditionally every time (R4: `dirtyFxHosts` is unbuilt and
measured not-warranted), so "membership changed → regenerate" is a
non-problem. A region host just **re-queries its covered notes each
rebuild** — a fresh containment query at expansion time, output-stable so
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
- **deltas** — additive breakpoints per target, the chosen pb / cc
  (continuous kinds), summed at the node as in v1.

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
  members** — overlaps are resolved by lane separation, not by clipping,
  so the unified tail-walk doesn't touch derived region notes (it still
  clips authored notes and, in the v1 augment path, the degenerate
  note-host's fxNote-1).

**Determinism is the whole ballgame.** Because lane allocation is the
sole overlap resolver, it must be a *pure function of the region's
occupancy* — lowest free lane first, deterministic append — exactly the
discipline carrier-code allocation already follows. Lean on iteration
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
persisted. The degenerate note host still binds PA to its note. (PA
parking and re-emit are **A4** — A3 parks notes only.) Augment is no longer
just the note-host case: a continuous-kind region keeps its members sounding, a
discrete-kind region parks them — the choice is per generator kind (A5), not per region.

## Authoring and editing the fx

Role (5), the seam that was free for notes. The editor *surface* — the
`FX_FIELDS` modal — is already substrate-neutral; what's new is
**addressing**: getting to a host that isn't a cell.

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

**Address existing regions through an fx column — not a region mode (B1,
landed).** Role (5) is handed back the way a note gets it: give the region
a *cell*. A per-channel **fx column** carries each region as a tailed
kind-badge — onset `startppq`, a note-style tail to `endppq`, a one-char
glyph for the primary kind; the cursor lands on it and Super-X opens the
editor. No second navigable object, no footprint mode. This supersedes the
earlier region-mode plan, and is Track A's standalone-not-gm call extended
to the UI (§ Open questions): borrow the *column/cell/tail* machinery — the
most native thing the tracker has — not gm's region-mode. The column is
**cc-like in lifecycle** (data-derived: it materialises iff the channel
carries a region with ≥1 kind, appears when one is created/pasted, drops
when the last goes; not proximity-gated) and **note-lane-like in render**
(discrete tailed badges — so overlap is the lane-packing question, deferred).
The existing cell+tail build draws badge and span bracket unchanged; the
only new view code is the column build and a one-char render branch.

**Indication.** Note scope keeps the v1 in-cell badge (`smallGlyph`,
untouched); a region is its column entry. A later per-lane note-fx
**pop-out** column — proximity-gated, the only pop-down thing — earns its
keep once parameter stops land and there is inline editing the badge can't
carry; until then badge + Super-X is the whole story.

**Visibility — invisible now, ghost later.** Generated notes stay
take-only for v2, routed out of columns as v1's derived notes are: visible
+ generator-owned invites editing a note the next rebuild silently
overwrites (G3). Later, a **ghost display mode** renders them in the grid
using the same styling as **interpolated cc values** — a visual grammar
that already says "computed, not editable." Same idiom, no new invention;
the choice turns only on whether you want the arp *seen* or just *heard*.

## Freeze — the invertibility axis as a feature

Two ways to commit a region's output, and they are the generator
spectrum's invertibility axis surfacing as user-facing commands, not two
ad-hoc verbs:

- **Freeze to raw notes** — project onto the *lossy* end. The generator
  is discarded, the notes become ordinary authored MIDI. One-way,
  exactly because macros are lossy (G3): there is no inverse from raw
  notes back to fx params.
- **Freeze to a mirror group** — project onto the *invertible* point of
  the spectrum. A mirror group retains an invertible structure
  (`toGroup`/`toInstance` duals), so it can be **unfrozen**.

What makes this clean rather than two unrelated features: an **fx region
and a mirror group are the same kind of object** — both regions on the
one substrate. Freezing to a group moves nothing; it swaps the region's
*generator* from lossy-macro to invertible-mirror over the **same
footprint**, and unfreeze swaps it back. The generator spectrum doing
exactly what it promised — three points, one substrate, reversibility
tracking invertibility.

Caveat to make explicit when it lands: unfreeze is clean only while the
group is unedited. Hand-edit a mirrored note and you are back in lossy
territory — so "unfreeze" means *discard group edits, restore the fx
region*, not *infer the generator from whatever is there now*.

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
Aliases sit between. Freeze (above) is this axis made a feature.

When region hosts land they are **carved from gm's regions substrate, not
built fresh** — gm is bug-hardened, and re-founding it buys vocabulary,
not capability. gm decomposes three ways:

1. **A generic `regions` substrate** — rect, anchor, instance identity,
   membership, disjointness, persistence, wash rendering, *and the region
   mode for selecting/editing them*. Exactly what a region host needs.
2. **The mirror generator** — anchor-rebased replay, already extracted as
   the pure core (`groups.project`); also the freeze-to-group target.
3. **The bidirectional edit protocol** — classify, override transitions,
   template writeback, localMode, the flush-seam shadow machinery. Most
   of gm's mass, with no macro analogue (macros are lossy — nothing to
   write back).

Macros use (1) only; group-mirror uses (1)+(2)+(3); aliases use (1)+(2).
v2 extracts (1) as the shared substrate and lets region hosts ride it;
(3) stays gm's, untouched. **The lean is gm-backed**: membership,
disjointness, persistence, the region-selection mode, *and* the
freeze-to-group target all already live in gm — a standalone region would
rebuild them. The remaining cost question is whether a full gm group is
too heavy for a bare fx-region; that's the substrate call to settle when
building.

## Generators as config — the ctx discipline (carried forward)

The contract is already a pure `(host, params, ctx) → {notes, delta}`.
The direction — *in due course, not gating* — is for the generator **set**
to become config: a kind is data, not a function. The route is a
discipline on **ctx**, the evaluation environment the body composes
against; when a body is nothing but arithmetic and named ctx operations,
it is already data. Region-host generators (chord arp, free LFO) are the
next things written against it, so the discipline matters now.

**ctx binds what the generator can't compute itself — and only that.**
Pure arithmetic stays in the module; the moment a generator must resolve
a scale step (the temper), find a neighbour, or honour a config bound, it
reaches into ctx. Landed: `nextLane1Note`, `pbRangeCents`, `step`.
`interval` is the instructive non-example — looks temper-bound, is pure
note arithmetic, lives as a module helper. **Build no interpreter now** —
the move costs ~nothing if new kinds are shaped as composition and ctx
accretes as named ops.

## Offline continuous realisation — park, seat, route-by-window (design)

Nothing here is built; it is the realisation change the fx chain waits on,
and it lands **before** the chain. The motive is a discomfort with
realisation needing a **runtime component**: augment continuous (pb / cc)
sums at the node today — `Continuum CC.jsfx` recomputes `base + Σ carrier`
per audio block — so the take is not what you hear until the node runs. That
summation is the node's *only* irreplaceable job; the 14-bit transport is
native to a seated pb (`centsToRaw` is already 14-bit) and the base-hold is
incidental. Move the sum offline and realisation is wholly in the take:
WYSIWYG, exportable as plain MIDI, no JSFX dependency. The landed pb-replace
path already proves it end to end — an absolute curve seated on the base
lane, no carrier, detune / densification / shape / I1 all handled — so this
generalizes that path to every continuous kind rather than inventing one.

**One model: park the base, seat the sum.** A continuous fx region parks the
authored automation its window covers off the take (a park sidecar), exactly
as note-replace parks the chord and cc-replace parks the cc — bounded
(authored breakpoints only), visible and editable via re-seat. The producer
emits the region's **absolute** target curve — augment sums
`parked-base + macro`, replace is `macro` alone — and seats it on the target
lane. Augment and replace collapse to one realisation path, differing only
in whether the sum folds in the parked base. The carrier, the add-bank
slots, and the node's per-block summation retire; a 14-bit cc target seats
its MSB/LSB pair through the existing `mm:wideCC`, so seated precision
matches the carrier's.

**Route-by-window is the metadata discipline, and it is load-bearing.** The
seats carry **no per-event metadata**. A dense curve is thousands of
breakpoints; tag each with a `derived=` sidecar and the persisted data
explodes. They are recognized as generator-owned *structurally* — by the region's
**window**, not a marker: inside it every event is re-derived each rebuild,
content-reconciled, routed out of the column and kept out of the authored
value stream by the window alone. A **live** region carries its own window
(`fxRegions`, in hand every rebuild), so recognition needs no standing
record; a **deleted** region's orphaned seats are swept by a one-shot
cleanup request the delete site enqueues with the bounds it still knows —
no persisted window mirror, which would be redundant every rebuild the
region lives.
This generalizes the carrier's metadata-free route-by-code (an allocated CC
code in `fxCarrier`) and **retires the absorber's `derived='absorber'`
per-seat tag** — a latent explosion the moment a replace curve is dense.
Parking the authored base is what makes the *shared* base pb lane routable
this way: inside a continuous window the base lane is entirely derived seats
(routed out wholesale), and the small parked set carries the only metadata.

**Summation adds points only where a curve is genuinely curved.** Two
piecewise-**linear** curves sum exactly at the *union* of their breakpoints —
no growth over the carrier, which already materialized that density as CC. A
**curved** segment (shape ≠ step / linear) has no closed-form sum, so it is
sampled onto the grid — the same CCINTERP densification the absorber runs
when a detune onset splits a curved segment. So extra points land only on
genuinely curved authored automation under a macro, or a curved-shape macro
segment; a pre-sampled vibrato or LFO emits linear breakpoints and sums
exactly. Densification adds MIDI, never sidecar.

**The grid is time-absolute — this is what makes densification idempotent.**
Sample points snap to a global `k·gridStep` lattice in ppq, *not* to a
segment's own endpoints. A curve re-densified next rebuild then lands points
at the identical ppqs, so the content-keyed reconcile sees no churn —
densification a pure function of absolute time, the G4 discipline of the
canon fix and lane allocation. This **refines** the existing absorber grid
(`A.ppq + gridStep`), stable today only because `A` is an authored
breakpoint; a summed curve's bounding points are themselves derived and
would drift a segment-relative grid into permanent churn.

**Detune folds in unchanged (I1).** Each pb seat's wire raw is
`centsToRaw(curveValue + detune)`, splitting at detune onsets exactly as the
replace-pb path seats now — detune stays realisation on the pb wire, the
curve rides on top. cc has no detune residual, so a cc seat is the curve
value verbatim.

**What migrates, what retires.** Vibrato, slide, autopan and cc-augment move
from the carrier to park-and-seat. `Continuum CC.jsfx`'s summation, the
`fxCarrier` code map, the add-bank slots, and the `derived='absorber'` /
`'ccbase'` markers retire (pre-beta — drop the persisted carrier state, no
shim). Detune pb is untouched: the absorber already seats it offline. Live
preview (R5 / plink) may still want a runtime path later, but *committed*
realisation is offline. Once this lands the chain's `stream.pb` /
`stream.ccs` are real summed curves a stage can read and fold, so
`stream ≡ host` holds for the continuous channels too, not just notes.

## Route-by-window — markerless seats via exclusive ownership (pb half landed; cc-replace next)

First build slice of offline continuous realisation, landing before cc-augment.
It retires the *in-window* per-seat `derived=` metadata on both landed replace
paths — pb-replace `absorber` seats and cc-replace `ccfill` — so a dense curve
costs **zero** `eventMeta`. `addCC` mints a uuid + sidecar iff a spec carries a
non-structural key (`mm:1027`); a seat written with only `{ppq, val, shape}` (all
native MIDI) carries none, so the metadata explosion a dense curve would otherwise
persist never happens.

**Continuous only.** `target ∈ {pb} ∪ cc-numbers`, never a note. A note always
carries a uuid + notation sidecar for identity and round-trip regardless, so
markerless elides nothing there; only the continuous streams — whose seats are
pure realisation — win.

**The enabling invariant is exclusive ownership.** A markerless seat is
indistinguishable on the wire from an authored pb/cc, so recognition works only if
*everything on-take inside a replace window is generated*. That already holds for
cc: `parkWindows` emits a `ccs[chan][cc]` span for every continuous-replace target
(`generators.lua:322`) and the park reconcile stashes the authored ccs off-take in
`fxParkedCC`. It does **not** hold for pb — `parkWindows` has no `dest == 'pb'`
arm, so authored pbs stay on-take and `tm:2373` bends them to follow the curve.
That branch is the workaround standing in for the parking pb never got.

**So pb catches up to cc — landed.** `parkWindows` gained a `pbs` arm and the pb
pass in `rebuildRegionPark` parks authored pbs off-take, with `tm:2373` deleted.
Two departures from the literal sketch above, both forced or cleaner: (1) the stash
is the **unified `fxParked`** table (one `evType`-tagged list, `fxParkedCC` folded
in) rather than a separate `fxParkedPb`; (2) the pb column isn't built until the
absorber runs *later* in the rebuild, so the pass scans authored pbs straight from
mm (not a column) and the authored breakpoints stay visible via a
`channels[chan].parkedPb` render union the **view** folds in — symmetric with how it
unions `parked`/`parkedCC`, not an absorber-side union. Audibly a no-op: an authored
bend already sounded as the curve. Now every on-take pb/cc in a window is a seat, and
parked pbs are editable off-take through the same `parked` backing as cc (pb values
are edited by typing, not solo-cursor nudge — `applyNudge` has no `pb` part). The
markerless recognition below is now **landed for pb**: in-window seats retire their
`derived=` tag (write native `{ppq, val, shape}` only) and are recognized by the
region window. **cc-replace `ccfill` is the remaining half.**

**Live recognition needs no standing record.** A live region recognizes its own
seats by its own current window — `fx.replacePb[chan]` in the pb pass, the region
bounds in the cc walk, both already in hand. Reconcile churn-free against the
freshly computed curve by `(ppq, val, shape)` via the R2 `reconcileDerived`
skeleton (`tm:127`); the seat grid is time-absolute, so unchanged seats keep. The
absorber back-derivation (`tm:2156`) must **skip** in-window pbs — a seat has no
cents and must not acquire any, or it stops looking like a seat.

**Bounds are logical; convert once, compare raw-to-raw.** A region's
`startppq/endppq` are logical; seats are raw-only (no `ppqL` — that is the win).
Convert the *bounds* to raw once per `(chan, window)` via `fromLogical(chan,
startL)` / `fromLogical(chan, endL)` and test raw seat ppqs against `[startRaw,
endRaw)` directly. Exact by construction: seats are placed at `fromLogical(chan,
bp.ppqL, d)`, so bounds converted by the same function have zero round-trip drift.
`replaceWinAt` (`tm:2180`) is the counter-example — it round-trips each event
raw→logical (`toLogical`), the inverse of seat placement; this slice corrects it
to the bounds-converted, raw-compared form. Two predicates result: `replaceWinAt`
stays **half-open** `[startRaw, endRaw)` for the curve interior
(`streamValue`/`ramps`), while seat *recognition* (`inSeatWindow`) is **inclusive**
of `endRaw` — the terminal re-centre seat sits exactly at the window end and must
read as a seat, not as an authored pb.

**Transitions: diff windows, don't mirror.** A markerless seat is invisible to the
park scan, so the scan cannot run every rebuild — it would re-park the seats. It must
fire only at the create/remove instant. The mechanism landed is **not** the
view-edit-site enqueue first sketched here, but tm's own `fxRegions` observer:
`enqueuePbTransitions` diffs the current pb windows against the last baseline
(`prevPbWindows`, RAM) and stages a one-shot transition the next rebuild drains — a
new window **parks** its authored pbs off-take (walk mm in the raw span, skipping
already-marked detune absorbers), a removed one **sweeps** its orphaned seats (delete
every mm pb in the raw span). The queue is transient RAM, consumed once, not
persisted.

Undo/redo needs no enqueue at all: the take + `fxRegions` + `fxParked` revert
atomically, and REAPER's undo watcher delivers those rewinds as `dataChanged` with
`invalidate=true` (`dataStore.lua:127`) — the observer reads the flag and only resyncs
the baseline, never enqueues (a stray sweep would delete the just-restored authored pb).
Reload resyncs the same way. This is why the diff lives in tm, not the edit site: the
edit site can't see undo, but the observer can. On a plain remove the parked authored
restores on its own — gone from `fxRegions` → `parkWindows` no longer covers it →
`reconcilePark` restores it. Diff-driven transition + automatic restore, no shadow of
last rebuild's reality.

**Known edge — swing at a boundary.** A seat is raw-only, so a swing change moves
it while its logical window is unchanged; a seat within a few ticks of a window
edge can land just outside the current-swing bounds and escape recognition.
`staleSwing[chan]` already flags the case — on a swing change, fully regenerate the
channel's replace-target seats (churn on swing is acceptable) rather than
reconciling.

**Pin.** The existing `tm_fx_region_spec` seated-curve / I1 / densify /
suppression-reversibility tests hold unchanged; add one asserting a dense in-window
curve writes zero `eventMeta` entries — the regression the slice exists to prevent
— and one that a removed region leaves neither an orphaned seat nor a lost authored
pb.

## The fx chain — series-composition and multi-column authoring (design)

Nothing here is built. It reframes the landed fan-out producer
(`runProducer`) and § *Generator output*'s compose semantics — both stay
accurate for what ships, this charts the series direction. The motivation
is the rigidity of bare kinds: you can arp but not shape the arp's
velocity, vibrate but not bend the rate in flight.

**Today the `fx` list fans out; the chain makes it a series.**
`runProducer` runs every kind in `note.fx` / `region.fx` against the
*same* host, then unions the notes and sums the deltas — no kind ever
sees another's output, so "shape the arp's velocity" has nowhere to live:
a second kind can only read the chord, never the arp's notes. Reinterpret
the (already ordered) list as a **series** — thread a `{ notes, delta }`
**stream** through the stages, each transforming what the last produced.
`[arp, velPattern]`: arp turns the chord into arp notes, velPattern
rewrites their velocities.

**One contract, no role.** Every stage is
`(stream, host, params, ctx) → stream`, and `stream` and `host` are the
**same record shape** (below) — so a stage reads whichever it wants: the
untouched membership + authored channels (`host`), or its predecessor's
output (`stream`), which equals `host` at the head and diverges after.
`host`, `params`, `ctx` are ambient, re-supplied each call. A stage that
ignores `stream` and reads `host` is a **source** (arp, retrig, trill,
vibrato, slide); one that reads and rewrites `stream` is a **transformer**
(velocity-pattern, humanize, transpose) — but that is a choice inside the
body, **not a registry flag**. The axes stay `mode` (replace | augment) and
`dest`, nothing added: velPattern is `mode='replace', dest='note'` — it
replaces the note stream with re-velocitied notes, no different in kind from
arp, which also replaces `notes`; it merely reads its input instead of
ignoring it. Parking and commit-ownership key off `mode`/`dest` exactly as
today (`parksNotes` fires on any note-replace kind, velPattern included), so
a transformer needs no new machinery and no ownership guard.

**`stream` and `host` are one shape — the A4 host.**
`{ window, chan, lane, id, notes, pas, ccs, ats, pb }`. `host` carries the
membership + authored channels unchanged for every stage; `stream` starts as
a copy of it and evolves as stages fold in, so a source reading `host.notes`
and the head stage reading `stream.notes` coincide. A note-replace stage
overwrites `stream.notes`; a continuous stage folds into the typed channel
named by `dest` (`stream.pb`, `stream.ccs[n]`) — the *same* channels a later
stage reads, which is why the shapes must match. The free-floating `delta`
output retires into the typed channel. Continuous folding rides the offline
park-and-seat realisation (§ Offline continuous realisation) and needs the
offline summation to be readable mid-chain; until a delta transformer exists
the continuous channels are read-only pass-through and the note channel is
the only one the first cut exercises.

**Order is semantic; replace/augment re-reads as channel ownership.** The
stream carries two channels, and a stage composes onto them by its op: a
note-replacing source overwrites `notes`, an augment source *adds* to
`delta`, a velocity transformer reads+writes `notes` and passes `delta`
through. So velPattern before vs after arp give different results — the
list order, cosmetic in v1, is now load-bearing. The A5 mode×dest axes
survive verbatim: `mode` is the op (overwrite | add | pack), `dest` the
channel it owns.

**The channel's fx region is a second note-grid; chains are its notes.** A
*chain* is a span carrying a series of stages — exactly `region.fx`'s
shape, no new storage. Multiple chains coexist on a channel as **fx
columns**, packed by overlap with A2's lane allocator re-pointed from
derived notes to chains (B1 already renders the lone column note-lane-like;
this resolves its deferred "overlapping-region sub-lanes"). The fxEdit
modal serves as the **interim chain editor** — it tabs across the sibling
chains, edits a chain's ordered stages (add / remove / reorder), and
deletes or mints whole chains — until the chain strip supersedes it
(§ The chain surface). On a note the chain is `note.fx`, reached as in v1
(in-cell badge + Super-X); per-lane note-fx columns stay deferred.

**Multiplicity resolves by the target's fold — pack, sum, or layer.** Every
output target folds overlapping contributions, and overlap is well-behaved
exactly when that fold is order-free:

- **notes** → lane-pack: any N chains flow into free lanes (two
  note-replace chains merge — they share the parked chord, pack into
  separate lanes);
- **augment continuous** (additive pb/cc) → sum — commutative; offline at
  seat time once realisation is park-and-seat (§ Offline continuous
  realisation), at the node until then;
- **replace continuous** (overwrite pb/cc) → **layer**: no commutative
  fold exists, so the **fx-column lane index is the precedence** and the
  topmost chain wins pointwise in the overlap (painter's algorithm).

The fold operates at both scopes — between stages within a chain (a stage's
op onto a stream channel) and between chains on a channel (at the node).
The replace conflict is scoped per `(channel, exact target)`: two chains on
the *same* cc number or both on pb; distinct cc numbers are independent
wires. Single-region pb-replace is **landed** as an absolute curve seated on the base lane (§ A4): the
absorber realises it as derived pb seats, no carrier. Multi-chain
painter-layering stays deferred: overlapping pb fx is blocked
at the authoring UI, so one replace per target is the only fold the immediate work owes --
which keeps top-wins open without building it.

**Transformers rewrite values; rate stays a source param.** A transformer
freely rewrites event *values* and nudges *discrete* timing (velocity,
density, humanize, swing, transpose); it cannot coherently rewrite a
continuous source's **rate**, because vibrato's breakpoints are placed by
accumulated phase and resampling them loses coherence. So the line: value
and discrete-timing are chain stages; rate / period / phase stay internal
to the source as params. "Shape the arp's velocity" is a transformer;
"bend the vibrato rate in flight" is a source param — modulate `period` in
vibrato's loop, swapping its closed-form breakpoint placement for a phase
accumulator.

**Tab scope — resolved: the cursor's ppq.** The editor (modal now, strip
later) cycles the chains stacked at the cursor's ppq, not every chain on
the channel — that is what the cursor means everywhere else in the
tracker. Overlap disambiguation falls out; a chain elsewhere is reached
by moving the cursor to it.

**First cut.** With continuous realisation already offline (§ above), thread
the `runProducer` fx-loop from fan-out to series: seed `stream` as a copy of
`host`, run each kind `expand(stream, host, params, ctx)`, fold a
`dest='note'` result by `mode` (replace overwrites `stream.notes`), and
build the derived specs **once** after the loop from the final
`stream.notes` — parking is automatic, since a note-replace kind (velPattern
included) already fires `parksNotes`. Write velPattern
(`mode='replace', dest='note'`, reads `stream.notes`) and prove
`[arp, velPattern]` and `[velPattern, arp]` give different, correct results.
Defer continuous (delta) transformers and the multi-column UI until the
single-chain note series is solid.

## The chain surface — strip, scripts, patches (design)

Nothing here is built either; it is the UI + extensibility half of the
chain, converged 2026-07-02. The through-line: **chains shrink the kind
vocabulary instead of growing it.** With series composition most new-kind
wishes are *spellings* of a few hard primitives — strum = `[arp,
humanize]`, gated arp = `[arp, densityGate]` — so the primitive set stays
small (sources: arp, retrig, trill, vibrato, slide, LFO; transformers:
velocity-pattern, humanize, transpose, density, swing) and expressivity
comes from composition. This is generators-as-config one level up: a kind
is data when its body is arithmetic over ctx ops; a chain is
composition-as-data.

**The chain strip — the comb made visible.** The modal fails
structurally: a chain has two axes (stages ×, params ↓) plus siblings,
and a flat field list shows none of that. The destination is a docked
horizontal strip at the bottom of the tracker page (a `chrome.row` strip,
so it aligns by construction), shown when the cursor sits on an fx cell
or an fx-carrying note:

    ┌─ ch3 fx ── chain 2/3 ──────────────────────────────────┐
    │ ▶ ARP        →  VEL PATT     →  HUMANIZE   │ + stage    │
    │   per 1/3       patt ▌▖▌▘        time 12t  │            │
    │   dir updown    depth 40%       [bypass]   │            │
    └────────────────────────────────────────────────────────┘

Left-to-right *is* signal flow — the load-bearing stage order is visible
at all times, the thing the modal can't show. The keyboard grammar is the
tracker's own: a focus key enters the strip; left/right walks stages;
up/down walks the focused stage's params; ± / typing adjusts; Backspace
deletes a stage; shift+left/right reorders; Tab cycles the sibling chains
stacked at the cursor's ppq (the tab-scope resolution above). Per-stage
**bypass** borrows the wiring page's verb and stores like `rest` —
realisation metadata riding the fx entry, never passed through
`fn(host, params, ctx)`. The `FX_FIELDS` row-walk ports near-verbatim,
rendered horizontally with params under each stage.

**Grid-side affordances.** The fx-column badge grows into a **chain
signature** — stacked one-char glyphs in series order (`a·v·h`) — so a
region's behaviour reads without opening anything. The ghost display mode
(§ Authoring and editing, *Visibility*) earns its keep here: default
ghost-on while the strip is focused, because "what does this chain
actually emit" becomes a live question the moment stages compose.

**Scripted kinds — an editor-page pane.** `generators.kinds` is already
the seam: one registry entry per kind (`expand`, `mode`, `dest`, `label`,
`defaults`, `fields`), user-extensible by construction. A scripted kind
is a user Lua chunk evaluating to that entry-shape, edited in a third
editor-page pane beside swing and temper. The pane rides the existing
`libraryTreeSpec` machinery whole — global/project tiers, promote/demote,
new/import/delete, dirty tracking — which already models exactly this:
named, tiered, user-authored artifacts. The ctx discipline is the
contract surface: a scripted `expand` composes host + params + named ctx
ops, pure, no reach into tm. Loading is eval-into-registry at startup /
library-save; a broken script degrades to its kind vanishing from the
registry with a status-bar complaint, never a rebuild fault.

**Patches ride the same library.** A patch is a *named chain* — an
ordered `{kind, params}` list, pure data, no code — saved to the same
tiered library and instantiated **by copy** onto a region or note. Live
patch references (edit the patch, instances follow) are the gm
invertibility axis reappearing; deferred until wanted.

**Param modulation — the gleam, not the build.** "Bend the vibrato rate
in flight" generalizes `dest` once more: `param:<stage>.<field>` — a
continuous stage whose delta targets a sibling stage's parameter instead
of a MIDI wire. Depth 1 only, the modulator living inside the chain it
modulates. Build nothing now; the obligation on today's work is only to
keep `dest` a clean single axis so the value can slot in.

**Stepped feed — modulation's contract (design, same gleam tier).** A
modulated param stops being a scalar and becomes a control signal, and
the contract must decide who integrates it over time. Handing bodies
`params:at(t)` leaves integration as per-author folklore — a closed-form
body under a varying param fails silently (vibrato's sine needs a phase
accumulator once `period` moves; the classic FM error). The structural
answer: the **runner drives the body through time** —
`expand(block, params, ctx, state)` — resolving modulators to *constant*
params per block and threading explicit state (vibrato: phase; arp: step
index; retrig: next fire). A block is just a **narrowed host** (window
shrunk, streams sliced), and a one-shot kind is a stepped kind run with
one block spanning the window — the same no-special-case-head move as
`role`. Whole-window properties (vibrato's end-of-window re-centre) become
runner epilogues, not block business.

Blocks are **segment-driven, not fixed-size**: edges at the union of
modulator breakpoints and membership note-on/offs (sample-and-hold at
the modulator's own breakpoints — exact, no block-size/aliasing
trade). With membership edges in the cut, params *and* polyphony are
block-constant — a block is precisely an interval of constancy, and
bodies go straight-line: no scanning, no mid-block cases.

**Notes arrive as held + triggered.** Per block: `held` = sounding at
block start (onset before it), `triggered` = note-ons inside it. No
`released` set — every note carries `endppqL`, so gate-shaped bodies read
release edges off the events. The partition **tiles the membership**:
each note is triggered in exactly one block, held in every later block it
spans; union over blocks = today's overlap query. The degenerate
one-block case is *more* correct than the flat list (`playingAt` stops
being something arp implements and becomes `held ∪ triggered`, handed
in). Simultaneous onsets in `triggered` order by ascending realised pitch
(as `playingAt` sorts) so "first triggered" stays G4-stable; segmentation
is a pure function of the input streams, so determinism holds by
construction. Cost stays proportional to event count, all offline; the
shape also mirrors the node's per-block run one level up, and is
streaming-ready if live feeds (preview, plink) ever want it.

**The obligation now is a writing discipline only**, same register as
ctx: shape new continuous kinds *incrementally* — phase accumulators and
step loops, never closed forms over the window — so the window can shrink
without rewriting the body. Discrete kinds are already step-shaped. When
param modulation lands, the build order writes itself: segment cutter +
state threading in the runner, vibrato ported as the proving kind.

**Resist the DAG.** Parallel → series with target folds is a comb, and
the comb is the model. Sibling chains give parallel; the fold gives
summing; order gives series. A node canvas (the wiring page's idiom)
invites exactly the fan-out and geometry-as-order the semantics forbid —
audio routing earns a DAG, note-fx doesn't. Borrow the wiring page's
*chrome* (bypass badges), never its canvas. Likewise no parallel blocks
*inside* a chain: sibling chains already express it.

**Sequencing.** (1) The fx-chain first cut above, modal intact. (2) The
strip, replacing the modal once ≥2-stage chains are real. (3) The
editor-page pane — patch library first (pure data, cheap once chains are
real), scripted kinds after. Param modulation stays a gleam.

## Owned elsewhere — not this doc's work

- **R5 — plink via MIDI; retire the listen bank**, and the **single-node
  packaging** it unblocks. Deferred to `design/cv-2.md`, which re-founds
  this exact path. Do not build under note-macros.
- **R4 — flush-time mechanism registry (`dirtyFxHosts`).** Measured
  not-warranted; the apparent cost was a carrier-reconcile churn bug
  (fixed). Build only if a measured hotspot reappears.
- **R3 — `forEachEffectiveNote`.** Extract on its third real occurrence;
  not before.

## Build progress

**Track A — generator-side substrate, no UI** (started 2026-06-26). Chose
standalone over gm-backed: the generator contract is already region-shaped
and an fx-region's membership is simpler than gm's, so the generator side
wants ~none of gm (see resolved open question below).

- **A1 — region producer + free LFO (N=0). Landed.** An `fxRegion =
  { uuid, chan, startppq, endppq, fx }` lives in dataStore (take scope),
  re-queried each rebuild. The 4.6 expansion seam now runs one
  `runProducer` over two sources — every note-carrying-fx (the degenerate
  region, augment path, `fxHostEnd` intact) and every explicit fxRegion
  (pure replace). `vibrato` reads only its window, so a region over an
  empty span *is* the N=0 free LFO: it drives the channel pb carrier with
  no host note, through the existing carrier path unchanged. Pinned by
  `tm_fx_region_spec` (N=0, window re-centre, G4 round-trip + float-churn,
  removal).
- **A2 — membership + chord-arp + lane allocation (N≥2). Landed.**
  Membership is an **overlap** query, not containment: authored notes whose
  interval intersects the window, re-queried each rebuild (`eachWindowNote`
  at the 4.6 seam feeds both the chord and the fixed lane occupancy from one
  walk). `generators.arp` samples the *sounding* set at each step
  (`playingAt`) and cycles it by `dir` (up/down/updown) — changing harmony is
  followed, gaps produce rests. The deterministic allocator
  (`allocateRegionLanes`) packs each derived note into the lowest lane free
  of overlap, authored notes seeding fixed occupancy; lowest-free + emission
  order = G4-stable. Pinned by the arp tests in `tm_fx_region_spec`
  (continuous read, held-chord packing, dropout + freed-lane reuse, N=0 rest,
  G4).
- **A3 — replace mode: member parking (true replace). Landed.** `region.mode`
  (`replace` default | `augment`) makes augment/replace a *choice*, read per
  dimension. Discrete replace **parks** the authored notes a window covers off the
  take into `fxParked` (ds): they can't be muted -- a muted note still carries a
  note-on/off pair that MIDI_Sort mispairs against a same-pitch derived note, and a
  CC/PA has no mute bit -- so they leave mm and live as the realised, *displayed*
  membership; the generated arp is the sole sounding voice (hidden, as v1 derived).
  Step **4.5** reconciles park/restore each rebuild (covered authored -> off-take;
  no-longer-covered -> restored, its `mm:add` riding the 4.8 commit *after* the
  derived deletions so the shared `(pitch,ppq)` content-key never clashes).
  `realiseParked` tail-walks the parked members in logical frame (`strictNextMap`
  now onset-parameterized) so membership is the held chord, not raw overlaps.
  Parking frees the lanes, so the arp packs to lane 1 and the same-pitch nudge
  dissolves *structurally* -- the chord is no longer a note-on in the take. augment
  is A2 verbatim (members sound + occupy lanes; nudge persists). Display of the
  parked bucket (`channels[chan].parked`) is the renderer's union (Track B B2). Pinned
  by the replace / augment / realise / removal / G4 tests in `tm_fx_region_spec`.
- **A4 — reframed: generator input streams (notes/pas/ccs/ats/pb) + continuous pb replace. Landed.**
  A3 parks notes only. The PA half was misframed as park-the-PA-and-re-emit-it-rebound-to-the-region;
  that operation can't exist generically -- a PA is generator *input*, like a member's pitch/detune, and
  the generator's input->output mapping preserves no event correspondence to rebind across (an arp samples
  a chord and emits one stream; which input PA maps to which output note is undefined). PA isn't special:
  it generalises to *the generator reads the windowed channel as typed input streams* (notes, pas, ccs,
  ats). **Landed**: `channelStreams` slices them from the real column projections at the 4.6 seam, keyed by
  `evt.ppqL or evt.ppq` (no toLogical round-trip); the PA projection moved ahead of the producer. See
  § A4 -- generator input streams.
  **pb as input -- landed (authored breakpoints only).** The feared absorber-split was avoided: a generator
  reads only the *authored* (non-derived) pb breakpoints, whose logical value is the persisted `cents`
  sidecar -- no `cents-minus-detune` reconstruction. Sliced from the pre-producer `mm:ccs()` walk, fakes
  excluded. **Continuous replace -- landed** (absolute curve seated on the base lane, no carrier).
  A replace-continuous kind emits its absolute pb curve, which rides the additive carrier verbatim;
  the absorber (4.9) emits a *detune-only* wire base inside the recorded replace window, so the node
  sum `detune + curve` lands on the curve (I1 intact). No `cancelBase`, no sampling. Overlapping pb
  fx is blocked at the UI. See § A4 -- generator input streams.
  Known gaps unchanged: a member straddling a window edge is parked whole (no split); a parked note
  carrying its own `fx` loses that host behaviour to the region; a replace region's parked PAs stay
  take-side (latent orphan) until the first PA-consuming generator, then park them out.

- **A5 -- mode is a generator property; one registry per kind. Landed.** `region.mode` is gone.
  Each kind declares `mode` (`replace`|`augment`) and `dest` (`'note'` for discrete kinds, else the
  continuous wire target) in a single `generators.kinds` registry that also carries the kind's `expand`
  fn and modal `label`/`defaults`/`fields` -- one place per generator, user-extensible. Both hosts now
  branch *by kind*: a region parks iff it carries a discrete-replace kind (`parksNotes`), so a
  continuous-only region augments instead (closing the prior all-regions-replace bug -- a vibrato region
  silenced its covered notes). The note host originally kept a clip-to-first-derived-hit realisation of
  replace (host stayed fxNote 1); superseded 2026-07-03 -- it now parks itself
  (§ Note-host replace parks). `mode` and `dest` are
  independent axes, so continuous-replace (A4) and discrete-augment are expressible; continuous-replace
is **landed** as an absolute curve seated on the base lane by the absorber, no carrier -- § A4), discrete-augment still expressible-not-built. The fxEdit
  modal reads its rows from the registry (`modalOrder` picks the shown kinds; arp is surfaced on both
  hosts -- single-note arp = retrig, so no host-aware list is needed). Pinned by the continuous-augment + parked-render
  reworks in `tm_fx_region_spec`/`tv_fx_region_spec`, and `generators_spec` driving `kinds.<k>.expand`.

**Track B -- authoring UI: the fx column** (started 2026-06-26). Standalone /
column-based, not gm-backed -- the Open-questions Track-B lean, now resolved.

- **B1 -- the fx-region column + Super-X addressing. Landed.** A per-channel
  `fx` column, data-derived from `ds.fxRegions`: each region is a `{ ppq =
  startppq, endppqC = endppq, kind, uuid }` cell-event, so the existing
  cell+tail build draws a one-char kind-badge and a note-style span bracket
  with no new geometry (the `tails` init just widened to `fx`). `tv:noteFx` /
  `tv:setNoteFx` now resolve a string `'fxr-N'` region uuid (disjoint from
  notes' integer uuids), so the whole `fxEdit` modal edits a region unchanged;
  region writes are document-data edits (ds -> dataChanged -> rebuild, the
  `addExtraCol` idiom). `tv:fxHostForEdit` routes Super-X: a selection
  authors/reopens a region (find-or-create by footprint, replace default),
  else the caret's fx cell, else the caret's note (v1). A region *is* its fx --
  emptying it (REMOVE / empty list) drops it, and a minted-then-abandoned
  region is pruned on close. Pinned by `tv_fx_region_spec` (column render, uuid
  generalisation, REMOVE-deletes, the three host branches). Deferred:
  tail-resize / onset-move, the replace/augment toggle in the modal,
  overlapping-region sub-lanes, the per-lane note-fx pop-out, a real
  kind-glyph vocabulary.

- **B2 -- parked display: the renderer's union. Display landed (note + cc); edit open.**
  A3 parks replace members off the take into `channels[chan].parked`; the grid build
  unions each back into its lane as a render-ready logical cell (`ppq == ppqL`,
  `endppqC == endppqL`), so the chord stays on screen -- the piece A3 punted here.
  **cc-replace gets the symmetric union:** it parks the covered authored cc into
  `fxParkedCC` and re-seats it via `channels[chan].parkedCC`, so the authored cc stays
  the visible surface and the generated fill is hidden realisation -- creating the region
  never blanks the lane (the invariant). pb-replace now parks symmetrically too (route-by-window):
  its authored breakpoints park off-take into the unified `fxParked` stash and re-seat via
  `channels[chan].parkedPb`, staying visible in-column and editable off-take -- the earlier
  "pb parks nothing" note is superseded. Display only: parked cells are tokenless, so a cursor edit no-ops.
  Making the parked events *editable* off-take (rebound to `fxParked` / `fxParkedCC`, as
  the "visible, editable surface" model intends) is still open (planned as B3 below).
  Pinned by the parked note- and cc-render tests in `tv_fx_region_spec`.

## B3 — parked notes/ccs as a third edit backing (landed)

**Progress — four green steps.** (1) extract `parksNotes`/`parkWindows` to `generators` —
**landed** (pure surface + `generators_spec` pins; tm now calls `parkWindows` once);
(2) logical-only park specs + identity capture in `rebuildRegionPark` — **landed**
(stashes are logical-only; parked notes carry `chan`+`uuid`, parked ccs `chan`+`ppqL`;
restore derives realised ppq via `fromLogical`; pinned in `tm_fx_region_spec`); (3) staging
verbs (`parkedEdits`) + flush integration + the `dataChanged` subscription — **landed**
(`tm:addParked`/`assignParked`/`deleteParked` dispatch on `evType` like `addEvent`; flush
writes the cloned stash under `flushingParked` then rides the mm reload→rebuild, or drives one
explicit rebuild when parked-only; `fxParked`/`fxParkedCC` joined the `dataChanged` rebuild
list; every parked spec/cell now carries `evType`; pinned in `tm_fx_region_spec`); (4) view
backing + tagging — **landed** (`backing.parked` routes the leaf-edit facade to the three tm
verbs; `toParkedSpec` normalises a view event — authoring ppq is already logical — to the
logical-only stash; a `parked` `cellKind` pass over `generators.parkWindows` mirrors the
`member` one and wins on overlap; the parked render cell gained `endppq` (authored ceiling) so
the note move/resize machinery edits it; move-out/in fall out of the facade's cross-kind
relocate; pinned in `tv_fx_region_spec`).

Closes the B2 *edit open* gap: a replace region's parked chord (and parked cc)
renders but is not yet editable (parked cells are tokenless, so a cursor edit
no-ops). The goal is that you edit a parked event exactly like any note/cc --
transpose, resize, retune, delete, *and type a new one into the window* -- with no
second editing surface.

**The shape -- a third backing, keyed by position.** The view's leaf-edit facade
(`trackerView.lua`) already dispatches every edit to a `backing` strategy by
`kindOf(evt)`: `member` (gm) when the cell sits inside a group region, else `plain`
(tm). An fx-region that parks **defines a parked zone exactly like a gm region
defines a member zone**, so the move is a third backing, `parked`, that `kindOf`
routes to positionally -- not a branch bolted into `tm:assignEvent`. Keeping it a
backing (rather than a tm dispatch) buys two things the tm-branch route can't:

- **a real, sensible `add`** -- typing into the zone writes a logical spec straight
  to `fxParked`/`fxParkedCC`, no mm round-trip; and
- **free move semantics** -- the facade's existing cross-kind relocate (delete from
  `src` backing, add to `dst`) gives move-out (`parked`->`plain`) = drop-spec +
  take-add, and move-in (`plain`->`parked`) = take-delete + stash, with **no churn**
  on an in-zone value edit or ppq nudge (`parked`->`parked` stays one kind).

Parked notes/ccs stay **out of `columns.notes`/`columns.ccs`** (the B2 array union),
so no sounding-walk -- 4.8 tail walk, PC synthesis, lane occupancy, `fxWindow`, the
flush collision scan -- ever sees them; the same-pitch collision dissolution that
parking buys is untouched.

**The forced constraint -- parked edits stage, they do not write `ds` inline.**
`ds:assign` fires `dataChanged` -> `tm:rebuild` **synchronously inline**
(`trackerManager.lua:2310`), and a rebuild reloads the um cache. So a parked edit
that wrote `ds` mid-loop during a multi-select (transpose spanning a parked chord +
normal notes) would rebuild and **discard the still-staged mm edits**. This is a
correctness hazard, not a deferrable nicety: parked edits **must** stage and ride
`tm:flush` like every other staged edit. The backing therefore routes to new tm
staging verbs, not to a bare `ds:assign` -- it still skips `assignEvent`'s
frame-translation machinery (parked specs are logical-only), just via a simpler
staged path.

**The shared park-window predicate (the DRY cut). Landed (step 1).** The view must
tag a cell `parked` over *exactly* the spans 4.5 parks over, or the tag and the
parking disagree. Both now come from `generators` (pure, reads only `kinds`):

- `generators.parksNotes(region)` -- moved from tm;
- `generators.parkWindows(regions) -> { notes = { [chan]={{s,e},..} },
  ccs = { [chan]={ [cc]={{s,e},..} } } }` -- one builder. `rebuildRegionPark` calls
  it once and its two window loops read `.notes`/`.ccs`; the view's tagging will read
  the same.

**Surface.**

- *`generators.lua`* -- `parksNotes` (moved) + `parkWindows` (new). Pure. **Landed.**
- *`trackerManager.lua`* -- (a) **identity capture** in `rebuildRegionPark` — **landed**:
  note `shape` captures `uuid = evt.uuid`; `channels[chan].parked` cells gain
  `chan`+`uuid`; `channels[chan].parkedCC` cells gain `chan`+`ppqL` (the fields
  `colFor`/the backing address by). Specs go **logical-only** (drop realised
  `ppq`/`endppq`; restore derives them fresh from `ppqL` via `fromLogical` under
  current swing). All four `--shape` annotations updated.
  (b) **staging** — **landed**: a `parkedEdits` buffer peer to `adds`/`assigns`/`deletes`, with
  `tm:addParked`/`tm:assignParked`/`tm:deleteParked` (evType-dispatched like `addEvent`). Note
  key = `uuid` (minted `fxp-N` on add); cc key = natural `(chan, cc, ppqL)` (cc events carry no uuid).
  (c) **flush integration** — **landed**: `parkedEdits` joins the no-op guard; apply to a cloned
  `fxParked`/`fxParkedCC` under a `flushingParked` guard, then -- mm-ops present ->
  the existing `mm 'reload'` rebuild picks up the written stash; parked-only -> one
  explicit `tm:rebuild`. (d) **dataChanged** — **landed**: `fxParked`/`fxParkedCC` joined the
  rebuild list (so undo rewinds still rebuild), skipped while `flushingParked`.
- *`trackerView.lua`* -- **landed**: `require 'generators'`; a `parked` cellKind tagging block
  mirroring the `member` one over `parkWindows` (parked wins on overlap); `backing.parked =
  { add, assign, delete, relocateDrop = { token, loc, uuid } }` routing to the three tm verbs.
  `add` runs `toParkedSpec` (the view's authoring ppq is already logical, so `ppqL = evt.ppq`)
  on the OPEN-ended note `edit.add` hands it (placeNewNote); `realiseParked` tails OPEN specs.
- *`trackerManager.lua`* (B2 render cell) -- **landed**: the parked note cell gained `endppq`
  (the authored ceiling) so the view's note move/resize machinery (`assignNoteMove` reads
  `evt.endppq`) edits a parked note instead of faulting on a missing field; `endppqC` stays the
  clipped render ceiling. The only tm touch -- **no `midiManager` change**.

**Decisions taken (revisit if a need appears).**

- *uuid stability across unpark: split by path (revised 2026-07-03).* A **restore**
  (fx removed / window moved off) supplies the spec's original uuid to `mm:addNote`
  under `keepUuid` -- fx-editor handles survive the round trip. A **move-out** still
  sheds the uuid via `relocateDrop` (a relocation is a new note, not the old one
  returning).
- *cc keyed by `(chan, cc, ppqL)`*, not a minted id -- cc events have no uuid here;
  the natural key is unique within `fxParkedCC` and simpler.
- *`member` vs `parked` precedence* if a gm group and an fx region ever cover the
  same cell: pre-beta, `parked` wins and we assert disjoint.
- *Specs logical-only* (drop realised, derive on restore) -- as above.

**No `fxManager` (decision).** tm is large (~2360 lines) but fx is not a *layer* --
it's phases woven into tm's one rebuild (`2197-2211`), sharing the `fx` accumulator
and the `deferred` mmBatch, and `rebuildTails` deliberately fuses authored +
external + derived notes into one atomic commit. An `fxManager` would have to reach
into tm's `channels`/`fx`/`deferred` -- the cross-layer reach the architecture
forbids; size-down, coupling-up. And B3's `parkedEdits` must coordinate with
`adds`/`assigns`/`deletes` in `flush`, so splitting parking out is the wrong cut.
Pressure-relief is instead: push **pure** fx logic into `generators` (where
`parkWindows`/`parksNotes` now go -- the ctx-discipline direction). If tm-size ever
forces a structural split, the honest seam is the **whole rebuild pipeline** lifted
to a `trackerRebuild` file with `channels`/`fx`/`deferred` as an explicit ctx --
not fx, and a separate decision from B3.

**Tests** (`tm_fx_region_spec` / `tv_fx_region_spec`): edit a parked pitch ->
`fxParked` updated, still parked, renders new pitch; delete a parked note -> gone,
not restored when the region moves off; add a note into a replace window -> stashed,
not in the take; move a parked note out of its window -> auto-restored to the take;
parked cc edit + delete (the symmetric cc path); multi-select spanning parked +
normal -> both land under one undo with one final rebuild (the case the staging
exists to protect).

**Out of scope.** Note-fx hosted on a *region*-parked note, and PA replace (A4) -- both
deferred (continuous pb replace landed; cc-target replace unbuilt).

## Note-host replace parks (landed 2026-07-03)

Note-host replace now does what the name says: a note carrying a
discrete-replace kind **parks itself** (membership `{self}`), exactly as a
region parks its covered chord. All hits are derived output -- retrig/trill
emit tile 0 -- and the parked cell (now carrying `fx`) is the visible,
editable surface via the B2/B3 machinery. Dead: the `fxHostEnd` view-restore
dance, the tail-walk's clip-host-to-first-fxNote special case, and the
no-derived-output-at-the-host-onset constraint on generators. The two hosts
now differ only in membership and where the fx is stored -- the precondition
for the fx chain's transformer role behaving uniformly on both.

Mechanics. The 4.5 note scan gains an identity criterion (`evt.fx` +
`generators.parksNotes`) alongside the window one, applied to live notes and
prior specs alike -- so a region-parked note whose own fx carries a discrete
kind stays parked when the region moves off, becoming its own host with no
take round-trip. Parked specs/cells carry `fx`; restore returns it, and
`mm:addNote` honours the spec's original uuid under `keepUuid`. The producer
walks parked cells (window = the realised parked extent, which
`realiseParked` already bounds exactly as `fxWindow` would; cells inside a
region note-park window stay region membership). Region lane allocation
seeds occupancy from already-emitted derived specs, so a parked host's tiles
hold its lane against an overlapping region. A parked edit dirties its
channel at flush -- parked specs are producer input. The view tags only the
parked cell's **onset row** `parked` (membership `{self}` is closed: adds
elsewhere in the span stay plain, unlike a region window), and
`noteFx`/`setNoteFx`/`noteByUuid` resolve parked uuids between mm and
regions. PA display anchors to the parked cell's lane; the PA itself stays
take-side and sounds against the derived same-pitch hits.

Gaps. `ctx.nextSameLaneNote` misses on a parked host, so a slide sharing a
chain with a discrete kind degrades to no delta (target `'fixed'`
unaffected). A region-parked note's own fx stays suppressed while
region-covered -- but it now survives in the spec instead of being destroyed
on restore.

## A4 -- generator input streams (landed)

Reframes the PA half of A4. PA was misframed as a park/re-emit/rebind problem; that
operation can't exist generically (no input->output event correspondence to carry a PA
across). So PA stops being special and becomes one of several **typed input streams the
generator reads over its window**. ADSR gated by note-ons, a CC-controlled vibrato, a
pressure-aware arp all fall out of one shape. Landed: notes, pas, ccs, ats, pb; continuous
pb replace rides the same input (below).

**Contract** (`generators.lua`). `host.events` -> `host.notes` (it *is* the note stream),
plus three more -- all window+channel scoped, logical frame, intent units:

```lua
host = { window={startppqL,endppqL}, chan, lane, id,
  notes = { {pitch,vel,detune,ppqL,endppqL}, ... },   -- the membership (was `events`)
  pas   = { {ppqL,pitch,vel}, ... },
  ccs   = { [ccNum] = { {ppqL,val}, ... } },
  ats   = { {ppqL,val}, ... },
  pb    = { {ppqL,cents}, ... } }                     -- authored breakpoints, logical cents
```

**Read the real projections, not mm.** Slice the streams from the **column projections**
(`channels[chan].columns`), never reconstruct them from `mm` -- re-deriving a view
projection at the seam is a smell, and for pb outright wrong (mm pb is raw, not the
`cents-minus-detune` the absorber computes). These four are cheap *because* their intent
value needs no computation (note fields / 7-bit `val` verbatim) and they are projected to
columns **before** the producer: notes/ccs/ats already are (steps 2-3; carriers already
routed out of `ccs` by step 3), and `pas` only needs its projection moved ahead of the
producer.

**Phased: project inputs -> generate -> reconcile outputs.** The structural move. The
generator consumes finished input projections; its output (derived notes, carrier) feeds
the existing later passes (4.8 tail walk, 4.9 absorber). The one new instance of "project
more of the view before generating" is moving the `pas` projection earlier.

**Implementation** (`trackerManager.lua`, at the 4.6 seam):

1. Rename host field `events` -> `notes`: the host literal (~1448), the 3 `runProducer`
   feeds (note host ~1485, region augment/replace ~1494-1507), the generator read-sites
   (`retrig`/`trill`/`arp`/`slide`; `vibrato` reads none), `generators_spec`.
2. Move the PA column projection (~1887: `mm:ccs()` -> `evType=='pa'` ->
   `findNoteColumnForPitch` -> `projectCC(.., {type='pa'})`) to **before** the producer
   (after step 3, note columns settled). Safe: every intervening note-column walk already
   guards `type ~= 'pa'` (producer 1482, `eachWindowNote` 1399, tail walk 1612, park 1284),
   and derived fxNotes are routed out of columns, so `findNoteColumnForPitch` only ever
   finds authored columns -- present pre-producer. VERIFY on build: the step-5
   `ppq->logical` note-col overwrite still leaves PA `ppqL` intact for render; nothing
   between old/new position needs PA absent.
3. `channelStreams(chan, startL, endL)` -- slice the columns by **`ppqL`** (col `.ppq` is
   raw until step 5, so `ppqL` is the logical key; the reason `membersOf` reads it):
   - `pas`: walk `columns.notes[*].events`, `type=='pa'`, `ppqL in [startL,endL)` ->
     `{ppqL, pitch, vel}`.
   - `ccs`: each `columns.ccs[cc]`, windowed -> bucket by cc -> `{ppqL, val}`.
   - `ats`: `columns.at`, windowed -> `{ppqL, val}`.
4. Hoist the host literal out of `runProducer`'s fx-loop (built once per host, not per
   kind), attach `notes` + the three streams; `channelStreams` computed inside
   `runProducer` from `(chan, window)` -- uniform across both host kinds and
   augment/replace.

**pb -- landed (authored breakpoints only).** Reading only the *authored* (non-derived) pb
breakpoints dodged the phased absorber-split: their logical value is the persisted `cents`
sidecar, so the pre-producer `mm:ccs()` walk reads it directly (fakes excluded by `derived`).
A foreign-MIDI pb lacks the sidecar for one rebuild until 4.9 back-derives + persists it --
harmless and self-healing, no consumer yet. The heavier path (the absorber's densified/derived
logical stream as input) stays unbuilt until a generator needs more than breakpoints.
**Continuous replace -- landed (curve seated on the base lane, no carrier).** A replace-continuous kind
(`mode='replace'`, `dest='pb'`) emits its **absolute** target curve. The absorber (4.9) seats it **on the
base pb lane**, reusing the value-aware seats: the producer records the replace window with its curve
(`fx.replacePb[chan] = {startL, endL, curve, d}`), and inside the window `streamValue` returns the *curve*
rather than the authored breakpoints. The curve's breakpoints become derived seats carrying their shape;
an authored pb inside the window rides the curve on its wire (`streamValue(ppq)`, its column cents untouched
and visible); a curved curve-segment split by a detune onset densifies exactly as an authored one does. Each
seat's wire raw is `centsToRaw(curve + detune)`, so detune still seats (I1 intact). **No carrier, no add-bank
slot** -- the retired path summed a detune-only base with a separate additive carrier at the node; the seated
model needs neither. Scoped to **one replace region per pb target**: two curves cannot both own the wire, so
**overlapping pb fx is blocked at the authoring UI**. Caveats: the boundary from authored base to curve can
step; a non-step authored pb *inside* the window rides the curve in value but keeps its own outgoing shape
over the next cell (the same bounded artifact a densified authored curve carries). cc-target replace is unbuilt
-- cc has no absorber/detune residual, so suppressing its authored base needs a different mechanism (below).
Pinned by the seated-curve / I1 / densify / suppression-reversibility tests in `tm_fx_region_spec`.

**Tests.** `tm_fx_region_spec`: a region over a window holding a cc + pa + at, with a
capture-kind injected into `generators.kinds` recording its `host`, rebuild, assert
`host.pas/ccs/ats` carry the windowed streams (real producer wiring; the capture kind is a
spec fixture, not a production surface). `generators_spec`: the `events`->`notes` rename.

**Files.** `generators.lua` (contract invariant/shape + rename), `trackerManager.lua`
(pa-projection move, `channelStreams`, host hoist, rename feeds), this doc, the two specs.

**Landed -- two refinements from the steps above.** (1) The stream key is `evt.ppqL or evt.ppq`, not a
bare `ppqL` slice: an authored cc/at/pa carries `ppqL == nil` whenever raw already equals logical (identity
swing, or a swing-neutral position), so the `or evt.ppq` fallback gives the logical position with no
`toLogical` round-trip -- the same convention step 5 uses. (2) The PA projection lands *before the producer
but after externals + 4.5 parking*, not "after step 3": note columns are only settled (foreign-MIDI in,
covered notes parked out) by then, and it must stay before step 5 so `findNoteColumnForPitch` still matches
in the raw frame.

## Continuous cc -- augment (landed); replace (landed)

Extends A4's carrier machinery to cc targets. pb proved the path; cc *augment* is simpler (no detune,
no I1, no absorber) and rides the same carrier wire. cc *replace* lands by a different route entirely --
it bypasses the carrier and node, parking the authored cc and writing the curve direct (see § cc replace).

**Augment -- landed.** The node carrier fork collapsed to the pb formula for every target
(`Continuum CC.jsfx`: `acc += acm*128+acl-8192`, centre 8192); the producer branches the *unit*
(pb -> `centsToRaw`, cc -> raw steps) over the shared `(8192+raw)/128` transport; the rest seat
emits a generator-owned base CC (`derived='ccbase'`) at take start for an un-automated target,
routed out of columns like a carrier (step 3) and recognised on reload via the mm sidecar.
`ccDefaultRest` + a first **auto-pan** kind (sine LFO on cc 10) ship in `generators.lua`. Pinned by
the cc-augment tests in `tm_fx_region_spec` (value-correctness, +/-127 transport, rest
fallback/withdraw, override) and the `autopan` test in `generators_spec`. **Replace** lands below, by a different route (no carrier, no node).

The mechanism subsections that follow are the design rationale, now landed-accurate as description.

**The transport is already 14-bit.** `mm:wideCC` (`midiManager.lua`) splits a *fractional*
carrier value 0..127.99 into an MSB(shaped)/LSB(step) wire pair; the node coalesces them via
`acm*128 + acl`. So the carrier the pb path already emits (`(8192 + centsToRaw)/128`) carries
14 bits, not 7 -- cc rides the identical wire. That is why ±127 "is fine, we have 14 bits": a
cc delta of ±127 lives almost entirely in the *low* bits, the MSB sitting at ~64.

**Node -- collapse the carrier branch** (`Continuum CC.jsfx`, the per-block sum). Today it
forks on target: `d >= 2048 ? acc += acm*128+acl-8192 : acc += acm-64`. The cc arm is 7-bit
MSB-only, centred 64 -- exactly what caps cc at ±63 and would quantise any delta below 128 to
zero. Drop the fork; use the pb formula for every target. The existing carrier centre-default
`acm = 64` still yields delta 0 for an absent carrier (`64*128 - 8192 = 0`), so nothing else
moves. (The centre-default comment "64 for cc" becomes "always 8192".)

**Producer -- branch the unit, not the transport** (`trackerManager.lua`, the carrier-value
emit ~1635). Stop hardcoding `centsToRaw`: per target, pb -> `centsToRaw(bp.val)` (cents ->
raw), cc -> `bp.val` (already cc steps, identity); shared `(8192 + raw)/128`. The take-start
anchor (~1651) is already centre-64 and target-agnostic -- unchanged.

**Base is held, not integrated.** The node emits `out = 64 + base + delta`, *recomputed each
block* -- base is the latest *authored* cc on the target, captured live (`abd = m3 - 64`) and
swallowed; delta is the current carrier sum. It never feeds its own emission back as base, so
there is no drift: when the macro delta returns to 0 the output returns exactly to the
authored value. For augment the authored automation *is* the base -- no synthesis (unlike pb,
whose base the absorber builds from breakpoints + detune).

**Rest -- the base when nothing is authored.** When a cc-augment target has *no* authored
automation, seat one CC at its resting value at take start; the node captures it as base and
the macro rides on top. Resolution:

```
rest(target) = region.fx.rest ?? ccDefaultRest[target] ?? 0
```

- `ccDefaultRest` -- a code constant. 64 for the bipolar family (pan 10, balance 8, sound
  controllers 71-79), 127 for expression (11), else 0. The only opinionated part.
- `region.fx.rest` -- optional per-region override, set in the fx UI. Realisation metadata: it
  rides `region.fx` but does *not* flow through `fn(host, params, ctx)` -- the base-seater
  reads it directly, leaving the generator contract untouched.

Seat only when the target has no authored automation (pure fallback) -- authored automation,
when present, already is the base, and seeding nothing sidesteps an ordering fight at ppq 0.
No node change; same shape as the absorber seating pb base, narrower job.

**cc replace -- landed (park + direct insert; no carrier, no node).** pb replace leans on the absorber
to seat its curve on the base lane. cc has neither an absorber nor a detune
residual, and the node step-holds the latest *authored* cc as its base. Rather than fight that, cc
replace **bypasses the node entirely**: inside the window on the target cc, the authored cc is *parked
off-take* and the generated curve is written as literal cc events onto the target *take* lane (the
realisation -- routed out of the visible column, below).
No carrier is allocated, so no `adst` is registered, so `Continuum CC.jsfx` is transparent to that
target -- the instrument hears the curve directly.

- **Parking** mirrors discrete note-replace (step 4.5): a `4.5b` block reads the per-`(chan, cc)`
  replace windows off the regions, parks the covered authored cc into the `fxParkedCC` sidecar (delete
  from take, drop from column), carries still-covered forward, and restores the rest on region removal.
  Like the note chord, the parked cc is **re-seated for display** via `channels[chan].parkedCC` (the cc
  twin of B2's `channels[chan].parked`), so it stays the visible, editable surface and the fill never
  shows -- creating a cc-replace region leaves the lane looking unchanged (the invariant).
- **The fill** is a derived cc (`derived='ccfill'`) on the target code: the producer emits it in place
  of the carrier `pending` entry, step 3 routes it out of columns like the rest seat, and Pass B
  reconciles it (keyed `(cc, ppq)`, matched on val + shape) so a steady rebuild does not churn it.
- `cancelBase` / base-sampling is **not** the path -- it was removed; this mechanism needs neither.

**Known edges** (not solved). (1) A cc target carrying *both* an augment region and a replace region:
the augment registers `adst`, so the node would swallow the replace fill inside the window. (2) Augment
`rest` is conceptually the *target's* value but stored per *region* -- two augment regions on one target
with different overrides resolve first/lowest-wins. Both are same-target overlaps, already UI-constrained.

**Files (augment).** `Continuum CC.jsfx` (one line + a comment), `trackerManager.lua` (producer
raw-branch + rest seating), `generators.lua` (a cc-dest augment kind + `ccDefaultRest`), a
fixture test in `tm_fx_region_spec` (value-correctness + ±127 range + rest fallback).

**Files (replace).** `trackerManager.lua` -- the `4.5b` cc-park block + `fxParkedCC` sidecar, the
producer `ccFill` fork, step-3 `ccfill` routing, the Pass B fill reconcile, and the
`channels[chan].parkedCC` render union; `trackerView.lua` -- the cc render-union (B2). No
`Continuum CC.jsfx` or `generators.lua` change; fixture tests in `tm_fx_region_spec` (replace
mechanics) + `tv_fx_region_spec` (parked-cc render).

## Open questions

- **gm-backed vs standalone region host. Resolved (both tracks):
  standalone.** The generator contract is already region-shaped, and an
  fx-region's membership is *simpler* than `groups.inRect` — gm's region
  carries a stream-map, a replay template, and per-instance override tables
  a bare fx-region has none of. So Track A is built fresh, gm untouched.
  Track B resolved the same way: authoring is an fx **column**
  (cell/tail/cursor, B1), not gm's region-mode/wash — a column is more native
  to the tracker than a second region object. The shared `regions` substrate
  (R7 piece 1) stays unextracted; no consumer has justified its shape.
- **Note host: keep augment, or migrate to replace too? Resolved: both branch
  by kind (A5), and both realise replace by parking (2026-07-03).** Mode is a
  generator-kind property: a discrete kind replaces, a continuous kind augments,
  on *both* hosts. The interim clip-to-first-hit realisation and the `fxHostEnd`
  dance are gone — § Note-host replace parks.
- **Selection over empty space and across lanes. Resolved: no new
  behaviour needed.** Selection is already a geometric channel × ppq
  rectangle (`editCursor.lua` `selection = {row1,row2,col1,col2,part1,part2}`)
  that iterates empty cells — it spans empty / cross-lane regions as-is, so
  N=0 and channel × ppq scoping fall out of the existing model.
- **Bake-on-export.** Address rewrite + merge of delta streams into their
  target lanes for plain-MIDI export; densification cost paid only there.
- **`plink.midi_*` parms.** Exact config-parm names and automation-bus
  addressing for R5 (→ cv-2); gates the listen-bank retirement.
- **Add-bank slot growth.** Whether the node's 16 add-bank slots need to
  grow once region hosts multiply overlapping carriers.
