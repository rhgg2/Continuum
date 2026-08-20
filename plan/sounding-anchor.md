# Sounding anchor — plan

> source: `design/sounding-anchor.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The intent** (§ What the note remembers, § What the cell says)
   — a note stores the cents of the step it was written on; the view and the
   solve read it where it is present, the cell reports the gap in cents where
   a tick once drew it, and the sites that write a detune set it, clear it or
   move it. — landed 2026-08-20, ten commits.
2. **Phase 2 — Wall and ruler** (§ Both wall and ruler, § What the beam
   loses) — the pull's strain becomes cents over fifty, `settle` collapses to
   a weighted mean with no clamp and no branch, and the beam's reach gate
   goes; the moves solve stops reading a window.  ← in flight
3. **Phase 3 — Presence** (§ Presence, § Springs price beating) — a presence
   per member per onset, `RECENT` where the sonority holds a class by recency
   alone, weighting every spring in `springCost`, `ties`, `joinCost` and
   `settle`; the box keeps its full weight.
4. **Phase 4 — The ambient reference** (§ The ambient reference, § Fixed at
   birth) — a strand's rest is the presence-weighted mean of the sonority it
   was born into, read once off `answer.displacement`, charged by the pull
   and carried in the merge key.
5. **Phase 5 — The dials remeasured** (§ The dials, § Open) — the beam's
   width and the walk's cap re-swept with the gate gone, harmonic lock's
   opening value and useful span, and a value for `RECENT`.

## Landed  (newest first; prune below ~4)

- 2026-08-20 sonority: charge the pull in cents and settle unclamped (§ Both wall and ruler)
- 2026-08-20 docs: intentCents (§ What the note remembers)
- 2026-08-20 tracker: read an interval as steps and the cents no step reaches (§ The notation is not a derivation input)
- 2026-08-20 tracker: carry a note's intent into the notes it derives (§ What the note remembers, § What the cell says)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

2. **The reach gate** — `reachOf` goes, with the `lo` and `hi` a beam state
   carries, the two offsets `admit` takes and the window `beamOver` reads;
   `sonority.spellings` sheds it in turn, and `sonority.seats` returns the
   seat cents alone, calling `tuning.seatWindow` still and discarding its
   half-gaps, so `solveToMoves` asks the notation for nothing else. The
   refusals invert: 'spellings: a sonority no chain connects is refused' is
   the red, its pair at 600¢ coming back spelled, and 'spellings: the windows
   hold the stretch between them, or no spelling does' and the diminished
   triad of 'solveToMoves: a chord stands at the target's intervals, or is
   refused' follow it. An empty spelling list now means a target that states
   no move, so `solveToMoves` keeps its nil. The wider frontier moves the
   spellings the walk chooses, so the figures in 'solveToMoves: the take
   settles where § Measured settles it' are re-taken here, and 'spellings: a
   width of infinity is the enumeration the beam is checked against'
   enumerates five members over eleven pitches with nothing pruning it —
   check what that now costs and cut the case down if it has grown out of
   hand. `take_bench.lua` says what the frontier costs the solve;
   `cap_sweep.lua` and `pairwise_box.lua` follow the two signatures. The three
   moves cases of `tests/specs/vm_retune_spec.lua` stand on the spellings the
   beam chooses, so their figures may move with the frontier too.
3. **Docs** — `docs/sonority.md` § The window and the pull becomes the pull
   alone, the window staying there as the points facility's and the
   notation's; § The springs takes the new unit and the unclamped sweep,
   § The candidates loses the reach, and § What it gives up loses the passage
   refused for a chord it cannot seat, its 0.54¢ giving way to the figure
   item 2 re-took. `design/adaptive-tuning.md` § Open items 5 and 7 are
   settled for the moves facility and say so, and `design/decisions.md`
   records the window retiring from the moves solve as wall and as ruler.
