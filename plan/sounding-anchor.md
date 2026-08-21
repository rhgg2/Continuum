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
   `settle`; the box keeps its full weight.  ← in flight
4. **Phase 4 — The ambient reference** (§ The ambient reference, § Fixed at
   birth) — a strand's rest is the presence-weighted mean of the sonority it
   was born into, read once off `answer.displacement`, charged by the pull
   and carried in the merge key.
5. **Phase 5 — The dials remeasured** (§ The dials, § Open) — the beam's
   width and the walk's cap re-swept with the gate gone, harmonic lock's
   opening value and useful span, and a value for `RECENT`.

## Landed  (newest first; prune below ~4)

- 2026-08-21 docs: give sonority presence, and a spring its weight (§ Presence, § Springs price beating)
- 2026-08-21 sonority: count a member held by recency for half (§ Presence, § Open)
- 2026-08-20 sonority: give a member a presence and a spring a weight (§ Presence, § Springs price beating)
- 2026-08-20 docs: retire the window from the moves solve, as wall and as ruler (§ The pull in cents, § What the beam loses)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty)
