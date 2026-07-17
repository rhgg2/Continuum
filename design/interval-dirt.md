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
| state | planned (§ Implementation plan), unstarted |
| supersedes | `incremental-rebuild` gap 4 (fx dirt signal) |
| enduring model it changes | `docs/trackerManager.md` § Derivation dirt |
| the hard part | was forward propagation — closed 2026-07-15 by onset-bounded closures (§ The crux, closed); same-pitch widens the tails closure rather than leaving tm (§ Same-pitch is a projection artefact), and tails *produces* its closure from the neighbour lookup it already does, rather than consuming a fence it could leak past (§ The tails closure is the walk's output, not its input) |

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
neighbouring onsets**. One closure vocabulary, per-stage
parameterisation:

| stage | closure | grouping / frame |
|---|---|---|
| tails | [prev onset, next onset] — **produced** by the walk, not consumed | same-lane ∪ same-pitch, raw order |
| seats (detune) | [onset, next lane-1 onset] **inclusive of that seat** | lane-1, raw order |
| PCs | [onset, next onset] | channel notes, raw order — conditional on the bearing rule below |
| fx | dirty interval ∩ host window | logical extents — already interval-native (§ The idea) |

Three of these needed a correction or a rule change to get bounded:

- **Tails: the union, not an exemption.** A 2026-07-17 draft had
  same-pitch commute out of the loop entirely, leaving tails to close
  same-lane alone. It cannot (§ Same-pitch is a projection artefact):
  same-pitch is realisation, tm owns the projection, so the walk keeps
  both groupings and closes over their union. Bounded all the same — a
  nudge chains only while notes sit within a tick of each other, so a
  detune cluster is bounded by its own size, and the clip needs one
  neighbour. And tails **produces** this closure rather than consuming
  one: the neighbour lookup that closes the interval is the same lookup
  the bound needs, so the walk sweeps out from its seeds and the anchors
  it reaches are the answer (§ The tails closure is the walk's output,
  not its input). It has to work this way — a fenced walk can leak a
  cascade, and mm's backstop cannot catch one, because it kills.
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

## Same-pitch is a projection artefact

> Amended 2026-07-17, twice. The first draft commuted only the
> *cascade* and left the tail clip standing in tm's walk. The second
> sent both to mm on an ownership argument — mm owns the raw frame, so
> mm should own the constraint — that does not survive contact with
> mm's code. This third version was checked against the machine before
> it was written, which is the only reason to believe it over the other
> two.

"One voice per `(chan, pitch)`" is a fact about MIDI, not about
trackers. The tracker rule is that a column is monophonic — a note ends
at the next onset in its own lane — and it would hold if MIDI did not
exist. That is the only truncation the intent frame owes.

Same-pitch exclusion is therefore an artefact of **realisation**, and it
belongs where the other realisation artefacts already live: at the point
tm projects intent into raw, beside swing and delay. Not in mm. The
ownership argument reads well and is wrong on the facts — **mm cannot
hold this**, on two counts:

- **The backstop is onset-only.** It detects a collision by exact token
  match (`tokenIdx[newTok]`, `midiManager.lua:1039` and `:1077`), and
  the token is `(evType, chan, ppq, pitch)`. That catches two notes
  landing on one raw onset — the clamp's case, and for free. Tail
  overlap produces no token collision and is structurally invisible to
  it. A clip in mm is new code, not a mechanism already there.
- **A clip in mm's model churns forever.** `rebuildTails` derives its
  bound from lane geometry and writes when `rounded ~= e.endppq`, where
  `e.endppq` was read back from mm via `buildRawScratch`. If mm clipped
  what it stores, the walk would re-derive the unclipped lane bound and
  write it back every rebuild, against an mm that re-clips it every
  time. That is `tm_zero_write_spec` red on both fixtures — the very
  fixpoint that terminates the rebuild self-trigger loop.

The rule that decides the boundary: **clip what the view can't draw;
don't clip what it can.** Two notes overlapping in one lane is
unrepresentable, a column being a list of cells with nowhere to put the
second, so the lane clip is intent-frame semantics and stays in tm. Two
notes overlapping at the same pitch across lanes is perfectly drawable,
and the overlap is right there on screen, so the truncation is
inferable from what is displayed: unrealisable intent, shown as
authored, no cue and no clip. The precedent is already in the model —
same-pitch *onset* separation nudges on the realisation side and "the
authored ceiling on `endppq` stands" (`docs/trackerManager.md` §
Same-pitch onset separation). A cue earns its place only where the
cause is invisible: swing collapsing two onsets is invisible, so
`delayC` gets its `*`; a same-pitch overlap is not.

**The walk computes two bounds instead of one.** The lane bound is
intent — `max(ppq+1, min(fromLogical(endppqL), fromLogical(laneNext.ppqL)
+ overlap, takeLen))` — and drives `endppqC` and the column's displayed
end. The raw bound is that, further clipped by the next same-pitch
onset, and is the only value that reaches mm. `endppqL` untouched,
`endppqC` lane-only, `endppq` clipped. Same-pitch becomes precisely what
swing already is: something that happens on the way out, true on the
wire, absent from the screen.

**What the clip deletes in tm.** `realiseParked`'s pitch grouping —
parked cells never reach mm, so they are pure intent and clip lane-only
— and the parked-bounds second grouping. `rebuildTails` keeps its pitch
grouping, because the clamp still needs it.

**One clip, once.** The flush pre-clip scan (`trackerManager.lua:1073-
1107`) carries a second same-pitch tail clip, and it is a vestige. That
scan exists for `voicing.resolveGroup`'s *verdicts* — killing genuine
duplicates through um's verbs, so PA culling and detune-aware resize
happen (`:1101-1106`), with the descending-target-ppq sort after it so
an occupying move cannot re-key onto a peer's token. None of that is
truncation. `design/archive/same-pitch-enforcement.md` records the
moment the loop went vestigial: when the verdicts were hoisted into
`voicing`, "tm's flush pre-clip consumes `resolveGroup` and **keeps only
the tail-bound loop**". The scan used to *be* the truncation site; the
loop is what was left standing when the job moved. The walk's bound is
strictly stronger (`ceiling ∧ lane ∧ pitch ∧ takeLen` against the scan's
`endppq ∧ nextSamePitch ∧ takeLen`), computed against post-walk rather
than staged geometry, and a rebuild always follows a flush — so the
scan's clip only ever produces a value the walk overwrites moments
later. Both docs already concede it: "This is the staging pre-clip only;
the authoritative raw tail is re-derived by rebuild step 4.8." The loop
goes; the verdicts stay.

**Separation is three sites, and the reason is not same-pitch.**
tm separates colliding onsets at *three* sites — the reseat
(`trackerManager.lua:1655`), the flush pre-clip scan (`:1087`), and the
tail walk (`:2701`) — and they look like three copies of one rule. They
are not. They are one rule forced three times by **content-keyed
addressing on a mutable field**. `tokenOf(evt)` hashes
`(evType, chan, ppq, pitch)`; two same-pitch notes on one raw ppq hash
identically; `tokenIdx` holds exactly one of them, and the other has no
name. `mmBatch.commit` stages `a.evt.token` and hands it to `mm:assign`,
which is a bare `tokenIdx[token]` lookup (`:1537-1544`) — so a collision
committed at one of the pipeline's nine mm commits leaves a note
unaddressable through the eight that follow, until the backstop
separates it at the outermost unwind.

So the sites are not handling collisions; they are preventing tm from
minting a name it cannot use. The walk's clamp is no counter-example: it
separates records that are not in mm yet (`:2700` — "a new fxNote (**no
token yet**) mutates in place") or not yet colliding there. Separation
is geometry over tm's own records and works fine with collisions
present. Addressing is a hash lookup on the field that collided.

The fix is the one the docs already name: `uuid` is stable, never
collides, and `docs/trackerManager.md` § Conventions calls it "the
durable cross-rebuild handle". Every note has one — `addNote` always
allocates, load mints for unbound survivors. It is an accessor over an
index mm already maintains (`eventsByUuid`, live across add / delete /
backstop / load), not new machinery. With `mmBatch` naming notes by uuid
and mm exposing a uuid-keyed assign beside the token surface, a
collision stays nameable, tm can carry one transiently across commits,
and separation collapses to a single site: **the walk, in tm, at the
projection**. Reseat's nudge goes — the walk covers it, and mm's
backstop, firing at an unwind that comes after the whole pipeline, finds
nothing, exactly as its contract promises. The flush scan's nudge goes
too, covered by the backstop at flush's *own* unwind, where the rebuild
that trues it up was already coming; its **kills** stay, because killing
a duplicate is a dedup verdict rather than separation and it is
correctly routed through um's verbs.

**And the clamp does not follow the clip to mm — a third reason, and the
decisive one: the backstop kills, and the clamp doesn't.**
`voicing.nudgeOnsets` only separates. `voicing.resolveGroup`, which the
backstop runs (`midiManager.lua:885`), deletes: `redundant`
(`voicing.lua:20`) returns true **unconditionally** when one note is
derived and the other is not — before any `ppqL` or `detune` comparison
— and `supersedes` then drops the derived one. `docs/voicing.md` states
the policy outright: an fxNote "always loses to an authored note". So
routing the walk's clamp to the backstop is not a relocation but a
silent behaviour change: a retrig fxNote landing on an authored note's
raw onset is separated today (+1, both voices live) and would instead be
deleted. The walk is the only site where fxNotes and authored notes meet
before commit — fxNotes do not exist until rebuild, so the flush scan
cannot cover them, and `same-pitch-enforcement` records the split
("reseat + tail walk consume `nudgeOnsets`"). The 2026-07-17 draft's
claim that both layers "drive the same algebra" was false: they drive
different halves, and the half mm runs is the one that kills.

`delayC`'s re-stamp (`trackerManager.lua:2707`) therefore stays, and the
draft that promised its deletion was promising something unreachable:
the walk still nudges mid-pass, after projection, which is the exact
condition that forces the re-stamp `0097742` had to add.

**`endppqC` stops being a projection.** `projectEvent` derives it from
mm's raw end (`tm:toLogical(chan, evt.endppq)`) — and that raw end is
now the same-pitch-clipped bound. Left alone, the next materialisation
would project the wire's clip straight back onto the screen: the
truncation just removed, reappearing one rebuild later. `endppqL`
protects `endppq`, not `endppqC`. So `endppqC` becomes an output of the
walk's lane geometry and never a projection of the raw end — the same
shape as `delayC`, which the walk already re-stamps rather than
projects.

That is load-bearing, because `endppqC` is not a paint value.
`soundingCell` builds a parked cell's producer stream note from it;
`adjustDurationCore` grows and shrinks from it ("the ceiling they
SEE"); the region window edits, the noteOff toggle, and the fx host
lookup all anchor to it. None wants the same-pitch component
specifically — each wants *the end the user sees* — so all survive on
the lane clip, with two accepted behaviour changes: a
same-pitch-truncated note now grows from its authored end, and a parked
cell's producer sounds to its lane clip, its derived notes clipped on
the wire like any others.

**I8 survives intact.** Because nothing commutes, the walk still
separates in-pass, and its two in-pass consumers stand: a nudged lane-1
onset reaches `rebuildPbs` later in the same pass, and the `delayC` stamp
(`trackerManager.lua:2707`) carries the raw shift. A colliding edit
converges in **one** pass, and phase 4's interval walk does not weaken
that — because the walk is never fenced by an interval it could escape.

How the first of those consumers is *delivered* changes at commit 3, and
the next section is about that. Through commits 1–2 it is
`dirtyChan(chan)`; after commit 3 it is the walk's own emission.

**The widen and the emission are the same fact, so commit 3 deletes the
widen.** `dirtyChan(chan)` at `trackerManager.lua:2703` is usually
described as what carries a moved seat to `rebuildPbs`. It isn't. The
walk runs only on channels that are already dirty (`:2665` gates the loop
body), so the line cannot add dirt and pbs re-derives the channel either
way; under whole-channel dirt it was a strict no-op. Under interval dirt
it becomes a **widen** — writing `true` over the channel's interval set
from inside the very stage phase 4 narrows.

Through commits 1–2 that is harmless and it stays: the walk is still
whole-channel there, so the promotion costs nothing. It does not survive
commit 3, and the reason is not cost. Once the walk emits its closure for
seats and PCs, the widen and the emission are **the same information on
the same trigger** — a nudge moved a lane-1 onset — delivered by two
mechanisms, and the coarse one wins: `dirtyChan` writes `true`, phase 1's
whole-channel value, wiping the interval set the emission just built.
Seats and PCs would read `true` and re-derive wholesale exactly as today,
and the emission would be dead code. So commit 3 must remove the widen,
not narrow it — the walk already knows precisely which onsets it moved,
and crux row 2's seat closure ([onset, next lane-1 onset], inclusive of
that seat) is exactly the consumer for them. The pipeline order is what
makes it legal: tails discovers at `:3221`, pbs consumes at `:3229`.

That also retires the idea of narrowing the widen in place — seeding both
positions of the moved onset, as um's verbs do for a ppq-moving assign
(`:724-726`). It reads right, and it is the wrong answer: it hand-builds
a second delivery path for what the emission already carries, on the
reasoning that the walk cannot reach phase 2's seeds (true — its clamp
writes go through `mmBatch` straight to mm, never `assignLowlevel`) and
so must hand-roll dirt. The walk does not need to reach phase 2's seeds.
It produces dirt of its own, at the moment it has the right data in hand.

What the widen costs meanwhile is small, and worth stating so it isn't
mistaken for a headline. `dirtyChans` clears at the end of the rebuild
(`:3243`), so a widen never crosses a pass; the only readers downstream
of tails are `rebuildPbs` (`:2785`) and `rebuildPCs` (`:3116`), both
phase 6, both profile-gated, measured at `pbs` 1.5 / `pcs` 0.0 on the
dense take. The edit-path win lives upstream of the walk, not below it.
The case for deleting the widen is coherence — one mechanism per fact —
and, if phase 6 ever runs, correctness: a moved lane-1 onset absent from
pbs's dirt is a stale absorber seat, the silent-stale class rather than a
slow re-derive.

Phase 2's dispensation does not cover this and should not be read as if
it did: it lists config, swing, take-length and external modifies — dirt
sources *outside* the pipeline, where dirt = everything is genuinely
true. `dirtyChan()` calls the rebuild makes *mid-pass* are a different
class, and the walk's is not the only one: the park and pb-restore stages
widen at `:2023`, `:2028`, `:2103`, `:2195`, `:2211` and `:2223`, and
they run *before* fx and tails, so their radius is strictly larger. Phase
5 owns those (§ phase 5). The walk's is the one phase 4 can fix while it
has the stage open.

**The tails closure is the walk's output, not its input.** The crux table
reads as though every stage is handed a closed region and derives inside
it. For tails that is backwards, and building it that way does the work
twice: closing the interval *means* finding each seed's same-lane and
same-pitch neighbours, and that is the identical lookup the walk already
performs to compute a bound. So the walk takes no fence. It sweeps
outward from the dirty seeds along the neighbour links it needs anyway —
the predecessor whose tail may reach into the seed, the successor that
clips the seed's own — and the anchors it touches **are** the closure,
fixed at the moment the walk has exactly the right data in hand.

The pipeline already runs in the order that permits this: fx first
(`trackerManager.lua:3219`), closing independently on window ∩ dirt, then
tails (`:3221`), then seats (`:3229`) and PCs (`:3230`). Every stage that
*consumes* a closed interval runs after the stage that discovers one.

**And it must be an output, because an escape has no other net.** A
2026-07-17 draft fenced the walk with a precomputed interval, let a
cascade chain past the fence onto a note outside it, and called mm's
backstop the net that discovers the nudge, at the price of an extra pass.
That net does not exist. The backstop runs `resolveGroup`, and
`resolveGroup` **kills**: an fxNote that cascades onto an authored note
outside the region is not nudged there but deleted, `redundant`
short-circuiting on the derived/authored mismatch before it compares
anything (`voicing.lua:20`). The group it builds is the whole lane
(`midiManager.lua:882-884`), not the interval, so the region's edge buys
no protection either. And `collisionsResolved` would carry
`kind = 'killed'` events (`:887`) — seeding the next pass from notes that
no longer exist. It would likely still converge, since fx regenerates
wholesale every rebuild and a second pass would have both notes in view;
but a pass that silently deletes a retrig fxNote the whole-channel walk
keeps is exactly the silent-stale-output class this design treats as the
governing risk (§ The problem it solves). The draft's own reassurance
pointed the wrong way: fxNotes being generated *inside* the fx window
bounds where a cascade starts, not where it lands, and what it lands on
outside is the authored note that triggers the kill.

Unfenced, the escape has nowhere to go: a nudge chaining onto a further
note follows a successor link the walk was already prepared to take.
There is no edge, so nothing crosses one, and the case that would have
killed an fxNote never arises. The sweep still terminates for the reason
the bound was bounded to begin with — nudges only move onsets forward,
each step consumes a real neighbouring onset, and chaining stops as soon
as two notes sit more than a tick apart. The interval handed downstream
covers every onset the walk moved, by construction rather than by
prediction. I8 needs no restatement, `collisionsResolved` gains no
seed-source job, and the backstop stays what its contract says it is: a
net that in steady state finds nothing.

The tail clip carries no such debt at all: nothing derives from the
wire's end, only from the lane clip tm computes itself. Sweeping is an
onset-side concern only.

**A settled decision, still settled.** same-pitch-enforcement decided
"no forced rebuild on `collisionsResolved` — geometry trues up at the
next natural rebuild" *because the path should never fire*. The 2026-07-17
draft made it a does-fire path and owed it a scheduling guarantee; this
design does not. It stays a rare-escape net, and phase 4 gives it no new
job — the interval walk closes its own escapes rather than reporting
them.

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

- **Not the bind.** A foreign-take bind marks everything dirty by
  definition — every event is genuinely new.
- **Not the write side or the output side.** `serialise` + `setEvts` +
  reindex + `meta` (≈35ms on the dense take below) and tm's monolithic
  `'rebuild'` fire (10.4ms) bracket the derivation this project
  narrows; each is its own successor programme (§ Framing;
  `15a343d`).

A first-draft bullet here — "not the one-note edit, it's at a ~1.15ms
floor" — was falsified 2026-07-15 by a live profile: that floor was
fixture-relative (3193 notes spread over 11 channels). On a dense take
whose notes sit on one channel (8437 notes), the same one-note edit
pays ~60ms of reload (warm; § Implementation plan, phase 0 pins all
three baselines), nearly all whole-channel materialisation and walks —
channel granularity is worthless when one channel ≈ the take.
The win is therefore two-sided: **dense single-channel takes**
(phases 3–4) and **fx/macro-heavy takes** (phase 5, gap 4's original
target).

## Implementation plan

> Restructured 2026-07-15, same day as the first draft: a live profile
> on a dense single-channel take (8437 notes, 1685 ccs; one-note edit =
> ~96ms flush, ~60ms reload, warm) falsified the draft's scoping. The
> draft kept materialisation channel-granular and deferred the tail walk
> as "expected dropped", on numbers from a fixture an order smaller where
> no channel dominated — but `internals` 18.5 + `tails` 14.0 +
> `projLogical` 8.5 + `fxWindows` 4.9×2 + `ccs` 3.0 ≈ 54ms of that
> reload sit exactly there. Channel granularity's virtue ("a whole
> dirty channel over-approximates the closure") is void when one
> channel ≈ the take. § Framing already named the true model — re-run
> the load derivation over the closed region — and the plan now follows
> it: materialisation, projection, windows, and the tail walk all
> consume intervals.

Discipline as in the predecessor programme: each phase lands
independently with the suite green, `tm_gate_parity_spec` extends at
each new consumer (interval-gated vs forced full re-derive, frame
equality, on both fixtures), "skipped means zero mm writes" is pinned
by write-counting under the harness, and later phases gate on measured
numbers. Phases 3–5 also restructure the stages they touch toward the
target dataflow in `design/rebuild-pipeline.md`; each such phase lands
the restructure as its own green commit before its gating commit, so a
regression bisects to a half. The split is by take shape: **phases 3–4 are the dense-take
programme, phase 5 the macro-take programme**, each measured against
its own fixture. I8 stays intact throughout, phase 4 included: the
interval walk produces its closure instead of consuming one, so there is
no fence to leak past and no pass to trade away (§ The tails closure is
the walk's output, not its input).

### Phase 0 — two fixtures

- **Dense single-channel (HAMMERKLAVIER): measured, go.** 8437 notes,
  1685 ccs, all on channel 1. Three baselines, re-measured warm on
  2026-07-15 (`collectgarbage` first, run 1 discarded; profiler recipe
  in `docs/bridge-cookbook.md` § Profiling a rebuild):

  | span (ms, warm) | import (virgin bind) | no-op (`rebuild(true)`) | edit (one note) |
  |---|---|---|---|
  | total | 415 | 72 | ~96 flush / ~60 reload |
  | `externals` | 98 (8437 uuids minted) | 0 | 0 |
  | `internals` | 12.5 | 27 | 18.5 |
  | `tails` | 34 | 14 | 14 |
  | `projLogical` | 9 | 8.6 | 8.5 |
  | `fxWindows` | 6.4×2 | 4.8×2 | 4.9×2 |
  | `ccs` | 11 | 3.4 | 3.0 |
  | `serialise`/`setEvts`/`sidecars` | 43/20/13, each ×2 | — | 14/10/2 |

  Phases 3–4 are judged against the **edit** column — the maintenance
  path they narrow. Import is the bind reference (§ What this does not
  buy); no-op is the forced-full ceiling the parity spec compares
  against. The draft's higher numbers (reload 92.6, tails 33.5) were a
  cold/GC-inflated run.
- **Macro-heavy (Glasswork): measured, go.** 1268 model notes over 16
  channels, 32 bars, 53EDO + classic58 swing. Exercises all 9 generator
  kinds, an fx chain (retrig→velPattern), a mirror-group canon, and
  cc11 / channel-AT / poly-AT — ~16.9k raw events (incl. 4759 sidecars).
  Builder at `tests/fixtures/glasswork.lua` (authors events given tm/gm;
  the caller presets temper/swing/length). Driven live off the bridge,
  not blob-reproducible — tuning/swing/groups/fx live in config, not the
  MIDI. Two baselines re-measured warm 2026-07-15:

  | span (ms, warm) | no-op (`rebuild(true)`) | edit (one note) |
  |---|---|---|
  | total | 78 | 25 flush |
  | `fx` | 35.7 | 0.0 |
  | `pbs` | 20.8 (`seats` 11.1×16) | 0.1 |
  | `ccs` | 9.0 | 0.1 |
  | `regionPark` | 3.0 | 1.4 |
  | `tails` | 3.5 | 0.1 |
  | `internals` | 2.5 | 0.1 |
  | `serialise`/`setEvts`/`sidecars` | — | 9.1/7.9/1.2 |

  The complement to the dense take: where that one is internals/tails-
  bound, the macro no-op is **producer-bound** — `fx` + `pbs` + `ccs`
  ≈ 65 of 78ms, phase 5's target, and the pb/cc seats (30ms) are *not*
  negligible here (§ phase 5's continuous-side decision). The edit path
  is **write-bound**: the re-derive subtree is ~3ms (one channel dirty),
  while `serialise`+`setEvts` ≈ 17ms rewrite the whole 16.9k-event blob
  every flush — the write-side successor, not what phases 3–5 narrow.
  Import is skipped: destructive to a non-reproducible fixture, and the
  bind path is already the dense take's import column.

### Phase 1 — the interval set, pure

`dirtyChans[chan]` becomes one of:

```
true                          -- whole channel: every unported dirt source,
                              -- and the widening fallback for edge cases
{ { loPpq, hiPpq,             -- logical span: merging + bookkeeping
    loUuid, hiUuid }, ... }   -- event anchors (§ Intervals are event-anchored);
                              -- nil uuid edge = open toward channel start/end
                              -- merged: ppq-ascending, non-overlapping
```

Operations as a pure module `intervals.lua` (shape-peer of `voicing`:
stateless, directly unit-specced): `seed`, `merge` (coalesce; collapse
to `true` past a size cap), `intersects(set, lo, hi)` (edge-inclusive —
see phase 3), `close(set, sortedEvents, opts)` — the § crux closure,
parameterised by grouping and frame. Merge at seed time, close at
consumption (open q3: merging can pull a new anchor into range, so the
consuming stage closes the merged set against its own ordering). An
anchor that dies before consumption widens its edge open; a set that
degenerates collapses to `true`. Spurious dirt is one re-derive; the
fallback is always available.

Alternative considered: tm-local helpers instead of a module — rejected
because the closure rules are exactly the pure logic that wants direct
unit specs, and tm internals are reachable only through the harness.

No consumer changes. Every gated stage already tests
`dirtyChans[chan]` truthy, so an interval-valued entry reads as "dirty"
and the stage re-derives the whole channel: over-approximation, today's
behaviour. (One audit needed: nothing may test `== true` or count
entries.)

### Phase 2 — seeds born at the verbs

um's low-level verbs (`addLowlevel` / `assignLowlevel` /
`deleteLowlevel`, `trackerManager.lua:712`) see every edit; they
accumulate seeds beside `adds`/`assigns`/`deletes`. An add seeds its
event; a delete seeds its point anchored to the surviving neighbours;
an assign that moves `ppq`/`ppqL`/`delay` seeds **both** positions; a
value-only assign seeds the point. `flush` hands the merged seeds to
the rebuild.

The mm `reload` subscriber's channel fold (`trackerManager.lua:3273`)
gains a flushing guard: during tm's own flush, a payload chan covered
by seeds is not widened — but a payload chan the seeds do NOT cover
still folds whole (mm-internal mutators — the collision backstop,
dedup — write outside the verbs, and their dirt must not be lost).
Every other dirt source keeps calling `dirtyChan()` unchanged: config,
swing, take-length, external modifies stay whole-channel, narrowing
later only if a phase pays for it. That dispensation is for dirt sources
*outside* the pipeline, where dirt = everything is genuinely true. It
does not cover the `dirtyChan()` calls the rebuild itself makes mid-pass
— those are a widen over an interval set rather than a source, they are
uncovered until a phase names them, and each one is a wholesale write
inside a stage some phase is narrowing (§ The walk's own dirt is a widen,
not a seed). Phase 5 owns the park/region ones; phase 4's commit 3 owns
the walk's.

Zero behaviour change by construction; specs pin the seed shapes per
verb and the flushing guard.

### Phase 2.5 — pipeline dataflow pre-phase

The mechanical half of `design/rebuild-pipeline.md` (§ The pre-phase),
landed before any stage goes interval-native: hoist the pipeline's ds
reads into one head snapshot, replace the `fx` blackboard with
explicit stage inputs/outputs, pin zero-write convergence by
write-counting on both fixtures, and audit non-tm ds subscribers for
mid-pipeline write-timing dependence. Shape only — no behaviour,
ordering, or commit changes; the suite and the phase-0 baselines pin
it. Phases 3–5 then port stages that are already functions.

### Phase 3 — interval materialisation: columns, projection, windows

The dense take's edit-path `internals` 18.5 + `projLogical` 8.5 +
`ccs` 3.0 + `fxWindows` 4.9×2 (§ phase 0).

- **Columns splice — and no closure.** `rebuildInternals` /
  `rebuildCCs` clone from mm only the events the merged **seed set**
  covers and splice them into the carried columns: seeded points out,
  fresh clones in. The draft's rule — materialise the union of the
  consuming stages' closures — rested on those stages reading the
  fresh clones, and they don't: every raw consumer reads
  `buildRawScratch`, built whole-channel from mm, which resolves
  carried and freshly-cloned events alike by uuid and writes results
  back through a `colEvt` backref. A carried event whose mm note is
  unchanged is already correct, so widening a seed to its neighbours
  buys nothing here (measured: it materialised ~90% of the channel and
  changed no output). Closure is the tail walk's, computed against its
  own raw-order scratch — phase 4. Splice position at equal `ppqL` is
  defined and `sortByPPQ` gains a tie-break: chord-mate order must be
  deterministic or the parity spec's frame comparisons flap.
- **Projection precedes the splice — in two moments.** Spliced events
  project at ingestion (`ppq := ppqL`, view end from `endppqL`/OPEN,
  initial `delayC`/`endppqC` from the mm raw in hand): no column ever
  holds a raw event (`design/rebuild-pipeline.md` § The frame law — no
  event list is ever part-raw, part-realised). But `delayC`/`endppqC`
  are post-walk facts — the give-way and the clip — so the walk
  re-stamps them through scratch backrefs at its write sites, which by
  I8 touch only the blast radius. `projectLogical` dissolves into
  these two moments. Carried events were logical already, so retention
  is unchanged.
- **The raw working set: scratch-from-mm.** Logical-born columns
  strand every raw consumer — the tail walk's gather, `rebuildPbs`'
  lane-1 list, the PA matcher, `rebuildPCs` — so materialisation's
  counterpart is their replacement: per dirty channel, light records
  (not clones) built from mm's per-channel index, **minus** members
  parked this pass, **plus** `restoredNotes` (in columns but absent
  from mm until the walk's deferred commit), each carrying a backref
  to its column event for the re-stamping above. `noteLive` unions at
  the walk, as today. Built whole-channel here — a cheap iteration
  re-added for the interim — and narrowed to the closed region by
  phase 4. `rebuildPCs` reads it permanently: phase 6 is
  profile-gated and may never run. *Alternative rejected:* retaining
  raw fields on column events — a hand-synced cache of mm with a
  dual-write invariant at every mm write site, whose failure mode is
  the silent-stale class this design names the governing risk. mm is
  already the persistent raw store; read it.
- **fx windows are carried state**, same regime as columns. A window
  recomputes iff a dirty interval intersects its extent
  (edge-inclusive — deleting the bounding next same-lane onset seeds
  exactly at the old window edge, and that delete is precisely the
  edit that grows the window) **or the window is itself dirty**: its
  defining spec changed — region edit, parking change, a host's fx
  edit — which seeds the spec's span. Clean windows carry from the
  prior set; the pipeline already persists exactly that set as the
  recognition baseline (`prevWindows`), so the carrier exists. Both
  `computeFxWindows` calls gate identically; the second (post-unpark
  re-scan) additionally short-circuits when park/unpark moved nothing.
- **Park scans ride the same rule.** `rebuildRegionPark`'s three scans
  (note/pa/cc — 1.1ms on the dense take) hunt events newly covered by
  a window, and coverage changes only where events changed or windows
  changed: the scan set is dirty intervals ∪ recomputed-window extents,
  the two-source rule again. `reconcilePark` already partitions the
  prior parked set, so carry needs nothing new.
- **PA dispatch is part of the splice.** A spliced interval's PAs
  re-attach to their host columns; carried events keep their
  attachments (`rebuildPA`'s per-chan touched set already exists to
  gate the re-sort).
- **Externals come for free; extraColumns has nothing to port.**
  Externals are discovered by the partition walk, which this phase
  scopes to the closed interval — a foreign event only appears under
  wholesale dirt or inside an edited interval. `extraColumns` is
  grow-only and merge-safe (§ Derivation dirt) already.
- **One deliberate wholesale residue.** The derived-note routing into
  `fx.noteExisting` stays whole-channel until phase 5: the fx
  reconcile is still channel-wide there, and a partial `noteExisting`
  would read as mass deletion. Cost is per *derived* note — zero on
  fx-free channels — so the dense-take win is untouched.

### Phase 4 — same-pitch, uuid addressing, and the interval tail walk

The dense take's edit-path `tails` ~14 (§ phase 0; the draft's 33.5
was a cold/GC-inflated run). **Three commits, in this order** — they are
independent and bisect differently, and landing them together means a
red suite says nothing about which idea was wrong.

**1. The clip** (§ Same-pitch is a projection artefact). The walk
computes two bounds, `endppqC` re-homes onto the lane bound,
`realiseParked` loses its pitch grouping, and the flush pre-clip's
tail-bound loop goes. This changes what the screen shows and which frame
owns the constraint, not how dirt works.

It predicted itself not spec-neutral, and it was wrong: the suite stayed
green at 2035. Every same-pitch spec that reads a *column* surface authors
its pair in one lane — `tm_proj_symmetry`, `tm_authoring_forward`,
`tm_macro`'s "same-pitch note bounds the host" — so the lane bound lands
on the peer onset and produces the same number the pitch clip did. Their
names say same-pitch; the mechanism they observe is the lane. The
cross-lane case, where the two bounds actually differ, had no spec at all,
which is why nothing went red. `tm_clear_same_key_spec` grew it: a
same-pitch peer in another lane, asserting the wire clips and `endppqC`
does not. It fails on the pre-commit code at exactly that assertion.

**2. uuid addressing, and separation lands once.** `mmBatch` names notes
by uuid, and mm grows a uuid-keyed assign over its existing
`eventsByUuid`. The reseat's and flush scan's nudges then delete, leaving
the walk as the single separation site.

mm's half is the easy one; tm's index reconcile is the exposure. Both
sides already maintain a uuid index (tm's at `trackerManager.lua:643`,
evicted and re-keyed at `:659-662` and `:681`) — but the index is not
what is token-shaped, the **reconcile** is. `idxReconcile` (`:668`)
drives entirely from a token: `prev = byToken[tok]`, then
`mm:byToken(tok)`, which under a collision returns only the survivor
(`midiManager.lua:1211`). `chansListFor` then matches — same chan, same
lane — so `refreshEntry` overwrites the loser's table in place and
re-keys `byUuid` from the loser's uuid to the survivor's. tm loses the
note from *both* indices, `byUuid` notwithstanding.

So this commit re-keys `idxReconcile` and `mmBatch`'s touched set to
uuid, while `byToken` stays for its other consumers (`tm:byToken`, the pb
seat lookup) as a knowingly-lossy half under collision — sound only
because a collision is transient within a batch and nothing reads
`byToken` while one is open. That is the decision the commit makes, and
it is the one worth pinning: a spec that carries a collision across two
commits and reads both notes out afterwards.

**Landed 2026-07-17, and the nudges were even less load-bearing than
this predicted.** Both deletions were spec-neutral (2044 → 2047 green,
the three new pins aside), and the reason is worth recording, because it
is not the reason given above. This section says the walk covers the
reseat and mm's backstop covers the flush scan. In fact **each collision
is covered twice over**: `tm_reseat_collision_spec` stays green with the
walk's `nudgeOnsets` disabled *and* stays green with mm's backstop
disabled — only disabling **both** lands two voices on one raw. The walk
and the backstop are independently sufficient, so the deleted nudges were
the third and fourth layers separating one collision, not the first.

That redundancy is also why neither nudge could be deleted on the
suite's word: no single-layer break can go red, so a spec written against
the layer you *think* delivers the geometry pins nothing. The pins that
landed therefore assert the surviving voice and name no layer at all.

Two findings fell out of building them, neither in scope here.
`swing.fromLogical` is **injective** — scanned over 0..3840 at shifts up
to 0.30, no two seats share a raw — so a reswing alone can never collide
two notes; it takes a delay, which the recompute folds in and swing then
moves the seats around. The reseat's deleted comment ("reswing can
collapse two distinct-ppqL same-pitch notes onto one raw") was true only
in that sense. And `vm_reswing_lane_stability_spec` declared its swing
curve as a bare factor list where the live shape is `{ factors = {...} }`
(cf. `vm_reswing_cc_spec:7`), so the curve resolved silently to identity
and the spec had never reswung anything despite its name — corrected
here, and its assertions hold under a real c58.

**3. The interval walk.** Tails close per the crux row — [prev onset,
next onset], same-lane ∪ same-pitch, raw order — and the walk **emits**
that closure for seats and PCs to consume. Closure lives here and only
here; phase 3 materialises against raw seeds and has none.

The shape of the change is not "narrow the group build to a region" but
"stop building groups". Today `strictNextMap(byLane)` / `(byPitch)` map
successors across the whole channel; this phase replaces them with
per-seed neighbour queries against mm's ppq-ordered per-channel index —
phase 3's scratch anchor query (open q5, resolved) — and the walk grows
its working set as the sweep reaches. I8 stands unchanged and
`collisionsResolved` gains no new job (§ The tails closure is the walk's
output, not its input).

**Delete `dirtyChan(chan)` at `:2703` in this commit** — not later, and
not narrowed in place. It carries the same fact as the emission on the
same trigger, and being the coarse mechanism it wins: left in, it writes
`true` over the interval set the emission just built, seats and PCs read
wholesale, and the emission is dead code (§ The widen and the emission
are the same fact). It stands through commits 1–2 and dies here.

Two things to pin, and one to measure. Pin that a same-pitch cascade
seeded at a sparse region's last onset lands its nudge rather than losing
a voice, and that the interval the walk emits covers every onset it
moved, since seats and PCs are the consumers that would silently miss
one. Measure the neighbour query: same-pitch successor over a ppq-ordered
index is a forward scan past unrelated pitches, so what was one O(n)
channel sweep becomes a per-seed scan that a dense single-channel take
could make worse than the whole-channel build it replaces. That is the
phase's real cost risk, and glasswork is the fixture that shows it.

The walk still unions `noteLive` wholesale until phase 5 — predicted
fxNotes outside dirty intervals re-derive converged clips, zero writes,
macro-take cost only.

### Phase 5 — fx producers consume intervals

The macro-take programme, and the same predicate as phase 3's windows
one level up — window recompute is the geometric half, producer re-run
the generative half: **a producer runs iff its window intersects dirt
or its spec is dirty.**

A skipped producer keeps its output by **identity-keep**: its existing
derived notes (`fx.noteExisting` — mm clones carrying every `fxKey`
field plus `lane`) feed `predicted` verbatim, so `reconcileFx` keeps
them all and stamps token + realised end through the normal `onKeep`
(`trackerManager.lua:565`). `noteLive` then carries the union of
regenerated and kept specs — unchanged in content — which resolves
open q4: `noteLive` stays the carrier, no cross-stage dirt plumbing.
Phases 3's and 4's wholesale residues (derived-note routing, the
`noteLive` union) narrow to intervals here.

The fiddly half is the continuous side, and it may stay wholesale. A
skipped producer's cc seats (`fx.ccExisting`, window-recognised) must
carry rather than reconcile away, and its pb chain feeds
`rebuildPbs`'s channel-wide fold — so either the continuous stages of a
skipped chain still run (gating only note expansion), or the fold
learns to keep window-keyed emitted output. The macro fixture puts this
at `pbs` 20.8 + `ccs` 9.0 ≈ 30ms of the 78ms no-op (§ phase 0) — large
enough that leaving it wholesale caps the phase-5 win; note expansion
first, then the continuous side decides on the measured residual.

Same phase: the all-16 region/parking dirt sources narrow to their own
spans — a region edit knows its chan and extent
(`trackerManager.lua:3314`, `flushParked` :1019); seed that interval
instead of `dirtyChan()`.

### Phase 6 — seats, PCs, and the sample stamp (profile-gated)

`pbs` 1.5 and `pcs` 0.0 on the dense take: genuinely small, so the
seats/PC closures (crux rows 2–3) run only if a profile ever says
otherwise. If one does, the walk's emitted dirt (phase 4's commit 3) is
what makes the seats closure *correct* here: without it a moved lane-1
onset is absent from pbs's dirt, which is a stale seat rather than a slow
one. Nothing further is needed at `:2703` — commit 3 removed the widen
that would have masked the emission with whole-channel dirt. The `note.sample` stamping (§ crux bearing rule) is
independent and landable any time — free under the no-legacy-data
policy, it unblocks PC closure, and it lands the semantic change
(inheritance freezes at stamp time) where its UX is judged on its own,
without interval machinery in the frame.

### The ceiling, stated

On the dense take, phases 3–4 take `reload` ~60 → ~15ms: what remains
is `fire` ~8 — the output side, tm's monolithic `'rebuild'` signal,
§ Framing's named successor — plus residuals. The flush's write side
stays put, because `serialise` ~14 + `setEvts` ~10 + `sidecars` ~2
is the write-side programme (`15a343d` is its first landed commit).
Interval dirt narrows the compute between the edit and the writes; it
touches neither neighbour.

### The end state — rebuild(∅) does literally nothing

The plan's terminal invariant: every stage consumes intervals, so the
degenerate rebuild — empty dirt, no stale swing, not wholesale, no
take swap — short-circuits **before** the pipeline: no nest, no
`clearSwing`, no `derivedInputs` clone, and no `'rebuild'` fire — the
fire is 10.4ms of tv re-placing a frame that did not change. Empty
dirt implies no staged ops, so the skipped `clearStaging` is vacuous.
The one fire that must survive is `takeChanged`: a converged rebind
carries no dirt but tv still needs the bind signal. This subsumes the
predecessor's 1.15ms floor — that number was the traversal cost of
discovering there was nothing to do; the short-circuit is the
statement that discovery is O(dirt), not O(take). (`fire` on a rebuild
that *did* derive something stays whole — that is the delta-signal
successor, not this project.)

## Open questions

1. What is the anchor, per stage, that terminates a forward closure?
   **Resolved** (§ The crux, closed): neighbouring onsets in the stage's
   own grouping and frame; the cascade is exempt via the backstop.
2. Where do intervals come from? **Resolved** (§ Framing): born at the
   um verbs, which know exactly what they touched. mm's `reload`
   payload stays channel-named; wholesale remains the external
   dirt-everything path.
3. How do intervals merge? **Resolved** (§ Implementation plan,
   phase 1): coalesce per channel at seed time; each consuming stage
   closes the merged set against its own ordering — closure after
   merge, since merging can pull a new anchor into range.
4. Is `noteLive` still the right carrier between fx and its downstream
   readers (`tails`, `pbs`, `pcs`)? **Resolved** (§ Implementation
   plan, phase 5): yes — a skipped producer's existing output feeds
   `predicted` verbatim, so `noteLive`'s contents are unchanged and no
   cross-stage dirt plumbing appears.
5. Which index answers raw-order anchor queries? Tails/seats/PCs close
   to raw-order neighbours (delay can reorder onsets between frames),
   and nothing persistent indexes that. **Resolved** (§ Implementation
   plan, phase 3): the raw working set, built per pass from mm's
   per-channel index — array order is raw-ppq ascending after
   reindex — whole-channel at phase 3, narrowed to the closed region
   at phase 4.
