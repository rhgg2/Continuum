# trackerManager: the algebra and the engine

> opened: 2026-08-07 · status: in flight — plan/tracker-manager-split.md;
> the three phases landed 2026-09-02 and the plan carries the follow-up
>
> Prior art: `design/archive/um-index-stager.md`, which split the index
> from the stager in place and deferred extracting either to a module.
> § Phase 3 settles that deferral.

## Length and coupling

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

1. A **cue** is a realisation field carried on a logical cell:
   `delayC`, `endppqC`, `sampleShadowed`. `REALISATION` enumerates the
   set, and the park stash is the clone minus it, so one list governs
   both.

1. The frame the layered model hands upward is the logical one.
   Realisation reaches the view only as cues, so the raw frame stays
   inside trackerManager.

## What the specs hold

1. `tm_gate_parity_spec` is the instrument that matters. `assertParity`
   snapshots the projected frame, the view grid and the mm bag, calls
   `tm:rebuild(true)` to force all sixteen channels to re-derive, and
   asserts all three unchanged. Gated and ungated agree across view,
   grid and wire. That is the property a stage extraction is likeliest
   to break, and it is already pinned.
