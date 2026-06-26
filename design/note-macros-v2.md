# note macros v2 — region hosts and the generator spectrum

> Working design doc. Supersedes the forward-looking half of
> `design/archive/note-macros.md`, now the **frozen record of v1** — the
> shipped proving pair (retrig + vibrato), plus slide and trill, the
> additive-delta mechanism, the carrier / add-bank, and the G1–G5
> invariants. Read that for the vocabulary (host contract, derived-event
> lifecycle, delta streams, the two-categories-one-mechanism model); this
> doc leans on it and states only the deltas.
>
> v1's **kind vocabulary is closed** — arp is dropped on purpose: a true
> chord arpeggiator wants a region host (below), and the single-note
> "generalised trill" arp isn't worth a one-off list widget. v2 is not
> about new kinds. It is about the **substrate** the kinds run on: the
> step from the note-only host (N=1) to **region hosts** (N≥2, N=0), and
> the convergence of macros, aliases, and group-mirror onto one generator
> spectrum over one regions substrate (R7).

## What v1 left standing

v1 is complete and shipped. The single open frontier is **region hosts**
— the host kinds the contract was deliberately fixed against but that N=1
can't express. Everything else the v1 doc flagged is either settled
(arp, trill-cents, gen-stack UI, R4 dirty-tracking) or **owned by another
doc** (R5 plink and single-node packaging defer to `design/cv-2.md`).
Those are listed at the end so nobody hunts for them here.

## The thesis — one generator spectrum over one regions substrate

Three mechanisms in the house already generate events on only one side
of the intent line, all sharing one lifecycle — *spec on a host,
ephemeral derived identity, regenerate per rebuild*:

- **macros** (`note.fx`) — `note.fx` is `root.children` in miniature.
- **aliases** (the substrate, docs'd but not landed) — spec tree on a
  root, materialised child events, `parentUuid`, regenerated per rebuild.
- **group-mirror** (gm) — `groups.project` is already a pure function
  from spec + anchor to desired events: a generator with `group.events`
  + overrides as params and the instance anchor as the host window.

They are **three points on one generator spectrum**, separated by a
single axis: **invertibility.**

- The **mirror generator is invertible** — `toGroup`/`toInstance` are
  exact duals — so its output earns stable per-slot identity (vuid→uuid)
  and user editability with override residue.
- **retrig / vibrato are lossy** — no useful inverse — which is exactly
  why G3 makes their output generator-owned and ephemeral.

Aliases sit between. The spectrum is one substrate seen at different
invertibility; v2 builds the substrate, not three parallel mechanisms.

## The host contract — already host-count-blind

What a generator consumes is narrower than "a note": a time **window**, a
set of **input events**, an **identity** for provenance and
dirty-tracking, and channel context (unchanged from v1):

```lua
host = {
  window = { startppqL, endppqL },  -- effective logical interval, never OPEN
  events = { note, ... },           -- inputs
  id     = <uuid>,                  -- provenance key (derived) + dirty key
  chan   = <chan>,
}
```

v1 has exactly one host kind — the **note** (window = its effective
logical interval, events = the note itself, id = its uuid). The signature
was fixed against this contract *precisely so* the two wanted kinds that
don't fit N=1 drop in without a re-cut:

- a true **chord arpeggiator** consumes several notes (**N≥2**);
- a **free-running generator** — a fill, an LFO on a cc lane with no note
  — consumes none (**N=0**).

Both are **region hosts**: something region-shaped carrying `fx` plus a
window, supplying its covered notes as input. Nothing downstream cares
about N — the derived lifecycle, delta streams, and reconcile are
host-count-blind. v2's job is to grow the host *producer* from "every
note" to "every note ∪ every region," not to touch anything below the
contract.

## Region hosts — the N≠1 unlock

A region host is a persisted, anchored window over member events that
carries `fx`. Candidate substrate: a **gm group** — already a persisted,
anchored window over member events, so group-hosted `fx` would make every
instance arp identically for free. Whether region hosts are gm-backed or
a lighter standalone region is the open call this doc has to make; the
v1 doc deferred it explicitly to "when region hosts land."

The two unlocks, concretely:

- **Chord arp (N≥2).** The region supplies its covered notes as
  `host.events`; the generator broadens the host note's pitch into the
  chord's pitches and cycles them at `period`. The single-note arp v1
  dropped is the degenerate N=1 case of this — so building the region
  form *is* arp, done right.
- **Free-running LFO / fill (N=0).** The region carries only a window and
  `fx`; a continuous generator runs the LFO over the window with no host
  note to anchor it, baking carriers exactly as vibrato does today. A
  fill is the structural analogue: derived notes filling an empty window.

## Replace vs augment, and the no-host endpoint

The note host wears three hats — intent carrier (`note.fx`), identity
anchor (uuid → `derived` provenance, PA binding), and **output note 1**
(the audible first hit). The entire `fxHostEnd` view-restore dance (v1 §
Structural realisation) exists *only* for the third hat: the host is at
once intent and output, so its realised tail must clip to fxNote-2 *and*
be restored for the view.

A **replace** model splits that hat off — the carrier holds intent +
identity, emits no audible note, *all* hits are derived. It is strictly
cleaner (carrier shows at authored length natively, no restore) and is
the natural endpoint of the region generalisation: output is *always*
purely derived, the carrier is *always* intent + identity only, and
note-vs-region-vs-group stops mattering downstream.

The reason augment exists today is **not** note-count — it is **PA
binding**: the host's PA rides fxNote 1 (itself). Under replace the
carrier is silent and PA must bind to the window, or to a
regenerated-each-rebuild first hit — the same wrinkle region hosts hit.
So this sequences *with* region hosts, and **PA binding is the gating
design decision**, not the splice mechanics.

## The regions-substrate decomposition (R7)

When region hosts land they are **carved from gm's regions substrate, not
built fresh** — gm is bug-hardened, and re-founding it buys vocabulary,
not capability. gm decomposes three ways:

1. **A generic `regions` substrate** — rect, anchor, instance identity,
   membership, disjointness, persistence, wash rendering. Exactly what
   region hosts need.
2. **The mirror generator** — anchor-rebased replay, already extracted as
   the pure core (`groups.project`).
3. **The bidirectional edit protocol** — classify, override transitions,
   template writeback, localMode, the flush-seam shadow machinery. Most
   of gm's mass, with **no macro analogue** (macros are lossy, so G3
   makes their output generator-owned — there is nothing to write back).

The invertibility axis (the thesis above) is what assigns each mechanism
its slice: macros use (1) only; group-mirror uses (1)+(2)+(3); aliases
use (1)+(2). v2 extracts (1) as the shared substrate and lets region
hosts ride it; (3) stays gm's, untouched.

## Generators as config — the ctx discipline (carried forward)

The contract is already a pure `(host, params, ctx) → {notes, delta}`.
The direction — *in due course, not gating* — is for the generator **set**
to become config rather than hand-written Lua: a kind is data, not a
function. The route there is not a separate interpreter but a discipline
on **ctx**, the **evaluation environment** the generator body composes
against. When a body is nothing but arithmetic and *named ctx
operations*, it is already data; serialising it is the only step left.
The DSL is the limit of good ctx design, not a rewrite — and region-host
generators (chord arp, free LFO) are the next things written against it,
so the discipline matters now.

The v1 kinds are two skeletons, not five:

- **Structural (retrig, trill, arp) is one skeleton:** tile the window at
  `period`, emit one note per tile, `{pitch, vel, detune}` as expressions
  in the tile index `i`. retrig ramps vel, trill alternates pitch, arp
  cycles it.
- **Continuous (vibrato, slide) is one skeleton:** a `cents(t)` envelope
  over the window, sampled at the breakpoints its shape needs.

The discipline that grows ctx into the stdlib: **ctx binds what the
generator can't compute itself — and only that.** Pure arithmetic stays
in the module; the moment a generator must resolve a scale step (the
temper), find a neighbour, or honour a config bound, it reaches into ctx.
Landed ctx ops: `nextLane1Note`, `pbRangeCents`, `step`. `interval` is
the instructive non-example — it *looks* temper-bound but is pure note
arithmetic, so it lives as a module helper. **Scope guard: build no
interpreter now** — the move costs ~nothing if new kinds are shaped as
composition and ctx accretes as named ops.

## Owned elsewhere — not this doc's work

- **R5 — plink via MIDI; retire the listen bank**, and the **single-node
  packaging** it unblocks. Deferred to `design/cv-2.md`, which re-founds
  this exact path. Do not build under note-macros.
- **R4 — flush-time mechanism registry (`dirtyFxHosts`).** Measured
  2026-06-26: not warranted — the apparent cost was a carrier-reconcile
  churn bug (now fixed). Build only if a measured hotspot reappears.
- **R3 — `forEachEffectiveNote`.** Extract on its third real occurrence
  (macro flush-reconcile would be it); not before.

## Open questions carried forward

- **gm-backed vs standalone region host.** The substrate call this doc
  must make — group-hosted `fx` is free instancing, a standalone region
  is lighter. Decided when region hosts are built.
- **PA binding under replace / no-host.** The gating decision for the
  replace model (above): bind to the window, or to a regenerated first
  hit.
- **Bake-on-export.** Address rewrite + merge of delta streams into their
  target lanes for plain-MIDI export; densification cost paid only there.
- **`plink.midi_*` parms.** Exact config-parm names and automation-bus
  addressing for R5 (→ cv-2); gates the listen-bank retirement.
- **Add-bank slot growth.** Whether the node's 16 add-bank slots need to
  grow once region hosts multiply overlapping carriers.
