# Rank-2 temperaments, MOS scales, and the keyboard seam

Design note for the rank-2 generator and the keyboard-input direction it
opens up. WHY and decisions; the generator's API surface lives in
`tuning.lua` annotations once built.

## Three layers, currently two fused

1. **Tuning** — the pitch reservoir (the cents lattice). What pitches
   *exist*.
2. **Scale** — a selection/pattern *over* a tuning. Which pitches are
   "in," in what L/s arrangement. **MOS lives here.**
3. **Keyboard map** — input key → pitch.

Continuum has no scale layer, and the keyboard map is welded to the
tuning. The path today:

- `commandManager.lua` `layouts.qwerty` → `noteChar = {semi 0..16,
  octOff 0..1}` — a two-row piano on QWERTY.
- `trackerView.lua` builds a 12-EDO MIDI pitch
  `(currentOctave + 1 + octOff) * 12 + semi`, then calls
  `tuning.snap(temper, pitch, 0)` = `stepToMidi(midiToStep(...))`:
  nearest scale point by cents within the period.

So: QWERTY is a 12-semitone-per-octave piano (n·100¢ over C-1), snapped
to the nearest tuning step.

## Rank

- **Rank 1** — one generator: every pitch a multiple of one step. An
  **EDO**.
- **Rank 2** — a **period** + a **generator** stacked within it.
  Meantone, Pythagorean, superpyth.
- **Rank 3+** — JI lattices (5-limit JI is rank 3: primes 2, 3, 5).

A temperament lowers rank by tempering out commas: 5-limit JI minus the
syntonic comma is meantone (rank 2); temper one more and it collapses to
an EDO (rank 1).

Rank-2 is the general framework; **MOS is what you draw from it** — a
contiguous generator-chain slice, sized to a count where only two step
sizes appear (a *moment of symmetry*). The generator need not be an EDO
step: quarter-comma meantone's fifth ≈ 696.578¢ is irrational. That is
exactly the expressivity an EDO-only MOS (Scale Workshop's) throws away.

## The seam: one 2D object, three views

A rank-2 tuning is a 2D lattice (`i·period + j·generator`). QWERTY is a
2D, *staggered* key grid. An MOS scale is a contiguous **band** in the
lattice (the generator chain). The current cents-snap is a **lossy 1D
projection** of that lattice onto the piano's 100¢ ladder — the source
of off-12 collisions and unreachable steps, and why MOS feels like an
awkward bolt-on (you are forcing a 2D structure through a 1D port).

Map the lattice onto QWERTY directly and the seam dissolves: the scale
becomes a *region of lit keys*, the keyboard *is* the lattice. The
stagger supplies diagonals → generalized-keyboard (Wicki-Hayden /
Bosanquet) layouts, where chord and scale shapes are **translation-
invariant** for any rank-2 tuning.

## Keyboard modes — decision: three, selected per tuning

- **current (cents-snap)** — key → nearest tuning step by cents.
  Pianoish; degrades off-12. Stays meaningful for arbitrary imported
  Scala scales that have no lattice to map onto. The fallback default.
- **(b) scale-faithful** — column = next scale degree in pitch order,
  row = +period (octave). Each row is one octave of the scale, the MOS
  pattern *is* the row. Melodic and intuitive; not translation-invariant
  (L and s alternate, so chord shapes shift along the row).
- **(c) isomorphic** — two axes = the two MOS step vectors (the large
  step L and the chroma L−s); the stagger supplies the diagonal.
  Translation-invariant **and** melodic. Most work; the destination.

(b) is the high-value first step (the generalized piano; subsumes
12-EDO). (c) is where it's going. **Keyboard rework is a separate later
thread** — the rank-2 generator lands first as a pure tuning generator.

## The rank-2 generator (this thread)

A pure emitter in `tuning.lua`, same contract as the existing
generators: returns `{pitches, periodPitch, periodAsStep}`.

`M.genRank2(generator, period, size, up)`:

- `generator`, `period` — Scala tokens (ratio / cents / EDO-step).
- `size` — note count N.
- `up` — *bright generators up*: how many of the N−1 non-root
  generators stack upward; the rest stack downward. `up ∈ [0, N−1]`,
  selects the mode (brightest at N−1, darkest at 0).

Construction: stack `k·generator` for `k ∈ [−(N−1−up), +up]`; reduce
each into `[0, period)`; sort ascending. The root (k=0) reduces to
0 = `1/1`, so the `cents[1] == 0` invariant holds for free.

(Check: pure fifth, N=7, up=5 → k ∈ {−1,…,5} = F C G D A E B → sorted
C D E F G A B = Ionian. up=6 → Lydian; up=0 → Locrian.)

### Token emission — rational when possible, else cents

When generator and period are both ratios (`3/2`, `2/1`, bare integers),
each degree is stacked and reduced as an exact fraction: Pythagorean
major comes out `1/1 9/8 81/64 4/3 3/2 27/16 243/128`, matching Scale
Workshop. A tempered, EDO-step (`7\12`), or cents generator is
irrational with no finite ratio, so those degrees emit decimal-cents
(`701.9550`). Exact integers overflow past ~2^40, so very long rational
chains (≳ 25 fifths) fall back to cents per degree.

### Well-formedness (MOS)

A size N is a moment of symmetry iff the sorted adjacent-difference set
(including the wrap step `period − last`) has exactly two values.
`M.nextMosSize(generator, period, fromN, dir)` walks N until the
two-size test holds — drives the UI "next MOS size" stepper.
`M.mosInfo(generator, period, n)` returns `{isMos, large, small}` — the
L/s step counts behind the `5L 2s` hover. The
step-size multiset is rotation-invariant, so both ignore `up`. Compute
the diffs from the abstract cents generator, never a pre-quantized EDO
grid, or the test passes at junk counts (an EDO's 700¢ fifth gives two
sizes at 8, 9, 10… because it divides the period evenly).

### UI (temperEditor generators pane)

New `GEN_KINDS` pill `rank2` (label "Rank-2 / MOS", desc "Stack a
generator into a period"). Fields: Generator, Period, Size, Bright
(up), with a "next MOS size" stepper on Size. `buildGen` validates the
two tokens via `scalaPitch`, `size ≥ 2`, `up ∈ [0, N−1]`.

### Deferred: vals & comma-list construction, multi-MOS

Scale Workshop also derives the generator from **vals** (TE/POTE/CTE
least-squares optimization over a prime subgroup, wart notation) or a
**comma list**, and supports **multi-MOS** (a fractional-octave period,
generators distributed among periods). That is substantial separate
machinery (subgroup optimization); v1 is the generator+period method
only. Whatever generator/period a vals or comma-list method computes
feeds the same `genRank2`, so they bolt on later without reworking it.

## Build order

1. `genRank2` + `nextMosSize` in `tuning.lua`, with tests. ← start here
2. The `rank2` UI pill in `temperEditor.lua`.
3. (Separate thread) the per-tuning keyboard mode + modes (b)/(c).
