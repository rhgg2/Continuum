# Design — Adaptive tuning

> opened: 2026-07-04 · status: pre-design

**Solve a selection in one pass for a single detune per note that makes
its sounding sonorities as compact as they can jointly be in a chosen
target, anchored so no note leaves the step it was written on.**

## Where it sits

**1** This is an edit command over a selection, one undo block,
writing `(pitch, detune)` through `edit.assign`.

**2** The conventions it needs exist: `scopedAction` for
selection-or-whole-take (`trackerRender.lua:813-819`), `eventsByCol`
and `allGroups` for the note set, `registerAll`'s tuple form for the
undo label.

**3** Behind the command sits a pure function, notes in and
detune-per-note out. Lattice enumeration belongs in `tuning.lua`, the
solver in a module of its own.

**4** Detune is not realised beyond lane-1 notes; that is the author's
problem, not the function's.

## The command's slots

**1** Scope — which notes.

**2** Notation — the active temper. It supplies the names, the step
each note is anchored to, and the window inside which the note keeps
that name (§ What the window guarantees).

**3** Target — the **candidates**, the pitches a note may be moved to
(§ What a target is).

**4** Sonority size — `n`, the arity of the largest chord to be
recognised when spread out in time (§ The model).

**5** Pull strength — how hard the written pitch pulls back (§ The one
knob).

**6** Boundary — what is frozen at the edges of the scope (§ Seams).

## What "in tune" means

**1** Pairwise-just tuning of intervals does not imply just tuning.
Consonance is a **joint** property of the whole **sonority** — the set
of pitches taken as one harmony.

**2** Each note is a ratio to a common reference, and that ratio has
coordinates in the **lattice** — the group of positive rationals under
multiplication, coordinatised via its standard basis of primes. Thus
`15/8`, which is `2⁻³·3·5`, becomes the point `(−3, 1, 1)`.

**3** A sonority is a handful of points in that lattice. Its **box** is
what it spans on each axis — the highest coordinate less the lowest,
which is that prime's exponent in `lcm/gcd`. Its **score** is the sum
of those spans, each multiplied by a weight per axis.

**4** The octave is quotiented out, or the box measures spacing rather
than harmony: one major triad scores 5.91 close, 6.91 in first
inversion and 4.91 open, where the quotiented box scores 3.91 in every
voicing.

**5** Each axis is weighted by `log₂ p`, the ear's distance to a prime
growing with its logarithm rather than its size.

**6** The score of a sonority is then the Tenney height of its
octave-free `lcm/gcd`, and for a dyad the Tenney height of the
interval itself.

**7** The **objective** sums that score over the sonorities in the
selection, together with a **pull** on each note toward the pitch it
was written at (§ The model).

**8** A small box is a sonority whose notes share a strong virtual
fundamental, so the score measures root fusion — Terhardt's
virtual-pitch theory.

## Choosing the target chooses the theory

**1** Score the common chords against two targets: the whole lattice of
§ What "in tune" means, against the chain of fifths inside it.

| chord | whole lattice | fifth chain |
|---|---|---|
| fifth C–G | 1.58 | 1.58 |
| sus4 C–F–G | 3.17 | 3.17 |
| major C–E–G | 3.91 | 6.34 |
| minor C–E♭–G | 3.91 | 6.34 |
| maj7 C–E–G–B | 3.91 | 7.92 |
| dom7 C–E–G–B♭ | 7.81 | 9.51 |
| dim C–E♭–G♭ | 7.81 | 9.51 |
| **aug C–E–G♯** | **4.64** | **12.68** |
| septimal C–B♭ | 2.81 | *no reading* |

**2** They agree exactly where the music needs only fifths, and their
orderings agree down the middle.

**3** They part at the augmented triad: in the whole lattice it is two
stacked `5/4`s and scores below the dominant seventh; in the chain it
is eight fifths and is the most remote sonority in the system.

**4** A solver told to make sonorities compact will treat that chord as
ordinary or as a crisis depending on nothing but which target it was
handed.

**5** A target decides which sonorities exist. `7/4` has no address in
a chain of fifths at all.

## When an adaptive solve exists

**1** The notation and the target are two tunings, separately chosen.

**2** An adaptive solve exists at all only where the target puts more
than one point inside the notation's window.

**3** Against a 12-EDO notation, the 5-limit subgroup offers rivals at
±19.6¢ (the diaschisma), ±21.5¢ (the syntonic comma) and ±41.1¢ (the
diesis); a Pythagorean chain offers one at ±23.5¢.

**4** Write in 31-EDO and the window is ±19.4¢, narrower than the
syntonic comma. The two 5-limit spellings of a note cannot both be
candidates, and the solve is left with the 3.8¢ a dominant seventh
still wants.

**5** Snap is the absence of a target rather than a setting of one:
every note goes to its own step, one candidate each, and nothing is
scored. It is already written down and unbuilt in
`design/archive/microtuning.md` § Slice 4.

## What a target is

**1** A target is a set of **points**, the pitches a note may be moved
to, each of them a ratio to the common reference.

**2** A set of points may be arrived at either as a finitely generated
subgroup under a complexity ceiling — the 5-limit, the 11-limit — or as
an authored list of ratios, like the twenty of a combination product
set on `{1, 3, 5, 7, 9, 11}`.

**3** The complexity ceiling belongs to the points and never to the
lattice (§ Bound the complexity, not the integers).

## The model

**1** The cost lives on a whole sonority at once rather than on its
pairs.

**2** Take the sonority current at an onset to be the last `n` distinct
sounding pitches.

**3** A block chord and an arpeggio of the same chord then hand the
objective the same set.

**4** *Distinct* carries weight: a plain last-`n` window counts strikes,
so a repeated note spends a slot the harmony has already paid for.

**5** `n` states the arity of the largest sonority to be recognised when
spread out in time, which is a musical claim rather than a tuning. It
has a floor just above that: at `n` equal to the arity one chord fills
the sonority exactly and the next displaces it whole, so consecutive
chords share nothing and the passage falls apart into independent
solves.

**6** Each note has one detune, chosen once for its whole length.

**7** It may move only to a target point inside the notation's window,
under a complexity ceiling — a handful of choices. Both bounds are
load-bearing and neither is a knob (§ What the window guarantees,
§ Bound the complexity, not the integers).

**8** The pull kills comma drift: each note is held near where it was
written, so the piece cannot walk off a syntonic comma the way naïve
chained-JI does.

**9** It also stops the solver collapsing a sonority into a drone, the
box being globally minimised at zero by putting every note on one
pitch.

**10** A note in two sonorities has one detune serving both, and takes
the best compromise they can agree on. That coupling is what makes this
one global problem rather than a bag of chords.

**11** The reference floats per sonority. There is no global fundamental
and no tonal-centre input: each sonority finds its own compact region on
its own reference, and the overlap and the pull are what keep
neighbouring chords coherent.

## What the window guarantees

**1** Take the window from the notation — the midpoint to the step on
either side — and three properties arrive together, none of which
survives a wider window.

**2** No note renames. `tuning.midiToStep` recovers a note's scale step
from `(pitch, detune)` by snapping to the nearest step
(`tuning.lua:401-409`), so a note that stays inside the window keeps
the name it was written under. Move it further and the tracker cell
relabels itself — the solver editing the score rather than tuning it.

**3** The written pitch stays recoverable. Because the step survives,
the pitch a second pass pulls toward can be read off the note itself,
and nothing has to be stashed beside it.

**4** The operation is therefore idempotent — but only if the pull is
toward the recovered step rather than the note's current cents.
Measured on a twenty-note chorale: pulling toward the step, a re-solve
moves nothing at all (0.00¢); pulling toward current cents it walks
2.8¢, then 3.3¢, with no sign of settling. The second is the
version that makes a piece impossible to work on, and the two differ by
one line.

**5** The window is "half a temper step" only in an equal notation.
Nearest-step recovery puts the boundary at the midpoint between
adjacent scale points, so an unequal scale gives an asymmetric window:
in a twelve-note quarter-comma meantone MOS, C may move +38.0¢ toward
C♯ and −58.6¢ toward B.

**6** Meantone's diesis is 41.1¢, so the A♭ a chord might want in place
of G♯ falls *outside* that window on the chromatic side, and the solve
cannot reach the very candidate that makes adaptive meantone
interesting.

**7** In 12-EDO it never binds. Widening it to two and then four
half-steps at a working pull strength left the answers where they were
— the largest deviation went 11.8¢, 10.5¢, 10.5¢, and no note passed a
half-step in any run. The pull stops a note long before the window
does.

## Bound the complexity, not the integers

**1** "Bounded by an odd-limit ceiling" admits an implementation that
looks equivalent and is not: capping the ratio's integers themselves.
The
two come apart on inversion, because a minor triad is 15-odd-limit in
every voicing and its integers are not:

| voicing | ratio | odd limit | largest integer |
|---|---|---|---|
| root | `10:12:15` | 15 | 15 |
| first inversion | `12:15:20` | 15 | 20 |
| second inversion | `15:20:24` | 15 | 24 |

**2** A cap on the integers is thus a ceiling that moves when the music
is revoiced and the harmony has not changed, and it fails without
saying so. A spike capped at 16 could not express `12:15:20` at all, so
it tuned that chord to something else — with a converged cost, a
confident answer, and a different answer per random seed. An excluded
candidate does not score badly. It does not score.

**3** So bound the complexity, and assert that every sonority's
shortlist holds at least one candidate inside the window of its
written pitches. That assertion earns its keep because this is the
failure you cannot hear: a drone announces itself, where an excluded
candidate sounds like a solver with taste you disagree with.

## Solving it

**1** The problem is non-convex and combinatorial with no closed form,
so an annealer is the obvious reach and the wrong one. Its noise does
not shrink with the correction it is there to compute: the spike
disagreed with itself by about 2¢ between seeds, at a pull strength
where the whole correction averaged 1.9¢. A solver whose error is half
its output is not measuring anything.

**2** Exact dynamic programming along the time axis is reachable, and
the sonority is what puts it in reach. Because the sonority is one set
over all parts rather than a window per part, the DP state carries the
chosen tuning of the `n−1` most recently distinct pitches and nothing
else. It costs `D^(n−1)` for `D` candidates per note, and the count
does not depend on how many parts are sounding. At five candidates:
`n=4` is 125 states, `n=6` is 15,625, `n=8` is 390,625.

**3** So the exact method is not a special case to hope for. It is the
method, up to a stated budget on `D^(n−1)`, with the annealer left as a
fallback for a passage wanting a sonority wider than the budget allows.

**4** Counting distinct pitches is what buys this, and the margin is
not close. A plain window reaching the same share of chords needs `n=9`
where distinct needs `n=3` — `390,625` states against `25`. Four orders
of magnitude, for a worse answer.

**5** This is also where solving **the whole passage at once** pays.
One global solve balances the pull optimally, where a causal chase
accumulates drift.

## The one knob: harmonic lock

**1** The strength of that pull, called **harmonic lock** on the modal,
is the whole expressive control — how far fidelity to the written pitch
yields to purity. It is a field beside the scope, set per invocation.
Its range is
narrower than 0 → 1 suggests. Five seeds on one twenty-note input, at
four increasing pull strengths:

| pull | seed-to-seed spread | mean correction |
|---|---|---|
| free | 38.2¢ | 6.4¢ |
| working | 4.7¢ | 5.2¢ |
| firm | 2.6¢ | 3.8¢ |
| stiff | 2.0¢ | 1.9¢ |

**2** Those figures come from a throwaway annealing spike on a
twenty-note four-voice chorale, predating this document's weight and
its collapse to one factor; its own ≈2¢ noise floor sits inside every
spread. The shape is indicative, the values are not. Every voice
changes together in that material, so the coupling of § The model went
untested.

**3** At the free end the solve is ambiguous rather than expressive:
several tunings score alike, and which one you get is the seed's
business rather than the music's. At the stiff end it is a no-op. The
usable band is the middle.

## Seams: collaring from the take before

**1** The reference floats, so the same written pitch can land at +30¢
closing take N and −30¢ opening take N+1. Nothing clicks — no note
holds across the boundary — but the ear carries pitch memory and hears
the reference move.

**2** Take N is already solved and written, so its detunes are data:
its tail — the **collar** — enters take N+1's solve as **frozen
variables**, contributing to the objective but unable to move, and the
opening notes are pulled into agreement with a tuning simply given to
them.

**3** That makes a sweep across takes order-dependent: solving take N
invalidates the collar under take N+1. A sweep in take order is
idempotent; out of order it is not. `am:reswingAll` already walks takes
serially and rebinds each in turn (`arrangeManager.lua:1003-1006`), so
the shape exists to borrow.

**4** The one genuine choice left is how far the collar reaches, and
whether a boundary should ever *want* a reset — a hard cut between two
unrelated sections, where a fresh reference is correct. Default: collar
it. Make the reset the exception.

## First brick

**1** Build the command with no target: every note to its own step.
That is snap, and it is not a stub — scope, window, write and undo all
get exercised with nothing to choose between, and the result is
checkable by eye against the grid's deviation ticks.

**2** Then the objective. The bounding-box norm and the sonority walk
as a pure module, hand-worked on a dominant seventh resolving to a
tonic: enumerate candidates, score each sonority, confirm the solver
picks the otonal `4:5:6:7` and the resolution the ear expects. That
test is what pins the weight (§ What "in tune" means). Ship it green
before the solve reaches a take.

**3** The order matters because the two halves fail differently. The
command half fails visibly — the wrong notes move, or undo does not
bring them back. The objective half fails silently, and every guard
against that (§ Bound the complexity, not the integers) is a property
of a pure function, which is to say a thing a spec can pin.

**4** A real target is a third step and not a prerequisite for either.
The cheaper of the two is an authored ratio scale, the combination
product set of § What a target is: it brings rivals to choose between
while wanting no enumeration and no ceiling, so it exercises the
objective for less than a generated subgroup does. The subgroup follows
it.

## Open

- **Harmonic entropy does not transfer.** It scores cents against the
  harmonic series, so it would answer the JI question whichever
  subgroup supplied the candidates. As an upgrade it is available to
  the JI target only.
- **Where the pitch window binds** — never in 12-EDO against a dense
  target, measured; in an unequal notation it can, and the meantone
  enharmonic is the case that matters (§ What the window guarantees).
  Whether that is answered by widening the window, by letting the
  rename happen, or by declaring meantone respelling a different
  command, is undecided.
- **The sonority at a chord change.** A sonority straddling a seam
  holds notes from two chords and asks them to be compact together.
  Large `n` buys coupling and costs this, and `n` one above the arity
  is the smallest that buys any. Where the trade sits is unmeasured,
  and it is the only thing stopping `n` from simply being set large.
- **Pitch or pitch class.** The octave quotient puts `C4` and `C5` on
  one lattice point, so they should be one entry in a sonority — but
  they remain two variables, and nothing in the objective then stops
  them drifting apart. Whether that wants a constraint or is right as
  it stands is untested.
- **The pull's shape** — a flat window with a quadratic pull was enough
  to make the spike stable, and it is the pull rather than `n` that
  bounds an edit's blast radius: at a firm pull, changing one note
  moved two or three of the other nineteen, by under 4¢. Whether a well
  — soft near the centre, stiff at the edge — buys anything is
  unmeasured.
- **The command's interface.** The target's shape is settled (§ What a
  target is); what is not is where it gets chosen, nor what the pure
  solver takes and returns. It cannot be a config key: `temper` is a
  single value on the tier merge (`configManager.lua:58`), pinned at
  take, track and project together by `tv:setTemperSlot`
  (`trackerView.lua:566-572`), and every consumer resolves exactly one
  name. So the target is an argument to the command, and the solver's
  signature is the next round.
- **A strength dial.** Retuning the selection *half way* toward the
  target is not the pull restated: the pull selects among candidates
  and always lands on one, where a blend lands between two, at a pitch
  that is not a point of the target. It would be a post-pass on the
  solved displacement, well-defined for the same reason the solve is
  idempotent — re-derive the target from the recovered step, and α
  applied twice is α rather than `1−(1−α)²`. It waits because nothing
  yet produces off-grid material for it to soften: capture snaps to the
  active temper (`design/midi-capture.md`), an import arrives on its
  source's grid, and the only off-grid material Continuum makes is this
  command's own output.
