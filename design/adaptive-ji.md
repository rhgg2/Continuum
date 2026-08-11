# Design — Adaptive just intonation

> opened: 2026-08-11 · status: working design — the candidate model
> measured, the solver's boundary unsettled; unstarted

**Tune a selection so that the notes of each sonority are joined by pure
intervals from a stated set, letting those intervals compose into
harmonies no scale holds, anchored so no note leaves the step it was
written on.**

## Where it sits

1. This is the command of `design/adaptive-tuning.md` with one part
   exchanged: the candidate model, what the solve may choose from.
   Everything else that document settles is cited here rather than
   restated, and where the exchange breaks something the section that
   breaks it says so.

2. There a note lands on a point of a chosen scale, so the tunings
   available to a passage are that scale's points and nothing else.

3. That ceiling is what this document is opened against. A solve that
   only ever seats notes on a scale's points produces what an author
   could have produced by switching to the scale and typing.

4. Neither document supersedes the other. They are alternatives an
   author chooses between, and which one a passage wants is a question
   about the music.

## The target becomes a move set

1. The target is a **move set**: a collection of **moves**, each an
   interval that may be sounded pure between two notes of a sonority.

2. The **reachable set** is every tuning a chain of moves arrives at
   from a given note. It is larger than the move set, since a chain of
   two moves leaves the set they were drawn from.

## A placement is a tree

1. A **placement** is a tree over the passage: its vertices are the
   notes, and each edge carries the move that reaches its child from
   its parent. The **root** is the vertex with no parent, and is the
   only note no move reaches.

2. A note's **candidates** are the tunings available to it. They are
   not a property of the note: every one of them is a tuning a move
   reaches from another note of the sonority.

3. The tree's shape decides what can be spelled. Under a move set
   holding `5/4` and `3/2` but not `6/5`, a C minor triad has no
   placement in which E♭ hangs off C, since that edge would be a `6/5`;
   it has one in which E♭ hangs off G, arriving a `5/4` below it and so
   a `6/5` above the C.

4. A move the set does not hold is therefore still available between two
   notes, provided a third note stands between them in the tree.

## Coords accumulate along it

1. A note's coords — the exponents of the odd primes in a ratio
   (`design/adaptive-tuning.md` § What "in tune" means) — are its
   parent's plus its move's, and the root's are zero. The tree fixes
   them.

2. The score sums the span of the coords on each axis, each weighted by
   `log₂ p` (`design/adaptive-tuning.md` § What "in tune" means). A span
   is unchanged by adding a constant to every coord, so the choice of
   root does not enter it.

3. The objective is reusable without amendment.

4. Two paths to the same note would fix its coords twice. They agree
   only where the moves around the loop multiply to unity. Where they
   do not, the difference is a **comma**, and the two paths are two
   pitches rather than one.

5. A placement is a tree rather than a graph for that reason. A cycle is
   either redundant or contradictory, and there is no third case.

## What composition reaches

1. Two moves reach what neither reaches alone. A major third above a
   major third is `25/16`, a tuning of the augmented triad's fifth, and
   no diamond up to odd limit 21 holds it.

2. A scale holding the same ratio cannot reach it. `5/4` is one of the
   15-odd-limit diamond's forty-nine points and `25/16` is not. The
   closest the diamond comes is `14/9`, 7.7¢ away and built from
   different primes.

3. The augmented triad is the sibling document's own case for a target
   choosing a theory (`design/adaptive-tuning.md` § Choosing the target
   chooses the theory).

4. The reachable set grows with the length of a passage rather than the
   size of a target. Five moves reach more than forty-nine points
   because they compose and the points do not.

5. What this costs is the grid. A passage tuned by composition lies on
   no one scale, so there is no temper an author can switch to and see
   every note on a step.

## What makes the candidate set finite

1. The reachable set is dense. Chains of moves fall arbitrarily close
   to any pitch, so reachability alone admits everything and decides
   nothing.

2. Complexity bounds the move set, and that is what makes a note's
   candidates finite. Each candidate is one move from a note already
   placed, so a note has the move set's size times the notes placed
   before it.

3. The window is the notation's, reaching half way to the adjacent step
   on either side (`design/adaptive-tuning.md` § The window). It bounds
   where a note may go and says nothing about how it got there: what it
   adds is a smaller count and a note that keeps its step.

4. Complexity is bounded by **octave-free Tenney height**: the base-2
   logarithm of the product of the odd parts of a move's two terms.
   `5/4` and `8/5` are one move and its inversion, and both read 2.32.
   A move set's **complexity bound** is the largest height it holds.

5. The bound does not fix the primes. Every figure here is measured over
   a move set holding all of 3, 5 and 7 under a stated bound, and prime
   11 would displace them: `11/8` reads 3.46 and sounds a tritone as one
   move, where nothing on 3, 5 and 7 sounds one under 3.91.

6. That measure is the objective's own. A sonority's score (§ Coords
   accumulate along it) is the Tenney height of its octave-free
   `lcm/gcd`, so one measure bounds what may be admitted and scores what
   results.

7. Odd limit is the wrong bound here, though it is the right one for a
   scale. It does not add along a chain: two `5/4`s are odd limit 5
   apiece and `25/16` is odd limit 25, where the Tenney heights are
   2.32 apiece and 4.64 together, which is exactly `25/16`'s.

## Where a move set comes from

1. A temper whose pitches are ratios is a move set already, read as
   intervals from its unison rather than as points.

2. Nothing new authors one. The generators that emit ratio tokens and
   the temper editor that drives them are the sibling document's account
   of authoring a target (`design/adaptive-tuning.md` § What a target
   is), and they serve here unchanged.

3. Partch's diamond is a table of intervals from a `1/1`, so taking it
   as a move set is closer to what it is than taking it as a scale.

4. The temper's own root does not enter. A move set has no place on the
   pitch line, so `rootCents` is never read and the question of where a
   key belongs (`design/temper-root.md` § Open) does not arise.

5. A temper holding a pitch in cents or in equal divisions cannot be a
   move set, for the reason `design/adaptive-tuning.md` § What a target
   is gives: the token carries no ratio, so there are no coords to
   accumulate.

## What it costs to solve

1. The DP's shape survives. Its state is the chosen tuning of the `n−1`
   most recently distinct pitches, for a sonority of `n`, counted
   distinct by the step a note was written on rather than the tuning it
   took
   (`design/adaptive-tuning.md` § The model).

2. Its count is one entry for each way of choosing a candidate for
   every one of those pitches (`design/adaptive-tuning.md` § Solving
   it).

3. What the state holds changes. A candidate carries its coords along
   with its tuning, where the sibling's was an index into a shortlist.

4. An onset chooses tunings only for the notes struck there; those the
   state holds are already fixed. Each must attach by a move to a note
   already placed, whether from the state or from the same onset, so
   the choices are not independent as the sibling's were.

5. Only a narrow range of complexity bounds is usable: between about 2.8
   and 3.3, admitting seven to nine moves. Below it a dominant seventh
   standing alone is spelled only by running a note to 49¢ of a 50¢
   window; in a ii–V–I the same chord solves inside 27¢. Above it the
   state count runs away, reaching 59,049 at 4.0.

6. Inside that range the state count is thirteen to thirty-two times the
   sibling's. Measured against a 12-EDO notation over a ii–V–I and a
   comma pump, candidates average 2.4 a note at the lower bound and 3.1
   at the upper, with maxima of five and six where the sibling's fixed
   model reaches three.

7. The absolute numbers stay small. Six candidates over a sonority of
   six is 7,776 states, where the sibling's own reckoning puts three
   candidates over a sonority of eight at 2,187
   (`design/adaptive-tuning.md` § Solving it).

## What the solver loses

1. The sibling's solver takes notes carrying shortlists and knows
   nothing of tempers, targets or ratios
   (`design/adaptive-tuning.md` § What the solver takes). That boundary
   does not survive.

2. A shortlist cannot be built before the solve, because a note's
   candidates depend on where the other notes went. The conversion from
   ratios to pitches happens inside the search rather than ahead of it.

3. So the search carries the move set and computes coords as it goes,
   and is not a pure function over anonymous candidates.

4. This is the largest cost the model incurs. The sibling's spec can
   hand its solver shortlists written straight into the test
   (`design/adaptive-tuning.md` § First brick); here the move set and
   the coord arithmetic are inside the search, and there is nothing
   smaller to pin.

## Drift

1. Drift is what the model produces when nothing resists it. Coords
   accumulate along the tree, so a note's tuning follows the chain that
   reached it rather than the pitch class it belongs to.

2. A comma pump is the case that tests it: a progression whose moves
   multiply to a comma returns to its opening step at a different
   tuning.

3. Drift cannot accumulate without bound, because the window bounds
   every note against the step it was written on. A passage returning
   repeatedly to a pitch class is held inside that note's window every
   time.

4. What the pull decides is where inside the window the trade lands, and
   its scale is the sibling's (`design/adaptive-tuning.md` § Harmonic
   lock).

## When a chord is misspelled

1. A chord can be seated by moves that spell a different chord. Nothing
   in the model reads the notated intervals: a tree is admissible when
   every note lands inside its window, however far its moves depart from
   what was written.

2. The objective prefers the respelling. A written diminished triad
   read as 4:5:7 on its middle note scores 5.13 where the notated
   stacking of two `6/5`s scores 7.81, so the compact reading wins
   wherever the windows admit it.

3. What refuses it is the pull, and only above a strength of about
   1.85. Below that a diminished triad standing alone takes the
   respelling and runs a note to the edge of its window, where the
   sibling puts the commonest trade at 1 and the top of the dial's
   travel at 2 (`design/adaptive-tuning.md` § Harmonic lock).

4. A move set reaching to 3.91 admits the notated reading without
   making it preferred, and that is above the range that keeps the
   state count in hand (§ What it costs to solve).

## Open

1. Whether the two models share a command. Scope, window, pull and undo
   are common, which argues for one command choosing on the kind of
   target it is handed; two commands would state the choice more
   plainly.

2. What the solver's module boundary becomes, and what can still be
   specified and pinned on its own (§ What the solver loses).

3. What the command does with a chord the move set misspells (§ When a
   chord is misspelled). Refusing, seating it unmoved, and stiffening the
   pull for that chord alone are all available and none is obviously
   right.

4. How a solve sees the take before it. The sibling's collar arrives
   with its tuning already chosen (`design/adaptive-tuning.md`
   § Seams), but a take stores cents where the objective reads coords,
   and a dense reachable set puts no ratio at a pitch in particular; a
   take left in 12-EDO has no coords to recover at all. Either a note
   carries its coords as metadata, or one solve spans the takes in
   sequence and carries the tree across.

5. Whether the search enumerates placements or the assignments they
   produce. Two trees reaching the same pitches are one answer to be
   scored once, and an enumeration over trees counts it twice.

6. What the pull's scale becomes (§ When a chord is misspelled).
   Defending a notated spelling takes about 1.85, the top of the
   sibling's useful travel, where its own account has the solve tending
   to a no-op (`design/adaptive-tuning.md` § Harmonic lock). Whether
   the dial is renormalised for this model or the objective reweighted
   is undecided.
