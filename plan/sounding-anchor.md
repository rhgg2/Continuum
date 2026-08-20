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

- 2026-08-20 docs: retire the window from the moves solve, as wall and as ruler (§ Both wall and ruler, § What the beam loses)
- 2026-08-20 sonority: drop the beam's reach gate, and state distinctness (§ What the beam loses)
- 2026-08-20 sonority: charge the pull in cents and settle unclamped (§ Both wall and ruler)
- 2026-08-20 docs: intentCents (§ What the note remembers)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **A spring carries a weight** — `sonority.onsets` puts a `presence` map
   beside each onset's members and sounding: one where a member sounds
   there, and the constant `RECENT` where the sonority holds its class by
   recency alone. A spring's weight is the product of its two members'
   presence, set where a spring is built — in `sonority.springs`, which
   takes the presence map beside the seats, and in `chargeOf`, which takes
   the presence of the onset whose members it charges.
   `sonority.springCost` multiplies each spring's charge by that weight;
   `sonority.ties` sums the weights where it counts springs, so the
   neighbour count and the summed weight part company where `count` serves
   as both today, and it keeps a weight beside each neighbour it lists;
   `settle` reads both, and its optimum becomes a weighted mean. `joinCost`
   prices its springs by the same weight, so the beam ranks under the
   objective the search minimises; the beam works in slot space, so the
   shortest road there is a `Placed` carrying its own member's presence.
   The box stays unweighted. `RECENT` opens at one, which is the model as
   built, so no answer moves and the suite pins the change green; the new
   cases hand a presence below one to `sonority.springs` and `springCost`,
   and to `ties` and `relax`, and 'onsets: a member held by recency has
   stopped, so it is joined to and does not wait' gains the presence that
   member now carries. The churn is an argument at twenty
   `sonority.springs` calls and twenty-one `sonority.spellings` calls in
   `tests/specs/sonority_spec.lua`, and at the spikes under
   `tests/spikes/springs/` that call them.
2. **`RECENT` drops below one** — the constant takes 0.5, a class counting
   half once it has stopped sounding, which phase 5 measures against a
   passage where the value decides. The evidence the item wants is the D
   held from D–F–A into G–B♭–D and released exactly as the second chord
   strikes (design § Open): at one it binds that chord as hard as a note
   still sounding does, so the chord keeps the `10/9` the first chord gave
   it, and at 0.5 it binds it half as hard. What moves is re-taken: the
   figures in 'solveToMoves: the take settles where § Measured settles it',
   the search cases whose sonorities hold a member by recency, and the
   spike take under `tests/spikes/springs/`.
3. **Docs** — `docs/sonority.md` § The walk defines presence where it
   defines a sonority, § The springs gives a spring its weight and states
   the relaxation's mean as weighted, and § The candidates says the beam
   ranks a join under the same weight; where the doc quotes a figure item 2
   re-took, the new figure stands.
