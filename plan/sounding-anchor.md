# Sounding anchor — plan

> source: `design/sounding-anchor.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The intent** (§ What the note remembers, § What the cell says)
   — a note stores the cents of the step it was written on; the view and the
   solve read it where it is present, the cell reports the gap in cents where
   a tick once drew it, and the sites that write a detune set it, clear it or
   move it.  ← in flight
2. **Phase 2 — Wall and ruler** (§ Both wall and ruler, § What the beam
   loses) — the pull's strain becomes cents over fifty, `settle` collapses to
   a weighted mean with no clamp and no branch, and the beam's reach gate
   goes; the moves solve stops reading a window.
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

- 2026-08-20 tracker: carry a note's intent into the notes it derives (§ What the note remembers, § What the cell says)
- 2026-08-19 tracker: store a generator's pitch demand in cents, not steps (§ The notation is not a derivation input)
- 2026-08-19 tracker: spend or carry a note's intent when a gesture moves it (§ What the note remembers)
- 2026-08-19 tracker: stamp the step a note was written on, spend it on a snap (§ What the note remembers)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

5c. **Steps and cents in the input** — the `stepInterval` widget becomes a
   step count and a signed cents residual over one stored cents value,
   anchored at the host's written step or at the notation's unison where
   there is no host note; a trill's interval joins a slide's on it, and the
   residual stops being quantised away on the next arrow press.
6. **Docs** — `docs/tuning.md` gains the intent rung, intent cents being
   realised as detune against a notation where detune is realised as pb
   against a channel; the ladder line at `trackerManager.lua:5` follows it,
   and `design/decisions.md` records the retirement of the rule that a step is
   never stored.
