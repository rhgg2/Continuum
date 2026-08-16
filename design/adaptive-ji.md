# Design — Adaptive just intonation

> opened: 2026-08-11 · status: superseded 2026-08-16 —
> design/adaptive-springs.md retires the lattice search; stopped at
> phase 4 of plan/adaptive-ji.md, behind the command
> `design/adaptive-tuning.md` has built

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
   adds one — complexity — and disables the key (§ Where a move set
   comes from).

2. The target slot holds the same object under either facility: a temper
   whose every token is a ratio. What differs is how those are read —
   the sibling takes them as points on the pitch line, and this document
   as intervals from a unison (§ The target becomes a move set).

3. Which facility runs is therefore a choice of its own, drawn beside
   the target, since nothing recovers the reading from the object. It is
   dead until a target is chosen, and it persists per take as the target
   and the key do (`design/adaptive-tuning.md` § Where it sits).

4. Harmonic lock opens at a different figure. The sibling's opens at 1
   and this facility's at 1.5, the offset having halved what a strength
   buys (§ What the pull's scale becomes). The two are not one dial, so
   choosing the other facility re-seats the slider on its own figure.

5. The added slot is complexity. It truncates the height-sorted move
   set at the bound it states, opening at 3.91, the figure that spells
   the minor third (§ What it costs to solve): the septimal diamond
   holds nineteen moves whole and eleven under it, and eleven is what
   a real take affords at a sonority of three.

6. The picker states each ratio temper's bound beside it. What makes a
   temper a target is facility-neutral — every token a ratio — so
   nothing else tells apart a temper cheap as points and unaffordable
   as moves; the bound is stated before the choice rather than
   discovered after it.

7. Sonority size re-seats as harmonic lock does, opening at five under
   the sibling and three here. The width of a chord change is the
   exponent of the cost (§ What it costs to solve), and the take that
   answers at every offset of the sweep at three answers at one of
   eleven at five, spending its minute mostly on the ten that reach
   the budget. Three is not a cheaper five, however: it reads
   five-part writing as the last three classes struck, so the setting
   the take affords is also the thinner account of its harmony.

## The target becomes a move set

1. The target is a **move set**: a collection of **moves**, each an
   interval that may be sounded pure between two notes of a sonority.

2. The **reachable set** is every tuning a chain of moves arrives at
   from a given note. It is larger than the move set, since a chain of
   two moves leaves the set they were drawn from.

## A placement is connected

1. A **placement** assigns coords to every strand of the passage. It
   fixes the strands' intervals and not their pitches; what seats it on
   the pitch line is § Where a placement sits.

2. A strand is the notes of a step-class that overlap in time, holding
   one tuning between them (`design/adaptive-tuning.md` § The strand),
   and a step-class is a step of the notation with every step an octave
   from it (`design/adaptive-tuning.md` § The model).

3. The strand is the placement's unit because a strand is exactly what
   must share one tuning.

4. A doubled octave therefore costs no strand, its notes sharing a
   step-class.

5. Two strands are **neighbours** where they share a sonority
   (`design/adaptive-tuning.md` § The model). A note held through the
   chords behind it neighbours whatever strikes against it for as long
   as it sounds.

6. An onset can leave nothing of what preceded it. The whole onset is
   absorbed before the sonority is taken, so `n` or more classes
   striking together evict everything that is not still sounding
   (`design/adaptive-tuning.md` § The model).

7. Such an onset is a **hinge**: the strands born there take the
   sonority before it as neighbours too. Without the hinge the passage
   is a forest of chords, each seated where it was written.

8. The hinge is the eviction onset's alone. Neighbouring every onset to
   its predecessor costs what it does not buy (§ What it costs to
   solve).

9. A placement is **admissible** where the offset seats every strand
   inside its window (§ Where a placement sits), and every strand is
   joined to every other by a chain of neighbours whose coords differ
   by a move the set holds.

10. Joined, not derived: no strand is another's root, no move between
    two strands has a direction, and a rolled chord whose notes sustain
    admits the placements the struck chord admits.

11. What the moves join decides what can be spelled. Under a move set
    holding `5/4` and `3/2` but not `6/5`, a C minor triad has no
    admissible placement joining E♭ to C directly, since that pair
    would differ by a `6/5`; it has one joining E♭ to G, seated a `5/4`
    below it and so a `6/5` above the C.

12. A move the set does not hold is therefore still available between
    two strands, provided a third stands between them.

13. A step-class returning later is a second strand. The one that held
    it has ended, so the new one is joined by its own moves and its
    coords owe nothing to the earlier strand's (§ Drift).

## Coords accumulate along moves

1. A strand's coords — the exponents of the odd primes in a ratio
   (`design/adaptive-tuning.md` § What "in tune" means) — differ from a
   neighbour's by the moves that join them, each move adding its
   exponents along the chain.

2. They are fixed against the passage rather than against the pitch
   line. What seats them there is § Where a placement sits.

3. The score sums the span of those coords on each axis, each weighted
   by `log₂ p` (`design/adaptive-tuning.md` § What "in tune" means). A
   span is unchanged by adding a constant to every coord, so it reads
   the intervals the placement fixes and nothing else.

4. The objective is reusable without amendment.

5. Two chains joining the same pair of strands agree automatically,
   both being read off coords the placement has already fixed. A second
   chain certifies nothing new and costs nothing, so admissibility asks
   for one chain and tolerates any number.

6. Where the moves around a loop multiply to a comma, the loop does not
   close. The difference stands in the coords, the two ends are two
   pitches, and at most one of the chains joins them.

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
   **candidates** — the tunings the search may offer it — finite. Each
   candidate is one move from a placed neighbour (§ A strand may wait),
   so their number is the move set's size times the neighbours the
   strand holds.

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
   accumulate along moves) is the Tenney height of its octave-free
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

7. The pull's strength does not enter the choice. It scales every
   strand's pull alike, so the mean stands wherever the dial is set; what
   a stiffer pull moves is which placement wins, and not where the winner
   sits.

8. Against a 12-EDO notation a I–IV–V–I seats at +14.7¢ and a ii–V–I of
   sevenths at +5.5¢. A diminished triad standing alone seats at +18.8¢,
   which is the edge of the admissible range rather than the mean of its
   displacements: the mean is +17.1¢, and no placement survives there.

9. Without an offset the model refuses chords it can otherwise spell. A
   dominant seventh under a complexity bound below 2.8 has no placement
   left where it was written, and neither has a diminished triad under
   any bound.

10. The strand seated is the first born at the first onset. Its coords
    are zero and its cents the seat of the step it was written on, so
    its strain reads the offset and nothing else.

11. That seat is a gauge rather than a claim. Seating any other strand
    shifts every coord and every displacement by a constant, which the
    span and the offset absorb (§ Coords accumulate along moves), so
    nothing the model reads depends on the choice.

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
   (§ What the pull's scale becomes), first moves at a strength ten
   times its top, and stops at 37¢ however hard it is pulled.

5. Where nothing reaches, the command refuses as the sibling's does
   (`design/adaptive-tuning.md` § What the solver takes), naming the
   onset and the interval that had nowhere to go, and offering the same
   widening.

6. Little refuses. The one refusal over the passages measured is a bare
   tritone standing alone, and it misses by 1.955¢: the nearest moves to
   600¢ are `4/3` and `3/2`, each 101.955¢ away, against the 100¢ that
   two 50¢ windows allow between them. Put a chord in front of it and it
   places.

## A strand may wait

1. A strand's anchor can be born after it. A rolled chord's third can
   strike before the fifth it must join, and admissibility is blind to
   direction (§ A placement is connected), so a search placing every
   strand at its own onset refuses placements the model admits.

2. The search therefore lets a strand **wait**: born unplaced, its
   coords chosen at a later onset, one move from a neighbour placed by
   then. The note does not move; only the choice does.

3. Waiting is a candidate rather than a fallback. A placement may join
   a strand backward even where a forward candidate exists, so a strand
   still sounding at the next onset forks a waiting branch beside its
   placements, and the objective judges the branches like any rivals.

4. A sonority holding a waiting strand is scored when its last member
   places. The box reads coords, the coords arrive late, and nothing
   else about the objective moves.

5. A strand waits only while it sounds. What places it is a neighbour,
   the neighbour it takes coords from is one it sounds with, and once
   it has stopped there is none left to come: a strand out of onsets to
   sound through places now or its branch is refused.

6. Recency joins but does not wait. A strand the sonority holds by
   recency has stopped (`design/adaptive-tuning.md` § The model), so
   the box scores it and a strand born now joins it, but it waits for
   nothing and nothing waits for it.

7. A hinge is no exception. It joins strands that never sound together
   (§ A placement is connected), so nothing waits across one, and a
   passage of detached chords keeps the entry count it has without
   waiting at all (§ What it costs to solve).

8. A waiting strand resolves only to coords no earlier onset offered.
   Whatever an earlier onset could offer, the branch that placed there
   already carries, so each placement is enumerated once however long
   its strands waited.

9. An offset can still refuse. A strand out of waits with nothing in
   its window ends its entry, an onset ending every entry refuses the
   offset there, and refusing an offset refuses nothing else
   (§ Where a placement sits).

10. Waiting answers what the sibling widens for
    (`design/adaptive-tuning.md` § What the solver takes). There a class
    with nothing in reach has its window scaled; here it waits for the
    neighbour that can reach it, the window being a joint constraint the
    offset already answers for (§ Where a placement sits). What the
    widening is left to answer is the passage no offset places
    (§ What reachability spends).

11. A composed interval is admitted only where real strands carry it.
    Every chain runs through neighbours that sound, so nothing enters
    the reachable set past the complexity bound (§ What makes the
    candidate set finite): a bare tritone under a move set holding no
    `7/5` is refused rather than spelled through a phantom strand a
    `5/4` above it (§ What reachability spends).

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

4. An onset chooses tunings for the strands born there and for those
   done waiting (§ A strand may wait); those the state holds placed are
   already fixed. Each joins a placed neighbour by a move, whether from
   the state or from the same onset, so the choices are not independent
   as the sibling's are.

5. The search grows the placed set outward from the seed, taking any
   unplaced strand from any placed neighbour, at its own onset or a
   later one. An order fixed in advance would lose the placements that
   join a strand through a later one: a C minor triad's E♭ joins its
   fifth (§ A placement is connected), so an order placing the E♭ first
   has nothing to join it to.

6. The search enumerates assignments rather than derivations. Two
   orders of joining that reach the same coords are one answer, and
   over a ii–V–I the derivations outnumber the assignments thirty-one
   to one.

7. Keying an entry by its coords collapses them at no cost. The entry
   already carries the coords that reached it.

8. The carry into an onset must still tell apart the strands that onset
   evicted, since they are what the strands born there join
   (§ A placement is connected).

9. It must tell apart, too, what a waiting strand may still read: the
   tunings of its neighbours, and the members of every sonority its
   waiting leaves unscored (§ A strand may wait).

10. The entries an onset produces need not tell apart what nothing
    waits on, an evicted strand with its boxes settled having no future
    left to alter.

11. The offset does not fit inside the walk (§ Where a placement sits).
    It is one figure for the whole passage, so no partial placement can
    be scored against it.

12. The DP therefore runs once for each offset in a sweep. The sweep
    spans the root strand's own window, an offset past it carrying the
    root off the step it was written on (§ Where a placement sits).

13. The sweep resolves the placement rather than the offset, where the
    passage has room for one. A sweep at 10¢ chooses what a sweep at
    0.25¢ chooses, and a sweep at 20¢ does not. A passage at the floor
    of § What reachability spends has no room: a minor triad under
    fifths alone places between +46.1¢ and +48.0¢ and nowhere else, and
    a sweep at 10¢ steps over that band and refuses it.

14. The winning placement's exact offset then follows from the mean of
    its displacements (§ Where a placement sits), so eleven passes over
    a range of 100¢ are enough. The pull is re-read there and the box
    reads coords alone, so the cost returned is the cost at the offset
    returned.

15. Settling the winner alone is enough. Settling every pass's placement
    and comparing the results there returns the same placement in every
    passage measured, and where a different one comes back the two costs
    agree to twelve figures: a diminished triad and an augmented triad
    are symmetric under inversion, so a placement's mirror costs what the
    placement costs.

16. The counts that follow are floors. They count only the strands the
    recency bound makes live, and they are stated in states where the
    budget is placements at an onset
    (`design/adaptive-tuning.md` § Solving it).

17. The bound must reach 3.91, which is where `6/5` sits: below it a
    bare minor third is not spelled, a minor triad is spelled only
    through its fifth (§ A placement is connected), and a minor cadence
    takes a placement the notation did not write however hard it is
    pulled (§ When a chord is misspelled). At the other end a bound of
    2.81 spells a dominant seventh standing alone only by running a
    strand to 49¢ of a 50¢ window, where in a ii–V–I the same chord
    solves inside 27¢.

18. Reaching 3.91 costs about twice the entries and no answer. A ii–V–I
    of sevenths goes from 3,324 entries to 8,801 and five detached
    triads from 13,199 to 45,217, each returning the placement the
    smaller set returned; the budget binds above that, the five triads
    passing it at 4.39.

19. Waiting costs nothing where nothing sounds into the change. With it
    offered and without, a struck ii–V–I of sevenths under nine moves
    reaches 1,937 entries at its third onset, five detached triads
    82,655 at their fifth, and a comma pump 11,257.

20. What it buys is the rolled textures. A rolled triad, which placing
    every strand at its own onset refuses, places at its struck coords
    for two entries; a rolled ii–V–I of sevenths places at 3,929
    against the budget of 200,000.

21. What sounds through the change pays. A comma pump whose chords are
    held into the next reaches 12,125 entries at its last onset against
    2,436 without waiting.

22. Waiting on what a strand does not sound with buys nothing
    (§ A strand may wait). Offered across recency and the hinge, the
    struck pump reaches 52,732 entries rather than 11,257 and returns
    the placement it returns anyway, as does every passage measured.

23. The budget cannot be read off the walk. A strand's candidates
    depend on where the others went (§ What the solver loses), so there
    is no product of shortlist sizes to take before the search begins.

24. The count is taken as the entries are reached, and the search
    refuses there. The upfront bound (the move set's size times the
    sonority's) overestimates by an order of magnitude and would
    refuse everything.

25. Hinging every onset to its predecessor rather than only where
    nothing is carried (§ A placement is connected) reaches 622,694
    entries where the ii–V–I's third onset reaches 1,937, and arrives
    at the same placement. A strand's candidates are its neighbours
    times the moves, and the strands born together multiply.

26. Where nothing is carried the price is real. Five detached triads at
    a sonority of three under nine moves reach 82,655 entries at the
    fifth onset, where the sonority alone reaches twelve, a chain free
    to wander leaving no placement to dominate the rest.

27. Those figures are floors in a second sense: the passages they are
    measured over are triads and sevenths, five chords at most. A take
    of five-part writing — forty-three notes, thirty strands over
    sixteen sonorities — states the shape: cost is linear in the
    number of chord changes and exponential in the width of one.

28. Width is the exponent. Under nine moves at a sonority of three,
    the onset where five strands are born against four carried anchors
    reaches 23,397 entries and carries 1,521 of them forward; the last
    onset carries eighteen; an onset adding a single voice costs
    nothing.

29. The dials multiply rather than trade. Under nine moves at a
    sonority of three the take places at all eleven offsets of the
    sweep; at eleven moves and a sonority of five it places at one,
    the other ten reaching the budget first. The workable region is a
    diagonal, both dials moving together or neither.

30. A bound the target already meets buys nothing. The take was
    written against a diamond of eleven moves, every one under 3.91,
    so the complexity slot would have truncated nothing there; what
    the slot offers is a way out of a wider target rather than a
    rescue of this one.

31. The sweep's cost is its refusals'. The take places at its one
    offset in 12.3 seconds inside the budget of 200,000; each of the
    ten offsets refusing spends four to twelve seconds reaching the
    budget first, and the sweep answers in 65.

## The solve stays exact

1. Cheaper searches were measured, and every one that reads quality
   was refused. The prunes with obvious forms — thinning a window's
   candidates, capping them, carrying only the best entries — break
   the search in the same place: what each discards is not an answer
   but an anchor. What survives is a fold of the entries the box
   cannot tell apart, which discards nothing.

2. A candidate is a waypoint before it is an endpoint. Two tunings a
   comma apart in one window are one pitch to the ear and two
   departures for the strands still unplaced, a move departing from
   exact coords (§ Coords accumulate along moves), so thinning a
   window by audibility removes the only path to somewhere a later
   strand needed. Under nine moves at a sonority of three, a tolerance
   of ten cents removes a tenth of the entries, none of the time and
   nothing of the answer; twenty answers worse; thirty refuses offsets
   that placed.

3. Capping the candidates a strand may consider changes nothing
   either. Capped at six the search runs as the uncapped search runs,
   the lists being short already; the cost is the product over the
   strands born together, which no one list's length carries.

4. An entry is an anchor as a candidate is. Carrying the best entry
   alone — a sonority of five, eleven moves — refuses every offset
   inside three onsets, 153 entries into the sweep: the entry
   discarded as second-best was the one the next onset's strands could
   reach through.

5. Nor can an onset read which entry is best. A sonority holding a
   waiting strand is scored when its last member places (§ A strand
   may wait), so an entry's cost omits every box still pending, and
   ranking entries on it keeps exactly those that have deferred the
   most scoring. Sixteen abreast, a beam places the take at 169.1
   where the exact search places it at 106.2.

6. A prune that reads no quality does hold. Two entries agreeing on
   the strands still sounding at the next onset, and on the span each
   prime reaches across the strands that are not, place alike from
   there on: the box reads those spans and nothing else, so what tells
   the two apart has no future left to alter. Keyed that way the
   search reaches 69,944 entries where the full key reaches 429,009 at
   the take's one offset, and 355,110 where it reaches 573,254 at a
   sonority of three, returning the placement it returns anyway in
   each case. The saving grows with the width that costs, which is the
   direction that helps; it is measured rather than proved, however,
   and a folded entry could still be the one a strand born beside it
   needed to reach through.

7. What remains are the prunes that read no quality: admissibility,
   the fold above, and the budget, a bound on work that refuses the
   offset where it binds (§ Where a placement sits). A bound read
   against a finished answer would also stand (§ Open); a bound read
   between rivals does not.

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
   its scale is § What the pull's scale becomes.

6. A passage of detached chords drifts at all only because the hinge
   joins each chord to the one before (§ A placement is connected). At
   a sonority of three with nothing sounding across the change, a comma
   pump would otherwise re-seat every chord and return to its opening
   step unmoved.

## When a chord is misspelled

1. A chord can be seated by moves that spell a different chord. Nothing
   in the model reads the notated intervals: a placement is admissible
   wherever its strands land inside their windows and its moves join
   them (§ A placement is connected), however far those moves depart
   from what was written.

2. The objective prefers the respelling. A written diminished triad
   read as 4:5:7 on its middle note scores 5.13 where the notated
   stacking of two `6/5`s scores 7.81, so the compact reading wins
   wherever the windows admit it.

3. What refuses a respelling is the pull, and each chord turns over at
   its own strength. A i–iv–V–i in C minor takes its dominant as a minor
   triad below 1.361, seating the leading tone 50¢ flat at the edge of
   its window; a ii–V–i whose supertonic is half-diminished holds its
   respelling to 1.447; and a diminished triad standing alone takes the
   notated stacking only at 1.842.

4. A diminished seventh has no notated reading to defend. Four just
   minor thirds overshoot the octave by 62¢, so the chord respells at
   every strength, and what the objective chooses between are readings
   none of which is the written one.

5. The move set decides whether there is anything to turn over. A minor
   cadence under a set holding no `6/5` respells however hard it is
   pulled, no move of the set spelling the third it was written with
   (§ What it costs to solve).

## What the pull's scale becomes

1. The dial is the sibling's renormalised. Harmonic lock opens at 1.5
   here where it opens at 1 there, and its useful travel runs from 0 to
   2 as before (`design/adaptive-tuning.md` § Harmonic lock).

2. The offset is what doubles it. Chosen to minimise the pull
   (§ Where a placement sits), it leaves the pull charging the spread of
   a placement's displacements while the mean rides free, so a strength
   buys about half the resistance the sibling's buys. The trade the
   sibling fixes its scale on — a written C7 giving up the otonal
   `4:5:6:7` for the Pythagorean `16/9` — turns over at 0.95 there and
   at 1.819 here.

3. The default sits between what defends the notation and what gives up
   a septimal reading. Every notated quality measured but the diminished
   triad's is defended by 1.447 (§ When a chord is misspelled), and a
   blues keeps its septimal sevenths to 1.700, so 1.5 holds both.

4. There is no no-op end. Once the notated placement has won the pull
   has nothing left to take: its strands stand at pure intervals of one
   another, every rival placement lies further from the notation, and a
   I–IV–V–I still moves a note 12¢ at a strength of 128.

5. The dial therefore reads how much respelling is permitted rather than
   trading purity against fidelity. Its free end is ambiguous as the
   sibling's is; its stiff end is the notated chords in pure intonation.

## Open

1. How a solve sees the take before it. The sibling's collar arrives as
   strands of one with their tuning already chosen
   (`design/adaptive-tuning.md` § Seams), but a take stores cents where
   the objective reads coords, and a dense reachable set puts no ratio
   at a pitch in particular; a take left in 12-EDO has no coords to
   recover at all. Either a note carries its coords as metadata, or one
   solve spans the takes in sequence and carries the placement across.

2. Whether the window should bind at all. Letting a strand drift past
   it, with the pull anchored to the step the note was written on rather
   than the one it would then recover, would collapse the refusal, the
   widening offer and the floor of § What reachability spends into a
   single trade. What it costs is idempotence by construction and a dial
   that means the same under every notation
   (`design/adaptive-tuning.md` § The window, § Harmonic lock).

3. Whether a refusal must cost what an answer costs. Ten of the
   sweep's eleven offsets spend their seconds reaching the budget, and
   a placement completed at an earlier offset bounds every later
   partial from below, the pending terms all being nonnegative; a
   later offset could then refuse at the incumbent's figure rather
   than the budget's. The figure cannot be the incumbent's stated
   cost, however: the winner is stated where its own strands settle
   (§ Where a placement sits), and settling only lowers the pull, so a
   partial standing above the incumbent may yet settle beneath it —
   the take's own winner falls from 106.2 to 103.0 on settling. What
   survives settling is the box alone, which bounds more weakly. This
   cheapens the refusals that dominate the sweep and rescues nothing
   (§ The solve stays exact).

4. Whether the sweep can be probed rather than swept. The winner's
   exact offset follows from its displacements (§ What it costs to
   solve), which invites one pass and a settle in place of eleven; but
   the take places at one offset with its neighbours refusing, so a
   probe starting anywhere else finds nothing to settle.
