# Design — Adaptive just intonation (tune the realisation, not the intent)

Status: pre-design. A vision note with a concrete v1 algorithm, not a
plan. Captured because it falls almost free out of the intent /
realisation split already in `docs/tuning.md`, and because the core
question — *what does "in tune" mean for a whole chord* — has a clean
answer worth writing down before it evaporates.

The one-line pitch: **solve the whole take offline for a single detune
per note that makes every sounding chord fuse to the strongest possible
root, anchored so it can't drift.**

## The thesis it rests on

Nothing here is a new axiom. It is what falls out of one decision
already made:

- **Detune is intent; pb is realisation.** A note's authored pitch (its
  scale step under a temperament) is untouchable document data. The
  channel-wide pb stream is a *compiled* realisation that tm already
  reconciles. So "retune for consonance" is not a new capability — it is
  one more transform in a frame that exists. We author in a tempered
  grid and let the realisation bend to make the harmony lock, exactly as
  swing bends the logical frame into realisation time (`docs/timing.md`).

Adaptive JI is the killer app of the pb-as-realisation model. The
document says *what harmony*; the solver says *what pitches best serve
it*; the intent is never mutated.

## What "in tune" means: minimise the chord's LCM

The naïve approach — pick a just target for each interval independently
and pull toward it — is wrong, and instructively so. Three locally-pure
dyads can be mutually inconsistent: the chord does not close. Pairwise
targets also pre-commit each dyad to an interval *identity* the ear may
not agree with.

The right target is a **joint** property of the whole sonority. Express
the sounding notes as integer ratios `{k₁ … kₙ}` over a common
fundamental and minimise `lcm(kᵢ)`. That LCM *is* the period of the
harmonic series the chord sits on, so minimising it **maximises the
virtual fundamental** — it makes the chord fuse to the strongest
possible root (Terhardt's virtual-pitch theory). This is the *otonal*
or *periodicity* view: a consonant chord is a compact segment of one
harmonic series. We are maximising root fusion, not minimising beating
dyad by dyad — which is why it beats the pairwise approach both in
theory and in the ear.

### Raw LCM is too brittle to be the objective

LCM jumps discontinuously and is hostage to its worst member:
`{4,5,6} → 60`, add one septimal note `{4,5,6,7} → 420`. You cannot
optimise that directly. Use a **co-monotone smooth surrogate** — same
ranking of good chords, graceful degradation on a near miss:

- **Euler's *gradus suavitatis*** — `N = lcm(kᵢ)`, factor
  `N = ∏ pᵉ`, cost `= 1 + Σ e·(p−1)`. Integer, cheap, ~five lines. The
  recommended v1 objective.
- **Tenney height** — `log₂(∏ kᵢ)`. Log-domain, no cliffs.
- **Harmonic entropy** (Erlich) — entropy over which simple ratio the
  ear plausibly hears. Best perceptual match, heaviest to compute; a
  later upgrade, not v1.

All three rank low-LCM chords first but cost a near-miss a little rather
than a cliff. Start with gradus.

## The model: a discrete solve on the pitch lattice

The structural consequence of "minimise the chord's LCM" is that the
cost lives on the **whole chord at once** — a hyperedge, not a sum over
pairs. So least-squares / spring relaxation does *not* apply. The
natural model is a factor graph over the JI lattice:

- **Variables** — one per note. *Single detune per note* → single
  variable. This is the v1 scope: no in-flight retuning of a held note,
  because per-note we just set `detune` and we are done.
- **Domain** — candidate rationals within ±tolerance (≈ ±35 ¢) of the
  written pitch, bounded by an odd-limit ceiling. A handful of choices
  per note.
- **Vertical factors** — for each time-slice (a maximal set of
  simultaneously sounding notes), `gradus(lcm(chosen integers))`. The
  hyperedge over the chord.
- **Horizontal factors** — per part, over a sliding memory window,
  `gradus(lcm(window's chosen integers))`. This is the "melody in tune
  with itself" term: it forces each voice to trace a *compact region* of
  the lattice instead of wandering.
- **Unary anchor** — cents deviation of the candidate from the written
  pitch. This bounds the search and kills comma-drift: a note cannot
  leave its window, so the piece cannot walk off a syntonic comma the
  way naïve chained-JI does.

The coupling that makes this **one global problem** and not a bag of
independent chords: a note held or overlapping across two chords is one
variable shared by two vertical cliques. Independent chords would solve
locally; the shared notes stitch them together. For v1's single detune,
that shared note simply takes the best compromise both cliques can
agree on — which is exactly the fidelity we are trading away by
deferring in-flight retuning (see Open).

**The reference floats per chord.** No global fundamental, no
tonal-centre input. Each vertical clique finds its own compact integer
set on its own virtual fundamental; the horizontal factors and the
anchor keep neighbouring chords coherent.

## Solving it

Non-convex, combinatorial, no closed form — but the instance is tiny:
hundreds of notes, ~5–10 candidates each. Simulated annealing or loopy
belief propagation converges in seconds *offline*. With a simultaneity
cap, exact dynamic programming along the time axis is on the table. This
is where **solve over the whole take at once** pays: one global anneal
that balances the anchor's restoring force optimally, instead of a
causal chase that accumulates drift.

## The one knob: harmonic lock

The anchor weight is the whole expressive control, and it wants to be a
single automatable scalar — **harmonic lock**, 0 → 1:

- **1** (stiff anchor) — play it as written; the realisation is the
  tempered intent.
- **0** (free anchor) — the whole take floats to its own most-consonant
  centre.
- **between** — purity balanced against fidelity to the written pitch.

Note the rhyme with the meta-sequencer: this is another *realisation
curve over a clean intent document*. A progression can breathe between
tempered tension and just-intoned rest as a drawn, composable line —
the same shape as the version-lane in `design/meta-sequencer.md`. Two
visions, one primitive.

## Seams: collaring take boundaries

The problem here is **purely perceptual** — there is nothing mechanical
to fix. Notes cannot hold across a take boundary; each note carries its
one detune inside one take. So no stream steps, nothing clicks, and a
per-take solve is internally clean on both sides. What breaks is the
*listener's* tuning reference: because the fundamental floats per chord
and per take, the same written pitch can land at +30 ¢ closing take N
and −30 ¢ opening take N+1. Every note is internally consonant, yet the
ear — which carries pitch memory across the seam — hears the tuning
*slip*. The anchor caps that swerve at 2×tolerance, but bounded is not
smooth.

The fix is not new machinery. It is the **horizontal memory-window term
refusing to reset at a container boundary.** The "melody in tune with
itself over time" factor is already the perceptual-continuity term; a
take boundary is just a place we would otherwise cut it, for a container
reason rather than a musical one. Let the window span the seam and the
opening notes of take N+1 are pulled into tuning agreement with the tail
of take N — smoothly, over the window's length, decaying to full
interior freedom. The take boundary is an artifact of the container, not
of the music; the perceptual-continuity term should not know it is
there.

The only genuine choice is how far that continuity reaches across the
seam — the window's length — and whether a boundary should ever *want* a
reset (a hard cut between two unrelated sections, where a fresh tuning
reference is correct). Default: span it. Make the reset the exception.

## The failure mode to guard first

With a weak anchor, LCM-minimisation has a **degenerate attractor**: the
global minimum of `lcm` is 1, reached by collapsing every note to a
unison or octave. Left unchecked the solver implodes the chord to a
drone. The anchor weight and the odd-limit ceiling are the only things
holding it musical. Tune those two before anything else; a solver that
produces beautiful gradus scores and inaudible music has found this
hole.

## Where it sits in the architecture (reuse, don't invent)

- **Input** — the compiled `doc`: notes with written pitch (intent) and
  onset/offset in the realisation frame, sliced into simultaneity
  groups. The slicing is the same onset/offset walk voicing and the
  pb reconcile already do.
- **Coordinate layer** — `tuning.lua` already converts between naming
  systems and knows temperaments; the candidate-lattice enumeration and
  the ratio ↔ cents maths belong here or beside it, as a pure module.
- **Solver** — a new pure module (`adaptiveJI`?): take slices +
  candidates + weights, return a detune per note. No take state, no
  REAPER; unit-testable against hand-worked chords.
- **Output** — the solved detune rejoins the existing intent →
  realisation reconcile. Crucially it writes **detune** (the field the
  pb stream already derives from), so nothing downstream changes: the
  fake-pb absorber and the lane-1 convention in `docs/tuning.md` carry
  the result to the wire unmodified. v1 sets one detune per note and is
  done.
- **Compile stage** — runs offline, as a stage before the pb
  realisation, gated by the harmonic-lock knob (skip entirely at
  lock = 1).

## First brick

**Gradus + slice extraction as a pure module, verified on paper before
any wiring.** Hand-work a dominant seventh resolving to a tonic:
enumerate candidates, score each slice's gradus, confirm the solver
picks the otonal 4:5:6:7 and the resolution the ear expects. Ship that
green, *then* touch the pb layer.

- It exercises the objective and the slice walk with zero REAPER
  coupling.
- It surfaces the degenerate-attractor and anchor-weight questions on a
  case small enough to reason about fully.
- Every richer path (harmonic entropy, in-flight retuning, the automated
  lock curve) is a deformation of a solver that already tunes one chord
  correctly.

## Open

- **In-flight retuning (v2).** A note sustained across a chord change
  wants two tunings; v1 forces one compromise. Because pb is a
  channel-wide stream that *can* move mid-note, the real fix is to split
  a note at the onsets that change its harmonic context, make each
  segment its own variable, and spring adjacent segments together so it
  glides. Deferred: per-note we only set detune today, and segment-level
  realisation is a bigger lift than v1 earns.
- **Objective choice** — gradus for v1; is harmonic entropy worth the
  cost later, and does it change the answers on real music or only at
  the margins?
- **Slice granularity** — maximal simultaneity groups, or a finer
  onset-to-onset grid? The held-note compromise depends on which.
- **Anchor shape** — is a flat ±tolerance window enough, or does the
  anchor want to be softer near the centre and stiff at the edge (a
  well, not a box)?
- **Determinism** — annealing must be seeded and reproducible; the same
  take must solve to the same detunes every time (compile purity).
- **Horizontal window** — how long a memory, and does it span rests?
