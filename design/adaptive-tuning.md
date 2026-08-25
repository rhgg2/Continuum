# Design — Adaptive tuning

> opened: 2026-07-04 · status: in flight — plan/adaptive-tuning.md, before
> phase 5 (seams) with phases 1–4 landed; the solver's boundary settled

**Solve a selection in one pass for a single detune per note that
makes its sounding sonorities as harmonious as they can jointly be
with respect to a chosen set of ratios, anchored so no note leaves the
step it was written on.**

## Where it sits

1. This is an edit command over a selection, one undo block, writing
   `(pitch, detune)` through `edit.assign`.

2. The solve selects rather than adjusts: each note lands on exactly
   one point of the target (§ What a target is), never between two.

3. The conventions it needs exist: `eventsByCol` and `allGroups` for the
   note set, and `modalHost:registerKind` for a modal carrying the slots
   (`trackerRender.lua:753-809`). The undo label goes on the modal's
   callback, through `util.atomic`: the command body only opens the modal,
   and the edit lands frames later.

4. The modal's slots reach the verb it calls as one table, unread by the
   modal itself (§ The command's slots).

5. Behind the command is a pure function, strands in and a choice per
   strand out (§ The strand). Points and their placement belong to
   `tuning.lua`, since the solver carries no tuning vocabulary. The
   solver's module also groups notes into strands. The command carries
   each note's class between the two, and asks `tuning.lua` for each
   strand's shortlist.

6. Detune is not realised beyond lane-1 notes; that is the author's
   problem, not the function's.

7. The target and the key are config keys of their own, written at take
   tier as the command runs, so the modal opens on the answers the take
   already carries.

8. One command opens one modal, and every retuning facility the tracker
   offers is reached through it — this one, and the adaptive just
   intonation the moves facility offers (`docs/sonority.md`). Scope and
   strength are common to all of them; the remaining slots belong to the
   facility chosen.

## The command's slots

1. Scope — which notes.

2. Notation — the active temper. It supplies the names, the step each
   note is anchored to, and the window inside which the note keeps that
   name (§ The window).

3. Target — the temper whose points a note may be moved to
   (§ What a target is).

4. Key — the notation step the target's `1/1` sits on
   (§ What a target is).

5. Sonority size — `n`, set above the arity of the largest chord to be
   recognised when spread out in time (§ The model).

6. Harmonic lock — how hard the written pitch pulls back
   (§ Harmonic lock).

7. Boundary — how far the collar reaches (§ Seams).

8. Strength — how far toward the answer the notes actually move
   (§ Strength).

9. Target and key persist per take (§ Where it sits). Sonority size and
   harmonic lock open at 5 and 1 every time, being read off the passage
   rather than off the take.

10. Under no target the command is the snap, and the slots the adaptive
    facility owns — key, sonority size, harmonic lock — are drawn
    disabled rather than hidden, so the modal keeps one shape.

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
   selection, together with a **pull** toward where the notes were
   written (§ The model).

8. A small box is a sonority whose notes share a strong virtual
   fundamental, so the score measures root fusion — Terhardt's
   virtual-pitch theory.

## The window

1. A note's **window** reaches half way to the notation's adjacent step
   on either side.

2. An unequal scale gives an asymmetric window: in a twelve-note
   quarter-comma meantone MOS, C may move +38.0¢ toward C♯ and −58.6¢
   toward B.

3. Inside it a note keeps its step. `tuning.noteStep` recovers the
   scale step from `(pitch, detune)` by snapping to the nearest
   (`tuning.lua:629`), so the tracker cell keeps the name it was
   written under; move a note further and the snap names a different
   step.

4. That recovery is the points solve's alone. A note may carry the step
   it was written on instead — `intentCents`, which a solve stamps and
   `tuning.noteStep` reads before it snaps anything (`docs/tuning.md`
   § The written step) — and the moves solve, which places notes past
   their windows, rests on it.

5. The pull is toward the step the note was written on rather than the
   note's current cents, which makes the operation idempotent at full
   strength (§ Strength).

6. The edge itself is no place to stand. A note exactly a half-gap out is
   equidistant from two steps, so the one it was written on is no longer
   readable off its cents: `midiToStep` breaks the tie downward, and the
   cell relabels as surely as if the note had moved further.
   `tuning.seatWindow` therefore stops each half a hair inside the edge —
   a ten-thousandth of a cent — and the shortlist's strain is measured
   off those halves.

7. Standing a strand there was reachable in ordinary use. Under a set
   holding `5/4` and `3/2` alone, an E♭–E–G spells its minor third as a
   stretched `5/4` and pins a strand to the edge to reach it; before the
   hair, a second run read that strand on its neighbour's step, solved a
   different chord, and left the two notes as one.

8. The window is spent before the solve, in building a strand's
   shortlist (§ What the solver takes). `tuning.stepWindow` returns both
   halves, and the shortlist is their only reader now: the grid reports a
   note's gap in cents rather than as a fraction of its window
   (`docs/tuning.md` § Display).

9. In 12-EDO the window never binds the points solve. Widening it to two and then four
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
   the target is chosen rather than when the solve runs. The picker
   offers the library's eligible tempers and no others, so a target the
   objective cannot score is never chosen.

4. No new mechanism authors a target. `tuning.genCPS`,
   `tuning.genHarmonics`, `tuning.genChord` and the rational case of
   `tuning.genRank2` already emit ratio tokens, and the temper editor
   already drives all four (`temperEditor.lua:667-713`).

5. Two generators bound a target by a measure of its intervals rather
   than by a count: the diamond (§ The diamond) and the Tenney ball
   (§ The Tenney ball).

6. The role reads a temper's `pitches` and nothing more. Step names,
   octave numbering and cell width are the notation's business, and a
   target is never displayed.

7. A target's own root therefore has no force. It is a list of
   intervals, and where the `1/1` sits in sound is determined by the
   key slot (§ The command's slots).

8. A target's period has no force either, since the octave is
   quotiented out of the score.

9. The key is stated as a step of the notation, and held as that step's
   index. A notation carrying fewer steps than the one the key was
   chosen under clamps it rather than raising.

10. Every temper holds the `1/1` on its first step, so the key's own
    step keeps a candidate at strain zero where it was written. The
    tonic does not move, at any strength.

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

7. What a diamond costs is therefore the points that survive the filter,
   not the odd limit that admits them: at odd limit 31 the 5-limit
   diamond holds 25 points where the unfiltered one holds 213. A hundred
   points put ten rivals in the widest 12-EDO window, which at sonority
   size 6 is 100,000 placements — half the budget of § Solving it, and
   past it at 7. So a hundred is where authoring one stops, and the
   21-odd-limit diamond, at 95, is the largest that fits.

## The Tenney ball

1. A target may instead be bounded by **octave-free Tenney height** —
   Σ |exponent| × log₂ p over the odd primes of a ratio — holding every
   interval its **generating intervals** compose to within that bound.
   `3/2` and `5/4` under a bound of 3.91 give eleven points: `1/1
   16/15 9/8 6/5 5/4 4/3 3/2 8/5 5/3 16/9 15/8`.

2. The bound is written as a ratio rather than as a figure, that ratio
   being the most complex interval admitted. `15/8` states 3.91, and an
   author reading it back hears a major seventh where the figure would
   have shown a logarithm.

3. Height is what a chain spends where odd limit is what a point costs.
   Two `5/4`s make `25/16` at height 4.64, so a bound of `25/16` admits
   it and a bound of `15/8` does not; odd limit reads `25/16` as 25
   however many moves arrived there (`docs/tuning.md` § A temper read as
   moves).

4. A ball is closed under composition and a diamond is not, so the two
   disagree at equal size: at thirteen points the 5-limit 15-diamond
   holds `10/9` and `9/5`, and the ball at `25/16` holds `25/16` and
   `32/25` in their place.

5. The generators are intervals rather than odd numbers, so a ball may
   sit on a sublattice. `3/2` alone gives the Pythagorean chain, eleven
   points out to `243/128`; `9/8` with `5/4` gives eleven over the even
   powers of 3. Neither is a diamond of any limit.

6. The points are the lattice the generators span, cut by the bound, rather than what a
   walk out from the unison reaches without leaving it. Under `5/4 5/3
   21/16` bounded at `7/5`, three fifths compose to `27/16` at height
   4.76, and every path there passes through a point above the bound; so
   the enumeration runs over a basis of the generators in echelon form,
   taking each coefficient's range from the height its pivot column has
   left to spend.

7. Points grow gently with the bound — eleven at `15/8`, thirteen at
   `25/16`, nineteen at `45/32`, twenty-seven at `125/64` — so the
   hundred-point ceiling of § The diamond binds here too, and binds
   late.

8. The ball is what the springs solve asks of a target, that solve
   joining two strands by one move and declining to invent an
   intermediate (`design/archive/adaptive-springs.md` § The candidates). The
   target therefore states the reach, and widening it is how an author
   buys a spelling the set does not already name.

## Choosing the target chooses the theory

1. Score the common chords two ways: with prime 5 admitted, and with
   only prime 3.

   | chord | 5-limit spelling | 5-limit | fifths only |
   |---|---|---|---|
   | fifth C–G | 1/1 3/2 | 1.58 | 1.58 |
   | sus4 C–F–G | 1/1 4/3 3/2 | 3.17 | 3.17 |
   | major C–E–G | 1/1 5/4 3/2 | 3.91 | 6.34 |
   | minor C–E♭–G | 1/1 6/5 3/2 | 3.91 | 6.34 |
   | maj7 C–E–G–B | 1/1 5/4 3/2 15/8 | 3.91 | 7.92 |
   | dom7 C–E–G–B♭ | 1/1 5/4 3/2 9/5 | 7.81 | 9.51 |
   | dim C–E♭–G♭ | 1/1 6/5 36/25 | 7.81 | 9.51 |
   | **aug C–E–G♯** | **1/1 5/4 25/16** | **4.64** | **12.68** |
   | septimal C–B♭ | — | *no reading* | *no reading* |

2. The spellings are the notation's. Where the target offers a more
   compact reading, the solver takes it, and the two rows at 7.81 both
   fall to 7.08 — the dom7 at `16/9`, the dim at `64/45`. Every other
   row already takes the most compact 5-limit reading.

3. They agree exactly where the music needs only fifths, and their
   orderings agree down the middle.

4. They part at the augmented triad: with prime 5 it is two stacked
   `5/4`s and scores below the dominant seventh; on fifths alone it is
   eight of them and the most remote sonority in the system.

5. A solver told to make sonorities compact will treat that chord as
   ordinary or as a crisis depending on nothing but which target it was
   handed.

6. Which primes a target admits also decides which sonorities exist at
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

2. A **step-class** is a step of the notation together with every step an
   exact octave from it, recovered from a note's written seat reduced into
   the octave (§ The window). Take the sonority current at an onset to be
   the last `n` distinct step-classes struck, together with every class
   still sounding.

3. The score quotients out the octave (§ What "in tune" means), so a
   step-class's members carry one set of coords between them.

4. A block chord and an arpeggio of the same chord hand the objective
   the same set, as do a chord and the same chord doubled at the octave.

5. *Distinct* carries weight: counting strikes instead would spend an
   entry, on a repeated note, that the harmony has already paid for.

6. The sonority forgets only what has fallen silent. A note held through
   the chords behind it leaves the last `n` struck while it is still
   sounding, and what strikes after it would then be tuned without
   reference to it.

7. The coupling usually survives that on its own, each note being tuned
   against its predecessors and so, at one remove, against the note
   still held.

8. What breaks the chain is a run of classes the target fixes outright,
   which a sparse target makes ordinary: the 5-limit diamond at odd
   limit 15 fixes nine of twelve classes, and behind a run of five such
   the answer moves by a syntonic comma about one time in seven.

9. A note released where the next is struck does not sound there, so a
   passage whose notes stop as the next begin reads as the last `n`
   struck alone.

10. `n` must exceed the arity of the largest sonority to be recognised
    when spread out in time. It must exceed it strictly, or else each
    sonority displaces its predecessor whole and the passage falls apart
    into independent solves.

11. Each note has one detune, chosen once for its whole length.

12. The pull kills comma drift: each note is held near where it was
    written, so the piece cannot drift by syntonic commas the way naïve
    chained-JI does.

13. It also stops the solver collapsing a sonority into a drone, the box
    being globally minimised at zero by putting every note on one pitch.

14. A note in two sonorities has one detune serving both, and takes the
    best compromise they can agree on. That coupling is what makes this
    one global problem rather than a bag of chords.

15. The compromise can overturn a chord's own preference. A C7
    sounding alone takes the otonal `4:5:6:7` (§ Harmonic lock); when
    resolving to F–A–C it takes the Pythagorean `16/9` under any pull,
    the resolution saving 1.22 of box against the 0.36 the seventh
    chord pays for it. The global solve imposes a kind of harmonic
    utilitarianism.

16. The objective is evaluated once per onset, over the set current when
    every note struck there has been placed.

17. Where classes strike together the lowest counts as the most recent.
    A chord released as the next strikes, at `n` one above the arity,
    leaves one class to the sonority that follows, and that class is its
    bass — in root position, its root.

18. A compromise across a chord change therefore wants `n` to reach the
    classes the two chords hold between them, six where a C7 resolves to
    F–A–C. At one above the C7's own arity the resolution reads its bass
    alone, scores the same under either seventh, and the chord is
    sounding alone after all.

## The strand

1. The notes of a step-class that overlap in time are a **strand**. They
   hold one tuning between them.

2. The constraint is acoustic where the sonority is harmonic. Two notes
   of a step-class sounding at once at different tunings beat, whatever
   the sonority remembers.

3. A note that overlaps nothing else in its class starts a new strand,
   which retunes freely: one step takes one tuning under the ii and
   another under the V.

4. A note released where the next is struck does not overlap it, the
   release being half-open as the sonority reads it (§ The model).

5. The release a strand reads is the one the note sounds to — its
   render clip — rather than the authored ceiling the editor holds. A
   note typed with no OFF carries no ceiling at all until one is
   written, and the tracker clips it to the next onset in its lane.

6. Reading the ceiling instead makes an open note sound for ever. The
   step-class returning after it merges into its strand rather than
   starting one, every later sonority holds it, and every later onset
   lets it wait; the springs walk costs exponentially in what may wait
   (`design/archive/adaptive-springs.md` § The solve), so a two-bar take that
   answers in a third of a second answers in minutes.

7. A note held across a chord change therefore bends the harmony to it
   rather than the reverse. Under a 5-limit target, at `n` one above the
   arity, a D held from D–F–A into G–B♭–D keeps the 10/9 the first chord
   gives it. Restruck it would take the 9/8 the second chord prefers, so
   the hold costs that chord 0.737 of box.

8. The strand is what earns the collapse to step-classes: an entry
   carries one tuning at a time only because every note that could write
   it agrees.

## What the solver takes

1. The solver takes strands and returns a choice for each. It knows
   nothing of tempers, targets or ratios; every conversion has happened
   before it is called.

2. The solver's pitch line is reduced into the octave, the score being
   unable to tell a point from the same point an octave away
   (§ What a target is). A strand's notes may sit in several registers,
   and one reading serves them all.

3. A **candidate** is a point placed on that line, carrying its cents
   and the coords of § What "in tune" means. The cents are the point's
   own position on the line, not an offset from a note: a strand's notes
   may sit on different steps, and no offset then serves them all. It
   carries its **strain**
   too: its distance from the step the strand was written on, as a
   fraction of the half-width of that step's window on the side it lies
   on (§ The window).

4. A strand arrives as `{ notes, class, shortlist }`. The **notes** are
   the note events themselves, each carrying when it is struck and when
   it is released; the **class** is the step-class they share; the
   **shortlist** is the candidates the strand may take.

5. The solver reads a note's strike and its release, and nothing else
   on it. The strike orders the walk, the release says what is still
   sounding (§ The model), and the note itself is what the command
   seats the answer on, so one shape serves all three and no parallel
   structure maps a strand back to its notes.

6. The pull reads strain, so the solver never interprets a cents value.
   The class is the identity under which a sonority counts distinct
   entries (§ The model), so two strands of one class are one entry in
   turn rather than two at once.

7. Beside the strands it takes the sonority size and the pull strength,
   and nothing else.

8. It returns an index per strand into that strand's shortlist. The
   command reads the chosen candidate's cents and seats them as
   `(pitch, detune)` on every note of the strand, each in its own
   register.

9. Building a strand's shortlist — the target's points that fall inside
   the window of the step it was written on (§ The window) — is
   `tuning.lua`'s work, and the only place the notation and the target
   meet. Strain is computed in the same pass, the window's half-widths
   being at hand there and nowhere else. Seating a chosen point back in
   the register of a note that takes it is the same fold in reverse, so
   it lives beside it.

10. One window serves the whole strand. Its notes stand exact octaves
    apart on one step of the notation, so the window folds onto itself in
    every register and one of them answers for all.

11. Where the notation's period is not the octave, no step usually stands
    an exact octave from another, and a strand gathers unisons only. A
    step a near-octave away — Bohlen-Pierce's ninth, 29.6¢ shy of it — is
    a class of its own.

12. Fixing a strand is a shortlist of one, and nothing in the solver
    distinguishes it. The collar (§ Seams) arrives as strands of one.
    Each still contributes its coords to every sonority it joins, and
    its pull is a constant that cannot move the answer.

13. An empty shortlist is asserted against rather than handled. An
    excluded strand does not score badly — it does not score, so the
    solve converges, answers confidently, and answers differently under a
    target the author took for a small variation.

14. The hole is not hypothetical. The 5-limit diamond at odd limit 15
    holds no point within 50¢ of the tritone, `45/32` being 590¢ at odd
    limit 45, so against a 12-EDO notation that step-class has nowhere
    to go.

15. The command refuses the solve whole, writing nothing and answering
    with every step that has nowhere to go.

16. The offer against that refusal is to **widen**: the class's window
    is scaled, both halves by the smallest factor that brings a point
    inside it, and the solve run again. A point past the half-way mark
    relabels the cell (§ The window), so widening is the solver editing
    the score rather than tuning it, and is offered rather than taken.

17. Every point that factor admits comes with it. A hole usually admits
    two: a diamond is closed under inversion, so its points stand
    symmetrically about the tritone, and `4/3` and `3/2` lie 101.955¢
    either side of a 12-EDO one.

18. Which of them the class takes is the objective's answer, and the
    sonority around it decides: against `1/1 5/3` the tritone takes
    `4/3`, and against `1/1 9/8` it takes `3/2`.

19. Those two distances agree to thirteen places, so the admitting test
    carries a tolerance. Without one the tie breaks on the last bit of a
    logarithm, and the class renames itself by arithmetic noise.

20. A widened candidate's strain runs past 1, the window it measures
    being one the note stands outside. It is equal across the admitted
    set, so the pull it charges is a constant and cannot move the
    answer.

21. Only a class that refused widens. One with a point already in reach
    keeps its window, so the offer moves the solve where it had no
    answer and nowhere else.

## Solving it

1. The problem is non-convex and combinatorial with no closed form, and
   still exactly solvable: dynamic programming along the time axis.

2. The sonority is what puts it in reach. Because a sonority is one set
   over all parts rather than a window per part, the state is one chosen
   tuning per live strand.

3. A strand is **live** on any of three counts. It stands among the
   `n−1` most recently distinct step-classes; or it is still sounding;
   or it has yet to strike again, and must keep the tuning its first
   strike chose until it does. The last two are bounded by the
   polyphony rather than by `n`.

4. The walk does not depend on the choices, so when a strand is chosen
   and how long it stays live are read off it before any enumeration
   begins.

5. Where no strand outlives the last `n` classes it costs `D^(n−1)`
   states for `D` candidates per step-class, whatever the number of
   parts sounding.

6. `D` is small. The twenty three-factor products of
   `{1, 3, 5, 7, 9, 11}` put on average 1.7 points inside a 12-EDO
   window and never more than three; the 5-limit diamond at odd limit 15
   never more than two. At three, `n=6` is 243 states and `n=8` is
   2,187.

7. Live strands are distinct step-classes, so the count cannot exceed
   the product of `D` over the classes a passage uses, which neither
   `n` nor the polyphony enters. Diatonic material against the 7-limit
   diamond at odd limit 15 ceilings at 36 states, and eight voices with
   every note held reach exactly that.

8. Collapsing the octave is what holds the count down where a chord is
   doubled. A four-voice chord doubled at two of its notes holds four
   step-classes rather than six, so `n` stays at five rather than
   climbing to seven, and at three candidates the count is 81 states
   rather than 729.

9. An onset carrying `m` simultaneous strands enumerates `D^m`
   placements against each state. A note added to a chord widens `m` and
   forces `n` up with it (§ The model), so it costs a factor of `D` more
   than a note added to `n` alone.

10. The DP is exact, not causal: the passage is solved globally and the
    pull balanced across all of it at once, where a left-to-right chase
    accumulates drift.

11. The budget is 200,000 placements at an onset: the states carried
    into it times the candidates of the strands born there. Reading it
    off the walk refuses an impossible solve rather than beginning one,
    and counts a chord wider than `n`, whose strands leave the sonority
    at once and so leave no state behind them.

12. Beyond it an annealer takes over, though the measured `D` leaves
    ordinary material far inside it. It is a fallback because its noise
    does not shrink with the correction it is there to compute — the
    spike disagreed with itself by about 2¢ between seeds where the whole
    correction averaged 1.9¢, and a solver whose error is half its output
    is not solving anything.

## Harmonic lock

1. The pull's strength is what trades fidelity to the written pitch
   against purity.

2. It is **harmonic lock** on the modal: a field beside the scope, set
   per invocation.

3. The pull is quadratic in the strain of the candidate a strand takes
   (§ What the solver takes). One dial value then means the same thing
   under any notation.

4. It is counted once per strand rather than once per note, which is
   what makes an octave doubling change no answer at all. The box
   already charges a doubling nothing (§ The model); counted per note
   the pull would charge it twice, halving the strength at which a
   written C7's doubled seventh gives up its otonal tuning.

5. A worked case fixes the scale. Under the 7-limit diamond at odd limit
   9, a written C7 sounding alone takes the otonal `4:5:6:7` below a pull
   of 0.95 and the Pythagorean `16/9` above it, trading 0.36 of box
   against 27¢ of fidelity.

6. So the dial's useful travel is roughly 0 → 2, and 1 is where the
   commonest trade turns over.

7. At the free end the solve is ambiguous rather than expressive:
   several tunings score alike and the winner is arbitrary rather than
   musical. At the stiff end it is a no-op. The usable band is the
   middle.

8. The pull rather than `n` bounds an edit's blast radius: at a pull
   near 1, changing one note of twenty moved two or three of the others,
   by under 4¢.

## Strength

1. **Strength** is how far toward the answer a note actually moves: the
   detune the note carries is interpolated with the one the command
   computed, and α of the way is where it lands.

2. It is a post-pass on the displacement rather than a term in the
   objective. The solve always lands on a target point (§ What a target
   is); a blend lands between two, which is a position no target holds and
   no solve would choose.

3. It is uniform over the facilities the command offers, reading only the
   displacement each one computed. Snap is the trivial case: at full
   strength every note reaches its step, and at half it closes half the
   distance to it.

4. A blend sits between two steps, so nothing seats the pair for it. The
   blended cents are re-seated on the nearest semitone, and what remains
   is written as detune.

5. Interpolating from the carried detune breaks idempotence deliberately.
   A note taken half way is taken half way again on the next invocation.

6. At full strength the operation is idempotent as before, the answer
   depending on the recovered step alone (§ The window). The computed pair
   stands as it is, so `stepToMidi`'s fold of a step past MIDI 127 into
   detune survives the blend.

7. At zero strength the command returns before touching anything.
   Re-seating would otherwise rewrite a note carrying more than half a
   semitone of authored detune, `(72, +70)` as `(73, −30)`, for an
   invocation asked to move nothing.

8. The idempotent blend is a composition of two invocations rather than a
   second dial: snap at full strength, then solve at α. The snap puts the
   note on its step, so the detune the solve interpolates from is the
   anchor.

9. There is no shortage of material for it. Switching temper relabels
   rather than moves, so a take authored under one notation reads wholly
   off the grid of the next.

10. The dial opens at full strength on every invocation. Nothing carries
    it between them.

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
   walk, hand-worked on a dominant seventh sounding alone, confirming
   the solver picks the otonal `4:5:6:7` and gives it up where
   § Harmonic lock says it does.

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

1. Whether a window already holding a point should ever widen. A hole
   widens on offer (§ What the solver takes), but a fine notation
   excludes the rival spelling outright — 31-EDO's ±19.4¢ against the
   syntonic comma's 21.5¢ (§ When an adaptive solve exists) — and there
   is then almost nothing to choose between. Whether that is a limit to
   accept or a case for letting the note rename is undecided.

2. Where the trade at a chord change sits. A sonority straddling one
   holds notes from two chords and asks them to be compact together.
   Large `n` buys coupling and costs this, and `n` one above the arity
   is the smallest that buys any; the other bound on `n` is the state
   count (§ Solving it).

3. Whether retention should follow the placement. The member nearest
   the centroid of the box is the root wherever the chord is otonal and
   the mirror of it wherever the chord is utonal: a minor triad is an
   inverted major, so the rule that picks a major triad's `1/1` picks a
   minor triad's `3/2`. Which member that is depends on the candidate
   the solve has yet to choose, so the choice would move into the DP and
   the state carry a class set per placement. Whether the survivor moves
   an answer at all is measurable once the DP exists.

4. Whether the pull wants a shape. A flat window with a quadratic pull
   was enough to make the spike stable; whether a well — soft near the
   centre, stiff at the edge — buys anything is unmeasured.

5. How a moves solve sees the take before it. The points solve's collar
   is a strand of one with its tuning already chosen (§ Seams), and a
   moves solve can pin a collar strand at the displacement the take
   stores; what no take stores is the spelling that put it there
   (`docs/sonority.md` § The model), so the collar is spelled afresh
   against the sonority it joins and may not be spelled as it was
   solved. Either a note carries its coords as metadata, or one solve
   spans the takes in sequence and carries the spelling across. The
   ambient rest sharpens it: a take's first onset asserts the page and
   every later strand rests on the drift the passage has reached
   (`docs/sonority.md` § The solve), so a passage spanning two takes has
   two anchors where the music has one.

6. Whether the command should go on offering both anchors. The points
   facility holds a note near the step it was written on and the moves
   facility prices it against the music it arrived in, so one command
   offers two instruments (§ Where it sits). Harmonic lock sharpens the
   question: one dial serves both, charging cents from a rest under
   moves and half-windows from a seat under points (`docs/sonority.md`
   § The pull), so the same number means two things wherever the
   notation's steps are not a hundred cents apart.

7. Where a score follows the page. A retune re-seats notes onto a
   target notation, so it is the gesture at which the page moves the
   score. A generator's pitch demand is stored in cents and a lens
   change no longer re-reads it (`docs/generators.md` § The ctx
   discipline); re-reading a demand at a retune, as the ladder it was
   typed on, would instead carry a trill's whole tone through a
   notation change. Whether it should is undecided.

