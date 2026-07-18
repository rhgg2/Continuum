# interval dirt — dirty ppq ranges, not dirty channels

> Working design doc, **in flight**. Successor to the
> `incremental-rebuild` programme (`design/archive/incremental-rebuild.md`,
> closed 2026-07-15). One idea: make the unit of derivation dirt a **ppq
> interval within a channel** rather than the whole channel. It subsumes
> that programme's one deferred gap — the fx dirt signal — which is why
> that gap was deliberately left undone rather than patched.
>
> 2026-07-18: the model inverted — the unit of dirt is the **seed**
> (an event, verb-born), and intervals are a derived view
> (§ The model, inverted: seeds carry the dirt).

## Status at a glance

| | |
|---|---|
| state | landed — phases 1–3; phase 4 2026-07-17; phases 4.5 + 4.75 2026-07-18; model inverted to seed dirt 2026-07-18 (§ The model, inverted); phase 5 note half 2026-07-18, continuous half planned 2026-07-19 (§ phase 5) |
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

> 2026-07-18: the interval proved to be the migration vehicle, not the
> model — the section below states what it converged to.

## The model, inverted: seeds carry the dirt

> Added 2026-07-18, out of phase 4.75's design round. Two commits had
> already voted: `2541738` and `e33b768` store raw seeds and
> materialise interval views from them per pass. This section makes
> that the stated model rather than an implementation accident.

**Dirt is a per-channel list of seeds.** A seed is an event reference
plus its birth snapshot: uuid, verb, and the position/lane/pitch/span
the event had at the verb. Everything the interval model laundered
into geometry decomposes back to seeds:

- **The walk starts from seeds by name.** Phase 4.75's binary seek —
  and its raw-vs-logical delay-slack constant — existed only to
  rediscover, from a positional range, the events the verb had in
  hand. Seeds hand them over: `byUuid` for survivors, the snapshot
  for the dead.
- **Span-staleness needs no scan.** An interval says "something
  happened in here" without saying what, forcing a
  scan-until-every-lane-is-represented. A seed names its lane and
  pitch, so the candidates are two keyed probes — the nearest
  same-lane and same-pitch predecessors of the seed position. The
  lane shield survives as the *proof* those two suffice; the overlap
  margin dissolves entirely (a keyed probe needs no stop-condition
  patch).
- **Region park was never a span.** Its effects are exactly the
  effects of the members it removed and restored — per-member
  deletion/insertion seeds. The region extent was the verb
  summarising, as a rectangle, events it knew individually.
- **The window gate is a query, not a set.** "A host regenerates iff
  a seed touches its window": the seed's span (a deleted note's
  reach, snapshotted) is a per-seed attribute, the window a per-query
  argument. No merged interval set participates — a sorted seed list
  and a range check. Dirt is one pass's edits, small by construction;
  coalescing was an optimisation for a size the set never has.
- **Dedup is by uuid, the semantically right key.** Interval merge
  could only coalesce geometrically; repeated edits to one event
  collapse to one seed.

What survives of "interval" is three shadows: spans as seed
attributes, spans as query windows (fx hosts, the walk's emitted
absorber stain — a span that is a fact *about* its anchor event,
cached on the seed or derived by the consumer), and the `wholesale`
sentinel, which was always outside the algebra. What that leaves of
the module itself is small enough to schedule (§ Retirement of
`intervals`).

**The one discipline seeds demand:** a consumer must not assume the
anchor still exists. Position goes stale as things move; uuid dangles
as things die; the seed carries both so each consumer picks the one
still true. Dirt clears every pass, so the staleness window is one
pass — unchanged from today.

§ Intervals are event-anchored was this model seen from the wrong
side: it bolted events onto intervals because naked numbers went
stale. The inversion completes it — events are primary, geometry is
derived. Phase 5 is unbuilt, so its gate gets written seed-shaped
rather than ported later.

### Retirement of `intervals`

The module's entire production surface is seven trackerManager call
sites; everything else is its own spec. Their fates:

- **Die with phase 4.75's walk**: the sweep's two `intersects` gates
  (`trackerManager.lua:2667`, `:2716`), and the emitted absorber
  stain's `seed` + `merge` (`:2707`, `:2755`) — the walk instead
  emits a seed record (the nudged anchor, span cached from
  `laneNext`) appended to the channel's seed list.
- **Convert at the flip** (phase 4.75 commit 1): `seedAt` (`:728`)
  becomes the birth-snapshot constructor; `absorbReloadDirt`'s
  `absorbSeeds` fold (`:1185`) becomes dedup-by-uuid plus the
  wholesale sentinel.
- **Convert at the switch** (phase 4.75 commit 4): the column
  materialisation gates `exciseNotes` (`:1587`) and
  `rebuildInternals` (`:1613`) move to seed membership — uuid for
  survivors and assigns, snapshot position for the holes deletions
  leave. `intersects` loses its last caller; `intervals.lua` and
  `tests/specs/intervals_spec.lua` delete.
- **Never written**: phase 5's window gate is born seed-shaped — a
  scan of the small per-channel seed list per host window, no module
  behind it.

Two conventions outlive the module, relocated rather than retired:
`dirt == true` was always a `dirtyChans` convention, not interval
algebra; and `MAX = 64`'s degrade-to-whole-channel role is replaced
by the seed-count threshold gating the degenerate walk
(§ Phase 4.75) — the same idea with a better justification.

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

> 2026-07-18: completed by the inversion (§ The model, inverted) —
> anchoring events to intervals was the half-step; the events are the
> dirt, and the geometry is the derived view.

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
  already the persistent raw store; read it. *Superseded by phase 4.5:*
  the per-pass build was measured as the edit path's single largest
  stage, and the working set becomes um's maintained index instead.
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
output, not its input). The backward sweep that builds these maps runs
once, right-to-left: at each note it reads the running next for its lane
and pitch, and — since 'next' is strict-greater on raw ppq — a chord-mate
sharing the note's own raw ppq is not itself next, so it hands over the
next it already resolved rather than standing in as one.

`disturbed` is the walk's per-note seed test, kept deliberately narrow:
an unnamed note that kept its raw and its ceiling, and last pass left it
separated from neighbours that also stood still, has no news to report.
A note is disturbed only when this pass's dirt intersects its `ppqL`, or
unconditionally when derived — fx regenerates `noteLive` whole, so a
tile's raw is news whatever the dirt says. Collision is one-directional:
a note colliding with its settled same-pitch predecessor gives way
forward past it — the predecessor never moves — and giving way marks the
mover disturbed afresh, so the cascade carries itself forward through
successive give-ways without needing a fence (§ The tails closure is the
walk's output, not its input).

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

**Landed 2026-07-17** (`9a4e341`; `e4b3804` follow-up). The measured
verdict reshaped the plan: the narrowing itself bought ~0.8ms of an
11.7ms walk — the structural half (no group builds, one backward sweep)
bought the rest — and the profile found the real cost a stage up, in
`rawScratch` (§ phase 4.5). The predicted neighbour-query risk never
materialised, because the landed shape never queries per seed: one
backward sweep resolves lane and pitch successors for every note in a
single pass, running state keyed by lane/pitch rather than by note.

The walk still unions `noteLive` wholesale until phase 5 — predicted
fxNotes outside dirty intervals re-derive converged clips, zero writes,
macro-take cost only.

### Phase 4.5 — the raw working set is um's index

> Added 2026-07-18, out of phase 4 commit 3's post-landing profile. The
> commit's narrowing bought ~0.8ms; `rawScratch`, the stage phase 3
> re-added "for the interim", cost more than the whole walk saved. Half
> of that was `util.pick` re-parsing its key string once per note
> (fixed, `e4b3804`, 19.1 → 9.4ms); the rest is the clone itself, and
> this phase deletes it.

Phase 3's working-set bullet rejected raw fields on column events as "a
hand-synced cache of mm with a dual-write invariant at every mm write
site" — and then built a per-pass derivation while overlooking that the
codebase already maintains exactly that cache, done right. um's index
(`byUuid`, per-channel `chans`) holds an um-owned clone of **every** mm
event in the **raw frame**, `ppqL` sidecar intact — `makeEntry` never
projects — and every mm-write site reconciles it: the verbs, flush, and
each `mmBatch` commit run `idxReconcile` over the touched set
(`trackerManager.lua:1517`). The dual-write invariant the rejection
feared is not a risk to decline; it is load-bearing, shipped, and was
validated by shadow-compare (`docs/trackerManager.md` § Incremental
index reconciliation). scratch re-derives a filtered copy of this index
wholesale each pass — on the dense edit, ~9.4ms cloning 8437 records so
the walk can bound three — and the walk then pays ~5ms sorting an array
whose source lists were sorted all along.

So the working set stops being derived and becomes the index. The walk,
`rebuildPA`/`findNoteColumnForPitch`, `rebuildPbs` and `rebuildPCs` read
index entries directly, with scratch's predicate (`not derived and ppqL
~= nil`) applied at the use sites; `buildRawScratch`, `pickScratch` and
the scratch threading die.

Three questions closed before planning, one landmine found:

- **Mid-pass mutation is safe, with one exemption.** Nothing reads the
  index between the walk's nudge/clip and `clampWrites.commit()`; the
  other readers (`detuneAt`, the pb seat adoption, `forEachAttachedPA`)
  are command-path, which never overlaps a rebuild. The commit is
  convergent by construction — `mm:assign` writes the values already on
  the entry, and the post-commit `idxReconcile` refreshes it to the same
  state. The exemption: `refreshEntry`'s nil-sweep strips fields mm's
  clone lacks, so the `colEvt` decoration (below) joins `realised` on
  its exempt list.
- **A nudge's resort is already solved.** `idxReconcile` removes and
  reinserts an entry whose `ppq` changed — the sorted lists re-true at
  the very commit that lands the nudge. The walk reorders its own
  working sequence only under `anyNudge`, as now.
- **Restores stay outside the index.** A restored note has no uuid until
  `mm:add` assigns one at `deferred.commit`; pre-filing it would
  duplicate against the canonical entry `idxReconcile` files at that
  commit. They remain extra walk inputs, exactly as today.
- **The landmine: wholesale passes consume a stale index.** On
  `wholesale=true` every mm event object is new and the index is dead —
  and `reload()` runs at the *end* of the pipeline (`:3226`), because
  nothing in the pipeline consumes the index today. Under this phase the
  walk would read dead tables. So `reload()` moves to the pipeline head
  on wholesale passes; the pipeline's own `mmBatch` commits then
  maintain it incrementally, exactly as edit passes do, and the end
  state is identical.

Four commits, each green alone:

1. **Rename.** `chans` → `rawIndex` (`chansListFor` / `chansInsert` /
   `chansRemove` follow). It sits one letter from `channels`, the
   logical column world; the new name says the frame and the role.
   Mechanical, zero behaviour.
2. **`reload()` to the pipeline head** on wholesale passes.
   Behaviour-neutral today; load-bearing for commit 4.
3. **Widen.** `rawIndex[chan].notes` goes all-lane, sorted
   raw-then-logical — strictly finer than today's bare-ppq `sortByPPQ`,
   so `at-or-before` seeks are unaffected; `detuneAt` gains a lane-1
   filter walking back from its seek rather than keeping a second
   overlapping list. Entries gain a `colEvt` backref stamped where
   columns seat their cells (internals, externals, region park) —
   O(dirty clones), replacing the per-pass O(channel) `colByUuid` scan —
   with the `refreshEntry` exemption.
4. **Consume and delete.** The four readers move onto the index; the
   walk's whole-channel sort becomes a merge of the pre-sorted index
   list with the small sorted extras (restores + `noteLive`);
   `buildRawScratch` dies.

Expected on the dense edit: `rawScratch` ~9.4 → ~0, the walk's sort ~5
→ a sub-ms merge — roughly 14ms → 4.5ms across the two stages. What
remains O(channel) is the sweep's own traversal (array build, seed
test, successor bookkeeping); if a profile ever demands more, that is a
separate narrowing with its own design, not this one — now written,
§ Phase 4.75.

> **Landed 2026-07-18**, four commits. Two corrections to the closed
> questions above. *The nudge's resort was not already solved*: the
> walk mutates the shared entry's ppq in place, so by reconcile time
> `prev.ppq == e.ppq` and the unchanged-ppq fast path keeps the stale
> slot — the remove-and-reinsert never fires. The walk re-trues the
> channel's list itself (`resortRawNotes`) under the same rare
> `anyNudge` branch that re-sorts its working sequence. And restores
> stayed extra inputs to the *walk alone*: `rebuildPA` never needed
> them — a restore's `endppq` is nil until the walk derives it, so the
> containment scan cannot match one — and `rebuildPbs`/`rebuildPCs`
> run after the deferred commit has filed them into the index.

### Phase 4.75 — the walk seeks, and stops sweeping

> Added 2026-07-18 — the "separate narrowing with its own design"
> that phase 4.5's closing line deferred, opened early because the
> design turned out to be small: every question the sweep answers has
> a positional bound. Probe split of the surviving sweep on the dense
> take, single-note edit: seed test ~1.1ms, nudge bookkeeping ~0.5ms,
> successor bookkeeping ~2.0ms, merge ~0.4ms — ~4ms per dirty dense
> channel, all O(channel), the useful output three notes.

The sweep's linear passes answer four questions. Each has a positional
bound, so the walk can seek to the dirt and probe outward instead of
visiting the channel.

**Seeds arrive named.** (Rewritten under § The model, inverted — the
first draft specified a binary seek with a raw-vs-logical delay
slack, machinery whose only job was rediscovering the events the verb
had in hand.) The disturbed set opens with the seeds themselves:
`byUuid` for survivors, the birth snapshot for events that died at
the verb. Derived seeds need no lookup either: they are `noteLive`,
seeded by membership.

**Nudge probes stop at the tick.** The verdict is `e.ppq <= prev.ppq`
(`voicing.lua:60`) over a ppq-sorted sequence: only a predecessor tied
at the seed's raw tick — or shoved onto it by a chain of ties, each
giving way one tick — can collide. The backward probe scans the
same-tick cluster and stops; forward, the cascade is self-limiting,
each nudge threatening only a successor within a tick of where it
landed.

**Lane bound first; the pitch probe is capped by it.** The pitch
successor enters only through `min(laneBound, pitchClip)` (`:2737`) —
a same-pitch successor beyond `laneBound` cannot bind. So the probe
order is: lane bound first (its own probe capped by the authored
ceiling and `takeLen`), then a pitch probe confined to
`[ppq, laneBound)` — typically one row. The linear sweep gets both
successors for free in one backward pass, which is why this ordering
doesn't exist today; it becomes the cap exactly when probes replace
the sweep.

**Span-staleness: two keyed probes per seed, by the lane shield.**
The authored-span test (`:2716`) is the piece with no positional
bound as written — an `open` note's authored span is infinite, so
every open note before any dirt recomputes every pass. Under the seed
model it is replaced outright: each seed names the lane and pitch it
disturbed — the snapshot carries them even for deletions, so the
neighbour that left *can* be asked — and the candidates are the
nearest same-lane and same-pitch predecessors of the seed position.
Two probes, keys known. The **lane shield** is the sufficiency proof:
a surviving same-lane note between a note and the seed caps both
bounds at once. `laneClip` cannot change — an insertion at the seed
is farther than the intervener, a deletion at the seed was never the
winner — and any same-pitch change at the seed sits beyond
`laneBound`, so it never binds in the min. Everything earlier in the
lane than the nearest predecessor is therefore shielded by it.
Equivalent to the authored-span test — the search dissolved, the
staleness rule untouched. Parked cells still participate as lane
bounds: a lane probe that meets a parked member first stops there —
shielded, and the parked cell itself is bound-only, never a
candidate. (The first draft scanned backward until every lane in use
had a representative, with an `overlap`-margin patch on the stop
condition — both were the interval model's price for forgetting
which events the dirt was born from.)

**The frontier keeps the sweep's two-pass structure.** Onset
settlement first, in ppq order — seeds settle against their same-tick
predecessors, a landed nudge may enqueue its pitch successor, and the
ordering preserves the sweep's invariant that a note consults only
settled predecessors. Then bounds, order-free: the settled set, plus every seed's and
every disturbed note's nearest lane and pitch predecessors, re-bound
via the capped probes — bound recomputes read
settled onsets and write only `endppq`, so they cannot re-disturb —
and the nudged-lane-1 seat emission (`:2706`) reads the lane successor
the bound probe already fetched.

**No merged array; extras stay visible to probes.** `mergeIndexed`
dies with the sweep: probes run against the index and the small extras
(restores + `noteLive`) side by side, taking the nearer hit. On an
fx-heavy channel the derived seeds are all of `noteLive` and the
frontier is as large as the regeneration — inherent, and exactly
proportional to the work fx created.

**The degenerate case gates on seed count.** `dirt == true` — and any
interval set whose seeds approach the channel — keeps a linear walk:
per-note probes without running state go quadratic on full-channel
frontiers. The two walks share the bound body (ceiling / laneClip /
pitchClip / write-back, extracted once); the switch is a count
threshold, not a second implementation of the rules.

Five commits, each green alone — the first is the model flip's
landing, since the seek walk starts from seeds by name and needs
`dirtyChans` seed-shaped before it exists:

1. **Dirt carries seeds** (behaviour-neutral). `dirtyChans[chan]`
   becomes a deduped seed list or `true`; `seedAt` constructs the
   full birth snapshot (uuid, verb, lane/pitch/span);
   `absorbReloadDirt`'s fold becomes dedup-by-uuid plus the
   wholesale sentinel. The four surviving `intersects` sites read a
   thin span view derived per pass, so the sweep behaves
   identically.
2. **Extract the bound body.** The per-note settle-and-bound rules
   leave the sweep's loop as functions over (note, neighbours); the
   sweep calls them. Zero behaviour.
3. **The linear walk, shadow-compared.** Build the whole-channel
   settle-and-bound walk — seeds by name, predecessor probes for the
   stale bound — and run it alongside the sweep, diffing staged writes
   and emitted dirt (the validation that landed the index, § phase
   4.5). This is the degenerate walk, not yet the frontier one; it
   earns its place as the permanent fallback. Fixtures the suite lacks
   and this phase needs: a same-tick nudge cascade, an open note behind
   dirt with and without a lane shield, an insertion inside the overlap
   margin.
4. **Switch, and the module goes.** The linear walk becomes
   authoritative and the shadow harness dies. `exciseNotes`/
   `rebuildInternals` convert to seed membership by logical row,
   `intersects` loses its last caller, and `intervals.lua` deletes with
   its spec (§ Retirement of `intervals`). No threshold yet — the
   linear walk is the sole walk until commit 5 adds its faster sibling.
5. **The frontier probe walk.** The sparse-seed fast path: seek to the
   dirt, cap the lane and pitch probes — no whole-channel traversal. A
   seed-count threshold picks it over the linear walk (§ The degenerate
   case gates on seed count). This is the commit that turns the ~4ms into
   sub-ms. Landed as two sub-commits: build + shadow-compare against the
   now-authoritative linear walk (2026-07-18), then the threshold flip
   that retires the shadow. Three deviations from the sketch above, all
   in `docs/decisions.md` § 2026-07-18: `rawThenLogical` became a total
   order (same-tick piles had no defined settlement order); settlement
   gathers each pitch's cascade against the pristine index before moving
   anything (a mid-mutation binary search hangs); and `mergeIndexed`
   survives on the linear path — only the frontier drops it.

Expected on the dense edit: the tails stage's ~4ms of remaining
traversal collapses to probes over dozens of entries — sub-ms, once the
frontier walk lands (commit 5). The O(channel) shapes still standing
after this are pbs' and PCs' channel folds — phase 6's profile-gated
business, ~1.5ms today.

### Phase 5 — fx producers consume intervals

The macro-take programme, and the same predicate as phase 3's windows
one level up — window recompute is the geometric half, producer re-run
the generative half: **a producer runs iff a seed touches its window
or its spec is dirty** — the window a query over the sorted seed
list, per § The model, inverted.

A skipped producer keeps its output by **identity-keep**: its existing
derived notes (`fx.noteExisting` — mm clones carrying every `fxKey`
field plus `lane`) feed `predicted` verbatim, so `reconcileFx` keeps
them all and stamps token + realised end through the normal `onKeep`
(`trackerManager.lua:565`). `noteLive` then carries the union of
regenerated and kept specs — unchanged in content — which resolves
open q4: `noteLive` stays the carrier, no cross-stage dirt plumbing.
Phases 3's and 4's wholesale residues (derived-note routing, the
`noteLive` union) narrow to intervals here.

> Commit 1 — the note half — landed 2026-07-18 (`83df1a4`): a
> pure-note producer (`generators.hasContinuous` false) gates on
> `windowSeeded` over the seed rows, identity-keeping via
> `noteExisting` bucketed by producer id. Measured ~0.4ms on
> glasswork — pure-note producers are cheap; the macro cost is the
> continuous side below.

The fiddly half is the continuous side, and the measurement resolves
it (glasswork, `rebuild(true)` ceiling, 2026-07-18). The generative
half is free: generator `.expand` across every producer is ~0.7ms of
a 69ms re-derive. The `fx` stage's 31.5ms is `emitCC` 19.2 (the cc
chain fold, `reconcileDerived`, and the wire commit), `expand` 8.0
(almost all `channelStreams` slicing and `foldContinuous` — `.expand`
is ~0.7 of it), `reconcileNotes` 3.5, and `bases` **0.0**; `pbs` is
20.2, its `seats` 10.8 the `foldChains` fold and `match` 2.2 the seat
reconcile.

Two candidate mechanisms this kills. A per-producer output **stash**,
so a changed chain's neighbours re-fold from cached curves instead of
re-expanding, saves the ~0.7ms of expansion and nothing else — dead.
**Window-scoping the base scans** (`pbBaseFor`/`ccBasesFor`) saves
`bases`' 0.0ms — dead; the absolute-curve scan I feared would need
entering-edge lookback costs nothing, so it stays whole.

What remains is one family — fold, emit, reconcile — so the continuous
gate is the note gate's point-2 shape applied to **seats**. Three
scopes, from the dirt out (sharpened 2026-07-19: the first draft's "a
connected group gates as a unit" overstated the run set — a clean
window in a dirty window's connected component keeps):

- **Emit scope**, per target: the union of the dirty windows — seeded
  or spec-dirty — and nothing wider. A dirty member's curve
  contributes nothing outside its own window, so the fold output in a
  clean neighbour's remainder is unchanged by construction and its
  seats carry.
- **Run set**: producers whose window intersects the emit scope — one
  step of overlap, not the component. A clean neighbour overlapping a
  dirty window still *expands* (its curve is a fold input inside the
  overlap) but emits nothing of its own; a producer overlapping only
  that neighbour neither expands nor emits. A running clean
  producer's note output regenerates as a byproduct and reconciles to
  zero writes.
- **Keep**: every other producer identity-keeps, notes and seats
  both. Kept continuous producers still emit window-only records
  (`{ window, kept = true }`): the window geometry must stay complete
  downstream, because a markerless pb seat that loses its window
  reads as an authored pb.

Keep flows **through** the cc reconcile, not around it (amending this
section's first draft, which had kept output "bypassing
`reconcileDerived`"): a kept range feeds its existing seats into
`ccLive` verbatim, they self-match at zero writes, and a *vanished*
window's orphans — fed by nothing — still fall through to deletion.
Bypassing would need a separate death-detection mechanism and reopens
the silent-stale class. The reconcile's `existing` slice never
narrows; only the fold does.

The pb half has no reconcile to flow through — `deriveChan`'s match
is an absorber pool — so its kept mechanics are fences plus one
carry. `replaceWins` splits into live ranges (folded bps) and kept
ranges (recognition-only, no bps — `inSeatWindow` must keep seeing
them); in-kept-range pbs leave the absorber pool, the consolidated
assign, and every seat source (detune onsets, bps seats, densify, the
I2a anchor); and the pb column carries its **prior slice** over kept
raw ranges — last pass's fold stamped exact cents on those hidden
seats, and by I8 the prior slice is what a re-fold would produce,
where back-deriving cents from the wire quantises through
`centsToRaw` and breaks exact parity. One boundary detail: folding a
sub-range of a merged span, the closing value at an interior edge
belongs to the kept side — chain cuts align with window edges, so the
fold decomposes there.

Commits (commit 1, the note half, above), each green alone,
`tm_gate_parity_spec` extending at each:

2. **Enumerate producers, then run.** `expandChannel` gathers its
   three producer sources (on-take hosts, parked cells, regions) into
   one list before any expand runs; `generators.continuousTargets(fx)`
   lands and `hasContinuous` re-expresses over it. Zero behaviour —
   the restructure half of the phase discipline. *Landed 2026-07-19.*
3. **The cc half.** Per-target dirty-window scopes, kept window-only
   records, fold and emit narrowed to the emit scope, kept seats fed
   verbatim through the reconcile. Parity: a disjoint lfo pair (edit
   one, the other keeps); an overlapping pair (the clean neighbour
   expands, emits nothing); fx removal (orphan seats still delete); a
   write-count pin (no mm writes outside the edited scope). *Landed
   2026-07-19.* One deviation: no kept cc records in `ccChains` --
   with emission clipped to the emit scope they are geometrically
   inert (kept windows never intersect it), so the kept side is a
   per-target **target scope** (all producer windows, merged) computed
   at classification; existing seats inside it but outside the emit
   scope re-feed the reconcile verbatim. cc window geometry persists
   via `computeFxWindows` upstream of the gate, so nothing downstream
   loses a window. `pbChains` kept records (commit 4) stand. The
   write-count pin is uuid stability of kept seats (a delete/re-add
   would re-uuid). `generators.hasContinuous` deleted -- `keepable`'s
   vacuous target loop subsumes the pure-note test.
4. **The pb half.** Kept `pbChains` records, the `replaceWins` split,
   the fences, the prior-column-slice carry. Parity: disjoint vibrato
   hosts; a detune edit outside every window still reseats its
   absorber; write-count pin. *Landed 2026-07-19.* Two amendments.
   *Hold-stream reach*: authored pb/cc bases and lane-1 detune hold
   forward past window edges, invisible to window-local seeds -- and
   `absorbReloadDirt` folds `pbSource`'s wholesale bit down to seed
   dirt, so detune edits genuinely arrive gated. The gate therefore
   forces live any pb window ending after the earliest hold-source
   seed (pitch-nil or lane-1), and any augment-cc window ending after
   the earliest pitch-nil seed (closing commit 3's latent version of
   the same gap), cascading to fixpoint through live lane-1
   note-emitters, whose detuned output re-enters the stream. Known
   blind spot shared with `windowSeeded`: a moved pb/cc whose uuid
   `tm:byUuid` cannot resolve contributes only its birth row.
   *Onset-pair ownership*: a ramp onset's dual point rides one tick
   before it; both seats follow the onset ppq's side of the kept
   fence, so a kept boundary onset's pair stands verbatim (carried
   via the prior pb column, keyed on a `ppqRaw` stamp that survives
   projection, identity refreshed from the fenced wire clone -- a
   creation-pass projection predates its committed uuid) and a live
   onset at a kept edge reclaims both. The
   write pin is a verbatim before/after comparison of the kept
   range's dumped pb records.
5. **Measure on glasswork-dense.** A variant of the glasswork builder
   piling the same chains onto one channel, bridge-driven like
   glasswork itself — glasswork's spread over 16 channels makes its
   edit path write-bound (~3ms of re-derive), so the gate's win only
   shows against a producer-dense channel. Record the numbers here.

Same phase: the all-16 region/parking dirt sources narrow to their own
members — a region edit knows the exact events it parked and restored
(`trackerManager.lua:3314`, `flushParked` :1019); seed those, per
member, instead of `dirtyChan()`.

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
   at phase 4. **Re-resolved** (§ phase 4.5): the per-pass build was
   measured as the edit path's largest single cost; the persistent
   raw-order index is um's own (`byUuid` + per-channel lists), widened
   to all lanes and consumed directly.
