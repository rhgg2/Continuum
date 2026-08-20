# Sounding anchor — a note is tuned against what sounds, not against the page

> opened: 2026-08-19 · status: in flight — plan/sounding-anchor.md, at
> phase 3 (presence)

**The moves solve stops anchoring a note to the step it was written on:
the pull prices drift rather than the window forbidding it, a strand
rests where the music was sitting when its note arrived, and a spring is
charged by whether its two members sound together.**

## Where it sits

1. This doc changes where the moves solve anchors a strand. The rest of
   the solve is unchanged, and `docs/sonority.md` describes it and
   supplies this doc's vocabulary.

## The pull in cents

1. The pull's strain is the displacement divided by fifty cents, the
   width of a half-window in 12-EDO. The springs' strain uses the same
   fifty, so purity and lock are measured in one unit.

1. The pull measures cents because a notation's step spacing has nothing
   to do with how far a note has drifted from the music around it. Scale
   the pull to the step spacing instead, and the same drift costs more
   under a fine notation: a lock of 1 charges 6.7 times as much in
   31-EDO as in 12-EDO.

1. `settle` is a weighted mean. A strand settles at `stiffness × seats /
   (stiffness × weight + strength)`; the fifty cancels, since both
   charges divide by it.

1. Only the points solve reads the half-gaps from `tuning.seatWindow`
   now. The grid reports a note's gap in cents instead (§ What the cell
   says).

1. If no chain of moves places a sonority, the solve prices it instead
   of refusing it. An author who dislikes the result turns the pull up.

## What the note remembers

1. A note gains an **intent cents** — the absolute cents of the step it
   was written on, stored as `intentCents` beside its pitch and detune. Where the field is
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

1. What a solve stamps is the seat it measured from, taken under the
   notation in force rather than carried over from the intent the note
   arrived with. The two differ only where the temper has changed since the
   last stamp — a C sharp stamped at 6100 under 12-EDO stands nearest the
   quarter-comma meantone step at 6076.05, and a solve under that notation
   restamps it there — so the field always names a step of the notation that
   wrote it.

1. The field is sparse, and the paths that write it are few. A solve sets
   it on every note it seats, whether or not that note leaves its step, so
   a cell's name never turns on how far the solve happened to move it;
   both facilities set it, a widened points shortlist being as free to
   place a note past its window's edge as a chain of moves is. The
   notation snap reads it and then clears it, seating a note on the step
   its intent names rather than on the step nearest what it sounds, which
   is what reasserting the page means; typing a note over an old one
   clears it.

1. A transpose reads the intent and then discards it. It steps from the
   step the note was written on rather than from where it sounds — a note
   written C and sounding 80¢ sharp would otherwise transpose from C♯ —
   and seats the note on the step it arrives at, the cents a solve found
   for one chord saying nothing about the chord the note is transposed
   into. A move of a whole number of 2/1 octaves is the exception: the
   pitch class is what the solve tuned, so the intent rides up or down
   with the note and the drift is kept.

1. That octave is measured in cents, from the step the note leaves to the
   step it arrives at, rather than in periods of the notation. A period is
   a 2/1 in most notations and the two readings agree there; where it is
   not, four steps of a 300-cent period still make an octave and carry the
   intent, and under thirteen equal divisions of 3/1 no whole number of
   steps makes one, so every transpose there spends it.

1. An octave move keeps a note's drift whether or not an intent stands
   beside it. A note sounds off its step with no intent where the score's
   notation has changed under it, and re-seating such a note on the way
   past would be a snap the author did not ask for.

1. The intent/realisation ladder gains a rung. Detune was intent and
   pitch bend its realisation (`trackerManager.lua:5`); now intent cents
   is the intent, detune realises it against a notation, and pb realises
   detune against a channel.

1. Two functions in the view derive a note's step, and both read the
   intent where it is present: `ctx:noteLabel` names the cell
   (`viewContext.lua:29`), and `ctx:noteDeviation` measures the gap the
   cell reports (`viewContext.lua:36`, § What the cell says). Three in the solve do the
   same: `strandsOf` groups notes into strands by step-class,
   `sonority.seats` reads each strand's seat and window, and `shortlisted`
   names a step the target left nowhere to go, that step being the one whose
   window refused it (`trackerView.lua:2087`, `sonority.lua:684`,
   `trackerView.lua:2111`). The generators derive none: a trill's alternation
   and a chord stamp's rebase are cents offsets from what their host sounds,
   and a derived note's intent is its host's moved by that same offset
   (§ The notation is not a derivation input).

1. A derived note carries an intent of its own rather than its host's. It is
   the host's moved by the cents that note stands off it, so a whole-tone trill
   on a note written C names C, D, C, D across its tiles rather than four C's. A
   chord stamp reads one step out from that: a voice's intent is the trigger's
   plus that voice's own interval from the pattern root, so a triad stamped on a
   note written D names D, F♯ and A wherever a solve has since put the trigger.
   The intent a voice carries in the pattern says nothing here — taken from
   there, the trigger's drift would rename the root while the voices above it
   stood still.

1. What a chain makes of its host is not the solve's to price. The solve reads
   the score's own notes, the host among them; a derivation's output is
   realisation, and it stands outside that reading. An author who wants a
   trill's alternation spelled by a solve freezes the chain first, which makes
   those notes the score's own.

1. The solve is therefore idempotent: a second run reads the same seats,
   groups the same strands, and returns the same cents. That property was
   lost once already, and cheaply — before `tuning.seatWindow` stopped its
   halves a ten-thousandth of a cent inside the edge, a strand pinned to
   the edge read back on its neighbour's step, solved a different chord,
   and left two notes as one (`design/adaptive-tuning.md` § The window).

## What the cell says

1. The cell reports a note's gap in cents. Its name is the step the intent
   names (§ What the note remembers), and beside the name stands a
   **deviation readout** — the signed cents from that step, drawn small in
   two columns against the note. A note standing on its step draws none, and a
   column whose notes all stand on theirs takes no width for the readout.

1. The tick the readout replaces measured the gap as a fraction of the
   step's own room: it normalised by the half-window and clamped the
   result to the edge of the cell, so a note a half-window out and a note
   twice that drew the same tick (`gridPane.lua:793`). That reading held
   while the wall did. With no bound on how far a note may stand from its
   step, an indicator that saturates says least where the note has gone
   furthest.

1. The sign is a tint rather than a glyph, in `colour.tracker.negative`,
   which is what a negative octave and a negative delay already do
   (`docs/tuning.md` § Display). Three digits then fit where two and a
   sign would, and the readout reads a note that has drifted past a
   hundred cents.

1. The readout takes no cursor stop. It is a reading of `(pitch, detune,
   intentCents)` rather than a field of its own — nothing types a
   deviation today, detune arriving from a step's cents or from a retune —
   so the cursor steps from the note to the field beyond it as it does
   now, and the clipboard's lanes are unchanged.

1. A ghost draws the readout as a cell does, and its column pops open to make
   room. A lane whose own notes all stand on their steps reserves no width for
   the readout, while the derived notes displayed over it are the caret's
   business rather than the lane's: the width is taken while a chain's off-step
   ghosts are on show, and given back when the caret leaves them. The readout
   addresses no stop, so nothing the cursor holds moves as that width comes and
   goes.

1. The rule the tick drew across the pitch field becomes the mark of a
   note carrying fx, which the cell drew as a star in the separator the
   readout now occupies (`gridPane.lua:775`). A rule over the note says
   what the star said, and says it over the note rather than in the margin
   beside it.

## The notation is not a derivation input

1. **A notation is read by a gesture and never by a derivation.** Two
   generators break that rule today: a trill stores its alternation as a
   count of scale steps, a chord stamp rebases its pattern by whole steps,
   and both resolve through the active temper on every rebuild
   (`trackerManager.lua:3482`). So a temper change re-sounds derived notes no
   author touched — 12-EDO to 31-EDO takes a trill's whole tone to
   seventy-seven cents — while the authored notes it renames stand where they
   were.

1. What a generator stores is cents. A trill's step count becomes a cents
   demand, and a chord stamp's rebase becomes the cents from its pattern's
   root to the trigger it fires on — `interval`, the module's own helper,
   which `docs/generators.md` § The ctx discipline holds up as the operation
   that looks temper-bound and is not. `ctx` then binds a resolution, the pb
   ceiling and a neighbour lookup, none of them a notation, and `temper`
   leaves `derivationInputs`, so a lens change no longer rewrites the take.

1. A slide's fixed target has stored cents from the start — "a cents demand
   stored temper-agnostically, authored as host-relative temper steps"
   (`design/archive/note-macros.md`) — so the pattern is the house's own, and
   the two readings have sat in one descriptor table since.

1. Steps stay in the input as a ladder. **A step ladder** is a step count
   and a signed cents residual, decomposed against an anchor and stored as
   the one cents demand they sum to: the count says which degree, and the
   residual holds what the notation cannot express. A re-temper re-reads the
   same stored cents, two hundred typed as two steps of 12-EDO reading as
   three steps and ten cents over in 19-EDO, so the reading rebases where the
   sound does not.

1. In an unequal notation a step count is well defined against an anchor and
   not as an interval — two degrees above the fifth step of a Scala scale
   need not span what two degrees above its first span — so the ladder is
   entry alone.

1. The anchor is the host's written step, or the notation's unison where
   there is no host note. An fx region carries a chain with no note of its
   own — a chain's host resolves to a note, a parked cell or a region
   (`trackerView.lua:2640`) — and today's widget falls back to middle C,
   which the region stands in no relation to. A region has no pitch, so its
   notation's unison is the one anchor it has, and the residual reaches
   whatever no count can.

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

1. The gate was holding a second rule the model never stated. A spelling
   states intervals, so nothing in it forbids two members taking the same
   one; a gate placing every member inside its own window forbade that as a
   side effect, two seats a hundred cents apart having no offset that sits
   both within fifty cents of one pitch. Without the gate such a spelling is
   admissible, and on E♭–E–G it wins — the E♭ settling at 6336.4 and the E at
   6340.4, four cents apart on one MIDI pitch. So the model states it
   directly, as **distinctness**: a member takes a spelling no member of its
   component already holds, and a sonority states as many pitches as it has
   members.

1. Distinctness forbids nothing an author could want. `promote` keeps one
   strand per step-class in a sonority (`sonority.lua:102`), so two members
   never share a seat, and a spelling stating a unison between two of them is
   one where two notes of a chord sound as one note.

1. What the gate was doing to the breadth is now measured. It refused a join
   before the join was scored, so removing it widens the set each round
   sorts: the eighty-eight-note take of `tests/spikes/springs/take.lua` costs
   1.8 seconds against 0.57, for the same tuning to the last digit, and a
   five-member sonority over eleven pitches enumerates 1,403,400
   spellings where the gate left 1018. A beam of twenty-four and a walk of
   four abreast were settled by measurement taken with the gate active
   (`docs/sonority.md` § The solve), so both figures are open again, and the
   width is the only bound the breadth has left (§ Open).

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

1. The box keeps its full weight, and has no pair to weight in any case.
   `sonority.score` reads a component's coords as a set — the span on each
   axis its members name, weighted by that axis's height — and returns one
   figure per component, so a product of two presences has nowhere to land.
   The most such a shape could take is a scalar over the whole component,
   which is a different quantity from a spring's weight.

1. A full weight is what the box's job asks for. What the box measures is
   root fusion — how nearly a sonority's notes share a virtual fundamental —
   and the recency tail is in the sonority so that a chord change is scored
   against the chord before it: a spring couples the tuning across that
   change, where the box couples the spelling, being charged over the
   component with the recency members standing in it. A detached line, whose
   every note stops before the next strikes, has the box alone relating note
   two's coords to note one's, its springs all standing at `RECENT` squared,
   and presence at zero decouples the sonorities (§ Presence). A silent
   member beats with nothing, yet it is still part of the harmony an ear is
   holding.

## The ambient reference

1. A strand no longer rests at its seat. Its **rest** is where the music
   was sitting when its note arrived — the mean displacement of the other
   members of the sonority it joins, each weighted by its presence — and
   `sonority.pullCost` charges the strain of `displacement − rest`, that
   gap over fifty (§ The pull in cents), rather than the strain of the
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
   the pull is taken there too (§ The pull in cents), so the two charges
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

1. A lock of zero now leaves a passage unmoored. The pull is the only term
   that reads where the page is — the springs read differences and the box
   reads coords — so at a strength of nothing the objective is flat under a
   translation of every displacement, and the sweep stops wherever it has
   drifted from the start it opened at. The five-part take settles 41¢ flat
   under it, its worst note 82¢ off, which is a figure of the sweep order
   rather than of the music. The clamp bounded that at the window before, so
   the dial's floor is unsettled along with its opening value.

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

1. A note's name and its sound come apart, and the cell reports the gap
   between them in cents (§ What the cell says). What it stops reporting
   is how far through the step's own room the note has gone: a tick on a
   ruler was read at a glance as a fraction of a window, where a figure in
   cents is read against a notation whose step spacing the reader has to
   know. The note column pays a column for the reading.

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
   reads it for the step it steps from and then clears it, and the
   generators' step arithmetic reads it to spell a derived note.

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

1. Where the beam's width should sit, and whether a cap of four still
   answers as the passages measured say it answers. The width was swept
   over the take with the gate gone — 0.34s at four, 0.94 at twelve, 1.82
   at twenty-four and 2.43 at thirty-two, where twelve and twenty-four
   differ by 0.086¢ across sixty-six strands — so what is open is what an
   author buys past twelve. `tests/spikes/springs/cap_sweep.lua` sweeps
   the cap.

1. How far notes actually drift. The pull alone may bound the excursion
   tightly enough that a stored intent rarely differs from the step its
   note would read back as, or the ambient may carry a piece far from the
   page within a few chord changes; the figure decides how much a note's
   name and its sound come apart in ordinary use.

1. Whether a deviation should be typeable. Nothing authors a detune
   numerically today, so a writable readout would be a new gesture rather
   than a convenience on an old one, and what it writes is an intent by
   hand — the name held and the sound bent. How far notes drift decides
   whether an author wants to type these figures.

1. Whether two strands of a sonority crossing is audible, or a curiosity
   of the model (§ What it costs).

1. Whether the box should charge pairs rather than spans. A span box
   charges a sonority what its coords span on each axis, so a pair sits
   anywhere inside room another member has already opened; a wolf fifth
   between two members costs nothing where a third member has widened
   the 3-axis past it. Charging every pair the height of the interval it
   states prices what the span lets through, and on the take of
   `tests/spikes/springs/take2.lua` it takes the sounding pairs a comma
   or more from a 5-limit interval from 72 to 41, the fifths and fourths
   among them from 25 to 3. What it costs is melodic: a step-class
   wanders twice as far across the take, a mean spread of 18.8¢ against
   9.9¢. That freedom is the one § The ambient reference takes away, so
   the two want judging together rather than one before the other. A
   pairwise box has a spring's shape, so presence would have a handle there
   the moment one landed, and the choice carries a second question with it:
   whether such a box prices beating, and takes the same product weight, or
   prices relation, and keeps its full one (§ Springs price beating).
   `tests/spikes/springs/pairwise_box.lua` carries both boxes and the
   dial figures each wants.

1. What the stiff end of a rest between a class's own strands sounds
   like. Tying consecutive strands of a step-class at a delta of
   nothing, inside the search where it can still move a spelling, has a
   limit worth knowing before § The ambient reference is built: at a
   stiffness of eight every class collapses to one tuning across the
   take, which is a fixed twelve-note scale, and the pairs a comma out
   rise from 41 to 50. Applied after the spellings are chosen it splits
   the difference instead — one class's spread falls from 26¢ to 17¢
   while the chords' own springs go from 3.1¢ to 7.5¢ out, and no pair
   leaves the count. An ambient rest is a different construction, yet
   its stiff end is likely the same scale.

1. Whether the command's surface should still offer the old anchor. The
   wall, the absolute reference and the unweighted springs are one
   instrument and this doc describes another; whether an author wants
   both, and under what control, is not settled. Harmonic lock sharpens
   it: one dial serves both facilities, and under the moves facility it
   now charges cents from a rest where under the points facility it
   charges half-windows from a seat, so the same number means two things
   wherever the notation's steps are not a hundred cents apart.

1. What a moves solve does at a take boundary.
   `design/adaptive-tuning.md` § Open item 5 asks this of the model as
   built, and an ambient reference sharpens it: a take's first onset
   asserts the page, so a passage spanning two takes has two anchors
   where the music has one.

1. Whether a notational demand should be nameable. "The degree above
   whatever the host is" is an intent of a different kind from an interval,
   and would be a mode on the field the way a slide's target chooses `Next`
   or `Fixed` (§ The notation is not a derivation input); nothing asks for it
   yet.

1. Where a score follows the page. The retune command re-seats notes onto a
   target notation, so it is the gesture at which the page moves the score,
   and re-reading a step-typed interval there would carry a trill through a
   notation change; a lens change no longer does.
