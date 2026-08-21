# Decision log

A list of all design decisions that bear on active work. One dated
entry each: what was chosen, over what, and why. Three or four lines,
not eight or ten.

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

