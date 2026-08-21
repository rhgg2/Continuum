# sonority

The objective an adaptive-tuning solve minimises, the strands it is
taken over, and the two searches that minimise it. Pure module — no
state, and no vocabulary of its own for ratios or cents, which are
`tuning.lua`'s.

The retune command offers one target under two readings, and the
facility slot says which (`docs/trackerView.md` § Retune). Under
`'points'` each strand selects one point of the target and
`sonority.solveToPoints` returns the point per strand; under `'moves'`
the target is read as intervals that may be sounded pure between one
strand and another, and `sonority.solveToMoves` returns the cents each
strand settles at. The strand, the walk, the box and the pull are
shared, each facility charging the pull in a unit of its own (§ The
pull); § The springs onward is the moves facility alone. The
points solve's own machinery — shortlists, the DP over them, and the
widening a refused strand is offered — is `design/adaptive-tuning.md`.

## The strand

1. A **step-class** is a step of the notation together with every step
   an exact octave from it, recovered from a note's written seat
   reduced into the octave. The notes of a step-class that overlap in
   time are a **strand**, and they hold one tuning between them: two
   notes of a class sounding at once at different tunings beat,
   whatever the harmony wants of them.

1. A note that overlaps nothing else in its class starts a strand of
   its own, which retunes freely — one step takes one tuning under the
   ii and another under the V. The release is half-open, so a note
   struck where another is released does not overlap it, and starts a
   strand rather than joining one.

1. The release a strand reads is the one the note sounds to, its render
   clip, rather than the authored ceiling the editor holds. A note
   typed with no OFF carries no ceiling until one is written, and
   reading the ceiling would make it sound for ever: the class
   returning after it merges into its strand, every later sonority
   holds it, and every later onset lets it wait (§ The candidates).

1. A note held across a chord change bends the harmony to it rather
   than the reverse. Under a 5-limit target a D held from D–F–A into
   G–B♭–D keeps the `10/9` the first chord gives it, where restruck it
   would take the `9/8` the second prefers, so the hold costs that
   chord 0.737 of box.

## The walk

1. The cost lives on a whole sonority at once rather than on its
   pairs. The **sonority** current at an onset is the last `n` distinct
   step-classes struck together with every class still sounding, and
   `sonority.walk` returns one per onset.

1. Distinctness is by class, so a block chord and an arpeggio of the
   same chord hand the objective the same set, as do a chord and the
   same chord doubled at the octave. Counting strikes instead would
   spend an entry, on a repeated note, that the harmony has already
   paid for.

1. Where classes strike together the lowest counts as the most recent,
   so a chord released as the next strikes leaves its bass to the
   sonority that follows — in root position, its root. The whole onset
   is absorbed before the sonority is taken, so a chord wider than `n`
   leaves its own lowest notes standing rather than its predecessor's.

1. `n` must exceed the arity of the largest sonority to be recognised
   when spread out in time, and exceed it strictly: at the arity itself
   each sonority displaces its predecessor whole, and the passage falls
   apart into independent solves. A compromise across a chord change
   wants `n` to reach the classes the two chords hold between them, six
   where a C7 resolves to F–A–C.

1. The sonority forgets only what has fallen silent, so a note held
   through the chords behind it drops out of the last `n` struck while
   it still sounds. The coupling usually survives that, each note being
   tuned against its predecessors and so, at one remove, against the
   note still held; what breaks the chain is a run of classes the
   target fixes outright, behind which the answer moves by a syntonic
   comma about one time in seven.

1. A member's **presence** at an onset is what it contributes to that
   onset's sonority: full where its strand sounds there, and a half
   where recency alone holds it, the class having stopped without yet
   being displaced. Presence is a constant rather than a dial: an
   author owns drift against distribution (§ The dials), and how much
   a released note still counts is a property of hearing. The moves
   facility spends it on the springs, which price beating between two
   sounding pitches (§ The springs).

1. The half is argued from its endpoints. At a presence of one a class
   held by recency counts for as much as one that sounds; at zero it
   counts for nothing, the sonorities decouple, and the passage falls
   apart into independent solves, which is the collapse `n` at the
   arity itself produces. The useful value stands well clear of zero,
   and no passage measured tells a half from one — the five-part take
   spells identically under both, though twenty-six of its onset
   memberships are held by recency.

## The box

1. Each pitch of a sonority is a rational number, and its **coords**
   are the exponents of the odd primes in it: `15/8`, which is
   `2⁻³·3·5`, has coords `{3 = 1, 5 = 1}`. Prime 2 is absent, or the
   measure would read spacing rather than harmony — one major triad
   scores 5.91 close, 6.91 in first inversion and 4.91 open, where the
   same triad without prime 2 scores 3.91 in every voicing.

1. A sonority's **box** is what its coords span on each axis, the
   highest exponent less the lowest, and `sonority.score` sums those
   spans weighted by `log₂ p` — the ear's distance to a prime growing
   with its logarithm rather than its size. That figure is the Tenney
   height of the sonority's octave-free `lcm/gcd`, reached without
   forming either integer, so no arithmetic ceiling bounds how far out
   the primes may go.

1. Adding a constant to every coord on an axis leaves that axis's span
   unchanged, so the score is blind to where the sonority sits and the
   model holds no reference pitch. A small box is a sonority whose
   notes share a strong virtual fundamental, so the score measures root
   fusion.

1. Presence does not weight the box (§ The walk). `sonority.score`
   reads a component's coords as a set and returns one figure for the
   whole component, so a product of two members' presence has nowhere
   to land, and a member the sonority holds by recency stands in the
   span at full weight.

1. Full weight is what the measure asks for. The recency tail is in
   the sonority so that a chord change is scored against the chord
   before it: the springs couple the tuning across that change, where
   the box couples the spelling. A member that has stopped beats with
   nothing, and is still part of the harmony an ear is holding.

## The pull

1. The **pull** charges a strand for standing away from the step it was
   written on, quadratically in the **strain** — the displacement taken
   in the unit its facility measures. It is counted once per strand
   rather than once per note, which is what makes an octave doubling
   change no answer: the box already charges a doubling nothing, and
   counted per note the pull would charge it twice.

1. A note's **window** reaches half way to the notation's adjacent step
   either side, and is asymmetric under an unequal scale: in a
   twelve-note quarter-comma meantone MOS, C may move +38.0¢ toward C♯
   and −58.6¢ toward B. It belongs to the points facility and to the
   notation: a points shortlist measures its strain off it, and inside
   it a note keeps its step, `tuning.noteStep` reading that step from
   the intent the note carries, or recovering it by snapping `(pitch,
   detune)` to the nearest where it carries none (`docs/tuning.md`
   § The written step).

1. The edge itself is no place to stand. A note exactly a half-gap out
   is equidistant from two steps, the tie breaks downward, and a cell
   with no intent to read relabels as surely as if the note had moved
   further, so `tuning.seatWindow` stops each half a hair inside the
   edge — a ten-thousandth of a cent. The shortlist's strain is what
   reads those halves; the moves solve reads the seat alone.

1. The two facilities take the strain in units of their own. A points
   solve takes it in half-windows, its shortlist having no other bound,
   so a strand pays for the fraction of its own room it has spent; a
   moves solve takes it in cents over fifty, the fifty the springs are
   charged over (§ The springs), and asks the notation nothing. For ten
   cents of drift a lock of 1 therefore charges a 31-EDO strand 6.7
   times what it charges a 12-EDO strand under the points facility,
   where under the moves facility it charges the two alike.

1. The pull kills comma drift, each note being held near where it was
   written, and it stops the solve collapsing a sonority into a drone,
   the box being globally minimised at zero by putting every note on
   one pitch. Its strength is harmonic lock (§ The dials).

## The springs

1. Under the moves facility a strand carries one variable: its
   **displacement**, signed cents from the seat of the step it was
   written on, which no bound holds and the pull alone resists. Each
   sonority takes a **spelling** — coords per member relative to the
   member that anchors it — which fixes, for every pair it holds, the
   interval that pair would sound if pure.

1. Each spelled pair is a **spring**: a quadratic charge on the gap
   between the interval the displacements realise and the interval the
   spelling states, that gap being the pair's **mistuning**.
   `sonority.springs` reads a spelling off as one delta per pair — the
   difference of the nearest-octave gaps from each member's seat to its
   pure position — so the pair sounds pure where `d[j] − d[i]` is that
   delta.

1. A spring's **weight** is the product of its two members' presence
   (§ The walk), and `sonority.springCost` charges the spring that
   fraction of what it charges a pair that sounds. Where one member
   has stopped the pair is charged a half, and where neither sounds a
   quarter, the falloff running once for each silence: a spring prices
   beating, and a pair neither of whose members sounds is the faintest
   thing a sonority states.

1. A placement whose spellings agree leaves every spring slack; one
   whose spellings cannot agree, as a comma pump's loop cannot, spreads
   the residue across its springs rather than holding the two ends
   apart for ever.

1. The objective is the box summed over the walk, the mistuning summed
   over the springs, and the pull summed over the strands. A spelling's
   box does not move with the displacements, so a relaxation never
   prices it: it is charged where the spelling is chosen (§ The
   candidates, § The solve).

1. Mistuning is beating between two sounding pitches, and knows nothing
   of how the notation spaces its steps, so it is taken in cents
   against a reference of 50 — what a half-window holds in 12-EDO, held
   constant so that a stiffness means one thing under any notation. The
   pull is taken there too (§ The pull), so the two charges are
   commensurable and the dials are the weights a strand settles under.

1. With the spellings chosen the objective is a convex quadratic in the
   displacements, with no bound on them and no branch in it, so
   `sonority.relax` sweeps strand by strand to the optimum: each strand
   settles at the weighted mean of what its springs ask of it and the
   seat it was written on — each ask weighted by its spring's weight,
   the two dials weighting the two terms, and the fifty both charges
   are taken over dividing out. The sweep order and the start buy
   speed rather than the answer, and `sonority.ties` pre-sums the asks
   and the weights they carry, since the strands a sweep holds still
   stand still while it runs.

## The candidates

1. A sonority's spellings are enumerated by a **beam** over joins: a
   round decides one member — joined by a move to a member already
   placed, or left waiting — and every road decides the same members,
   so two orders reaching one spelling collapse where they land. A beam
   of twelve returns the spelling a full enumeration certifies wherever
   the enumeration is affordable, which is 456 spellings for four
   members under a target of three pitches; five members under eleven
   pitches is 1,403,400 spellings, and a minute to walk them.

1. The score of a spelling is run up join by join rather than taken at
   the end: each join pays the box its component widens by, and a
   spring against each member already placed, both priced at zero
   displacement and the springs weighted as the relaxation weights
   them (§ The springs). A beam ranking by one objective while the
   search minimises another would return spellings the search does not
   want. Both charges are additive and neither is negative, so
   a partial spelling's score is a floor under every spelling that
   completes it, and the beam ranks its states by a figure no
   continuation can undercut.

1. A join is one move, and the reach is the move set's own. Members
   that sound do the joining, so an interval the set does not name is
   spelled wherever a third member carries it: a C minor triad under a
   set holding `5/4` and `3/2` spells its E♭ a `5/4` below the G, the
   fifth doing the work. A pair no chain reaches from nearby is spelled
   at what the set does name and priced for the stretch: a tritone under
   that set comes back as a fourth, standing 102¢ from where it was
   written. What
   has no spelling is a sonority under a target that states no move at
   all, and `sonority.solveToMoves` answers nil for the passage holding
   it.

1. Coords are differences, so two chains arriving at one spelling have
   to key alike: `joinCoords` drops a prime whose exponents cancel, and
   `rebase` reads a member in another member's frame by one vector
   shift.

1. A spelling states intervals and not pitches, so it stands at any
   **offset** of its members from their seats, and no offset is any
   part of it. The beam anchors on the first member to place and joins
   the rest to it, so which member anchored decides nothing, and where
   a spelling then stands is the relaxation's business rather than the
   beam's.

1. What two members may not take is one spelling. Nothing in the
   objective forbids it, and on E♭–E–G such a spelling wins, the two
   settling four cents apart on one MIDI pitch; so the model states
   **distinctness** directly — a member takes a spelling no member of
   its component already holds, and a sonority states as many pitches
   as it has members.

1. Distinctness forbids nothing an author could want. `promote` keeps
   one strand per step-class in a sonority, so two members never share
   a seat, and a spelling stating a unison between two of them is one
   where two notes of a chord sound as one note.

1. The displacement never waits, and the spelling may. A strand's
   variable stays free while the strand sounds, so a rolled chord's
   early third is seated by the fifth that arrives after it; coords are
   another matter, since a member joined against an incomplete sonority
   claims an interval the chord has not yet stated. A member may
   therefore be left **unplaced**, taking its coords at a later onset
   from a member it sounds with: spelled where it stands, the rolled C
   minor's opening pair takes its C a `5/4` below the E♭, stretching
   the pair 86¢ from what was written.

1. Waiting runs while the member has an onset left to sound through and
   ends at that onset, where it places or the state fails; a member the
   sonority holds by recency has stopped, so it is joined to and does
   not itself wait. An unspelled member states no interval, so it is
   charged none, and a spelling that left one untied would price under
   every spelling that spoke for it — the price of saying nothing has
   to be everything, or saying nothing wins. A member out of waits that
   joins nothing therefore refuses the sonority that holds it, and a
   bare tritone under a 5-limit set is no spelling at all.

1. The first member to place anchors, and the members before it wait.
   Every move has its inversion, so a spelling stands at as many coords
   as the sonority has members to anchor on, and fixing the anchor at
   the first member to place is what holds a set of waiters to one
   spelling rather than one per member it leaves.

1. A waiting member is charged where it places: its springs against the
   members it was written with, and the box its coords widen, fall due
   at the onset it takes coords and are read off the spelling that
   places it. Those coords arrive in the later sonority's frame and are
   carried back through a member the two share; where the two share
   none there is no frame to carry them, the waiter states no interval
   at the onset it deferred, and the road fails there as it fails at
   the beam. An arpeggio's opening pair is then charged the interval
   the finished chord states rather than one invented before it
   arrived, and the rolled C minor lands where the struck chord lands.

1. Waiting is a candidate rather than a fallback, forked beside the
   placements, and it resolves only to coords no earlier sonority could
   have offered — what an earlier sonority offered being what its beam
   returned rather than what its moves could have reached. A deferral
   moves charge out of the running score rather than paying it, so a
   state that waits is no rival to one that spells: the cut runs within
   a waiting count, and the width an author states is a width per
   count. Two states of one count have placed equally many members,
   which is what makes the scores the cut ranks commensurable; ranked
   across the counts instead, a beam of twelve over five members with
   four free to wait returns twelve states that each defer two members
   or more, and no fully spelled state among them.

## The solve

1. `sonority.search` walks the onsets carrying a set of partial
   **answers**, each a choice of spellings so far with the
   displacements that choice relaxes to. Two answers merge where the
   strands the future can still see agree to half a cent, since what
   the future reads of a past is its cents; a deferral is a debt rather
   than a saving, so two answers agreeing in cents are one answer only
   where they owe the same sonorities the same members.

1. The carried set is capped, and the cut runs over two pools — the
   answers that owe nothing and the answers that owe, each keeping the
   cap. A deferral moves charge out of the running score rather than
   paying it, so an answer that owes looks cheaper than the one that
   spelled the same thing where it stood, and a cut ranking the two
   together fills with debtors: 76 of 136 answers three onsets into a
   rolled seventh, and 37,872 of 64,977 by the fifth. The exact rule
   would be a pool per outstanding wait, as the beam's cut runs within
   a waiting count; that grain returns what the two pools return on
   every passage measured, and multiplies where the debts do not
   settle, so the walk takes the pair.

1. A relaxation along the walk frees the strands the onset sounds —
   those born there, and those a note carries through it — and the rest
   of an answer stands as data, at the displacements it already
   carries. Freeing every strand at every onset, once per carried
   answer, is where the walk's cost would go, and it buys little:
   holding one strand 10¢ off its optimum moves later strands by
   amounts halving every three to four onsets, and that attenuation
   runs backward as well, so a new onset moves a settled past by
   little.

1. What the walk has closed, it charges once. A strand sounds over one
   run of onsets, so once the walk is past every strand a sonority
   named, neither that sonority's springs nor the strands they tie can
   move again: the onsets before that cursor are closed, and an answer
   carries what they charge as a running sum rather than retaking it at
   every extension. The pull is charged over a closed strand on the
   same terms, and the merge key shrinks with it — a strand no onset
   has sounded yet stands at zero in every answer alike, so the key is
   the strands the walk has moved that something ahead still names.

1. What every spelling of an onset would tie alike, the answer ties
   once. The onsets behind the cursor stand still while the spellings
   at it are tried, so an answer gathers those ties once and each
   spelling starts from them, tying only what it wrote: its own
   sonority's springs, and those of the deferrals it completed.

1. An extension that cannot survive the cut is refused before it is
   relaxed. The spring and pull terms are sums of squares, so what an
   answer had closed plus the boxes an extension carries is a floor
   under any cost it can come back with, known before its ties are
   gathered; the bar it is read against — the cost of the cap-th best
   distinct key its pool holds — only falls as a round runs, and the
   keys under it only improve, so a floor above the bar marks an
   extension nothing can bring back under the cut. Two extensions in
   three refuse this way, paying for no ties, no relaxation and no key.

1. The walk takes four answers abreast and a beam of twenty-four. Every
   passage measured returns the same cents from three abreast upward at
   that beam, where two abreast loses them, and an eighty-eight-note
   take answers in 1.7 seconds. The two figures are not independent: at
   a beam of forty-eight the five-part take wants more than four
   abreast, the spellings the wider beam admits crowding the capped
   walk. What would settle the cap is a passage that loses the answer
   at the beam the walk actually takes, which
   `tests/spikes/springs/cap_sweep.lua` sweeps for.

1. The winner is settled by one joint relaxation over its springs,
   which recovers what the frozen past gave up along the way;
   `sonority.solveToMoves` then seats each strand at its own seat plus
   the displacement that relaxation returns.

## The dials

1. **Harmonic lock** is the pull's strength, a field on the retune
   modal set per invocation, and it opens at 1 under either facility. A
   written C7 sounding alone takes the otonal `4:5:6:7` below a pull of
   0.95 and the Pythagorean `16/9` above it, trading 0.36 of box
   against 27¢ of fidelity, so 1 is where the commonest trade turns
   over and the useful travel is roughly 0 → 2. At the free end several
   tunings score alike and the winner is arbitrary rather than musical;
   at the stiff end the solve is a no-op.

1. **Purity** is the springs' stiffness, authored as how nearly a
   spelled interval sounds pure, and it opens at 8 over a logarithmic
   span from 0.5 to 64. Doubling it halves the mistuning — a major
   triad's third stands 3.4¢ wide of a pure `5/4` at 1, 0.5¢ at 8 and
   0.1¢ at 32 — so equal travel along the slider buys equal halving. At
   zero the springs are slack and every note stands where it was
   written, which is the snap the command already offers, so the span
   stops short of it.

1. Purity is the moves facility's alone: a points solve selects among a
   target's points and prices no interval against a spelling, so there
   is nothing there for the dial to hold. The two are dials of their
   own rather than one riding the other — the pull asks how far a note
   may stand from where it was written, and the stiffness how impure an
   interval may become — so an author owns drift against distribution.

## What it gives up

1. The step a note was written on. Nothing walls a note inside it, the
   pull pricing the drift rather than a bound stopping it, so a note's
   name and its sound come apart and the cell reports the gap in cents
   (`docs/tuning.md` § The written step). Over the five-part take at
   purity 8 and a lock of 1, a strand stands 6.57¢ from its seat on
   average and none stands past 11.4¢.

1. The order two strands were written in. Past its own half-window some
   other strand is the nearer host for a pitch, and nothing holds two
   strands of a sonority in the order their steps stand in, so they may
   cross; what that sounds like is not known.

1. Exactness. A spelled interval is pure to the stiffness rather than
   by construction, 0.63¢ at worst over the five-part take at purity 8,
   and an author wanting more turns the dial up.

1. A statement about the passage. The moves solve places no passage at
   a single displacement, so "the passage sits 14.7¢ sharp" is not a
   thing the model says; what it holds instead is a pull per strand
   toward the step its own note was written on.

1. One account of a carried strand. A strand present at two onsets is
   spelled at both, and the box charges each onset's spelling; where
   the two disagree the springs arbitrate. That has no counterpart in a
   one-coord-per-strand account, and it has not been squeezed for
   anomalies.

1. The pair a deferral loses. A waiter's charge is read off the
   spelling that places it, so a member of its sonority released before
   then states no interval with it and the pair goes uncharged; a
   sonority holding a waiting member is scored over what still sounds
   when that member arrives.

1. The grain of the cut. A width per waiting count is coarser than a
   width per waiting set, since two states sharing a count at a round
   may end at different sets, so a spelling can be crowded out by a
   state that goes on to defer more. Nothing measured loses by it, and
   at infinite width the two grains enumerate the same spellings.
