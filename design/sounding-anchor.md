# Sounding anchor — a note is tuned against what sounds, not against the page

> opened: 2026-08-19 · status: working design; not started

**The moves solve stops anchoring a note to the step it was written on:
the pull prices drift rather than the window forbidding it, a strand
rests where the music was sitting when its note arrived, and a spring is
charged by whether its two members sound together.**

## Where it sits

1. The adaptive solve offers a target under two readings, and this doc
   changes one of them. Under the moves facility a target is read as
   intervals that may be sounded pure between one strand and another,
   and `sonority.solveToMoves` returns the cents each strand settles at;
   under the points facility each strand selects one point of the target
   (`docs/sonority.md`). The points solve is unchanged: its window still
   binds, its shortlist having no other bound, and `tuning.seatWindow`
   goes on returning the same two half-gaps. What changes is who reads
   them, the moves solve stopping and the half-gaps becoming the points
   solve's and the grid's (§ Both wall and ruler). The points solve does
   read an intent where a moves solve has left one (§ What the note
   remembers), the intent being a field on a note rather than on a
   facility.

1. What the moves solve is built from stands unchanged. The strand, the
   walk, the box, the spelling and the beam that enumerates spellings,
   the two-pool cut and the running sum over closed onsets are all as
   `docs/sonority.md` describes them. What changes is where a strand is
   anchored while those machineries run.

1. The vocabulary is `docs/sonority.md`'s throughout — strand, sonority,
   seat, window, displacement, spring, box, pull, strain — and this doc
   defines only the terms it adds.

1. Two questions in `design/adaptive-tuning.md` § Open are settled here,
   for the moves solve alone. Item 7 asks whether the window should bind
   at all, and the answer is that it should neither bind nor measure.
   Item 5 asks what an author is told when a sonority no chain of moves
   can place is refused; with no window to place it inside, that refusal
   does not arise.

## The anchor today

1. The moves solve anchors every strand to the page twice over.
   `sonority.pullCost` charges a strand for standing away from the cents
   of the step its note was written on, and that seat never moves
   (`sonority.lua:347`); `settle` clamps every displacement into the
   strand's own window (`sonority.lua:412`), while the beam refuses a
   spelling that no single offset places inside every member's window
   (`sonority.lua:566`). The reference is thus the page rather than the
   music, and the window is a bound rather than a price.

1. A sonority the target cannot place inside those windows has no
   spelling, and `sonority.solveToMoves` returns nothing for the whole
   passage. A diminished triad under a set holding `3/2` and `5/4` alone
   is refused this way, where under a set holding `7/4` it is spelled and
   seated (`docs/sonority.md` § What it gives up). The refusal falls on
   the passage rather than on the chord that caused it.

1. An author's control over drift runs out at that wall. Purity trades
   drift against distribution smoothly — stiff springs let a comma pump
   arrive a syntonic comma flat, soft ones spread the comma across the
   intervals at under 2¢ apiece — but only as far as the point where a
   displacement meets its clamp, and where that point lies is set by the
   notation's step spacing rather than by anything the music is doing.

1. A passage that has already moved as a body keeps paying for having
   moved. The pull is charged against the written seat whatever the
   strands around a note have done, so it resists the second comma as
   hard as the first.

1. A spring is charged alike whether both its members sound or one of
   them has stopped. `chargeOf` springs every pair of a sonority's placed
   members (`sonority.lua:603`), and a sonority holds both the classes
   still sounding and the last `n` distinct classes struck
   (`docs/sonority.md` § The walk); yet what a spring prices is beating,
   and beating wants two sounding pitches. The set of strands that do
   sound is already computed, and is spent only on deciding which of them
   the relaxation may move (`sonority.lua:701`, `sonority.lua:999`).

1. Behind all of this stands one constraint. A note's step is derived and
   never stored: `tuning.midiToStep` recovers it from `(pitch, detune)`
   by snapping to the nearest step, and `tuning.seat` normalises a solved
   answer so that detune never exceeds a half-semitone and the MIDI pitch
   absorbs the rest (`tuning.lua:833`). A note that leaves its window
   therefore reads back as a different step, and the window's bound is
   what keeps that derivation honest.

## Both wall and ruler

1. The window does two jobs, and both of them end. As a **wall** it
   bounds where a strand may stand, in `settle`'s clamp and in the beam's
   reach; as a **ruler** it is the unit the pull's strain is taken in, a
   displacement being divided by the half-window on the side it points
   toward, so that a strength means one thing under any notation.

1. The wall goes first. `settle` returns its optimum unclamped and the
   beam stops gating a join on reach (§ What the beam loses); a strand at
   its window's edge still pays the strength and a strand at twice that
   pays four times it, so the quadratic runs on past the edge rather than
   stopping there.

1. The ruler is the wall priced rather than enforced, so it goes too.
   Where a displacement starts to cost is set by the half-window it is
   divided by, and a note whose notational neighbours sit close meets its
   resistance early where one under a coarse notation meets it late —
   which is § The anchor today's objection to the clamp, answered by a
   slope in place of a stop. In the quarter-comma meantone MOS a C
   reaching +38.0¢ and −58.6¢ pays 2.4 times as much to drift ten cents
   sharp as ten cents flat; under the ruler a lock of 1 in 31-EDO charges
   6.7 times what the same lock charges in 12-EDO for the same drift.

1. The justification the ruler had is one this doc retires. The pull was
   taken in half-windows because it asked whether a note was still the
   step it was written on, which the notation's own spacing settles,
   where mistuning was taken in cents because beating knows nothing of
   that spacing (`docs/sonority.md` § The springs). Under an ambient
   reference the pull asks how far a note stands from the body of music
   it arrived in, and no notation settles that either.

1. So the pull joins the springs, its strain being `displacement − rest`
   over fifty — what a half-window holds in 12-EDO, held constant so that
   a strength means one thing under any notation. The arithmetic asks for
   the move as well: a ruler branching on the sign of the displacement
   while the strain is measured from a rest is discontinuous at zero, a
   strand whose rest is +30¢ paying `(30/below)²` an instant below it and
   `(30/above)²` an instant above.

1. `settle` collapses to a weighted mean. Both charges carry the same
   fifty, which divides out, and a strand settles at `(stiffness × seats
   + strength × rest) / (stiffness × count + strength)` — what its
   springs ask of it against where the music was, weighted by the two
   dials. The half, the branch that chose it and the clamp leave
   `sonority.lua:405` together, and no term of the objective reads a
   window again.

1. `tuning.seatWindow` is unchanged, and the half-gaps it returns are the
   points solve's and the grid's now. They are still what the deviation
   tick normalises by and still what a points shortlist measures its
   strain against; the moves solve stops reading them, and stops knowing
   how a notation spaces its steps.

1. The refusal collapses into a trade. A sonority no chain of moves
   places inside the windows is now spelled and priced, and an author who
   dislikes where it lands turns the pull up rather than being told the
   passage cannot be solved.

1. A note may now leave the step it was written on. That is what this
   change costs, and § What the note remembers is where it is paid for.

## What the note remembers

1. A note gains an **intent cents** — the absolute cents of the step it
   was written on, stored beside its pitch and detune. Where the field is
   present it is the origin a solve measures displacement from and the
   step the view names the cell from, and `(pitch, detune)` then says only
   where the note sounds. A note no solve has touched carries none, and
   reads as it reads today.

1. This retires a rule stated twice and never hedged: that a step is
   never stored, cents being the source of truth and labels following
   (`design/archive/microtuning.md`), and that the written pitch stays
   recoverable so nothing has to be stashed beside a note to hold it
   (`design/adaptive-tuning.md` § The window). The rule was sound while
   the wall held it up. The objection it carried — that a solver moving a
   note past its window is editing the score rather than tuning it — is
   answered by conceding it: the solve does edit where a note sounds, and
   the wall did not prevent that so much as keep the edit small enough to
   round away. Storing the intent makes the edit legible.

1. Absolute cents rather than a step index, because an index is bound to
   the notation that indexed it. Cents re-read correctly when the active
   temper changes, which is what `(pitch, detune)` does today.

1. The field is sparse, and the paths that write it are few. A moves
   solve sets it on every note it seats, whether or not that note leaves
   its step, so a cell's name never turns on how far the solve happened to
   move it; the notation snap clears it, snapping to the temper being an
   instruction to reassert the page; typing a note over an old one clears
   it. A transpose moves it with the note, and reads the
   intent rather than the sounding pitch, or a note written C and
   sounding 80¢ sharp would transpose from C♯.

1. The intent/realisation ladder gains a rung. Detune was intent and
   pitch bend its realisation (`trackerManager.lua:5`); now intent cents
   is the intent, detune realises it against a notation, and pb realises
   detune against a channel.

1. Two functions in the view derive a note's step, and both read the
   intent where it is present: `ctx:noteLabel` names the cell, and
   `ctx:noteDeviation` measures the gap the grid's tick draws
   (`viewContext.lua:29`, `viewContext.lua:36`). Two in the solve do the
   same: `strandsOf` groups notes into strands by step-class, and
   `sonority.seats` reads each strand's seat and window
   (`trackerView.lua:2087`, `sonority.lua:684`).

1. The solve is therefore idempotent: a second run reads the same seats,
   groups the same strands, and returns the same cents. That property was
   lost once already, and cheaply — before `tuning.seatWindow` stopped its
   halves a ten-thousandth of a cent inside the edge, a strand pinned to
   the edge read back on its neighbour's step, solved a different chord,
   and left two notes as one (`design/adaptive-tuning.md` § The window).

## What the beam loses

1. The beam's reach gate goes with the clamp. A spelling states intervals
   and not pitches, so it is placed as a whole at one offset of all its
   members from their seats; the beam carries the interval of offsets
   still open, narrows it at each join, and abandons a road where the
   interval closes (`sonority.lua:566`). With no window to narrow
   against, the interval never closes and every join is admissible.

1. What survives is the rank. A partial spelling's score is a floor under
   every spelling that completes it, both charges being additive and
   neither negative, so the beam still ranks its states by a figure no
   continuation can undercut (`docs/sonority.md` § The candidates). That
   argument nowhere depends on the gate, and the cut within a waiting
   count is untouched.

1. What the gate was doing to the breadth is not known. It refuses a join
   before the join is scored, so removing it widens the set each round
   sorts, by a factor that depends on the size of the move set and on how
   tightly the notation's windows bound it. A beam of twenty-four and a
   walk of four abreast were settled by measurement taken with the gate
   active (`docs/sonority.md` § The solve), so both figures are open
   again.

## Presence

1. A strand's **presence** at an onset is what it contributes to that
   onset's sonority: full where the strand sounds there, and a constant
   `RECENT` below one where the sonority holds it by recency alone. A
   sonority is the last `n` distinct step-classes struck together with
   every class still sounding (`docs/sonority.md` § The walk), so the
   second case is a class that has stopped and has not yet been displaced
   from the recency list.

1. Presence is an argued constant rather than a dial. Two dials already
   ride the solve, and a third would divide an author's attention without
   buying a decision they are equipped to make; what an author owns is
   drift against distribution, where how much a released note still counts
   is a property of hearing rather than a taste.

1. `RECENT`'s endpoints are known even where its value is not. At one it
   is the model as built, a recency member counting for as much as a
   sounding one. At zero the recency members contribute nothing, the
   sonorities stop being coupled to one another, and the passage falls
   apart into independent solves — the collapse a sonority size at the
   arity itself already produces (`docs/sonority.md` § The walk). The
   useful value therefore stands well clear of zero.

1. Presence is defined once and spent twice: it weights a spring
   (§ Springs price beating), and it weights the mean a strand rests at
   (§ The ambient reference).

## Springs price beating

1. A spring's weight is the product of its two members' presence. Where
   both sound, the spring is charged as it is charged now; where one has
   stopped, `RECENT` of that; where both have stopped, `RECENT` squared,
   which is the weakest constraint the model states.

1. A pair neither of whose members sounds is the faintest thing a
   sonority states, a spring pricing beating and neither pitch being there
   to beat. The product is what gives such a pair its standing, falling
   off once for each silence.

1. The arithmetic stays where it is. `sonority.springCost` multiplies
   each spring's charge by its weight; `sonority.ties` accumulates the
   weights where it now counts springs, and carries a weight beside each
   neighbour it lists; `settle` is unchanged in form, its optimum
   becoming the weighted mean of what a strand's springs ask of it, since
   a count of springs was only ever a sum of unit weights.

1. `joinCost` carries the weight too (`sonority.lua:486`). It prices a
   join's springs at zero displacement in order to rank spellings, and a
   beam ranking by one objective while the search minimises another would
   return spellings the search does not want.

1. The box keeps its full weight. What the box measures is root fusion —
   how nearly a sonority's notes share a virtual fundamental — and the
   recency tail is in the sonority precisely so that a chord change is
   scored against the chord before it. A silent member beats with
   nothing, yet it is still part of the harmony an ear is holding.

## The ambient reference

1. A strand no longer rests at its seat. Its **rest** is where the music
   was sitting when its note arrived — the mean displacement of the other
   members of the sonority it joins, each weighted by its presence — and
   `sonority.pullCost` charges the strain of `displacement − rest`, that
   gap over fifty (§ Both wall and ruler), rather than the strain of the
   displacement alone. A strand does not speak for where it should itself
   stand, so a mean over no other member is zero.

1. The mean runs over the other members alike, the sounding and the
   merely recent. A melodic line sounds one note at a time, so a mean over
   sounding members alone would leave each note of it resting at its own
   seat, and a solo passage would snap back to the page a note at a time;
   taken over the recency members too, each note rests at the running mean
   of the last `n` classes struck, and the line carries its own drift
   forward.

1. Presence divides out where every contributor carries the same one,
   which is what a detached line is: each note has stopped before the next
   strikes, so every contributor is a recency member. Note two of a solo
   rests exactly where note one stands, note three at the mean of one and
   two, and `RECENT` appears in neither figure. The weight tells where the
   textures mix — under a held bass, or where one note of a line laps over
   the next — and a sounding neighbour then speaks louder than a released
   one about where the music currently is.

1. Every strand born at the first onset rests at its own seat. The other
   members it could read are the strands struck beside it, which stand at
   zero until that onset relaxes, and a strand alone there has no others
   to read. That onset is the only place the page is asserted, and
   everything after it is relative to what came before.

1. A silence returns nothing to the page. The recency list is positional
   rather than temporal (`sonority.lua:102`), so the last `n` classes
   struck stand in the sonority however long the gap before the next note,
   and a passage may drift as far from the notation as its harmony takes
   it.

1. The pull no longer says where a sonority sits. That is inherited from
   the sonority before it and traces back to the first onset; what the
   pull says now is how far one note may stand from the body of music it
   arrived in.

## Fixed at birth

1. A rest is read once, when its strand is born, and never moves again.

1. It has to be frozen data, or the objective loses its unique minimum.
   The springs constrain only differences of displacements, and a pull
   charged against a mean of those same displacements is unchanged when
   every strand moves together, so the whole passage could slide by any
   amount at no cost. The relaxation is a sweep of coordinate descent,
   whose answer along such a direction depends on where it started, and
   the invariant that the sweep order and the start buy speed rather than
   the answer would no longer hold (`sonority.lua:416`).

1. Freezing is what the search already affords. A rest is read off
   `answer.displacement` — the displacements the answer carried into the
   onset, before that onset's relaxation runs — so a member still
   sounding, and thus still free to move within the onset, contributes
   its entry value rather than a live one.

1. One rest per strand matches how the pull is already charged. Each
   strand's pull enters an answer's running total exactly once, at the
   onset where it sounds for the last time (`sonority.lua:1007`), so a
   rest per onset would have no slot to be charged in.

1. The rest joins the merge key. Two answers agreeing in cents on every
   strand a later onset names, and owing the same sonorities the same
   members, are one answer today (`docs/sonority.md` § The solve); with
   rests in play they are one answer only where the rests agree too,
   since a strand's rest decides what its pull will cost when it closes.
   The key grows by a figure per open strand, so more answers survive as
   distinct, and the cap's slots go to answers differing in what they owe
   rather than in what they sound like.

1. Where a later onset's members decide a rest, that rest is keyed
   already. `visibleAhead` collects the strands a later onset names,
   reading `members` rather than the sounding subset
   (`sonority.lua:728`), so a strand feeding a future rest by recency is
   one the key already carries.

## The dials

1. Purity is unchanged. It is the springs' stiffness, authored as how
   nearly a spelled interval sounds pure, and it keeps the unit it is
   taken in — cents against a reference of fifty, held constant so that a
   stiffness means one thing under any notation. What has changed is that
   the pull is taken there too (§ Both wall and ruler), so the two charges
   are commensurable and the dials are the weights a strand settles under.

1. Harmonic lock's opening value goes back into play. The lattice this
   model replaced carried a single offset chosen to minimise the pull,
   which left the pull charging the spread of a placement's displacements
   while the mean rode free; a strength then bought less resistance, and
   the dial opened at 1.5 where it now opens at 1
   (`design/archive/adaptive-springs.md` § The dials). An
   ambient reference restores that effect one strand at a time, and the
   change of unit moves the dial again under every notation but 12-EDO,
   so the opening value and the useful span are both unsettled.

1. The moves figures in the record lapse. A major triad's third stands
   3.4¢ wide of a pure `5/4` at purity 1 and 0.5¢ at 8; the five-part
   take's worst mistuning is 0.54¢. Each was taken under a wall, an
   absolute reference and unweighted springs, and neither speaks for the
   model this doc describes. The pull of 0.95 at which a written C7 turns
   from the otonal `4:5:6:7` to the Pythagorean `16/9` stands, being a
   points figure (`tests/specs/sonority_spec.lua:1667`) and so untouched
   here.

1. The change of unit is not what costs the moves figures. That record is
   taken in 12-EDO throughout, where a half-window is fifty cents less a
   hair, so the new ruler is the old one there and every figure holds
   across the change of unit alone; it is the wall, the reference and the
   springs' weights that unsettle them. What the ruler was worth outside
   12-EDO was never measured.

## What it costs

1. A note's name and its sound come apart. The cell keeps the step the
   note was written on, the view reading the intent; what the grid no
   longer tells is how far the note has gone, its deviation tick
   normalising the gap by the half-window and clamping the result to the
   edge of the cell (`gridPane.lua:796`). A note a half-window out and a
   note twice that draw the same tick.

1. A lock means the same in cents under every notation, which tells
   against a fine one. Fifty cents reaches a note's own cell edge in
   12-EDO and a step and a third in 31-EDO, so the dial that lets a
   12-EDO note drift inside its cell lets a 31-EDO note drift into its
   neighbour's, and the gap between a name and a sound widens with the
   notation's fineness. Scaling the pull to the steps is what the ruler
   did, and an author under a fine notation turns the lock up instead.

1. The merge key grows by a rest per open strand (§ Fixed at birth), so
   the walk's cap is spent on answers that differ in a way it could
   previously merge away.

1. Two strands of one sonority may cross. Past its half-window some other
   strand is the nearer host for the pitch, which is an argument the
   springs model gave for the wall (`design/archive/adaptive-springs.md`
   § The candidates), and nothing here holds two strands of a sonority in
   their written order. What that sounds like is not known.

1. The measured record lapses (§ The dials), and with it the two figures
   the search was tuned to — a beam of twenty-four and four answers
   abreast — which were settled with the reach gate active.

1. A dozen sites write a note's detune, and each must be taught what to
   do with the intent beside it. Most copy it or clear it; the transpose
   moves it, and reads it rather than the sounding pitch.

1. Nothing bounds the drift of a long piece but its first onset. A
   passage returning to its opening chord may return to it flat, and no
   term in the objective objects.

## Open

1. What `RECENT` is. The value wants the treatment the other two dials
   had: a passage where it decides between two answers an ear can tell
   apart, and the figure at which the decision turns over. One candidate
   is the D held from D–F–A into G–B♭–D, which keeps the `10/9` the first
   chord gives it because it sounds through the change
   (`docs/sonority.md` § The strand); released exactly as the second
   chord strikes it becomes a recency member, and the value at which it
   stops dragging `10/9` into that chord is the figure wanted.

1. Where harmonic lock now opens, and how far it usefully travels
   (§ The dials).

1. What the beam costs without its gate, and whether a width of
   twenty-four and a cap of four still answer as the passages measured
   say they answer. `tests/spikes/springs/cap_sweep.lua` sweeps the
   second of those.

1. How far notes actually drift. The pull alone may bound the excursion
   tightly enough that a stored intent rarely differs from the step its
   note would read back as, or the ambient may carry a piece far from the
   page within a few chord changes; the figure decides how much a note's
   name and its sound come apart in ordinary use.

1. Whether two strands of a sonority crossing is audible, or a curiosity
   of the model (§ What it costs).

1. Whether the command's surface should still offer the old anchor. The
   wall, the absolute reference and the unweighted springs are one
   instrument and this doc describes another; whether an author wants
   both, and under what control, is not settled. Harmonic lock sharpens
   it: one dial serves both facilities, and under the moves facility it
   now charges cents from a rest where under the points facility it
   charges half-windows from a seat, so the same number means two things
   wherever the notation's steps are not a hundred cents apart.

1. What a moves solve does at a take boundary.
   `design/adaptive-tuning.md` § Open item 6 asks this of the model as
   built, and an ambient reference sharpens it: a take's first onset
   asserts the page, so a passage spanning two takes has two anchors
   where the music has one.
