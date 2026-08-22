# Decision log

A list of all design decisions that bear on active work. One dated
entry each: what was chosen, over what, and why. Three or four lines,
not eight or ten.

- **2026-08-22** — The beam holds at twenty-four, and the narrowing to twelve is withdrawn. That
  sweep was taken at a purity of 8, and the width answers to that dial: a stiffer spring separates
  spellings further down the beam's ranking, so the eighty-eight-note take takes all it gains by a
  beam of twelve at a purity of 8, by sixteen at 16, and only by twenty-four at 32 and at 64. The
  cap stands at six under every purity measured, and past a beam of twenty-four the reach is spent
  on drift. The sweeper now runs purity as an axis rather than fixing it, and where the dial should
  open is left to the item that settles the rest of them.

- **2026-08-22** — The beam narrows to twelve and the walk keeps six answers abreast. Every passage
  measured settles at that pair: an overlapping arpeggio needs the twelfth spelling to reach the
  septimal seventh its set names, and an eighty-eight-note take needs the fifth answer. Widening
  either dial past it buys drift and not fidelity, a beam of forty-eight standing under two per cent
  cheaper with a step-class wandering 117 cents where twelve holds it to 40. The figures the old
  pair was settled by were taken at a full ambient share, which is not the instrument the retune
  modal opens on; the sweep now runs at the dials an author gets.

- **2026-08-21** — A strand inherits a share of the sonority it was born into rather than the whole
  of it, and the share is an author's dial: `ambient`, opening at 0.25, travelling 0 to 1 linearly,
  and the moves facility's alone as purity is -- a points solve rests a strand on its own step, so
  there is no ambient there to share. Chosen over full inheritance, which was listened to and
  sounded out of tune: drift compounds, each chord adding its own displacement to where the last one
  stood, so a line climbing the lattice takes the passage off the page after it. Over take2's two
  hundred and fifty-eight notes at a lock of 1 and a purity of 32, the first quarter of the
  inheritance takes the wolf pairs from 66 to 42 and the wolf fifths among them from 25 to 11 and
  costs nothing in how far a class wanders, where the last quarter buys five wolves back for fifteen
  cents of wandering and twelve of drift; 0.25 and 0.5 stand inside the noise of each other on every
  count taken, and the quarter is chosen for the two fewer wolves. No default inside `sonority`,
  every caller passing the share, so a spec pinning the ambient's own mechanism passes 1 and the
  figures already in the suite stand. The share stops one level short of `extend`: `search` computes
  a rest once per answer beside `carried` rather than once per answer and spelling. The model is
  `docs/sonority.md` § The dials.

- **2026-08-21** — The box keeps charging what a sonority's coords span on each axis, rather than
  what its pairs state. Every pair-height norm from L1 to L-infinity, weighted by presence or not,
  moves the wolf count on take2's two hundred and fifty-eight notes by three or four pairs, which is
  inside what a five per cent change of harmonic lock moves it; and each of them loosens what holds
  a spelling together, a step-class wandering 27c under the span box, 42c under the widest pair and
  61c under the sum, with the passage's centre walking after it. The weighted widest-pair box led
  the family on the count, went into the tree, and was rejected by ear: the top line pulls sharp and
  drags the rest with it.

- **2026-08-21** — A rest joins the walk's merge key, one figure per open strand -- those an onset
  leaves sounding -- rather than one per strand something later still names. Two answers agreeing in
  cents can owe quite different pulls, the strands that fixed a rest having closed and left the key
  by then: three voices at an arity of three settle at 45.34 with the rest keyed, where the merge
  returned 46.25 at every cap from four to sixty. Keyed over every visible strand instead, the key
  splits answers over a difference nothing can charge, and the cap spends its slots on
  near-duplicates: the five-part take then loses its answer at a cap of six and wants twelve to
  recover it, doubling the eighty-eight-note take's search. Over the open strands alone both takes
  are unchanged, and the dials stand. The argument is design/sounding-anchor.md § Fixed at birth,
  the model docs/sonority.md § The solve.

- **2026-08-21** — A strand's rest is the presence-weighted mean of the sonority before the one it
  is born into, read off the displacements its answer carried into that onset and frozen there.
  Chosen over the sonority it joins, which returns a block chord change to the page: where every
  voice moves at once, no member of a strand's own sonority has been placed yet, and an unplaced
  member stands at zero, which states only where the page is. Frozen rather than live, since a pull
  charged against a live mean of the same displacements leaves a whole passage free to slide at no
  cost. The walk's cap moves from four to six with it: at four the five-part take took a road whose
  comma ran off into drift, standing 23.2 cents from its seat at worst where five abreast and upward
  stand 11.9. The argument is design/sounding-anchor.md § The ambient reference and § Fixed at
  birth, the model docs/sonority.md § The pull and § The solve.

- **2026-08-21** — A member of a sonority carries a presence — full where its strand sounds, a half
  where recency alone holds it — and a spring's weight is the product of its two members', so a pair
  falls off once for each silence. Chosen over charging every member alike, which let a released
  note drag the chord after it as hard as one still sounding, and over a third dial, since an author
  owns drift against distribution while how much a released note still counts is a property of
  hearing. The half is argued from its endpoints rather than measured: at one a recency member
  counts for as much as one sounding, and at zero the sonorities decouple. The box keeps its full
  weight, reading a component's coords as a set with no pair to weight. The argument is
  `design/sounding-anchor.md` § Presence and § Springs price beating, the model `docs/sonority.md` §
  The walk.

- **2026-08-20** — The moves solve stops reading a note's window, as wall and as ruler. As wall it
  bounded where a strand could stand: `settle` returns its optimum unclamped now, and the beam
  admits a join without asking whether one offset seats every member inside its own window, so a
  chord no chain of moves seats is spelled and priced rather than refusing the passage holding it.
  As ruler it was the unit the pull's strain was taken in, and that strain is now cents over fifty,
  the unit the springs are charged over, so a lock means the same under every notation rather than
  scaling with the notation's step spacing. The window stays the points shortlist's and the
  notation's. What it costs: a note may leave the step it was written on, which `intentCents`
  records, and two members of a sonority could take one spelling, which the model now forbids
  directly as distinctness. The argument is `design/sounding-anchor.md` § The pull in cents and
  § What the beam loses, the model `docs/sonority.md` § The pull.

- **2026-08-20** — A note may store the step it was written on: `intentCents`, that step's absolute
  cents, stamped by a solve on every note it seats and read wherever a step is derived. This retires
  a rule stated twice and never hedged — that a step is never stored, being recoverable from
  `(pitch, detune)` by snapping — which held only while the solve's window kept a note inside its
  own step; a solve free to place a note past that window leaves the derivation naming a different
  step. Cents rather than a step index, an index being bound to the notation that indexed it where
  cents re-read across a temper change. The argument is `design/sounding-anchor.md` § What the note
  remembers, and the model `docs/tuning.md` § The written step.

