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

## The candidates

1. A sonority's spellings are enumerated by a beam over joins, scored
   by box plus the mistuning the spelling would carry at zero
   displacement. A beam of twelve returned the spelling a full
   enumeration certifies at the widths where a full enumeration was
   affordable — 2,342 spellings at five members, 31,642 at six — and
   the full count reaches 532,244 at seven; the width that was the
   the lattice's exponent prices the beam nothing.

1. The score of a spelling is run up join by join rather than taken at
   the end: each join pays the box's widening — a span over some prime
   stretched by the member it admits — and the mistuning of the springs
   the new member makes with those already placed. Both charges are
   additive and neither is negative, so a partial spelling's score is a
   floor under every spelling that completes it, and the beam ranks its
   states by a figure no continuation can undercut.

1. A join may seat a member two half-windows from where it was written,
   and no further: the neighbouring step, past which some other strand
   of the sonority is the nearer host for the pitch. In 12-EDO that
   reach is a whole tone, which is what § Measured's figures were taken
   under; under a notation whose steps are finer it narrows with them.

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
   below the E♭ — 86¢ from where the C was written, which the
   two-half-window reach admits.

1. A member may therefore be left **unplaced**, taking its coords at a
   later onset from a member it sounds with, which is
   `design/adaptive-ji.md` § A strand may wait carried over. Waiting
   runs while the member has an onset left to sound through and ends at
   that onset, where it places or the state fails; a member the sonority
   holds by recency has stopped, so it is joined to and does not itself
   wait. A member out of waits that joins nothing stands alone as a
   **component** — a group of members the box scores and the springs tie
   within, and across which neither charges — which the beam admits as a
   third way to resolve a member rather than as a pass that follows it.
   A bare tritone under a 5-limit set is then two components of one
   member each, and comes back with no spring and no box (§ Open 2).

1. A waiting member states no interval, so the sonority spelled around
   it is the sonority without it: the beam runs over the members that
   remain, the first of them anchoring, and enumerating a sonority's
   spellings is running that beam once per set of members left waiting.

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
   waiting set, and the width an author states is a width per set.
   Ranked across the sets instead, a beam of twelve over five members
   with four free to wait returns twelve states that each defer two
   members or more, and no fully spelled state among them.

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
   take's cost by under one percent.

1. A relaxation along the walk frees the strands the onset sounds —
   those born there, and those a note carries through it — and the rest
   of an answer stands as data, at the displacements it already
   carries; a member the sonority holds by recency has stopped, so it
   is read and not moved. Freeing every strand at every
   onset, once per carried answer, is where the walk's cost would go,
   and the attenuation § Measured finds running forward runs backward
   as well, so a new onset moves a settled past by little.

1. The winner is settled by one joint relaxation over its springs, as
   the lattice settled its winner's offset; what the frozen past gave
   up along the way, that relaxation recovers.

## Measured

The passages are the sibling documents' and the five-part take — 43
notes, thirty strands over sixteen sonorities, under its own
eleven-move 5-limit set. All are notated in 12-EDO, where the two
units of § The model coincide; the figures are at stiffness 8 against
pull strength 1, the pump's stiff springs at 40 and its soft at 2.

1. The take. The lattice sweep answers in 63.3s, placing at one offset
   of eleven and carrying every note 40¢ flat; the springs answer in
   one to three seconds at cost 97.78 against the lattice's 103.18,
   with mean displacement 5.7¢, no note past 22¢, and no interval more
   than 1.69¢ from pure.

1. A ii–V–I of sevenths. The walk returns what an exhaustive search
   over its spelling lists returns — 18.3248, over 13,824 choices —
   within 0.66¢ realised of the lattice's answer.

1. A diminished triad. The lattice places it only 18.8¢ sharp of where
   it was written, one strand at the edge of its window; the springs
   seat it centred, three cents of stretch across the chord, at a
   lower cost.

1. A dominant seventh and a C minor triad land within 0.6¢ of the
   lattice's placements; the comma pump within 0.7¢ under stiff
   springs, closing a syntonic comma flat.

1. Locality. Clamping one strand 10¢ off its optimum moves later
   strands by amounts halving every three to four onsets, under a cent
   by twelve — which is what the merge of § The solve relies on.

## What it costs

1. Exactness. The lattice's intervals were pure by construction; the
   springs' are pure to the stiffness — 1.69¢ at worst over the take
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

1. The pair a deferral loses. A waiter's charge is read off the spelling
   that places it, so a member of its sonority released before then states
   no interval with it and the pair goes uncharged; a sonority holding a
   waiting member is scored over what still sounds when that member
   arrives.

## Open

1. Refusal. The lattice refused a passage its moves could not reach;
   here a sonority with no spelling falls back to components with no
   spring and no box, so a bare tritone under a 5-limit set places
   silently where it refused loudly. Whether silence is the right
   account of "nothing pure to say here" is unsettled.

1. Certification at width. The beam is checked against a full
   enumeration only where the enumeration was affordable; at seven
   members and beyond its answer is uncontradicted rather than proved,
   and a bound on what a wider beam could have found may be worth
   having before the search is trusted there.

1. The price of deferral. A waiter pays every sonority it held once it
   places, so waiting saves no charge in the end; what it moves is when
   the charge is read, and the walk ranks its answers on a running score
   the outstanding charges sit outside. An answer that owes therefore
   looks cheaper than one that has paid, and the cap keeps it in
   preference; the beam guards against exactly this by cutting within a
   waiting set, and the walk has no such rule. It shows in the figures: a
   rolled triad over three bars under pure fifths and thirds comes back
   at 40.61 with the debts carried in the merge key against 38.98 with
   the key blind to them, more answers abreast not being the same as the
   right ones. Whether the walk wants the beam's rule, a floor on what an
   outstanding debt will come to, or neither, is unsettled.
