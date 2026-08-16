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
   apiece, so the stiffness is a dial with an audible meaning.

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

1. A join may compose two moves. An interval the set does not hold is
   then still a spelling between two strands — a C minor triad under a
   set holding `5/4` and `3/2` spells its E♭ a `5/4` below the G even
   where the two never sound together — and the box prices the
   composed reach, so a far-fetched spelling loses to a near one by
   cost rather than by rule.

1. Nothing waits. A strand's variable stays free while the strand
   sounds, so a rolled chord's early third is seated by the fifth that
   arrives after it, and a strand that has stopped is data for its
   successors. The rolled C minor lands within a quarter cent of the
   lattice's answer.

## The solve

1. The search walks the onsets carrying a set of partial answers, each
   a choice of spellings so far with the displacements the choice
   relaxes to; two answers merge where the strands the future can
   still see agree to half a cent, since what the future reads of a
   past is its cents. This is the merge the lattice forbade. It is
   also what turns the budget from a refusal into a stopwatch: the
   carried set is capped, and the caps measured — 20 to 200 answers
   abreast, rounding from 0.1¢ to 0.5¢, beams of 24 and 48 — move the
   take's cost by under one percent.

1. A relaxation along the walk frees only the strands born at the
   onset it extends; the rest of an answer stands as data, at the
   displacements it already carries. Freeing every strand at every
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

## Open

1. Harmonic lock. The dial's meaning was fixed against placements pure
   by construction; with purity graded there are two strengths — the
   pull's and the springs' — and whether both surface, one rides the
   other, or the stiffness stays a constant is unsettled. The comma
   figures are the case for surfacing the stiffness: drift against
   distribution is a choice an author might want to own.

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
