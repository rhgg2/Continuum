# interval dirt — dirty ppq ranges, not dirty channels

> Working design doc, **not started**. Successor to the
> `incremental-rebuild` programme (`design/archive/incremental-rebuild.md`,
> closed 2026-07-15). One idea: make the unit of derivation dirt a **ppq
> interval within a channel** rather than the whole channel. It subsumes
> that programme's one deferred gap — the fx dirt signal — which is why
> that gap was deliberately left undone rather than patched.

## Status at a glance

| | |
|---|---|
| state | pinned, unstarted |
| supersedes | `incremental-rebuild` gap 4 (fx dirt signal) |
| enduring model it changes | `docs/trackerManager.md` § Derivation dirt |
| the hard part | was forward propagation — closed 2026-07-15 by onset-bounded closures + the cascade commute (§ The crux, closed); residual risk is the multi-pass I8 restatement |

## The problem it solves

Derivation dirt is currently a per-channel set, `dirtyChans`. A channel
absent from it freezes completely: its columns carry forward, its derived
notes/CCs/absorbers/PCs stand untouched in mm, and every gated stage skips
it.

fx breaks this. fx output regenerates every rebuild with **no change
tracking**, so fx-hosting channels are marked dirty *wholesale*, every
time. On a macro-heavy take — where most channels host fx — the gate
degrades toward doing nothing, and those takes get materially less of the
gating win than the headline numbers suggest.

The obvious patch is to give fx its own dirt signal by hashing the
generator inputs per host. That was **rejected**: it bolts a second dirt
axis alongside `dirtyChans`, to be plumbed through every stage that reads
it, and this project deletes it again. Two mechanisms wired together where
one suffices.

## The idea

Dirt becomes a set of intervals per channel. fx then needs no dirt signal
of its own, because the question answers itself:

> **a host regenerates exactly when a dirty interval intersects its window.**

That test is expressible against what the pipeline already computes.
`computeFxWindows` yields, for each fx host, a **logical-ppq extent** —
the voice's authored end, the take end, or the strict next same-lane
onset, soonest wins. Windows are already ppq ranges. Nothing new needs
representing; only the dirt does.

The channel model becomes the degenerate case (interval = the whole
channel), which is what makes the migration tractable: every stage can be
ported one at a time, and a stage that hasn't been ported yet simply
widens its interval to the channel and behaves exactly as it does today.

## Framing: maintenance, not narrower rebuild

This project reads as the third step of a narrowing series — everything
→ channels → intervals — but the truer model is that rebuild is already
`maintain(dirt)`. The wholesale bit made the split: `wholesale=true`
(bind, external hash drift, undo) is **load**, every object new;
`wholesale=false` with a dirty set is **maintenance**, a clean channel
frozen with columns carried and index live. First load is the degenerate
case where dirt = everything.

Interval dirt is the safe implementation of that model: **seed** (what
the edit touched) + **per-stage closure** to anchors + **re-run the load
derivation over the closed region**. The unsafe implementation — each
edit verb hand-writing the delta it applies to derived state — is the
same idea wearing verb × stage combinatorics, duplicated derivation
logic, and no I8 oracle to converge against. The crux below is the
maintenance question — *what does this edit invalidate* — and no framing
escapes it.

Two consequences, one extension declined:

- **Intervals are born at the verbs.** The edit verb knows the exact
  events, ppqs, and fields it touched; don't launder that through mm's
  channel-named `reload` payload. mm's wholesale signal stays as the
  external-change path, where dirt = everything is genuinely true.
  (Resolves open question 2.)
- **The output side is the successor.** This project gates derivation
  *inputs*; tm still fires a monolithic `'rebuild'` ("anything may have
  changed"), which is what holds the one-note edit at its ~1.15ms floor
  (`fire`, 0.53ms). A delta-shaped signal — *these columns changed* — is
  out of scope here but is the natural next project under this framing.
- **Declined: trusting direct patches.** Strong maintenance would skip
  re-derive-and-diff (`reconcileFx`, absorber reconciliation) and trust
  the patch. The reconcile is the churn-invisible safety net under
  content-keyed tokens; dropping it trades a small constant for the
  silent-stale-output class this design treats as the governing risk.

## The crux, closed: per-stage closure rules

**This was the whole risk**, and the 2026-07-15 design round closed most
of it. A dirty interval is the **seed** of a blast radius, not the radius
itself — each stage must close its seed to an anchoring event before
consuming it. The finding: per stage, propagation is **bounded by
neighbouring onsets**, with one true exception that commutes out of the
loop entirely (next section). One closure vocabulary, per-stage
parameterisation:

| stage | closure | grouping / frame |
|---|---|---|
| tails | [prev onset, next onset] | same-lane + same-pitch, raw order |
| seats (detune) | [onset, next lane-1 onset] **inclusive of that seat** | lane-1, raw order |
| PCs | [onset, next onset] | channel notes, raw order — conditional on the bearing rule below |
| fx | dirty interval ∩ host window | logical extents — already interval-native (§ The idea) |
| same-pitch cascade | none — exempt | commuted to the mm backstop (§ below) |

Two of these needed a correction or a rule change to get bounded:

- **Seats.** Per `docs/tuning.md`, detune prevails from a lane-1 onset
  until the **next lane-1 onset** (not `endppq`), and the absorber
  invariant runs both directions, so the next seat's fake-pb value is
  `next.detune − this.detune`. A detune change therefore perturbs up to
  and *including* the next seat — and stops there: past the re-anchor,
  prevailing detune is the successor's own.
- **PCs: the bearing rule.** Unbounded only because notes may inherit
  from the prevailing PC. New rule: under trackerMode every note bears a
  sample — stamped from the prevailing PC at first rebuild (free under
  the no-legacy-data policy) and at foreign-MIDI import. The closure
  drops to [onset, next onset] — not zero: with dedup, whether the
  successor *emits* a PC depends on this note's value. **Semantic trade,
  decided as UX not implementation:** inheritance freezes at stamp time;
  editing one note's sample stops re-colouring downstream inheriting
  notes and colours only itself.

The asymmetry still governs: spurious dirt costs one re-derive; missed
dirt writes wrong notes and says nothing. Worst case a closure runs to
the end of the channel, which *is* today's behaviour.

## The cascade commutes to the edge

Same-pitch cascades are the one genuinely unbounded propagation — a
nudged onset can collide with the next same-pitch note, which nudges,
which collides. They get no closure rule; they are **exempted from the
interval machinery** and enforced at the edge of the loop, where the
mechanism already exists: `same-pitch-enforcement`'s mm write-path
backstop (landed in full) detects collisions for free at `tokenIdx`
filing and resolves them at the outermost `modify` unwind via the shared
`voicing` verdicts, firing `collisionsResolved`.

Under interval dirt, `collisionsResolved` events become **seed intervals
for the next maintenance pass**: the cascade's blast radius is discovered
by running it, not predicted. Escapes are rare by construction — the
common cascade source, retrig hosts expanding to same-pitch fxNote runs,
lives *inside* the fx window, which is already the interval; the tail
walk keeps nudging within intervals, and the backstop catches only
boundary-crossers (an authored note at the exact nudge target).

Two recorded consequences:

- **I8 weakens, deliberately.** "Rebuild converges in one pass" becomes
  "one pass in the common case; finitely many when a cascade escapes an
  interval." The fixpoint survives but is reached by iteration; the
  soundness oracle and the specs that pin it need restating in those
  terms.
- **A settled decision re-opens.** same-pitch-enforcement decided "no
  forced rebuild on `collisionsResolved` — geometry trues up at the next
  natural rebuild" *because the path should never fire*. Commuting makes
  it a does-fire path; the signal must reliably schedule that next pass.

## Intervals are event-anchored

Every closure edge above is an *event*, not a number — which mostly
dissolves the logical-vs-raw question. An interval is anchored by
**uuid** (tokens re-key on ppq change; uuids survive, and
`idxReconcile` already handles re-keys), carries a logical span for
merging and bookkeeping, and each stage reads its edge events in the
frame it consumes — raw order for the raw-stream stages (tails, seats,
PCs), logical extents for fx. The edges that make a naked-number
representation delicate, and how anchoring absorbs them:

- **Delay reorders note-ons between frames** (raw = swing(ppqL) +
  per-note signed delay). "Neighbouring onset" is frame-relative, and a
  delay edit is a point in logical but genuine dirt in raw — an anchored
  seed carries it; a logical numeric interval would miss it.
- **Swing remaps the frames** — but `markSwingStale` already goes
  channel-wide and rebuild freezes one `swingSnapshot` per pass, so
  within a maintenance pass the map is a constant.
- **The pipeline's own movers** (tail nudges) would invalidate numeric
  edges mid-pass; uuid anchors survive them.

The blast radius of any edit is then computable in one hit: seed = the
edited events (a move is delete-at-old + insert-at-new — **both**
positions seed), radius = the per-stage union of [prev anchor, next
anchor] around each seed. Closure runs after interval merge, never
before — merging can pull a new anchor into range. Logical-order anchor
queries fall out of the ppqL-ordered note columns; raw-order queries
have no persistent index yet (open question 5).

## What this does not buy

Worth stating plainly, so the project is scoped honestly rather than sold:

- **Not the one-note edit.** That path is already at a ~1.15ms floor, and
  its largest single item (`fire`, 0.53ms) is subscriber notification, not
  derivation. There is little left to gate away.
- **Not the bind.** A foreign-take bind marks everything dirty by
  definition — every event is genuinely new.

The win is concentrated on **fx/macro-heavy takes**, which is exactly gap
4's target, plus finer gating on fat multi-channel edits. If that is not a
shape of project you are working on, this buys nothing, and the honest
move is to leave the wholesale fx row where it is.

## Open questions

1. What is the anchor, per stage, that terminates a forward closure?
   **Resolved** (§ The crux, closed): neighbouring onsets in the stage's
   own grouping and frame; the cascade is exempt via the backstop.
2. Where do intervals come from? **Resolved** (§ Framing): born at the
   um verbs, which know exactly what they touched. mm's `reload`
   payload stays channel-named; wholesale remains the external
   dirt-everything path.
3. How do intervals merge? A fat edit produces many; coalescing overlapping
   ranges per channel keeps the set small, but the closure must run
   *after* the merge, not before.
4. Is `noteLive` still the right carrier between fx and its downstream
   readers (`tails`, `pbs`, `pcs`)? Its current virtue — one gate, no
   cross-stage dirt plumbing — is worth preserving if the interval can
   ride it.
5. Which index answers raw-order anchor queries? Tails/seats/PCs close
   to raw-order neighbours (delay can reorder onsets between frames),
   and nothing persistent indexes that — the tail walk's ppq-sorted
   groups are per-pass transients.
