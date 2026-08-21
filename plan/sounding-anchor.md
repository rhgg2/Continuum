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
   and carried in the merge key.  ← in flight
5. **Phase 5 — The dials remeasured** (§ The dials, § Open) — the beam's
   width and the walk's cap re-swept with the gate gone, harmonic lock's
   opening value and useful span, and a value for `RECENT`.

## Landed  (newest first; prune below ~4)

- 2026-08-21 sonority: rest a strand where the sonority before it stood (§ The ambient reference)
- 2026-08-21 sonority: relax against a rest, not zero (§ The ambient reference)
- 2026-08-21 docs: give sonority presence, and a spring its weight (§ Presence, § Springs price beating)
- 2026-08-21 sonority: count a member held by recency for half (§ Presence, § Open)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. The rest joins the merge key. `answerKey` keys a rest beside the cents
   it already keys over the strands ahead, so two answers agreeing in
   cents but differing in what their rests will cost when those strands
   close survive as two. Red-first through `sonority.search`, on a
   passage where the answer the merge would drop is the one the walk
   should return; finding that passage is the work of the commit.
