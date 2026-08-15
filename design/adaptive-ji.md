# Design — Adaptive just intonation

> opened: 2026-08-11 · status: in flight — plan/adaptive-ji.md, at
> phase 2 (the placement), behind the command
> `design/adaptive-tuning.md` has built; the state counts of § What it
> costs to solve await re-measurement

**Tune a selection so that the notes of each sonority are joined by pure
intervals from a stated set, letting those intervals compose into
harmonies no scale holds, anchored so no note leaves the step it was
written on.**

## Where it sits

1. This is the solve of `design/adaptive-tuning.md` with one part
   exchanged: the candidate model, what it may choose from. Everything
   else settled there is cited here rather than restated; where
   the exchange breaks something, we say so.

2. There a note lands on a point of a chosen scale, so the tunings
   available to a passage are that scale's points and nothing else.

3. That ceiling is what this document is opened against. A solve that
   only ever seats notes on a scale's points produces what an author
   could have produced by switching to the scale and typing.

4. The exchange makes two facilities of one command
   (`design/adaptive-tuning.md` § Where it sits). One modal opens over
   both, with a pure function apiece behind it.

5. The two functions stand side by side in the solver's module. The
   strands, the walk, the score and the schedule of live strands serve
   both, and only the enumeration at an onset differs.

## The command's slots

1. Every slot is the sibling's
   (`design/adaptive-tuning.md` § The command's slots). This facility
   adds none and disables the key (§ Where a move set comes from).

2. The target slot holds the same object under either facility: a temper
   whose every token is a ratio. What differs is how those are read —
   the sibling takes them as points on the pitch line, and this document
   as intervals from a unison (§ The target becomes a move set).

## The target becomes a move set

1. The target is a **move set**: a collection of **moves**, each an
   interval that may be sounded pure between two notes of a sonority.

2. The **reachable set** is every tuning a chain of moves arrives at
   from a given note. It is larger than the move set, since a chain of
   two moves leaves the set they were drawn from.

## A placement is a tree

1. A **placement** is a tree over the passage's strands, each edge
   carrying the move that reaches its child from its parent. The
   **root** is the vertex with no parent, and is the only strand no move
   reaches.

2. A strand is the notes of a step-class that overlap in time, holding
   one tuning between them (`design/adaptive-tuning.md` § The strand),
   and a step-class is a step of the notation with every step an octave
   from it (`design/adaptive-tuning.md` § The model).

3. The strand is the vertex because a vertex holds one tuning, and a
   strand is exactly what must share one.

4. A doubled octave therefore costs no vertex, its notes sharing a
   step-class and so a strand.

5. A strand's **candidates** are the tunings available to it. They are
   not a property of the strand: every one of them is a tuning a move
   reaches from another strand of the sonority.

6. What a strand may attach to is the sonority current where it strikes
   (`design/adaptive-tuning.md` § The model). A note held through the
   chords behind it stays attachable for as long as it sounds.

7. An onset can leave nothing of what preceded it. The whole onset is
   absorbed before the sonority is taken, so `n` or more classes
   striking together evict everything that is not still sounding
   (`design/adaptive-tuning.md` § The model).

8. The sonority before such an onset stays attachable, and only there.
   Without it the strands born there reach from nothing, and the passage
   is a forest of chords each rooted where it was written.

9. Keeping it attachable at every onset costs what it does not buy
   (§ What it costs to solve).

10. The tree's shape decides what can be spelled. Under a move set
    holding `5/4` and `3/2` but not `6/5`, a C minor triad has no
    placement in which E♭ hangs off C, since that edge would be a `6/5`;
    it has one in which E♭ hangs off G, arriving a `5/4` below it and so
    a `6/5` above the C.

11. A move the set does not hold is therefore still available between two
    strands, provided a third stands between them in the tree.

12. A step-class returning later is a second vertex. The strand that held
    it has ended, so the new one attaches by its own move and its coords
    follow that chain rather than the earlier strand's (§ Drift).

## Coords accumulate along it

1. A strand's coords — the exponents of the odd primes in a ratio
   (`design/adaptive-tuning.md` § What "in tune" means) — are its
   parent's plus its move's, and the root's are zero. The tree fixes
   them.

2. It fixes them against its root rather than against the pitch line.
   What seats them there is § Where a placement sits.

3. The score sums the span of those coords on each axis, each weighted
   by `log₂ p` (`design/adaptive-tuning.md` § What "in tune" means). A
   span is unchanged by adding a constant to every coord, so the choice
   of root does not enter it.

4. The objective is reusable without amendment.

5. Two paths to the same strand would fix its coords twice. They agree
   only where the moves around the loop multiply to unity. Where they
   do not, the difference is a **comma**, and the two paths are two
   pitches rather than one.

6. A placement is a tree rather than a graph for that reason. A cycle is
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

2. Complexity bounds the move set, and that is what makes a strand's
   candidates finite. Each candidate is one move from a strand of the
   sonority (§ A placement is a tree), so their number is the move set's
   size times the sonority's.

3. The window is the notation's, reaching half way to the adjacent step
   on either side (`design/adaptive-tuning.md` § The window). It bounds
   where a strand may go and says nothing about how it got there: what
   it adds is a smaller count and notes that keep their step.

4. Complexity is bounded by **octave-free Tenney height**: the base-2
   logarithm of the product of the odd parts of a move's two terms.
   `5/4` and `8/5` are one move and its inversion, and both read 2.32.
   A move set's **complexity bound** is the largest height it holds.

5. The terms are the reduced ratio's. A generator stating its points over
   a common root emits `9/6` for the fifth, and read literally that is
   4.75 rather than the 1.58 the move sounds.

6. The bound does not fix the primes. Every figure here is measured over
   a move set holding all of 3, 5 and 7 under a stated bound, and prime
   11 would displace them: `11/8` reads 3.46 and sounds a tritone as one
   move, where nothing on 3, 5 and 7 sounds one under 3.91.

7. That measure is the objective's own. A sonority's score (§ Coords
   accumulate along it) is the Tenney height of its octave-free
   `lcm/gcd`, so one measure bounds what may be admitted and scores what
   results.

8. Odd limit is the wrong bound here, though it is the right one for a
   scale. It does not add along a chain: two `5/4`s are odd limit 5
   apiece and `25/16` is odd limit 25, where the Tenney heights are
   2.32 apiece and 4.64 together, which is exactly `25/16`'s.

## Where a placement sits

1. A placement fixes the intervals between its strands and not their
   pitches. Every edge is an exact ratio, so seating one strand seats
   all of them.

2. Nothing else seats one. The key is disabled
   (§ The command's slots), and a move set has no place on the pitch
   line (§ Where a move set comes from).

3. A placement therefore carries an **offset**: one figure for the whole
   passage, added to every strand.

4. The offset is what makes the window a joint constraint. A placement
   is admissible where some offset puts every strand inside its window,
   which bounds the span of the strands' displacements rather than any
   one of them.

5. An offset admitting no placement refuses nothing but itself. Some
   strand's window holds nothing reachable there, and another offset
   may place what it could not.

6. The offset is chosen to minimise the pull. Where the notation's
   windows are equal it is the mean of the displacements, clamped to the
   admissible range.

7. Against a 12-EDO notation a I–IV–V–I seats at +4¢ and a ii–V–I at
   +32¢.

8. Without an offset the model refuses chords it can otherwise spell. A
   dominant seventh under a complexity bound below 2.8 has no placement
   left where it was written, and neither has a diminished triad under
   any bound.

9. The strand seated is the first born at the first onset. Its coords
   are zero (§ Coords accumulate along it) and its cents the seat of
   the step it was written on, so its strain reads the offset and
   nothing else.

10. The choice of root stays immaterial. Re-rooting a placement shifts
    every displacement by a constant, which the offset absorbs, so the
    pull reads a placement as blindly as the score does
    (§ Coords accumulate along it).

## What reachability spends

1. A passage needs a window of some minimum width merely to have a
   placement. That width is a property of the move set and the notation,
   the objective having no part in it.

2. Triadic material is placeable well inside a 12-EDO window. A I–IV–V–I
   and a comma pump each need about 10¢ of the 50¢ available.

3. Seventh chords spend most of it. A ii–V–I needs 35.5¢ and a
   diminished triad 43.2¢, and neither figure moves when the move set
   grows from seven moves to nine.

4. What the floor consumes, the pull cannot use. A ii–V–I returns one
   answer across the dial's whole useful travel
   (`design/adaptive-tuning.md` § Harmonic lock), first moves at a
   strength ten times its top, and stops at 37¢ however hard it is
   pulled.

## Where nothing is in reach

1. A partial placement can be **stuck**: no strand the onset has yet to
   place is reachable by any move from any strand already placed. The
   search refuses that offset there.

2. Refusing an offset refuses nothing else (§ Where a placement sits). A
   ii–V–I whose chords are rolled rather than struck together is refused
   at five of the sweep's eleven passes and placed at the other six.

3. Where every pass refuses, the fallback is a **composite** edge: two
   moves where the tree can carry one. It stands in for the vertex the
   tree would have routed through had that vertex been placed.

4. The objective is untouched by it. A composite arrives at the coords
   the missing vertex would have given, and the score reads coords
   (§ Coords accumulate along it).

5. It fires at a stuck partial and nowhere else. Composing a nine-move
   set gives thirty-seven moves, and offering all of them at every
   attachment does not finish; offered where a partial has no extension
   at all, they cost nothing until they are needed.

6. This is what transfers of the sibling's widening
   (`design/adaptive-tuning.md` § What the solver takes). There a class
   with nothing in reach has its window scaled; here the reach deepens,
   the window being a joint constraint the offset already answers for
   (§ Where a placement sits).

## Where a move set comes from

1. A temper whose pitches are ratios is a move set already, read as
   intervals from its unison rather than as points.

2. Nothing new authors one. The generators that emit ratio tokens and
   the temper editor that drives them are the sibling document's account
   of authoring a target (`design/adaptive-tuning.md` § What a target
   is), and they serve here unchanged.

3. Partch's diamond is a table of intervals from a `1/1`, so taking it
   as a move set is closer to what it is than taking it as a scale.

4. A move set has no place on the pitch line. Its `1/1` is wherever a
   move departs from rather than a pitch of its own.

5. A temper holding a pitch in cents or in equal divisions cannot be a
   move set, for the reason `design/adaptive-tuning.md` § What a target
   is gives: the token carries no ratio, so there are no coords to
   accumulate.

## What it costs to solve

1. The DP's shape survives. Its state is one chosen tuning per live
   strand (`design/adaptive-tuning.md` § Solving it).

2. Its count is one entry for each way of choosing a candidate for every
   live strand (`design/adaptive-tuning.md` § Solving it).

3. What an entry holds changes. There is no shortlist to index, so it
   carries a tuning together with the coords that reached it.

4. An onset chooses tunings only for the strands born there; those the
   state holds are already fixed. Each must attach by a move to a strand
   already placed, whether from the state or from the same onset, so
   the choices are not independent as the sibling's are.

5. The search grows a placement outward from the root, taking any
   unplaced strand from any strand already placed. Fixing the order in
   advance would lose the trees that reach a strand through a later
   one: a C minor triad's E♭ hangs off its fifth (§ A placement is a
   tree), so an order that places the E♭ first has nothing to hang it
   on.

6. The search enumerates assignments rather than trees. Two trees
   reaching the same coords are one answer, and over a ii–V–I the trees
   outnumber the assignments thirty-one to one.

7. Keying an entry by its coords collapses them at no cost. The entry
   already carries the coords that reached it.

8. The carry into an onset must still tell apart the strands that onset
   evicted, since they are what the strands born there attach to
   (§ A placement is a tree). The entries it produces need not, an
   evicted strand having no future left to alter.

9. The offset does not fit inside the walk (§ Where a placement sits).
   It is one figure for the whole passage, so no partial placement can
   be scored against it.

10. The DP therefore runs once for each offset in a sweep.

11. The sweep resolves the placement rather than the offset. A sweep
    at 10¢ chooses what a sweep at 0.25¢ chooses, and a sweep at 20¢
    does not.

12. The winning placement's exact offset then follows from the mean of
    its displacements (§ Where a placement sits), so eleven passes over
    a range of 100¢ are enough.

13. The counts that follow are floors. They count only the strands the
    recency bound makes live, and they are stated in states where the
    budget is placements at an onset
    (`design/adaptive-tuning.md` § Solving it).

14. Only a narrow range of complexity bounds is usable: between about
    2.8 and 3.3, admitting seven to nine moves. Below it a dominant
    seventh standing alone is spelled only by running a strand to 49¢ of
    a 50¢ window; in a ii–V–I the same chord solves inside 27¢. Above it
    the state count runs away, reaching 59,049 at 4.0.

15. Inside that range the state count is thirteen to thirty-two times
    the sibling's. Measured against a 12-EDO notation over a ii–V–I and
    a comma pump, candidates average 2.4 a strand at the lower bound and
    3.1 at the upper, with maxima of five and six where the sibling's
    shortlists never exceed three.

16. The absolute numbers stay small. Six candidates over a sonority of
    six is 7,776 states, where the sibling's own reckoning puts three
    candidates over a sonority of eight at 2,187
    (`design/adaptive-tuning.md` § Solving it).

17. The sweep leaves them inside the budget. Eleven passes of 7,776 is
    85,536, against the 200,000 placements at an onset the sibling
    allows (`design/adaptive-tuning.md` § Solving it).

18. The budget cannot be read off the walk. A strand's candidates
    depend on where the others went (§ What the solver loses), so there
    is no product of shortlist sizes to take before the search begins.

19. The count is taken as the entries are reached, and the search
    refuses there. The upfront bound (the move set's size times the
    sonority's) overestimates by an order of magnitude and would
    refuse everything.

20. Counted that way, a ii–V–I of sevenths under nine moves reaches
    1,937 entries at its third onset, against a budget of 200,000.

21. Keeping the preceding sonority attachable at every onset rather than
    only where nothing is carried (§ A placement is a tree) reaches
    622,694 there, and arrives at the same placement. A strand's
    candidates are its anchors times the moves, and the strands born
    together multiply.

22. Where nothing is carried the price is real. Five detached triads at
    a sonority of three under nine moves reach 82,655 entries at the
    fifth onset, where the sonority alone reaches twelve, a chain free
    to wander leaving no placement to dominate the rest.

## What the solver loses

1. The sibling's solver takes strands carrying shortlists and knows
   nothing of tempers, targets or ratios
   (`design/adaptive-tuning.md` § What the solver takes). Only the
   strand survives that.

2. A strand arrives as `{ notes, class, shortlist }`, and this model
   fills the notes and the class as the sibling does. Grouping notes
   into strands is the solver module's own work
   (`design/adaptive-tuning.md` § Where it sits), and the class it
   groups by comes from the notation alone.

3. The shortlist is what cannot be filled. A strand's candidates depend
   on where the other strands went, so they do not exist before the
   solve.

4. So the search carries the move set, computing coords and pitches as
   it goes rather than reading them off a shortlist. It is not a pure
   function over anonymous candidates.

5. This is the largest cost the model incurs. The sibling's spec can
   hand its solver shortlists written straight into the test
   (`design/adaptive-tuning.md` § First brick); here the move set and
   the coord arithmetic are inside the search, and there is nothing
   smaller to pin.

6. Carriage replaces that purity. The solve hands the notation, the
   move set and a candidate's cents to `tuning.lua`, and reads back the
   coords and the strain it scored and pulled on already.

7. The invariant given up is the sibling's own rather than the
   module's. The sibling's solve reads no cents and knows no ratios,
   and states that of itself.

## Drift

1. Drift is what the model produces when nothing resists it. Coords
   accumulate along the tree, so a strand's tuning follows the chain
   that reached it rather than the step-class it belongs to.

2. A comma pump is the case that tests it: a progression whose moves
   multiply to a comma returns to its opening step at a different
   tuning.

3. Drift cannot accumulate without bound, because the window bounds the
   span of a placement's displacements (§ Where a placement sits). A
   passage returning repeatedly to a step-class is held inside that span
   every time.

4. What the window does not bound is where the passage sits as a whole.
   The offset can carry all of it as far as a half-width from where it
   was written, and a ii–V–I takes +32¢ of the 50¢ a 12-EDO notation
   allows.

5. What the pull decides is where inside the window the trade lands, and
   its scale is the sibling's
   (`design/adaptive-tuning.md` § Harmonic lock).

6. A passage of detached chords drifts at all only because the sonority
   before an onset stays attachable (§ A placement is a tree). At a
   sonority of three with nothing sounding across the change, a comma
   pump would otherwise re-root every chord and return to its opening
   step unmoved.

## When a chord is misspelled

1. A chord can be seated by moves that spell a different chord. Nothing
   in the model reads the notated intervals: a tree is admissible when
   every strand lands inside its window, however far its moves depart
   from what was written.

2. The objective prefers the respelling. A written diminished triad
   read as 4:5:7 on its middle note scores 5.13 where the notated
   stacking of two `6/5`s scores 7.81, so the compact reading wins
   wherever the windows admit it.

3. What refuses it is the pull, and only above a strength of about
   1.85. Below that a diminished triad standing alone takes the
   respelling and runs a strand to the edge of its window, on a dial
   whose useful travel the sibling puts at 0 to 2
   (`design/adaptive-tuning.md` § Harmonic lock).

4. A move set reaching to 3.91 admits the notated reading without
   making it preferred, and that is above the range that keeps the
   state count in hand (§ What it costs to solve).

## Open

1. What the command does with a chord the move set misspells (§ When a
   chord is misspelled). Refusing, seating it unmoved, and stiffening the
   pull for that chord alone are all available and none is obviously
   right.

2. What the pull's scale becomes where it still has room
   (§ What reachability spends). Defending a diminished triad's notated
   spelling takes about 1.85, the top of the sibling's useful travel,
   where its own account has the solve tending to a no-op
   (`design/adaptive-tuning.md` § Harmonic lock). Whether the dial is
   renormalised for this model or the objective reweighted is undecided.

3. How a solve sees the take before it. The sibling's collar arrives as
   strands of one with their tuning already chosen
   (`design/adaptive-tuning.md` § Seams), but a take stores cents where
   the objective reads coords, and a dense reachable set puts no ratio
   at a pitch in particular; a take left in 12-EDO has no coords to
   recover at all. Either a note carries its coords as metadata, or one
   solve spans the takes in sequence and carries the tree across.

4. Whether the window should bind at all. Letting a strand drift past
   it, with the pull anchored to the step the note was written on rather
   than the one it would then recover, would collapse the refusal, the
   widening offer and the floor of § What reachability spends into a
   single trade. What it costs is idempotence by construction and a dial
   that means the same under every notation
   (`design/adaptive-tuning.md` § The window, § Harmonic lock).

5. Whether a rolled chord should be one onset. The tree grows forward in
   time, so a rolled chord's first note is its root and the rest hang
   off it: a rolled ii–V–I places its V with a wolf fifth where the same
   chord struck together gives 4:5:6. What is lost is the joint
   enumeration rather than a move, so composite edges do not recover it
   (§ Where nothing is in reach) and folding strikes inside a tolerance
   into one onset would. That is the walk's business rather than the
   placement's.
