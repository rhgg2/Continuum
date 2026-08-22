# Sounding anchor — plan

> source: `design/sounding-anchor.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The intent** (§ What the note remembers, § What the cell says)
   — a note stores the cents of the step it was written on; the view and the
   solve read it where it is present, the cell reports the gap in cents where
   a tick once drew it, and the sites that write a detune set it, clear it or
   move it. — landed 2026-08-20, ten commits.
2. **Phase 2 — Wall and ruler** (§ The pull in cents, § What the beam
   loses) — the pull's strain becomes cents over fifty, `settle` collapses to
   a weighted mean with no clamp and no branch, and the beam's reach gate
   goes; the moves solve stops reading a window. — landed 2026-08-20, three
   commits.
3. **Phase 3 — Presence** (§ Presence, § Springs price beating) — a presence
   per member per onset, `RECENT` where the sonority holds a class by recency
   alone, weighting every spring in `springCost`, `ties`, `joinCost` and
   `settle`; the box keeps its full weight. — landed 2026-08-21, three
   commits.
4. **Phase 4 — The ambient reference** (§ The ambient reference, § Fixed at
   birth) — a strand's rest is the presence-weighted mean of the sonority it
   was born into, read once off `answer.displacement`, charged by the pull
   and carried in the merge key. — landed 2026-08-21, three commits.
5. **Phase 5 — The box judged** (§ Open) — the pairwise box measured against
   the span box again, and the span box keeps the objective. Charging pairs
   barely moves the wolf count and loosens what holds a spelling together, so
   a passage drifts further under every pairwise reading; the widest-pair box
   was listened to and rejected. — answered 2026-08-21, no production change.
6. **Phase 6 — The dials remeasured** (§ The dials, § Open) — the
   ambient's share, the beam's width and the walk's cap re-swept with
   the gate gone, harmonic lock and purity's opening value and useful
   span, and a value for `RECENT`. ← in flight

## Landed  (newest first; prune below ~4)

- 2026-08-22 sonority: narrow the beam to twelve, the cap staying at six (§ The dials, § Open)
- 2026-08-22 design: settle the box on spans, not pairs (§ What the box charges)
- 2026-08-21 sonority: give the ambient a dial, opening at a quarter (§ Open)
- 2026-08-21 sonority: key an answer by its open strands' rests (§ Fixed at birth)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

4. **Harmonic lock and purity's opening value and useful span**, and a
   value for `RECENT` (§ The dials, § Open).

