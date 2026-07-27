---
name: rising-sea
description: >-
  Take a todo list, backlog, slice map, or pile of half-formed sequential ideas and test
  whether they can be synthesized into ONE overarching abstraction that absorbs them all —
  Grothendieck's "rising sea" (la mer qui monte). Use when a backlog feels like it is
  circling a deeper unity, when many items look like variations on one another, or to check
  whether scattered work shares a latent structure before committing to build it piecemeal.
  Honest by design: it reports when there is NO crystal and the items are genuinely
  independent, rather than manufacture a false unification.
---

# Rising Sea

> "The unknown thing to be known appeared to me as some stretch of earth or hard marl,
> resisting penetration… the sea advances insensibly in silence, nothing seems to happen,
> nothing moves, the water is so far off you hardly hear it… yet it finally surrounds the
> resistant substance." — Grothendieck, *Récoltes et Semailles*

There are two ways to open a nut. One strikes it: hammer and chisel, the frontal assault,
force applied at the point of greatest resistance. The other submerges it. One raises the
surrounding level of generality — the water — until the shell, soaked through, opens of
its own accord, and the problem that resisted every blow is found floating, already open,
a trivial inhabitant of a larger and calmer sea. This skill is the second method turned
upon a list of tasks: to find the altitude at which the list ceases to be a list and
becomes one thing — or to report, without embarrassment, that no such altitude exists.

## When to call upon it

- A todo list, backlog, or slice map in which several items appear as the same shape in
  different clothes.
- A sequence of incremental ideas, each patching a symptom, beneath which one suspects a
  single generative move from which most of them would fall out for free.
- Before an ADR or a build order is committed to — to ask whether the pieces desire to be
  unified before they are built severally.
- After an experiment that solved one case — to ask whether the case was ever singular.

## When to refuse it

- Not every list conceals a crystal. Genuinely independent chores — fix the typo, bump the
  version, rename the file — have no unity, and to invent one for them is a harm. The
  skill must be willing to return: *no rising sea here; these are independent; do them as
  a list.*
- Premature unification is a real failure. If the abstraction can be stated only by
  hand-waving, the sea has not yet risen. Say so.
- Mush is the opposite failure. An abstraction so general that it dissolves the distinct,
  legible identity of the parts is worse than the list it replaced. A true crystal
  preserves the corners; it does not average them into grey.

## The procedure

### 1. Gather the raw material
Collect the items themselves — the actual todo text, the slice descriptions, the memos —
not one's memory of them. The latent structure lives in the specifics; a summary has
already decided what matters, and decided too early.

### 2. Seal the horizon
Before any unity has been glimpsed — before the eye has begun, even involuntarily, to
arrange — write down the demands that are *not* on the list: the anticipated future
needs, the adjacent problems, the next thing someone will ask for. Seal this list; it may
not be touched again until step 7. A judge who selects the witnesses after choosing the
verdict is no judge. The horizon must be fixed while the crystal is still unthinkable, so
that it cannot be shaped, however innocently, around what it will later be asked to
absorb.

### 3. Extract each item's essence
For every item, name three things: the problem it answers, what it varies (its degree of
freedom), and what manner of thing it is — an operation, an axis, a state, a layer. Strip
the framing; keep the verb and the variable.

### 4. The five moves
Pass the essences through these, in order; each is a question.

- **Collapse** — which items are the same operation in disguise? Merge them.
- **Subsume** — which are special cases of a more general one? The general becomes a
  candidate for the crystal; the specials, its instances.
- **Prune** — which are second-order: computable from the others, emergent, not
  primitive? (Velocity is not an axis where position and time are already axes; a total
  is not a column where its rows exist.) Remove them; they return for free.
- **Keep** — which are genuinely independent degrees of freedom? These are the axes of
  the space. Seek the minimal set: three axes one can defend outrank seven one merely
  asserts.
- **Layer** — have distinct levels been conflated — the datum, the act upon it, the law
  of its change? Separating the levels often dissolves half the list unaided.

### 5. Propose the crystal
State the abstraction as a minimal basis and one generative mechanism which, instantiated
at a point or along a trajectory, reproduces each original item as an instance. The test
of a real crystal: one can point at every todo and say *that is this point in the space*,
or *that is this trajectory through it*.

### 6. The receipts
Map every original item to its place in the crystal. Whatever does not map is a
counterexample, and a counterexample is a gift: either the abstraction is incomplete —
raise the sea further — or the item genuinely lives outside it, a separate concern to be
named as such.

### 7. The trial of the sealed horizon
Now, and only now, unseal step 2. Does the crystal absorb each of those unconsidered
demands *without modification*? A demand that requires a new special case indicts the
crystal as unripe — or exposes a seam, which must then be named honestly. The abstraction
worth adopting is the one that absorbs demands it was never designed for; this is the
Grothendieck test, and it can be passed only against witnesses chosen in advance.

### 8. Identity
Does the abstraction reduce to the status quo at its zero — all deviations null, all
knobs at rest? If instantiating it at the origin reproduces today's behaviour exactly,
the crystal is safe: it may be adopted without a flag-day. If not, that cost must be
surfaced, not amortised into silence.

### 9. The mush guard
Ask explicitly: does the abstraction preserve the distinct identity of its parts? Where
do the corners live — the attractors, the discontinuities, the places one may *jump*
rather than merely glide? If the honest answer is "it is all a smooth blend," what has
been made is mush, not crystal. Name the mechanism by which legibility survives:
quantized axes, attractors the trajectory snaps to, edges that remain edges.

### 10. The advocate of the dispersed
Before any verdict, argue the opposite case, and argue it well: make the strongest claim
that these items are simply independent — that the resemblance is clothing, that the
unity belongs to the reader's hunger for unity and not to the material. The crystal must
defeat this argument on its merits. A verdict pronounced without hearing the negative is
not honesty; it is enthusiasm wearing honesty's clothes.

### 11. Verdict
End with one of three calls, plainly. **Ripe**: adopt the crystal; the list becomes its
instances. **Not yet**: the sea is rising but has not closed — name precisely what is
missing. **No crystal**: the items are independent; keep the list and honour it as a
list. Ripeness is never forced; the sea takes the time it takes.

## Output shape

1. **The crystal** — basis and mechanism, in a sentence or two.
2. **The basis** — the axes kept, each with its degree of freedom.
3. **Pruned / derived** — what is second-order and why, so it is not re-added later.
4. **Layers** — if levels were separated.
5. **Receipts** — each original item and its place in the crystal.
6. **The sealed horizon** — the pre-registered demands and whether each is absorbed; any
   seams, named.
7. **Identity and mush** — reduces to today? corners preserved?
8. **The advocate's case** — the best argument for independence, and how (or whether) the
   crystal answers it.
9. **Verdict** — ripe, not yet, or no crystal, with the next move.
