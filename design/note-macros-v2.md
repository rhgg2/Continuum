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
the generator may or may not emit, and the dance disappears.

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
persisted. The degenerate note host still binds PA to its note. So
augment survives only as the v1 note-host special case; region hosts are
pure replace.

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

**Edit existing regions in a region mode**, mirroring the mode that
already exists for mirror (group) regions: in normal mode cells are the
cursor targets and a selection authors a region; in fx-region mode the
*regions* are the navigable objects — footprints you tab between, select
to open the editor, create / delete. Note scope needs no mode (no object,
just the cursor note). Reusing the mirror-region interaction is the cheap
path, and another reason the substrate wants to *be* gm's regions
substrate (§ R7).

**Indication** generalizes onto existing machinery: the v1 badge
(`smallGlyph` in the note cell) for note scope, a footprint wash / edge
(the region-paint machinery — `tv_region_paint`, `ec_regions`) for a
region.

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

## Owned elsewhere — not this doc's work

- **R5 — plink via MIDI; retire the listen bank**, and the **single-node
  packaging** it unblocks. Deferred to `design/cv-2.md`, which re-founds
  this exact path. Do not build under note-macros.
- **R4 — flush-time mechanism registry (`dirtyFxHosts`).** Measured
  not-warranted; the apparent cost was a carrier-reconcile churn bug
  (fixed). Build only if a measured hotspot reappears.
- **R3 — `forEachEffectiveNote`.** Extract on its third real occurrence;
  not before.

## Open questions

- **gm-backed vs standalone region host.** Leaning gm-backed (above); the
  open part is only whether a full group is too heavy for a bare
  fx-region, decided when building.
- **Note host: keep augment, or migrate to replace too?** Region hosts
  are pure replace; the note host stays v1 augment (host plays as fxNote
  1). Unifying it onto replace would delete the `fxHostEnd` dance
  entirely, at the cost of re-binding the single-note PA case to a region.
- **Selection over empty space and across lanes.** The authoring gesture
  needs the selection rect to work over *empty* spans (for N=0) and to
  scope a channel × ppq region. If today's selection is event-anchored,
  that is new selection behaviour, not just new fx behaviour — verify
  against `tv_selection_rect` before relying on it.
- **Bake-on-export.** Address rewrite + merge of delta streams into their
  target lanes for plain-MIDI export; densification cost paid only there.
- **`plink.midi_*` parms.** Exact config-parm names and automation-bus
  addressing for R5 (→ cv-2); gates the listen-bank retirement.
- **Add-bank slot growth.** Whether the node's 16 add-bank slots need to
  grow once region hosts multiply overlapping carriers.
