# Design — Adaptive tuning

> opened: 2026-07-04 · status: working design — the solver's boundary
> settled, unstarted

**Solve a selection in one pass for a single detune per note that
makes its sounding sonorities as harmonious as they can jointly be
with respect to a chosen set of ratios, anchored so no note leaves the
step it was written on.**

## Where it sits

1. This is an edit command over a selection, one undo block, writing
   `(pitch, detune)` through `edit.assign`.

2. The solve selects rather than adjusts: each note lands on exactly
   one point of the target (§ What a target is), never between two.

3. The conventions it needs exist: `scopedAction` for
   selection-or-whole-take (`trackerRender.lua:813-819`), `eventsByCol`
   and `allGroups` for the note set, `registerAll`'s tuple form for the
   undo label.

4. Behind the command sits a pure function, notes in and a choice per
   note out (§ What the solver takes). Points and their placement belong
   to `tuning.lua`; the solver is a module of its own and carries no
   tuning vocabulary at all.

5. Detune is not realised beyond lane-1 notes; that is the author's
   problem, not the function's.

6. The target is named at invocation rather than pinned as a config key.
   `temper` is a single value on the tier merge (`configManager.lua:58`),
   pinned at take, track and project together by `tv:setTemperSlot`
   (`trackerView.lua:566-572`), and every consumer resolves exactly one
   name.

## The command's slots

1. Scope — which notes.

2. Notation — the active temper. It supplies the names, the step each
   note is anchored to, and the window inside which the note keeps that
   name (§ The window).

3. Target — the temper whose points a note may be moved to
   (§ What a target is).

4. Sonority size — `n`, the arity of the largest chord to be recognised
   when spread out in time (§ The model).

5. Pull strength — how hard the written pitch pulls back
   (§ Harmonic lock).

6. Boundary — how far the collar reaches (§ Seams).

## What "in tune" means

1. Pairwise-just tuning of intervals does not imply just tuning.
   Consonance is a **joint** property of the whole **sonority** — the
   set of pitches taken as one harmony.

2. Each pitch of a sonority is a rational number, and its **coords** are
   the exponents of the odd primes in it: `15/8`, which is `2⁻³·3·5`,
   has coords `{3 = 1, 5 = 1}`.

3. Prime 2 is absent, or the measure would read spacing rather than
   harmony: one major triad scores 5.91 close, 6.91 in first inversion
   and 4.91 open, where the same triad without prime 2 scores 3.91 in
   every voicing.

4. A sonority's **box** is what its coords span on each axis — the
   highest exponent less the lowest. Its **score** is the sum of those
   spans, each weighted by `log₂ p`, the ear's distance to a prime
   growing with its logarithm rather than its size.

5. That score is the Tenney height of the sonority's octave-free
   `lcm/gcd`, and for a dyad the Tenney height of the interval itself.
   The coords reach it without forming either integer, so no arithmetic
   ceiling bounds how far out the primes may go.

6. Adding a constant to every coord on an axis leaves that axis's span
   unchanged, so the score is blind to where the sonority sits. The
   model holds no reference pitch and none has to be chosen.

7. The **objective** sums that score over the sonorities in the
   selection, together with a **pull** on each note toward the pitch it
   was written at (§ The model).

8. A small box is a sonority whose notes share a strong virtual
   fundamental, so the score measures root fusion — Terhardt's
   virtual-pitch theory.

## The window

1. A note's **window** reaches half way to the notation's adjacent step
   on either side.

2. An unequal scale gives an asymmetric window: in a twelve-note
   quarter-comma meantone MOS, C may move +38.0¢ toward C♯ and −58.6¢
   toward B.

3. Inside it a note keeps its step. `tuning.midiToStep` recovers the
   scale step from `(pitch, detune)` by snapping to the nearest step
   (`tuning.lua:400-408`), so the tracker cell keeps the name it was
   written under. Move a note further and the cell relabels itself —
   the solver editing the score rather than tuning it.

4. The written pitch therefore stays recoverable, and nothing has to be
   stashed beside the note to hold it.

5. The pull is toward that recovered step rather than the note's
   current cents, which makes the operation idempotent.

6. The window is spent before the solve, in building a note's
   shortlist (§ What the solver takes). `ctx:noteProjection` already
   computes both half-gaps, but returns only the smaller
   (`viewContext.lua:42`); the two-sided window is new.

7. In 12-EDO the window never binds. Widening it to two and then four
   half-steps, at a pull strength in the usable band (§ Harmonic lock),
   left the answers where they were — the largest deviation went 11.8¢,
   10.5¢, 10.5¢, and no note passed a half-step in any run.

## What a target is

1. A target is a temper whose every pitch token is a ratio. Its
   **points** are the pitches a note may be moved to.

2. The token is what carries the coords the objective scores
   (§ What "in tune" means). A pitch given in cents or in equal
   divisions has none, so a temper holding one cannot be a target.

3. Eligibility is therefore a predicate over the tokens, answered when
   the target is chosen rather than when the solve runs.

4. No new mechanism authors a target. `tuning.genCPS`,
   `tuning.genHarmonics`, `tuning.genChord` and the rational case of
   `tuning.genRank2` already emit ratio tokens, and the temper editor
   already drives all four (`temperEditor.lua:667-713`).

5. The one generator still to write is the diamond (§ The diamond).

6. The role reads a temper's `pitches` and its `rootCents`. Step names,
   octave numbering and cell width are the notation's business, and a
   target is never displayed.

7. Which of a target's points a note meets depends on where the music
   sits against that root (`docs/tuning.md` § The root).

8. A target's own period is not consulted. The octave is quotiented out
   of the score, so the solver cannot tell a point from the same point
   an octave away, and every point is available in every register.

## The diamond

1. A generated target is bounded by **odd limit**: the largest odd
   number left in a point's ratio once the powers of two are divided
   out.

2. Odd limit is invariant under octave placement and inversion where the
   largest integer is not. `45/32` and `64/45` are one interval and its
   inversion, both of odd limit 45, where the largest integer reads 45
   and 64.

3. A cap on the integers is therefore a ceiling that moves when a point
   is respelled and the interval has not changed.

4. Capping at odd limit `N` while admitting every prime up to `N` gives
   exactly Partch's `N`-odd-limit tonality diamond: 19 points at 9, 29
   at 11, 49 at 15, 95 at 21.

5. The diamond is a double loop over the odd numbers to `N`, keeping the
   coprime pairs and reducing each into the octave. There is no exponent
   range to choose and no overflow to guard, where `stackRatio`'s chain
   needs both.

6. Restricting the primes is then a filter rather than a second
   generator: the 5-limit at odd limit 15 is the 15-diamond less every
   point with a prime factor above 5, and holds 13 points rather than
   49.

## Choosing the target chooses the theory

1. Score the common chords two ways: with prime 5 admitted, and with
   only prime 3.

   | chord | 5-limit | fifths only |
   |---|---|---|
   | fifth C–G | 1.58 | 1.58 |
   | sus4 C–F–G | 3.17 | 3.17 |
   | major C–E–G | 3.91 | 6.34 |
   | minor C–E♭–G | 3.91 | 6.34 |
   | maj7 C–E–G–B | 3.91 | 7.92 |
   | dom7 C–E–G–B♭ | 7.81 | 9.51 |
   | dim C–E♭–G♭ | 7.81 | 9.51 |
   | **aug C–E–G♯** | **4.64** | **12.68** |
   | septimal C–B♭ | *no reading* | *no reading* |

2. They agree exactly where the music needs only fifths, and their
   orderings agree down the middle.

3. They part at the augmented triad: with prime 5 it is two stacked
   `5/4`s and scores below the dominant seventh; on fifths alone it is
   eight of them and the most remote sonority in the system.

4. A solver told to make sonorities compact will treat that chord as
   ordinary or as a crisis depending on nothing but which target it was
   handed.

5. Which primes a target admits also decides which sonorities exist at
   all. The septimal seventh has an address in neither column; admit
   prime 7 and the same dyad scores 2.81.

## When an adaptive solve exists

1. The notation and the target are two tunings, separately chosen.

2. An adaptive solve exists at all only where the target puts more than
   one point inside the notation's window.

3. Against a 12-EDO notation, the 5-limit offers rivals at
   ±19.6¢ (the diaschisma), ±21.5¢ (the syntonic comma) and ±41.1¢ (the
   diesis); a Pythagorean chain offers one at ±23.5¢.

4. Write in 31-EDO and the window is ±19.4¢, narrower than the syntonic
   comma. The two 5-limit spellings of a note cannot both be candidates,
   and the solve is left with the 3.8¢ a dominant seventh still wants.

5. Snap is the absence of a target rather than a setting of one: every
   note goes to its own step, and with no points there are no coords and
   nothing to score. It never reaches the solver, and is already written
   down and unbuilt in `design/archive/microtuning.md` § Slice 4.

## The model

1. The cost lives on a whole sonority at once rather than on its pairs.

2. Take the sonority current at an onset to be the last `n` distinct
   pitches struck.

3. A block chord and an arpeggio of the same chord then hand the
   objective the same set.

4. *Distinct* carries weight: a plain last-`n` window counts strikes, so
   a repeated note spends a slot the harmony has already paid for.

5. `n` must exceed the arity of the largest sonority to be recognised
   when spread out in time. It must exceed it strictly, or else each
   sonority displaces its predecessor whole and the passage falls apart
   into independent solves.

6. Each note has one detune, chosen once for its whole length.

7. The pull kills comma drift: each note is held near where it was
   written, so the piece cannot drift by syntonic commas the way naïve
   chained-JI does.

8. It also stops the solver collapsing a sonority into a drone, the box
   being globally minimised at zero by putting every note on one pitch.

9. A note in two sonorities has one detune serving both, and takes the
   best compromise they can agree on. That coupling is what makes this
   one global problem rather than a bag of chords.

10. Two notes written on the same step share an anchor and hold one
    entry between them, the later strike replacing the earlier.

11. The objective is evaluated once per onset, over the set current when
    every note struck there has been placed.

## What the solver takes

1. The solver takes notes and returns a choice for each. It knows
   nothing of tempers, targets or ratios; every conversion has happened
   before it is called.

2. A **candidate** is a point placed on the pitch line: absolute cents,
   and the coords of § What "in tune" means.

3. A note arrives as `{ onset, anchor, shortlist }`. The **anchor** is
   the absolute cents of the step it was written on; the **shortlist**
   is the candidates it may take.

4. The anchor does two jobs — what the pull pulls toward, and the
   identity under which a sonority counts distinct pitches
   (§ The model).

5. Beside the notes it takes the sonority size and the pull strength,
   and nothing else.

6. It returns an index per note into that note's shortlist. The command
   reads the chosen candidate's cents and seats them as
   `(pitch, detune)`.

7. Building a shortlist — the target's points, in every octave, that
   fall inside the note's window (§ The window) — is `tuning.lua`'s
   work, and the only place the notation and the target meet.

8. Fixing a note is a shortlist of one, and nothing in the solver
   distinguishes it. A collar note (§ Seams) is that. It still
   contributes its coords to every sonority it joins, and its pull is a
   constant that cannot move the answer.

9. An empty shortlist is asserted against rather than handled. An
   excluded point does not score badly — it does not score, so the solve
   converges, answers confidently, and answers differently under a
   target the author took for a small variation.

10. The hole is not hypothetical. The 5-limit diamond at odd limit 15
    holds no point within 50¢ of the tritone, `45/32` being 590¢ at odd
    limit 45, so against a 12-EDO notation that pitch class has nowhere
    to go.

## Solving it

1. The problem is non-convex and combinatorial with no closed form, and
   still exactly solvable: dynamic programming along the time axis.

2. The sonority is what puts it in reach. Because a sonority is one set
   over all parts rather than a window per part, the state carries the
   chosen tuning of the `n−1` most recently distinct pitches and nothing
   else.

3. It costs `D^(n−1)` states for `D` candidates per note, whatever the
   number of parts sounding.

4. `D` is small. The twenty three-factor products of
   `{1, 3, 5, 7, 9, 11}` put on average 1.7 points inside a 12-EDO
   window and never more than three; the 5-limit diamond at odd limit 15
   never more than two. At three, `n=6` is 243 states and `n=8` is
   2,187.

5. An onset carrying `m` simultaneous notes enumerates `D^m` placements
   against each state, so a wide chord costs more than a wide `n`.

6. Counting distinct pitches (§ The model) is what keeps `n` small
   enough for those counts to stay in reach.

7. The DP is exact, not causal: the passage is solved globally and the
   pull balanced across all of it at once, where a left-to-right chase
   accumulates drift.

8. Beyond a stated budget on the state count an annealer takes over,
   though the measured `D` leaves ordinary material far inside it. It is a
   fallback because its noise does not shrink with the correction it is
   there to compute — the spike disagreed with itself by about 2¢
   between seeds where the whole correction averaged 1.9¢, and a solver
   whose error is half its output is not solving anything.

## Harmonic lock

1. The strength of the pull is the command's only expressive control —
   how far fidelity to the written pitch yields to purity.

2. It is **harmonic lock** on the modal: a field beside the scope, set
   per invocation.

3. The pull is quadratic in the note's deviation from its anchor,
   normalised by the half-width of the window on the side it moved. One
   dial value then means the same thing under any notation.

4. A worked case fixes the scale. Under the 7-limit diamond at odd limit
   9, a written C7 takes the otonal `4:5:6:7` below a pull of 0.97 and
   the Pythagorean `16/9` above it, trading 0.36 of box against 27¢ of
   fidelity.

5. So the dial's useful travel is roughly 0 → 2, and 1 is where the
   commonest trade turns over.

6. At the free end the solve is ambiguous rather than expressive:
   several tunings score alike and the winner is arbitrary rather than
   musical. At the stiff end it is a no-op. The usable band is the
   middle.

7. The pull rather than `n` bounds an edit's blast radius: at a pull
   near 1, changing one note of twenty moved two or three of the others,
   by under 4¢.

## Seams

1. The solve couples notes only where they share a sonority. Two takes
   share none, so nothing holds them to a common answer: each resolves
   the trade between box and pull on its own material, and they can
   resolve it differently.

2. The same written pitch then closes take N at +30¢ and opens take N+1
   at −30¢. Nothing clicks, since no note holds across the boundary, but
   the ear carries pitch memory and hears the note move.

3. Take N is already solved, so its detunes are data. Its tail — the
   **collar** — enters take N+1's solve with a shortlist of one
   (§ What the solver takes): it contributes to the objective, cannot
   move, and pulls the opening notes into agreement with a tuning given
   to them.

4. The collar is not a special provision for boundaries but the coupling
   a boundary removes: notes shared between two solves, exactly as a
   note in two sonorities is shared within one (§ The model).

5. A sweep across takes is therefore order-dependent: solving take N
   invalidates the collar that take N+1 was solved against. In take
   order it is idempotent; out of order it is not.

6. `tracker.reswingTakes` already walks a take list serially, binds each
   in turn and restores the original binding after
   (`trackerPage.lua:135-145`), so the shape exists to borrow.

7. How far the collar reaches is undecided, as is whether a boundary
   should ever *want* a reset — a hard cut between two unrelated
   sections, where an unconstrained solve is correct. Collar by default,
   and make the reset the exception.

## First brick

1. Build the command with snap (§ When an adaptive solve exists) and no
   solver: scope, window, write and undo all get exercised with nothing
   to choose between, and the result is checkable by eye against the
   grid's deviation ticks.

2. Then the objective, as a pure module: the score and the sonority
   walk, hand-worked on a dominant seventh resolving to a tonic,
   confirming the solver picks the otonal `4:5:6:7` and the resolution
   the ear expects.

3. Its shortlists are built from a list of ratios written into the spec
   — the shape a target takes (§ What a target is) — so no target
   mechanism is needed to run it.

4. That test is what fixes the pull's scale (§ Harmonic lock), and it
   ships green before the solve reaches a take.

5. The order matters because the halves fail differently. The command
   half fails visibly — wrong notes move, or undo does not bring them
   back. The objective half fails silently, so its guards
   (§ What the solver takes) live in the pure module where a spec can
   pin them.

6. A target the command can be handed is a third step, and neither of
   the first two waits on it.

7. Of the two ways to author one, the diamond comes first. It is a
   double loop where a combination product set is a subset walk, and it
   is what the objective's spec needs: the twenty three-factor products
   of `{1, 3, 5, 7, 9, 11}` hold no `5/4` at all, their nearest points to
   a major third being 369¢ and 432¢.

## Open

1. Whether the window should ever widen. A fine notation excludes the
   rival spelling outright — 31-EDO's ±19.4¢ against the syntonic
   comma's 21.5¢ (§ When an adaptive solve exists) — so there is almost
   nothing to choose between. Whether that is a limit to accept or a
   case for letting the note rename is undecided.

2. Where the trade at a chord change sits. A sonority straddling one
   holds notes from two chords and asks them to be compact together.
   Large `n` buys coupling and costs this, and `n` one above the arity
   is the smallest that buys any; the other bound on `n` is the state
   count (§ Solving it).

3. Whether a sonority holds pitches or pitch classes. The octave
   quotient gives `C4` and `C5` the same coords, so they should be one
   entry — but they remain two variables, and nothing in the objective
   stops them drifting apart.

4. Whether the pull wants a shape. A flat window with a quadratic pull
   was enough to make the spike stable; whether a well — soft near the
   centre, stiff at the edge — buys anything is unmeasured.

5. What the command does with a note whose shortlist is empty. Refusing
   the solve and naming the step is loud where passing the note through
   unmoved is quiet, and a target with a hole in it is common enough
   that refusal may be too blunt (§ What the solver takes).

6. Whether to offer a strength dial — retuning the selection *half way*
   toward the target. It is not the pull restated: the pull always
   lands on a target point, where a blend lands between two. It would
   be a post-pass on the solved displacement, idempotent for the same
   reason the solve is (§ The window) — re-derive the target from the
   recovered step, and α applied twice is α rather than `1−(1−α)²`. It
   waits on there being off-grid material to soften: capture snaps to
   the active temper (`design/midi-capture.md`), an import arrives on
   its source's grid, and this command's own output is the only
   off-grid material Continuum makes.

7. Where the key belongs. A root says where a scale sits in sound;
   which of a target's points the material meets is a further question,
   and nothing answers it yet. Root state showed the tier an answer
   could sit on: the library holds a scale and a project holds a scale
   placed (`docs/tuning.md` § The root), so a key would be one more
   project-tier field beside the four, and a second key a second project
   copy the temper editor forks — not the library copy per key that made
   the question look expensive. Whether it is a temper field at all, or a
   slot on the command beside the target, is what stays open.
