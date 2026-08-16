# Ratio lens — a note read as an interval from an anchor

> opened: 2026-08-16 · status: working design; not started
>
> A sibling of `design/adaptive-ji.md`, which owns the solve this reads
> without running. `docs/tuning.md` § Display holds the cell budget it
> must live inside.

**A note is read as the interval it makes with an anchor note on the
take: the nearest ratio in the two-step closure of a temper's moves,
with the cents it misses by, so that harmony can be looked at rather
than solved for.**

## Where it sits

1. The tracker reads a note as a position and never as a relation.
   `viewContext` offers two lenses onto a pitch cell: `noteLabel` spells a
   note's `(pitch, detune)` as a step name and an octave under the bound
   temperament, and `noteDeviation` reports how far off that step the note
   sits. Both are pure coordinate queries, and both take the temperament
   as their only other argument.

2. A just third and a Pythagorean third above C are 22¢ apart, and under
   12-EDO both seat on E. The two cells read `E-4` either way, and each
   note's deviation is measured from its own step rather than from the C
   below it.

3. `design/adaptive-ji.md` computes the relation already. Its solver
   assigns each strand coords — a vector of prime exponents naming a ratio
   — and the intervals between those coords are the answer. The answer is
   internal to a solve, however: it is reached by running the retune
   command, and it becomes visible only by being committed as detune.
   There is no way to look at the harmony one has.

4. A third lens joins the two. It is a **reading** — a pure query taking
   a note and returning the interval that note makes with another, phrased
   as a ratio. Nothing is stored, and no note moves.

## The anchor is a note

1. A reading is taken against an **anchor**: one note of the take,
   chosen by the author, against which every other note is read. The
   anchor read against itself gives 1/1, so it confirms its own binding.

2. The anchor is held as a uuid rather than as a cents value. A snapshot
   of the anchor's cents can come apart from the note it was taken from —
   nudge that note and the lens goes on reading against a value nothing on
   the grid holds — where a uuid keeps the two together, and nudging the
   anchor shifts every residual on screen by the same amount.

3. That is the house handle for a note: `uuid, not the event, is the
   durable handle` (`trackerView.lua:2636`), and the fx strip pins its
   host by uuid and meets deletion by lookup returning nil rather than by
   invalidation (`trackerRender.lua:237`, `trackerView.lua:2597`). The
   lens takes the same course. An anchor whose note has gone resolves to
   nil and the lens reads nothing, rather than choosing a new anchor.

4. The anchor is view state and is not persisted, which follows from the
   lens being a reading: no note carries a ratio, and no take records that
   one was ever taken.

## A reading is a fit

1. Cents do not determine a ratio. Any interval lies within a comma of
   infinitely many ratios, so a reading cannot be computed from the cents;
   it is a **fit** — the nearest member of a set stated in advance.

2. Someone might say the set need not be stated, since the simplest
   ratio near an interval can be searched for, weighting error against
   complexity. In some sense this is right, and it fails on the numbers.
   Under octave-free Tenney height bounded at 10, the nearest ratio to
   12-EDO's fifth is 767/512 — a fit accurate to a third of a cent, and
   useless. Raise the bound and the error goes to zero while the labels
   become a way of spelling a decimal in fractional form; lower it and the
   vocabulary keeps 64/61 and 128/87, which name nothing a musician hears.

3. So the set is stated rather than searched, and two things follow. A
   fit has a **tolerance**, the widest error it will accept; and a reading
   may be **blank**, where no member of the set falls within it. A blank
   is a determinate answer — nothing in this vocabulary is near — rather
   than a failure to answer.

## The vocabulary is a temper's two-step closure

1. The set read against is a **move set**: a temper whose every pitch is
   a ratio, read as intervals from its unison. `tuning.moves` builds one
   already — every pitch and its inversion, deduped by coords, cents
   octave-reduced, simplest first by height — and `tuning.isTarget` is the
   test a temper must pass to serve as one.

2. The move set is the lens's own slot rather than the displayed
   temperament. A display temper is commonly an EDO whose pitches are
   `n\m` tokens, which carry no coords and fail `isTarget`; and the case
   worth having is precisely a 31-EDO grid read against 7-limit ratios. So
   the lens names its own temper, and the two vary independently.

3. A move set alone is too thin to read a passage with. Take
   `{3/2, 5/4, 7/4}`: with inversions that is six intervals, and 901 of
   the octave's 1200 cents fall outside a 25¢ tolerance of any of them. A
   grid read against it is nearly all blank.

4. The set is therefore closed under one composition: every product of
   two moves joins the moves themselves, deduped by coords as before.
   This is the **two-step closure**, and its **depth** is the number of
   moves a reading may compose. It is the reachable set of
   `design/adaptive-ji.md` § The target becomes a move set, cut off at two.

5. Closing `{3/2, 5/4, 7/4}` gives 25 intervals, against which 12-EDO
   reads:

   ```
   1/1  16/15-12  9/8-4  6/5-16  5/4+14  4/3+2  7/5+17  3/2-2  8/5-14  5/3+16  16/9+4  15/8+12
   ```

   Each is an interval with a name, and the bands are wide: 31 label
   changes across the octave, so a one-cent nudge rarely moves a note from
   one reading to another.

6. What the depth excludes is the point. 81/64 is four fifths, so the
   closure does not hold it, and 12-EDO's third reads `5/4+14` rather than
   `81/64-8`. A search weighted by height prefers the second, it being
   nearer; the closure never offers it. The bound on complexity is thus
   stated in the intervals the author chose, rather than as a threshold on
   a number they did not.

7. The closure earns its keep for a small move set and oversaturates a
   large one: closing an 11-limit set of four moves gives 41 intervals,
   which at a 25¢ tolerance leaves 44 of 1201 cents blank, and a lens that
   labels everything says little by labelling. What sets the tolerance is
   § Open.

## The deviation belongs to the label

1. A ratio on its own asserts a purity the note does not have. 12-EDO's
   major third is 400¢ and 5/4 is 386¢, so a cell reading `5/4` says the
   note is just, and the note is 14¢ from just.

2. The reading is therefore a pair — the ratio, and the **residual**,
   the signed cents by which the note misses it — and the ratio does not
   appear without it. `5/4+14` is a true statement about a 12-EDO third;
   `5/4` is not.

3. This is `noteDeviation` in another frame. That lens reports the gap
   from the note's seat in the scale, and this one the gap from the ratio
   it is nearest; both say how far a note sits from a nominal position,
   one in the scale and one in the harmony.

## What the grid can hold

1. `cellWidth` is exact. It is derived as the widest step label plus the
   octave field, sized from the octave numbers at the two ends of the
   addressable range (`docs/tuning.md` § Display), and the pitch cell
   holds a step name and an octave. Nowhere does the tracker put a number
   on pitch: `noteDeviation` is drawn as a tick on a ruler
   (`gridPane.lua:793-799`), and the two per-cell glyphs — delay
   divergence and fx presence — are stars at fixed offsets.

2. A ratio and its residual do not fit that budget. `5/4+14` is six
   characters against three for `C-4`, and the octave field is spoken for.
   The reading needs room the pitch cell has not got; where it goes is
   § Open.

3. What does fit is a tint. Colour costs no columns, and the repo
   already carries distinctions that way: a negative octave renders as its
   magnitude tinted in `colour.tracker.negative`, and a shadowed sample
   and a negative delay tint likewise. A declared colour key beside those
   is available to the reading without widening anything.

## Depth and rebinding are one dial

1. A fixed anchor reads a modulating passage at increasing depth. A
   chord a fifth from the anchor has its own third two moves out rather
   than one; a further modulation puts that third past the closure, and
   the cell goes blank. The answer is to **rebind** — to bind the anchor
   to a note of the passage one is now in.

2. Depth is drawn as tint, so the three things a reading can say are
   three things one can see:

   ```
   5/4+14     one move from the anchor
   7/5+17     two moves          (tinted)
   --         further than the closure reaches
   ```

3. The closure depth and the rebinding gesture are one dial seen from
   its two ends. The depth says how far from the anchor a reading is still
   given; the rebinding says how far the author lets the music travel
   before moving the anchor. A blank is not a gap in the lens, then, but
   the lens reporting that the anchor has been left behind.

## Open

1. Where the reading renders. The pitch cell has no room for it (§ What
   the grid can hold), and the candidates differ in what they cost: a
   column of its own widens the grid for every take; the status bar
   carries the cursor note alone, and is a per-frame `printf` until
   `design/status-bar.md` makes it a declared segment; a pane costs a
   place to put it.

2. Whether a note below the anchor reads octave-reduced or literally. A
   fifth below the anchor is `3/2` under the first reading and `2/3` under
   the second. Reduction matches how the vocabulary is built, `tuning.moves`
   reducing every move's cents into the octave; the literal ratio matches
   what sounds.

3. What sets the tolerance, and whether a vocabulary that saturates the
   line should force it down. 25¢ against the closure of three moves
   leaves a fifth of the octave blank, and the same tolerance against four
   moves leaves almost none.

4. Whether the anchor is one per take or one per channel. A bass line
   and a lead read against the same origin under the first, which is what
   a fixed origin is for; the second lets two parts be read in their own
   terms at the cost of the reading no longer being comparable across the
   grid.

5. Whether repeated rebinding wants an **anchor lane** — roots written
   at rows, each governing until the next. That is document data rather
   than a reading, and it is the object a solve would want handed to it
   rather than inferring. How often an author rebinds is the evidence, and
   it is not yet in.
