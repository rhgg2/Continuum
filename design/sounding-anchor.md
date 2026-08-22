# Sounding anchor — a note is tuned against what sounds, not against the page

> opened: 2026-08-19 · status: in flight — plan/sounding-anchor.md, at
> phase 6 (the dials remeasured)

**The moves solve stops anchoring a note to the step it was written on:
the pull prices drift rather than the window forbidding it, a strand
rests where the music was sitting when its note arrived, and a spring is
charged by whether its two members sound together.**

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
   four abreast were settled by measurement taken with the gate active, so
   both were swept again without it: the beam holds at twenty-four, which is
   what the eighty-eight-note take needs once purity is 16 or more, and the
   walk goes to six abreast (`docs/sonority.md` § The solve).

## Presence

> Landed 2026-08-21; the model is `docs/sonority.md` § The walk.

## Springs price beating

> Landed 2026-08-21; the model is `docs/sonority.md` § The springs.

## The ambient reference

> Landed 2026-08-21; the model is `docs/sonority.md` § The pull and
> § The solve.

## Fixed at birth

> Landed 2026-08-21; the model is `docs/sonority.md` § The solve.

## What the box charges

1. **The box charges what a sonority's coords span on each axis, and not
   what its pairs state.** A span leaves a pair free anywhere inside room
   another member has opened, so a wolf fifth between two members costs
   nothing where a third has widened the 3-axis past it; charging every pair
   the height of the interval it states prices what a span lets through. The
   gain does not reach the count, and the loss reaches the drift.

1. The count barely separates the two. Of the 440 sounding pairs on the take
   of `tests/spikes/springs/take2.lua`, 37 stand a comma or more from any
   5-limit interval under the span box and 39 under every pair-height norm
   from L1 to L∞; the pairwise readings trade fifths for thirds, 6 to 3
   against 24 to 28. A five per cent change of harmonic lock moves the total
   by three, so nothing there stands outside the noise.

1. The norm's shape makes no difference. Summing the pair heights and taking
   the worst reach the same count, and q=1 and q=2 return the same spellings
   and the same displacements to the last figure, differing only in the box's
   scale, which the dials absorb.

1. Drift separates them, and drift is what an ear hears. A step-class wanders
   26.7¢ across the take under the span box, with the passage's centre inside
   −23¢…+6¢; under the widest pair it wanders 42.5¢ and the centre reaches
   −44¢, and under the sum 60.6¢ and −64¢. Charging pairs loosens what holds
   a spelling together.

1. Weighting each pair by the product of its two members' presence improves
   every pairwise box without saving the family. The widest pair goes from 39
   to 34, its wolf fifths from 3 to none, which leads the family on the count;
   it went into the tree and was rejected by ear. A maximum reads the worst
   pair alone, so a spelling may walk its members as far apart as that pair
   already reaches, and a member held by recency is spelled remotely at a
   quarter of the price. The top line sounds sharp and the rest follows it.
   Presence therefore stays out of the box (`docs/sonority.md` § The box).

## The dials

> Landed 2026-08-22; the model is `docs/sonority.md` § The dials.

