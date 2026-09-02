# trackerManager: the algebra and the engine

> opened: 2026-08-07 · status: the three phases landed 2026-09-02;
> plan/tracker-manager-split.md carries the follow-up
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
   `rebuildTails` adds to a channel's dirt and `rebuildRegionPark` does
   the same at seven sites; `rebuildPA`, `rebuildFx`,
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
   the edit through `stager.assign`. The edit path stages to mm and seeds
   dirt, and never writes the frame. Today that holds by discipline,
   and it took a script to confirm; after the split it holds because
   the edit-side file has no such variable in scope.

1. The frame is one seam, and the index is the other. Both sides use
   the index, and they use it differently. The edit path reaches it
   through semantic doors — `index.detuneAt` for the prevailing detune
   at a seat, `index.forEachAttachedPA` for a host's PAs — and touches
   the raw lists six times in all. The engine takes the lists and walks
   them, twenty-seven times. The mediated write surface that
   `um-index-stager.md` D2 built — `index.assign`, `index.stampColEvt`,
   `index.withDeferredSort` — has no edit-side caller at all.

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

## One window population

Landed 2026-09-01. The model is `docs/trackerManager.md` § Note host
clips and windows.

## The time context

Landed 2026-09-02 as `timeContext.lua`, built at the rebuild head and
taken by the stages as a parameter. The model is `docs/timing.md`
§ The time context.

## Phase 1 — the algebra leaves

Landed 2026-08-30 as `spans.lua` and `curves.lua`, with the two seeks in
`util`. The model is `docs/algebra.md`.

## Phase 2 — the dirt spine becomes `dirt.lua`

Landed 2026-08-31 as `dirt.lua`, one journal per tracker: `add` is the
sole write and the gates are queries. The journal mints the seeds it
stores, while `seedCovers` and `seedRowsFor` stay with the structures
they read. The model is `docs/trackerManager.md` § Derivation dirt: the
gated spine.

## Phase 3 — the engine leaves

Landed 2026-09-02 as `trackerRebuild.lua`, taking eight dependencies,
with the window constructors as `fxWindows.lua`. The model is
`docs/trackerManager.md` § The frame handle and § Fx window census.

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
   `tm_pb_gating_spec` asserts table identity of `onTake.pb`, so
   anything reconstructing the wrapper fails on equal data. And
   `VOLATILE` in `tm_gate_parity_spec` enumerates the three fields
   allowed to differ between a carried and a fresh frame, so a new
   per-pass scratch field on a column event registers as a spurious
   diff. Both are cheap to update and expensive to meet unprepared.

1. `rebuildPbs` is pinned at its own seams by `tm_pb_keep_split_spec`,
   `tm_seat_scope_spec` and `tm_pb_seam_spec`.
