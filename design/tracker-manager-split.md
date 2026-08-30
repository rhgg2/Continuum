# trackerManager: the algebra and the engine

> opened: 2026-08-07 · status: proposed — plan to follow
>
> Prior art: `design/archive/um-index-stager.md`, which split the index
> from the stager in place and deferred extracting either to a module.
> § Phase 3 settles that deferral.

**`trackerManager.lua` holds three tenants: an algebra, an edit side,
and a derivation engine of about 2900 lines that reconstructs intent
and then reauthors raw from it. Two of the three leave, in three
phases, each useful alone; phase 1 is also the measurement that
decides whether phase 3 is worth taking.**

## Length and coupling

1. The file's length is the sum of three well-kept jobs. Four couplings
   join them, and all four travel by mutation. Naming the three is most
   of the design, and § Two movements gives the record couplings their
   reason.

1. tm is 5427 lines against a 46230-line codebase, more than one line
   in nine. `trackerView.lua` follows at 4929, and then there is a
   cliff to `wiringRender.lua` at 2825. Two outliers, and tm is the
   larger.

1. Every large section of the rebuild exports exactly one name:
   `rebuildPbs` for 570 lines, `rebuildFx` for 519, `rebuildTails` for
   421, `rebuildRegionPark` for 409. Those four are 1919 lines behind
   four doors, and `rebuildPipeline` hands each stage its inputs as
   parameters off one head snapshot. No large section calls into
   another.

1. The first coupling is mid-pass enlargement of the dirt.
   `rebuildTails` writes `dirtyChans[chan]` and `rebuildRegionPark`
   calls `seedDirty` at seven sites; `rebuildPA`, `rebuildFx`,
   `rebuildPbs` and `rebuildPCs` then gate on the enlarged set. A stage
   before the park pass gates on a strictly smaller set than a stage
   after it.

1. The head snapshot is the second, and has the same shape.
   `rebuildExtraColumns` grows `extras[i].notes` on the snapshot's own
   table and `rebuildPbs` reads `extras[chan].pb` from it; a comment in
   the tail walk carries the argument that the two keys do not collide.
   Dirt is phase 2's subject, and the join it introduces is the model
   for both.

1. The third travels through the records the stages pass along. The
   specs `fxOut` carries in `noteLive` are the same tables the tail
   walk mutates: `rebuildTails` takes them as `extras`, and
   `settleOnset` writes their raw onsets and clipped ends in place.
   `rebuildPbs` reads the moved positions. Tails-before-pbs is a data
   dependency, and neither signature says so.

1. The fourth runs the same way. `rebuildInternals` mints
   `noteExisting`, and `reconcileFx`'s keep path writes `uuid`,
   `realised` and `endppq` onto those same tables seven stages later;
   `rebuildPCs` writes `sampleShadowed` into an fx spec. Measured
   across the suite, every rebuild shares tables between `noteLive` and
   `noteOps.adds`; the clip lands in `tm_macro_spec`, `tm_trill_spec`
   and `tm_fx_region_spec`, the onset move in `tm_interval_walk_spec`'s
   same-pitch cascade.

## Three tenants

1. **The algebra.** About 325 lines: half-open span sets, and ppq-keyed
   breakpoint curves with their fold. Strip comments and string
   literals and the region's free variables number one — `util`. It
   reaches nothing and holds nothing, and could as easily be a library
   the project depends on.

1. **The edit side.** The raw index, the stager, the accessors, the
   mutation API, length, transport, mute, lifecycle. It writes mm and
   seeds dirt. Roughly 1700 lines.

1. **The derivation engine.** The REBUILD region, plus the fx-expansion
   helper family that only it calls. It reads mm, the index and the
   dirt, and produces the frame. Roughly 2900 lines. Its two movements
   share the frame, the index and the dirt, so they are one tenant
   (§ Two movements).

1. The seam between the edit side and the engine is checkable.
   `channels` is assigned in five places: its declaration, the reset at
   the head of `tm:rebuild`'s carry-forward loop, and the loop's three
   arms. Inside REBUILD, two dozen writes reach its fields. Outside it,
   every occurrence is a read or a comment — the accessors publish the
   frame, and the mute sweep walks it for cells to mute and then routes
   the edit through `assignEvent`. The edit path stages to mm and seeds
   dirt, and never writes the frame. Today that holds by discipline,
   and it took a script to confirm; after the split it holds because
   the edit-side file has no such variable in scope.

1. The frame is one seam, and the index is the other. Both sides use
   the index, and they use it differently. The edit path reaches it
   through semantic doors — `detuneAt` for the prevailing detune at a
   seat, `forEachAttachedPA` for a host's PAs — and touches the raw
   lists six times in all. The engine takes the lists and walks them,
   twenty-seven times. The mediated write surface that
   `um-index-stager.md` D2 built — `setRaw`, `stampColEvt`,
   `withDeferredSort` — has no edit-side caller at all.

## Two movements

1. The engine reconstructs intent, then reauthors raw from it.
   **Reconstruction** settles which events exist, where they sit in the
   logical frame, and what they mean. **Reauthoring** derives the
   realisation frame from that and reconciles it into mm. Every write
   one stage makes into another's records belongs to the second
   movement.

1. `projectEvent` is the hinge. It takes an mm-shaped record,
   overwrites `ppq` with `ppqL` and drops the logical sidecar, so a
   column cell is logical-framed while an index entry is raw-framed and
   carries logical alongside. `colEvt` links the two, and the engine is
   the only thing that holds both.

1. `rebuildPipeline`'s order is already the cut. Internals, the CC
   walk, extra columns, externals, the sample stamp, region park, PA
   and fx expansion reconstruct; tails, pbs and PCs reauthor.

1. There are three reauthoring stages because a MIDI channel offers
   three media its notes contend for: one raw timeline on which two
   same-pitch notes cannot overlap, one pitch-bend stream, and one
   program change. An axis earns a reauthoring stage exactly when its
   realisation depends on other events. Velocity is per-note and CC
   lanes are independent streams, so neither needs one.

1. Contention fixes the scope. A shared medium can be allocated only
   once every claimant is known, so reauthoring runs after all
   reconstruction and over a whole channel. Dirt is channel-keyed for
   the same reason, which makes phase 2's journal and phase 3's engine
   one subject seen twice.

1. The movements divide the fields a stage may author, and stages
   straddle. `rebuildInternals` rederives raw onsets from logical under
   stale swing, as part of a walk it performs anyway; `rebuildPbs`
   seats detune before it synthesises pb, which are pitch's second and
   third rungs (`docs/tuning.md`).

1. Measured on the 32-bar `glasswork` fixture, a forced full re-derive
   spends 15.7ms reconstructing and 11.4ms reauthoring out of 31.7ms.
   Of `rebuildPbs`'s 8.9ms, 1.9ms is the detune seating, so counted by
   stage the second movement reads larger than the field cut makes it.

1. A **cue** is a realisation field carried on a logical cell:
   `delayC`, `endppqC`, `sampleShadowed`. `REALISATION` enumerates the
   set, and the park stash is the clone minus it, so one list governs
   both.

1. The frame the layered model hands upward is the logical one.
   Realisation reaches the view only as cues, so the raw frame stays
   inside trackerManager.

## Phase 1 — the algebra leaves

1. The algebra leaves as two modules. `spans.lua` holds half-open span
   sets; `curves.lua` holds ppq-keyed breakpoint curves and their fold.
   `curves` requires `spans` for `overlapping`, and the arrow is one
   way.

1. `spans.lua` publishes six names and `curves.lua` eight. Spans:
   `mergeSpans`, `mergeWindows`, `overlapping`, `spanSetIntersects`,
   `clipToSpanSet`, `subtractSpanSet`. Curves: `evalCurve`,
   `sliceCurve`, `sumStreams`, `foldChains`, `foldIntoWindow`,
   `closeAtWindowEnd`, `anyNonZero`, `isCurved`. Four of the fold's
   helpers — `negated`, `foldWhole`, `chainCuts`, `foldSub` — have no
   caller outside the region and stay private.

1. `firstAfter` and `firstAtOrAfter` go to `util`. They are binary
   seeks over a ppq-sorted list, with nine external callers each and
   further use inside both new modules. `util` already holds
   `util.seek` and `util.insertSorted`, and these join them.

1. The cents↔raw conversions stay in tm. `pbLim`, `centsToRaw` and
   `rawToCents` read `cm:get('pbRange')`, which makes them
   configuration. This costs nothing: `sumStreams` clamps from
   `opts.lo`/`opts.hi` and never names `pbLim` itself, so the boundary
   falls where it already is.

1. Phase 1 goes first because it is also the instrument. Its own value
   is about 325 lines, six per cent of the file. The curve fold is
   currently reachable only through a full tm rebuild; extracted, it
   can be tested against a list of points. And removing the pure names
   from every rebuild stage's dependency set gives the phase-3 count
   its meaning.

## Phase 2 — the dirt spine becomes `dirt.lua`

1. Derivation dirt is a lattice. A channel's entry rises from absent
   through a seed list to wholesale `true`; a list longer than
   `WHOLESALE_SEED_CAP` collapses to `true`; every writer joins — moves
   an entry up — and never assigns (`docs/trackerManager.md` §
   Derivation dirt: the gated spine).

1. The journal has one write verb, `join(chan, dirt)`. `dirt` is
   `true`, a seed, or a seed list; the verb moves the channel's entry
   up the lattice and enforces the cap in one place. A wholesale mark
   is `join(chan, true)`, and a mid-pass enlargement is the same call
   at a visible call site.

1. `dirt.lua` holds the journal and its lattice, and whatever reads
   another structure stays with that structure. The module keeps
   `dirtyChans`, `staleSwing`, the join, the per-channel read the stage
   gates use, and two clears: `staleSwing` clears mid-pipeline once its
   two consumers have run, and `wipe` returns the set of channels it
   consumed, which tm folds into its mute-conform sweep. The module
   requires nothing.

1. Four families stay with the structures they read.
   - `parkSeed`, `rawSeed`, `seedRegionEdit` and `seedParkedEdit` mint
     seeds by calling `tm:fromLogical` and reading `derivedInputs`, so
     they stay with that projection.
   - `seedCovers` and `seedRowsFor` interpret seeds against the live
     index, and their only callers are stages, so they move with the
     engine.
   - `shedLane` is frame identity, and travels on the frame handle
     (§ Phase 3).
   - `clearSwing` invalidates the time projection's swing cache, and
     stays beside it.

1. The code implements the join by hand three times: `seedDirty`, the
   reload fold in `absorbReloadDirt`, and the tail walk's emission. Two
   of the three are wrong today.

1. The tail emission has no cap check, so a large disturbance carries
   forward as an ever-growing seed list. The reload fold assigns its
   deduped list over whatever stands, which would drop standing seed
   dirt. It is sound only because every edit-path seeder rebuilds
   immediately, so no seed list survives to flush time — a discipline
   nothing enforces.

1. The class has already cost a bug of the kind a real join makes
   impossible. The fold's wholesale guard was missing until 2026-07-28;
   it demoted a standing wholesale and left an OPEN tail uncut.

1. Gathering the spine shrinks phase 3's interface, which is why this
   phase precedes the engine move. The join is a correctness fix, and
   it stands whether or not the engine ever moves.

## Phase 3 — the engine leaves

1. The engine leaves as `trackerRebuild.lua`, taking eight
   dependencies: `mm`, `cm`, `ds`, `tm`, `index`, `stager`, `dirt`,
   `frame`. The first four the file takes via `(...)` exactly as tm
   does today, and `dirt` is phase 2's module, required by both sides.
   The last three are the decisions below.

1. `trackerRebuild.lua` is one file. Its nine stages need the same
   substrate, so a file each would carry the same constructor nine
   times; sectioned as it already is, 2900 lines is the size of a batch
   derivation pipeline.

1. The frame is passed as a handle and mutated in place, and the
   published maps come back as a return value. The stages splice into
   columns that they and later stages both read, so the frame departs
   from the house sequence of gather, compute, mutate. The rule is that
   the engine mutates only what it was handed, and everything it
   *creates* leaves by the return.

1. The fx maps meet that rule directly. `fxRealisationByUuid`,
   `fxTargetsByChan`, `freezeEligibleByUuid` and their siblings are
   written once at the tail of the pipeline and read only by
   accessors, so they come back from `run` and tm installs them.

1. `fxOut` marks the rule's scope. It is created by the engine and
   never leaves it, so nothing about the boundary bears on it; the one
   value that does cross, `fxNotesByProducer`, is built from copies of
   the specs because the tail walk is still settling them.

1. Two things are the engine's own and stay with it: `parkedClipEnd`
   and `fxHostWin`, uuid-keyed caches that outlive a pass. Inside one
   file their invalidation is implicit — `didReload` flows down from
   `tm:rebuild` and each cache reads it in passing. Across a boundary
   it has to be said out loud, most simply as a `forget()` the
   take-tier path calls. The boundary earns its keep here: a cache that
   survives a take swap is a bug, and today nothing in the code names
   the moment it must not.

1. The fx builders are the protocol already working. `buildFreezeMaps`,
   `buildFxTargets` and `buildFxRealisation` are declared beside the
   accessors that read their output and called from `rebuildPipeline`.
   The map lives with its readers and the pipeline reaches out to fill
   it — that arrow, in production, today. Three of the fx maps are
   written directly by the fx stage; under the rule they join their
   siblings.

1. The index and the stager stay in tm, gathered into door tables. They
   are the edit side's own state and their doors are already declared
   as explicit lists. Passing `index` and `stager` as tables of those
   doors costs two names and moves no code.

1. The write surface falls on the same line. `setRaw`, `stampColEvt`
   and `withDeferredSort` are engine-only, so the line the handle draws
   is the line the mutation privilege already has: tm keeps the lists
   true across edits, the engine is the only writer mid-pass, and
   `um-index-stager.md` D2's contract governs exactly that. Of
   thirty-five references to `rawIndexFor`, twenty-seven are the
   engine's and six the edit side's, the remaining two being the
   declaration and the definition. A structure two modules use needs
   one owner, and the door table gives it one.

1. Each field of a travelling record has one authoring stage. A record
   passes from the stage that mints it through the stages that settle
   it, so no stage owns it, and the boundary needs no rule about what
   one stage may touch of another's output.

1. The pipeline order follows from the fields. `rebuildPbs` reads `ppq`
   and `rebuildTails` authors `ppq`, so tails precedes pbs. The two
   fields with a second writer say the same thing from the other side:
   `reconcileFx`'s keep path stamps `realised` and `endppq` from the
   matched mm record so the tail walk's diff has a baseline, which
   mirrors mm and leaves the field's author unchanged.

1. The move renders the coupling. An ambient upvalue is free to use and
   impossible to count; an injected dependency is neither. The question
   is whether making the number visible is worth 2900 lines changing
   file, and the answer turns on what the number is.

1. The REBUILD region references about 110 names it does not declare.
   Two deductions cut that to eight.

1. The first is material that travels. Twenty-two of those names have
   *zero* uses outside the engine — they are the engine's own,
   lexically stranded at file scope. The fx-expansion helper family is
   the bulk of it: `coverInto`, `membersOf`, `channelStreams`,
   `allocateRegionLanes`, `hostProducer`, `producerCensus`, the
   reconcile skeletons. They move with the engine and stop being names
   at all.

1. The second is operations on structures already being passed. If the
   frame travels as a handle, then `insertNoteCell`, `setCell`,
   `sortNoteColumn`, `shedLane`, `sortByPPQ`, `rawThenLogical` and
   `isSorted` travel on it: they are the frame's operations, and each
   takes a frame or a piece of one as its first argument. Seven names
   become zero.

1. Two of the seven have a third caller. `setCell` is applied to a bare
   fx spec and `setRaw` to bare specs, and each carries a branch for
   it — `setRaw` accepts that a non-member record flags its channel's
   list spuriously, and `setCell` calls `shedLane` on a lane the spec
   does not sit in, against the invariant that a note lane's events
   table changes identity only when its contents change. The cost is a
   spurious re-render. Naming the travelling record as a thing in its
   own right lets `setCell` belong to the frame and `setRaw` to the
   index.

1. The two deductions leave the eight named above.

## What the specs hold

1. A restructure is only as safe as what notices it breaking. The
   `tm_*` specs address tm through four verbs — `tm:flush`,
   `tm:addEvent`, `tm:getChannel` and `tm:rebuild`; none requires
   `trackerManager` directly, and none touches an upvalue. The harness
   fakes only REAPER, so mm, cm and ds are real. Whatever moves behind
   which boundary, the suite exercises the same doors.

1. `tm_gate_parity_spec` is the instrument that matters. `assertParity`
   snapshots the projected frame, the view grid and the mm bag, calls
   `tm:rebuild(true)` to force all sixteen channels to re-derive, and
   asserts all three unchanged. Gated and ungated agree across view,
   grid and wire. That is the property a stage extraction is likeliest
   to break, and it is already pinned.

1. Two specs would nonetheless go red on a faithful move.
   `tm_pb_gating_spec` asserts table identity of `columns.pb`, so
   anything reconstructing the wrapper fails on equal data. And
   `VOLATILE` in `tm_gate_parity_spec` enumerates the three fields
   allowed to differ between a carried and a fresh frame, so a new
   per-pass scratch field on a column event registers as a spurious
   diff. Both are cheap to update and expensive to meet unprepared.

1. The gap is `rebuildPbs`. It is the largest stage and the thinnest
   pinned against its size: `tm_pb_gating_spec` is two identity cases,
   `tm_pb_interp_spec` covers interpolation across a detune onset,
   `tm_absorber_reseat_spec` the delay reseat, and `tm_tuning_spec`
   reaches it only obliquely through cents. Its keep/live split and
   `pbScope` gating rest on one case, gate parity's pb half, and the
   seam between its seating and its synthesis (§ Two movements) is
   unpinned on either side. § Phase 1 makes the same observation one
   level down, where the curve fold is reachable only through a full
   rebuild. So pb realisation needs coverage at its own seam before
   phase 3 moves it.

## Open

1. What `tm` in the engine's dependency list covers. The stages call
   four of its methods: `tm:fromLogical` and `tm:toLogical` are the
   swing projection, `tm:byUuid` is a raw-index read declared inside
   RAW INDEX, and `tm:length` is the take length with the shrink-flush
   override. If `byUuid` travels on the index handle, the dependency
   reduces to a time projection and a scalar, and should be named as
   those.
