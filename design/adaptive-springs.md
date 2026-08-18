# Design — Adaptive just intonation by springs

> opened: 2026-08-16 · status: in flight — plan/adaptive-springs.md;
> replaces design/adaptive-ji.md, whose lattice search it retires;
> figures from a spike of 2026-08-16, kept at `tests/spikes/springs/`

**Tune a selection so that the notes of each sonority stand at pure
intervals drawn from a stated set, holding the state in cents and the
purity in springs, so that placements the ear cannot tell apart are
states the search may merge.**

## Where it sits

1. This is the solve of `design/adaptive-tuning.md` with the candidate
   model exchanged a second time: the first exchange let notes leave a
   scale's points for chains of pure moves, and this one lets the
   chains flex. The command, its slots and the facility choice are the
   sibling's; the target is still a ratio temper read as a **move
   set** — its tokens taken as intervals from a unison rather than
   points on the pitch line.

1. The lattice model pinned every interval. A strand's tuning was
   coords — exponents of the odd primes — reached by exact moves from
   a neighbour, so the constraints lived in the lattice while the
   objective, the windows and the ear lived on the pitch line; and the
   map between the two is dense, so two placements a comma apart were
   one pitch to the ear and two states to the search, each the only
   departure point for some continuation. Every prune that read
   quality therefore discarded an anchor some later strand needed, and
   the exact search that remained spent 63 seconds on a five-part
   take, refusing at ten of its eleven offsets.

1. What survives the exchange: the strand and the walk
   (`design/adaptive-tuning.md` § The strand, § The model), the box
   the objective sums (§ What "in tune" means), and the reading of a
   ratio temper as moves. What is retired: the placement search, the
   offset sweep and the waiting machinery — plan/adaptive-ji.md phases
   2 and 3; phase 1's move set arrives here unchanged as what the
   candidates compose from.

## The model

1. A strand carries one variable: its **displacement** — signed cents
   from the seat of the step it was written on, bounded by its window
   either side (`design/adaptive-tuning.md` § The window). The window
   is a box constraint per strand; there is no offset and no sweep,
   the pull charging each strand where it stands.

1. Each sonority of the walk takes a **spelling**: coords per member
   relative to the first, assigned as the lattice model assigned them
   — each member joined to another by a move — but read as intent
   rather than pinned. A spelling fixes, for every pair it holds, the
   interval the pair would sound if pure.

1. Each spelled pair is a **spring**: a quadratic charge on the gap
   between the interval the displacements realise and the interval the
   spelling states; the gap is the pair's **mistuning**. A placement
   whose spellings agree leaves every spring slack and reproduces the
   lattice's answer; one whose spellings cannot agree — a comma pump's
   loop — spreads the residue across its springs, where the lattice
   held the two ends apart as two states forever.

1. The objective is the box summed over the walk, the mistuning summed
   over the springs, and the pull summed over the strands. The box and
   the pull are the sibling's; the springs' stiffness is a new figure.
   Stiff springs buy the lattice's behaviour — the pump drifts,
   arriving a syntonic comma flat, within 0.7¢ of the lattice's figure
   — and soft ones spread the comma into the intervals at under 2¢
   apiece, so the stiffness is a dial with an audible meaning. It is a
   dial of its own beside the pull rather than one riding the other:
   the pull asks how far a note may stand from where it was written,
   and the stiffness how impure an interval may become, so an author
   owns drift against distribution.

1. The two charges are taken in different units, since they price
   different things. The pull asks whether a note is still the step it
   was written on, which is a question the notation's own spacing
   settles, so it is taken in half-windows, over the half the
   displacement lies in; a note at its window's edge costs the
   strength under any notation. Mistuning is beating between two
   sounding pitches, and knows nothing of how the notation spaces its
   steps, so it is taken in cents against a reference of 50 — what a
   half-window holds in 12-EDO, kept so the stiffnesses measured below
   keep their calibration.

1. With the spellings chosen, the objective is convex and
   box-constrained in the displacements — a quadratic where the
   notation's steps are even, and two quadratics meeting at zero on a
   strand whose window is lopsided — and projected relaxation finds
   its optimum in milliseconds at every size measured. A spelling's box
   does not move with the displacements, so a relaxation never prices
   it; it is charged where the spelling is chosen — in the beam of
   § The candidates, and in the running cost the walk carries. All of
   the model's hardness is the choice of spellings.

## The dials

1. The stiffness is authored as **purity** — how nearly a spelled
   interval sounds pure — and it opens at 8, the figure § Measured takes
   its figures at, over a logarithmic span from 0.5 to 64. Doubling it
   halves the mistuning: a major triad's third stands 3.4¢ wide of a pure
   `5/4` at 1, 0.5¢ at 8 and 0.1¢ at 32, so equal travel along the slider
   buys equal halving. At zero the springs are slack and every note stands
   where it was written, which is the snap the command already offers, so
   the span stops short of it.

1. Purity is the moves facility's alone. A points solve selects among a
   target's points and prices no interval against a spelling, so there is
   nothing there for the dial to hold.

1. Harmonic lock opens at 1 under either facility. The lattice's
   placement rode on a single offset, which halved what a strength bought
   and opened that dial at 1.5 (`design/adaptive-ji.md`
   § The command's slots); the springs carry no offset, and every figure
   measured here is taken at a pull of 1.

## The candidates

1. A sonority's spellings are enumerated by a beam over joins, scored
   by box plus the mistuning the spelling would carry at zero
   displacement. A beam of twelve returns the spelling a full
   enumeration certifies wherever the enumeration is affordable — 1,018
   spellings at five members, 7,950 at six, 73,085 at seven — so the
   width that was the lattice's exponent prices the beam nothing.

1. The score of a spelling is run up join by join rather than taken at
   the end: each join pays the box's widening — a span over some prime
   stretched by the member it admits — and the mistuning of the springs
   the new member makes with those already placed. Both charges are
   additive and neither is negative, so a partial spelling's score is a
   floor under every spelling that completes it, and the beam ranks its
   states by a figure no continuation can undercut.

1. No note leaves the step it was written on: past its half-window some
   other strand of the sonority is the nearer host for the pitch. A
   spelling states intervals and not pitches, so it is placed as a
   whole, at one **offset** — a single displacement of all its members
   from their seats — and it is admitted where some offset seats every
   member inside its own window. The beam anchors on a member
   arbitrarily and carries the interval of offsets still open, narrowing
   it at each join; which member anchored is then no part of the answer.
   A pair may still differ from what was written by the two windows
   between them — a hundred cents in 12-EDO, and less under a notation
   whose steps are finer — so a whole tone under `3/2` and `5/4` alone
   is refused, its nearest move stretching it by 186¢.

1. The gate is the relaxation's own region, taken rigidly. The springs
   move each strand inside its own window and no further (§ The model),
   and a spelling is admitted where one rigid placement of it already
   lies in that region; so what the beam enumerates and what the
   objective is minimised over read the same bounds.

1. A join is one move, and the reach is the move set's own. Members
   that sound do the joining, so an interval the set does not name is
   spelled wherever a third member carries it: a C minor triad under a
   set holding `5/4` and `3/2` spells its E♭ a `5/4` below the G, the
   fifth doing the work. What no chain of sounding members reaches
   would have to be spelled through a phantom strand, which
   `design/adaptive-ji.md` § A placement is connected refuses; an author
   wanting that interval widens the target instead
   (`design/adaptive-tuning.md` § The Tenney ball). The eleven-move set
   § Measured takes its figures over is the ball of radius `15/8` over
   `3/2` and `5/4`, and the same ball at `45/32` holds the two spellings
   of the tritone, so the reach is stated where the target is authored.

1. The displacement never waits, and the spelling may. A strand's
   variable stays free while the strand sounds, so a rolled chord's
   early third is seated by the fifth that arrives after it, and a
   strand that has stopped is data for its successors. Coords are
   another matter: a member joined against an incomplete sonority
   claims an interval the chord has not yet stated, and the rolled C
   minor's opening pair, spelled where it stands, takes its C a `5/4`
   below the E♭ — stretching the pair 86¢ from what was written, which
   the two windows hold between them.

1. A member may therefore be left **unplaced**, taking its coords at a
   later onset from a member it sounds with, which is
   `design/adaptive-ji.md` § A strand may wait carried over. Waiting
   runs while the member has an onset left to sound through and ends at
   that onset, where it places or the state fails; a member the sonority
   holds by recency has stopped, so it is joined to and does not itself
   wait. A member out of waits that joins nothing **refuses** the
   sonority that holds it. An unspelled member states no interval, so it
   is charged none, and a spelling that left one untied would price
   under every spelling that spoke for it; the price of saying nothing
   has to be everything, or saying nothing wins. A bare tritone under a
   5-limit set is then no spelling at all.

1. A waiting member states no interval, so the sonority spelled around
   it is the sonority without it. Waiting is therefore a decision the
   beam makes rather than a set it is handed: a round decides one member,
   joining it by a move to a member already placed or leaving it waiting,
   and one beam over those decisions enumerates a sonority's spellings.

1. The first member to place anchors, and the members before it wait.
   Every move has its inversion, so a spelling stands at as many coords
   as the sonority has members to anchor on — the same intervals read
   from a different member each time — and fixing the anchor at the first
   member to place is what holds a set of waiters to one spelling rather
   than one per member it leaves.

1. A waiting member is charged where it places. Its spelling pays at its
   own onset for what it states — the springs among the members present
   and the box their components carry — and the waiter's own contribution
   to that sonority, its springs against the members it was written with
   and the box its coords widen, falls due at the onset it takes coords
   and is read off the spelling that places it. Those coords arrive in the
   later sonority's frame, and are carried into the earlier one through a
   member the two share. An arpeggio's opening pair is then charged the
   interval the finished chord states rather than one invented before it
   arrived, and the rolled C minor lands where the struck chord lands,
   within a quarter cent of the lattice's answer.

1. Waiting is a candidate rather than a fallback, forked beside the
   placements; it resolves only to coords no earlier sonority could have
   offered, so a spelling is enumerated once however long it waited. What
   an earlier sonority offered is what its beam returned rather than what
   its moves could have reached: the beam is capped, a spelling it cut is
   carried by no branch, and refusing a wait against one would lose that
   spelling. The
   running score is a floor under a spelling's completions, and a
   deferral moves charge out of the floor rather than paying it, so a
   state that waits is no rival to one that spells: the cut runs within a
   waiting count, and the width an author states is a width per count.
   Two states of one count have placed equally many members, which is
   what makes the scores the cut ranks commensurable. Ranked across the
   counts instead, a beam of twelve over five members with four free to
   wait returns twelve states that each defer two members or more, and no
   fully spelled state among them.

1. The refusal falls where the wait resolves rather than where it is
   taken. A completion leaves a placement of the sonority that held the
   waiter, and that placement — each component read from its earliest
   member, which is how the charge reads it — either stands in the
   sonority's own list or does not. A rolled C minor under a set holding
   `6/5` then spells its opening pair where the pair stands, reaching the
   cents and the cost the road that waited reached; under `3/2` and `5/4`
   alone nothing reaches the minor third, so the resolution states
   something new and the wait stands.

1. A completion tied to nothing refuses the road that took the deferral.
   The waiter's coords arrive in the later sonority's frame and reach the
   earlier one through a member the two share; where they share none
   there is no frame to carry them back, and the waiter states no
   interval at the onset it deferred. Two sonorities come to share
   nothing once the walk has turned over between them — a released upper
   note drops out of the sonorities that follow, while the bass that
   sustained under it places in one of them. The price of saying nothing
   is everything wherever it is said, so the road fails here as it fails
   at the beam, and the pair is spelled where it stood.

## The solve

1. The search walks the onsets carrying a set of partial answers, each
   a choice of spellings so far with the displacements the choice
   relaxes to; two answers merge where the strands the future can
   still see agree to half a cent, since what the future reads of a
   past is its cents. A deferral is a debt rather than a saving, so two
   answers agreeing in cents are one answer only where they owe the same
   sonorities the same members. This is the merge the lattice forbade. It is
   also what turns the budget from a refusal into a stopwatch: the
   carried set is capped, and the caps measured — 20 to 200 answers
   abreast, rounding from 0.1¢ to 0.5¢, beams of 24 and 48 — move the
   take's cost by under one percent. The walk takes twenty answers
   abreast and a beam of twenty-four, the cheap end of that band; the
   cost is linear in the cap, and an overlapping arpeggio of four
   voices, whose debts do not settle, runs 12.7 seconds at sixty
   answers where twenty returns the same tuning in 4.1.

1. The cut runs over two pools: the answers that owe nothing, ranked
   among themselves, and the answers that owe, ranked among themselves,
   each pool keeping the cap. A deferral moves charge out of the running
   score rather than paying it, so an answer that owes looks cheaper than
   the one that spelled the same thing where it stood, and a cut ranking
   the two together fills with debtors — 76 of 136 answers three onsets
   into a rolled seventh, and 37,872 of 64,977 by the fifth. The exact
   rule is a pool per outstanding wait, as the beam's cut runs within a
   waiting set; that grain returns what the two pools return on every
   passage measured, and multiplies where the debts do not settle — an
   overlapping arpeggio of four voices owes 2, 6, 24, 120 and 720
   patterns over five onsets — so the walk takes the pair.

1. A relaxation along the walk frees the strands the onset sounds —
   those born there, and those a note carries through it — and the rest
   of an answer stands as data, at the displacements it already
   carries; a member the sonority holds by recency has stopped, so it
   is read and not moved. Freeing every strand at every
   onset, once per carried answer, is where the walk's cost would go,
   and the attenuation § Measured finds running forward runs backward
   as well, so a new onset moves a settled past by little.

1. What the walk has closed, it charges once. A strand sounds over one
   run of onsets, so once the walk is past every strand a sonority
   named, neither that sonority's springs nor the strands they tie can
   move again; the onsets before that cursor — the earliest onset at
   which a strand still sounding was named — are closed, and an answer
   carries what they charge as a running sum rather than retaking it at
   every extension. The relaxation gathers its ties from the same
   cursor, where before it read the whole past: the take's walk visits
   12.4 million springs, of which 3.5 million can still move. Charging
   the closed onsets once, and keying an answer by a strand's position
   in the list its onset reads rather than by its name, returns the
   take's cents unchanged in 4.2 seconds against 6.9.

1. The same run read the other way closes a strand, and the pull is
   charged over it on the same terms. A strand the walk has passed for
   the last time cannot move, so its strain is taken once into the
   carried sum, where before every extension retook the pull on every
   strand of the passage. What the merge key reads shrinks with it: a
   strand no onset has sounded yet stands at zero in every answer
   alike, so the key is the strands the walk has moved that something
   ahead still names, and not the whole future. The take comes back at
   3.3 seconds against 4.2, and a passage eight times its length at
   half what it cost — both terms the two changes drop grew with the
   passage rather than with what was open at the cursor.

1. What every spelling of an onset would tie alike, the answer ties
   once. The relaxation reads an answer's springs as ties per strand,
   and the onsets behind the cursor stand still while the spellings at
   it are tried, so the answer gathers those once and each spelling
   starts from them, tying only what it wrote: its own sonority's
   springs, and those of the deferrals it completed. A candidate ties
   11 of the take's springs where it tied 60, and the take comes back
   in 3.1 seconds against 3.3.

1. An extension that cannot survive the cut is refused before it is
   relaxed. The spring and pull terms are sums of squares, so what an
   answer had closed plus the boxes an extension carries is a floor
   under any cost it can come back with, known before its ties are
   gathered. The bar it is read against — the cost of the cap-th best
   distinct key its pool holds — only falls as a round runs, and the
   keys under it only improve, so a floor that clears the bar marks an
   extension nothing can bring back under the cut. Two extensions in
   three refuse this way, paying for no ties, no relaxation and no
   key, and the take comes back in 1.7 seconds against 3.1.

1. The winner is settled by one joint relaxation over its springs, as
   the lattice settled its winner's offset; what the frozen past gave
   up along the way, that relaxation recovers.

## Measured

The passages are the sibling documents' and the five-part take — 66
notes, forty strands over sixteen sonorities, under its own
eleven-move 5-limit set. All are notated in 12-EDO, where the two
units of § The model coincide; the figures are at stiffness 8 against
pull strength 1, the pump's stiff springs at 40 and its soft at 2.

1. The take. The lattice sweep answers in 63.3s, placing at one offset
   of eleven and carrying every note 40¢ flat; the springs answer in
   1.2 seconds at cost 102.96 against the lattice's 103.18,
   with mean displacement 6.6¢, no note past 11.4¢, and no interval
   more than 0.54¢ from pure.

1. A ii–V–I of sevenths. The walk returns what an exhaustive search
   over its spelling lists returns — 18.3248, over 13,824 choices —
   within 0.66¢ realised of the lattice's answer.

1. A diminished triad, under a set holding `7/4` beside `3/2` and
   `5/4`. The lattice places it only 18.8¢ sharp of where it was
   written, one strand at the edge of its window; the springs seat it
   centred, three cents of stretch across the chord, at a lower cost.
   Under `3/2` and `5/4` alone the chord has no spelling: the tritone
   stands 102¢ from the nearest single move, and the chain through the
   minor third lands 173¢ from where the tritone was written, against
   the hundred cents the windows hold between them.

1. A dominant seventh and a C minor triad land within 0.6¢ of the
   lattice's placements; the comma pump within 0.7¢ under stiff
   springs, closing a syntonic comma flat.

1. Locality. Clamping one strand 10¢ off its optimum moves later
   strands by amounts halving every three to four onsets, under a cent
   by twelve — which is what the merge of § The solve relies on.

## What it costs

1. Exactness. The lattice's intervals were pure by construction; the
   springs' are pure to the stiffness — 0.54¢ at worst over the take
   at the stiffness measured — and an author wanting more turns the
   dial up.

1. The single offset. The lattice stated a passage at one
   displacement, so "the passage sits 14.7¢ sharp" is no longer a
   statement the model makes; every note still keeps the step it was
   written on.

1. The account of a carried strand. A strand present at two onsets is
   spelled at both, and the box charges each onset's spelling; where
   the two disagree the springs arbitrate. This has no counterpart in
   the lattice's one-coord-per-strand account, and it has not been
   squeezed for anomalies.

1. A thin target refuses ordinary chords. A sonority no chain of moves
   seats inside the windows has no spelling, and the walk returns
   nothing for a passage holding one: a diminished triad under `3/2`
   and `5/4` alone is refused, where under a set holding `7/4` it is
   spelled and seated. The springs' tolerance buys no relief, since the
   windows are where that tolerance lives; what the author is told
   instead is § Open's question.

1. The pair a deferral loses. A waiter's charge is read off the spelling
   that places it, so a member of its sonority released before then states
   no interval with it and the pair goes uncharged; a sonority holding a
   waiting member is scored over what still sounds when that member
   arrives. Two members of one sonority that wait and place at different
   onsets would lose their pair the same way, but the first to place finds
   no placed fellow to join, and a completion tied to nothing refuses the
   road that took it (§ The candidates). A rolled dominant seventh under
   the eleven-move set took that road, coming back 2.32 under the road
   that spelled as it went, at a tuning the two agree on within 0.03¢;
   what stands in its place is the road that spelled the pair as it went.

1. The grain of the cut. A width per waiting count is coarser than a
   width per waiting set: two states sharing a count at a round may end
   at different sets, so a spelling can be crowded out by a state that
   goes on to defer more, where a beam of its own would have kept it.
   Nothing measured loses by it, and at infinite width the two grains
   enumerate the same spellings, which leaves the coarser cut
   uncontradicted rather than proved — the footing § Open's certification
   item puts the width itself on.

## Open

1. Where a refusal goes. A sonority no chain of moves connects has no
   spelling, and the walk comes back with nothing for a passage holding
   one, as the lattice refused a passage its moves could not reach. What
   the author is told is unsettled: a thin target refuses ordinary
   chords, and nothing yet carries that back to them.

1. Certification at width. The beam is checked against a full
   enumeration only where the enumeration was affordable; at seven
   members and beyond its answer is uncontradicted rather than proved,
   and a bound on what a wider beam could have found may be worth
   having before the search is trusted there.

1. Whether the cap can come down. The walk's cost is linear in the cap:
   the take answers in 4.1 seconds at twenty answers abreast, 1.3 at
   five and 0.9 at three, at the same cents under every one of them.
   The band § The solve measures found the answer holding from three
   upward on every passage it took, so twenty is a margin rather than a
   figure some passage has asked for; what would settle it is a passage
   where a lower cap loses the answer, or enough passages failing to
   find one. The beam's width is not such a lever — at twelve the take
   moves a strand 41¢, so the beam is doing work at twenty-four.
