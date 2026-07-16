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
| the hard part | was forward propagation — closed 2026-07-15 by onset-bounded closures + the cascade commute (§ The crux, closed); the multi-pass I8 restatement arrives with phase 4 (the interval tail walk) and is core |

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
its own fixture. I8 stays intact through phase 3; the multi-pass
restatement (§ The cascade commutes) arrives with phase 4, core rather
than avoidable.

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
later only if a phase pays for it.

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

- **Columns splice.** `rebuildInternals` / `rebuildCCs` clone from mm
  only events inside the closed interval and splice them into the
  carried columns: dirty span out, fresh clones in. The
  materialisation closure is the **union of the consuming stages'
  closures** — those stages read the fresh clones, so whatever they
  will re-derive must be re-materialised. Anchors resolve against the
  carried columns (uuids survive; § Intervals are event-anchored).
  Splice position at equal `ppqL` is defined and `sortByPPQ` gains a
  tie-break: chord-mate order must be deterministic or the parity
  spec's frame comparisons flap.
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

### Phase 4 — the interval tail walk, and the cascade machinery

The dense take's edit-path `tails` ~14 (§ phase 0; the draft's 33.5
was a cold/GC-inflated run). Tails close per the crux row — [prev onset,
next onset], same-lane + same-pitch, raw order — and the walk's groups
build only over closed intervals. The raw-order anchor query is
phase 3's scratch (open q5, resolved): this phase narrows its build
from whole channel to the closed region, slicing mm's per-channel
index between the interval's anchors.

This is where the exempt cascade arrives for real: `collisionsResolved`
becomes a seed source for the next maintenance pass, the signal owes
the scheduling guarantee § The cascade commutes records, and I8
restates as "finitely many passes when a cascade escapes an interval",
with the soundness specs updated in those terms. The walk still unions
`noteLive` wholesale until phase 5 — predicted fxNotes outside dirty
intervals re-derive converged clips, zero writes, macro-take cost only.

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
otherwise. The `note.sample` stamping (§ crux bearing rule) is
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
