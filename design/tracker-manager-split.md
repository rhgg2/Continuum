# trackerManager: the algebra and the engine

> opened: 2026-08-07 · status: proposed — plan to follow
>
> `trackerManager.lua` is 5328 lines. This doc argues that it holds
> three tenants rather than one, that two of them can leave, and that
> the third — a ~2900-line derivation engine — is the right size for
> what it does. Two phases, each useful alone; phase 1 is also the
> measurement that decides whether phase 2 is worth taking.
>
> Prior art: `design/archive/um-index-stager.md`, which split the index
> from the stager in place and deferred extracting either to a module.
> That deferral is revisited under § What is not proposed.

## The problem

**1** tm is 5305 lines against a 39840-line codebase — one line in
seven. `trackerView.lua` follows at 4246, and then there is a cliff to
`wiringRender.lua` at 2687. Two outliers, and tm is the larger.

**2** The tempting diagnosis is that it is long because it is tangled,
and that the cure is to find the knot. The evidence is against it. Every
large section of the rebuild already exports exactly one name:
`rebuildPbs` for 574 lines, `rebuildFx` for 519, `rebuildRegionPark`
for 406, `rebuildTails` for 259. Around 2300 lines sit behind a single
door each, and `rebuildPipeline` (trackerManager.lua:4979) hands each
stage its inputs as parameters off one head snapshot. No large section
calls into another.

**3** Two couplings qualify that, and both travel by mutation rather
than by call. The first is dirt. `rebuildTails` writes
`dirtyChans[chan]` (trackerManager.lua:4253) and `rebuildRegionPark`
calls `seedDirty` at seven sites; `rebuildPA`, `rebuildFx`,
`rebuildPbs` and `rebuildPCs` then gate on the enlarged set. So dirt is
not a snapshot. A stage before the park pass gates on a strictly
smaller set than a stage after it, and the head snapshot gives the ds
keys exactly the discipline dirt lacks.

**4** The second is `fxOut`. The specs it carries in `noteLive` are the
same tables the tail walk mutates: `rebuildTails` takes them as
`extras` (:4217), and `settleOnset` writes their raw onsets and clipped
ends in place. Measured across the suite, every firing shares tables
between `noteLive` and `noteOps.adds`; the clip lands in
`tm_macro_spec`, `tm_trill_spec` and `tm_fx_region_spec`, the onset
move in `tm_interval_walk_spec`'s same-pitch cascade. `rebuildPbs`
reads the moved positions at :4288. Tails-before-pbs is therefore a
data dependency, and neither signature says so.

**5** So the length is not disorder. It is that three different jobs
share a file, and each is individually well kept. Naming them is most
of the design; what the two couplings cost it is D6 and § Open.

## Three tenants

**1** **The algebra.** Lines 272–586: half-open span sets, and
ppq-keyed breakpoint curves with their fold. Strip comments and string
literals and the region's free variables number one — `util`. It
reaches nothing, holds nothing, and could as easily be a library the
project depends on.

**2** **The edit side.** The raw index, the stager, the accessors, the
mutation API, length, transport, mute, lifecycle. It writes mm and
seeds dirt. Roughly 1700 lines.

**3** **The derivation engine.** Lines 2205–5108, plus the fx-expansion
helper family at 590–908 that only it calls. It reads mm, the index and
the dirt, and produces the frame. Roughly 2900 lines.

**4** The seam between 2 and 3 is not asserted, it is checkable.
`channels` is assigned in nine places. One is its declaration; four are
the carry-forward loop in `tm:rebuild` that allocates the frame; the
remaining four are stage writes inside REBUILD. The Mutation, Length,
Transport, STAGER and RAW INDEX sections do not mention it at all, and
every occurrence in Lifecycle is in a comment. The edit path stages to
mm and seeds dirt; it never touches the frame. That is what the layered
model already claims, and today it is true by discipline — it took a
script to confirm. After the split it would be true because the
edit-side file has no such variable in scope.

**5** The frame is one seam; the index is the other, and it runs the
other way. Both sides use it, but not alike. The edit path reaches it
through semantic doors — `detuneAt` for the prevailing detune at a
seat, `forEachAttachedPA` for a host's PAs — and touches the raw lists
six times in all. The engine takes the lists and walks them, twenty-six
times. And the mediated write surface that `um-index-stager.md` D2
built — `setRaw`, `stampColEvt`, `withDeferredSort` — has no edit-side
caller at all. The edit side asks the index questions; the engine walks
it.

## Phase 1 — the algebra leaves

**D1 — two modules, `spans.lua` and `curves.lua`, not one.** A span set
is not a curve. Folding them into one file would produce a grab-bag
whose name has to be vague enough to cover both, and vagueness in a
module name is how the next unrelated tenant gets in — which is the
history this doc is unwinding. `curves` requires `spans` for
`overlapping`; the arrow is one way.

**D2 — `spans.lua` publishes six, `curves.lua` eight.** Spans:
`mergeSpans`, `mergeWindows`, `overlapping`, `spanSetIntersects`,
`clipToSpanSet`, `subtractSpanSet`. Curves: `evalCurve`, `sliceCurve`,
`sumStreams`, `foldChains`, `foldIntoWindow`, `closeAtWindowEnd`,
`anyNonZero`, `isCurved`. Four of the fold's helpers — `negated`,
`foldWhole`, `chainCuts`, `foldSub` — have no caller outside the region
and stay private.

**D3 — `firstAfter` and `firstAtOrAfter` go to `util`.** They are
binary seeks over a ppq-sorted list, with nine external callers each
and further use inside both new modules. Putting them in `curves` would
make half of tm require a curve module to look up an index. `util`
already holds `util.seek` and `util.insertSorted`; these join them.

**D4 — cents↔raw stays in tm.** `pbLim`, `centsToRaw` and `rawToCents`
read `cm:get('pbRange')`, so they are configuration, not algebra. This
costs nothing: `sumStreams` clamps from `opts.lo`/`opts.hi` and never
names `pbLim` itself, so the boundary falls where it already is.

**D5 — phase 1 goes first because it is also the instrument.** Its own
value is modest — about 300 lines, six per cent of the file. Two other
things recommend it. The curve fold is currently reachable only through
a full tm rebuild, and six of the seven tests red at the session
baseline are `tm_fx_region_spec` pb-curve cases that run through
`foldChains`; extracted, it can be tested against a list of points.
And removing the pure names from every rebuild stage's dependency set
is what makes the phase-2 count below mean anything.

## Phase 2 — the engine leaves

**1** The tempting claim is that splitting the file reduces the
coupling. It does not. The engine needs what it needs, and moving it
across a file boundary changes none of that. What the move does is
*render* the coupling: an ambient upvalue is free to use and impossible
to count, and an injected dependency is neither. The question is
whether making the number visible is worth 2900 lines changing file,
and the answer turns on what the number is.

**2** Counted naively it is bad. The REBUILD region references about
110 names it does not declare. But most of that is not interface. Two
deductions cut it down.

**3** The first is material that travels. Twenty-two of those names
have *zero* uses outside the engine — they are the engine's own,
lexically stranded at file scope. The fx-expansion helper family at
590–908 is the bulk of it: `coverInto`, `membersOf`, `channelStreams`,
`allocateRegionLanes`, `hostProducer`, `producerCensus`, the reconcile
skeletons. They move with the engine and stop being names at all.

**4** The second is operations on structures already being passed. If
the frame travels as a handle, then `insertNoteCell`, `setCell`,
`sortNoteColumn`, `shedLane`, `sortByPPQ`, `rawThenLogical` and
`isSorted` travel on it rather than beside it: they are the frame's
operations, and the criterion is that each takes a frame or a piece of
one as its first argument. Seven names become zero.

**5** What remains, gathered, is eight: `mm`, `cm`, `ds`, `tm`,
`index`, `stager`, `dirt`, `frame`. The first four the file would take
via `(...)` exactly as tm does today at trackerManager.lua:54. The last
four are the decisions below.

**D6 — the frame is passed as a handle and mutated in place; the
published maps come back as a return value.** These pull opposite ways
and the reason for each should be plain. Mutating the frame in place is
not the house preference — gather, compute, mutate — but the stages
splice into columns they and later stages both read, and rewriting that
into a return-at-the-end is a different and much larger refactor than
this one. The fx maps have no such excuse: `fxRealisationByUuid`,
`fxTargetsByChan`, `freezeEligibleByUuid` and their siblings are
written once at the tail of the pipeline and read only by accessors, so
they come back from `run` and tm installs them. The rule is that the
engine mutates only what it was handed, and everything it *creates*
leaves by the return.

Two things are the engine's own and stay with it: `parkedClipEnd`
(trackerManager.lua:2828) and `fxHostWin` (:3328), uuid-keyed caches
that outlive a pass. Inside one file their invalidation is implicit —
`didReload` flows down from `tm:rebuild` and each cache reads it in
passing. Across a boundary it has to be said out loud, most simply as a
`forget()` the take-tier path calls. This is the boundary earning its
keep rather than a cost of it: a cache that survives a take swap is a
bug, and today nothing in the code names the moment it must not.

**D7 — the fx builders are the protocol already working.**
`buildFreezeMaps`, `buildFxTargets` and `buildFxRealisation` are
declared beside the accessors that read their output and called from
`rebuildPipeline`. The map lives with its readers and the pipeline
reaches out to fill it — which is D6's arrow, in production, today.
Three of the fx maps are instead written directly by the fx stage;
under D6 they join their siblings.

**D8 — the dirt spine becomes `dirt.lua`.** `dirtyChans`,
`staleSwing`, `shedLanes`, `muteConform` and their verbs — `dirtyChan`,
`seedDirty`, `parkSeed`, `rawSeed`, `seedRegionEdit`, `seedParkedEdit`,
`clearSwing` — are thirteen names, about ninety lines, and one job: the
journal the edit path writes and the rebuild reads and clears. Left
loose they are the largest lump in the engine's interface. Gathered,
they are one name. This is the phase's only genuinely new module
boundary, and it earns its keep on the count alone.

**D9 — the index and the stager stay in tm, gathered into door
tables.** They are the edit side's own state and their doors are
already declared as explicit lists (trackerManager.lua:908, :1170).
Passing `index` and `stager` as tables of those doors costs two names
and moves no code. The write surface makes this a positive choice
rather than a grudging one. `setRaw`, `stampColEvt` and
`withDeferredSort` are engine-only, so the line the handle draws is the
line the mutation privilege already has: tm keeps the lists true across
edits, the engine is the only thing that stains them mid-pass, and D2's
contract governs exactly that. Whether the index should later become a
file is a separate question, deferred below.

## What the specs hold

**1** A restructure is only as safe as what notices it breaking. The
tempting worry is that specs reaching into tm would have to move with
it. They do not. Across the `tm_*` specs the verbs are `tm:flush`,
`tm:addEvent`, `tm:getChannel` and `tm:rebuild`; none requires
`trackerManager` directly, and none touches an upvalue. The harness
fakes only REAPER (tests/harness.lua:29-34) — mm, cm and ds are real.
Whatever moves behind which boundary, the suite watches the same doors.

**2** `tm_gate_parity_spec` is the instrument that matters.
`assertParity` (tests/specs/tm_gate_parity_spec.lua:101-109) snapshots
the projected frame, the view grid and the mm bag, calls
`tm:rebuild(true)` to force all sixteen channels to re-derive, and
asserts all three unchanged. Gated and ungated agree across view, grid
and wire. That is the property a stage extraction is likeliest to
break, and it is already pinned.

**3** Two specs would nonetheless go red on a faithful move.
`tm_pb_gating_spec:24-25` asserts table identity of `columns.pb` —
reuse, not value — so anything reconstructing the wrapper fails on
equal data. And `VOLATILE` (tm_gate_parity_spec.lua:26) enumerates the
three fields allowed to differ between a carried and a fresh frame, so
a new per-pass scratch field on a column event fails as a spurious diff
rather than a regression. Both are cheap to update and expensive to
meet unprepared.

**4** The gap is `rebuildPbs`. It is the largest stage and the thinnest
pinned against its size: `tm_pb_gating_spec` is two identity cases,
`tm_pb_interp_spec` covers interpolation across a detune onset,
`tm_absorber_reseat_spec` the delay reseat, and `tm_tuning_spec`
reaches it only obliquely through cents. Its keep/live split and
`pbScope` gating rest on one case, gate parity's pb half. D5 makes the
same observation one level down, where the curve fold is reachable only
through a full rebuild. So pb realisation wants coverage at its own
seam before phase 2 moves it, not after.

## What is not proposed

**1** **Stage-per-file inside the engine.** Each stage is a single door
and could be a file, but each wants the same substrate, so ten files
would each carry the same constructor. The entity count multiplies and
nothing is learned. A 2900-line engine, sectioned as it already is, is
the right size for a batch derivation pipeline with nine stages.

**2** **`eventIndex.lua`.** `um-index-stager.md` D1 rejected it — "it
would make the record-sharing contract public before it is sound" —
and deferred a revisit until D2 settled who may mutate an entry. D2 has
landed; `setRaw` is in the export list, so the condition is met.

The answer is still no, and the readership is not the reason. Of
thirty-four references to `rawIndexFor`, twenty-six are the engine's
and six the edit side's — a thing two modules use, which ordinarily
argues *for* a module of its own. What argues against is unchanged from
D1. The readers receive live mutable records, so the boundary would
publish the sharing contract rather than close it, and it would buy 242
lines for a fourteen-door interface. A thing two modules use needs one
owner, not its own file. D9 gives it one.

## Open

**1** Whether `dirt.lua` (D8) is a phase-2 step or its own phase
before it. It is independently coherent and it shrinks the phase-2 diff
by thirteen names, which argues for going first. A second argument,
found since, is stronger. The lattice's join — every writer joining and
never assigning, `docs/trackerManager.md` § Derivation dirt: the gated
spine — is implemented three times: `seedDirty`
(trackerManager.lua:171), the reload fold (:1585), and the tail walk's
emission (:4251). The first two collapse past `WHOLESALE_SEED_CAP`; the
third does not. And the guard was missing from the reload fold until
2026-07-28, where it demoted a standing wholesale and left an OPEN tail
uncut. A lattice with three hand-rolled joins has already cost one bug
of the class a join makes impossible. The count is a tidiness argument.
This is a correctness one.

**2** What the module's doors are. D8 describes dirt as the journal the
edit path writes and the rebuild reads and clears, but the rebuild
writes it too, at the eight sites § The problem ¶3 names. So `mark` and
`seed` want a third companion for the mid-pass growth. That is the
boundary earning its keep rather than a cost of it: if the orchestrator
has to call it, the enlargement becomes visible at the call site, which
it is not today.

**3** What D6 says about a value the engine creates and a later stage
mutates. `fxOut` leaves by the return under D6's rule, and § The
problem ¶4 shows the tail walk writing its specs in place mid-pass. The
rule governs what the engine may touch of what it was handed. It does
not yet say what one stage may touch of another's output.

**4** What `tm` being in the engine's dependency list actually covers.
The stages call `tm:fromLogical`, `tm:toLogical`, `tm:byUuid` and
`tm:interpolate`; if that is the whole set, the dependency is four
functions rather than the manager, and should be named as such.

**5** Whether the engine's file is `trackerRebuild.lua` or something
that says derivation rather than rebuild. The current name is the verb
the pipeline is invoked by, not the thing it produces.
