# interval dirt — closing punch list

> The residue of the `interval-dirt` programme
> (`design/archive/interval-dirt.md`, closed 2026-07-21). Everything
> else landed: seeds carry the dirt (an event reference plus its birth
> snapshot — uuid, verb, position/lane/pitch/span), every stage from
> materialisation through fx/cc/pb consumes them, and geometry is a
> derived view. Model: `docs/trackerManager.md` § Derivation dirt;
> per-landing deviations: `docs/decisions.md`.

Three items. The first two are the mop-up round; the third is the
terminal invariant and can land with or after them.

## 1. pbs consumes the walk's emitted dirt (crux row: seats)

`rebuildPbs` still folds every dirty channel whole. The closure is
[onset, next lane-1 onset] **inclusive of that seat**, lane-1, raw
order: per `docs/tuning.md`, detune prevails from a lane-1 onset to the
next lane-1 onset, and the absorber invariant runs both directions —
the next seat's fake-pb value is `next.detune − this.detune` — so a
detune change perturbs up to and including the next seat, and stops
there.

The delivery mechanism already exists: phase 4 commit 3 made the tail
walk **emit** its closure (the onsets it moved, the nudged-lane-1 seat
emission) and deleted the `dirtyChan(chan)` widen that would have
masked it with whole-channel dirt. Pipeline order permits it — tails
discovers before pbs consumes. Correctness note from the archive: once
pbs gates on seed dirt, a moved lane-1 onset absent from its dirt is a
*stale absorber seat* (silent-stale class), which is exactly what the
emission prevents — the gate and the emission land together or not at
all.

Phase 5's pb kept-range machinery (fences, prior-column-slice carry)
already narrows the fold to dirty windows; this item narrows the
*seat* side the same way.

Baseline: `pbs` 1.5ms on the dense-take edit; glasswork-dense edit
`pbs` 15.1 (`seats` 7.3, `gather` 5.4) after phase 5.

*Landed 2026-07-21.* `seatScope` in `rebuildPbs` closes seeds to raw
spans; onsets, densify grid points, the I2a anchor, and the absorber
pool filter on it, with the pool also admitting any absorber standing
at a computed seat (duplicates structurally impossible) and the
delta-gated consolidated assign staying whole as the backstop. Four
deviations from the sketch: a move's deduped seed spans both its
snapshot and its `byUuid`-resolved live position (the frontier walk's
convention); `moved` in `assignLowlevel` gained `update.lane`, closing
a vacated-snapshot hole tails shared; the first lane-1 onset is always
in scope and the anchor decision reads the unfiltered jump count,
because the I2a anchor is channel-global; and a channel with fresh
(non-kept) derived lane-1 output goes ungated — fx-born onsets have no
verb seed, and the cost is proportional to the regeneration. Pinned in
`tm_gate_parity_spec` (closure keep + cascade-nudge emission cases).

## 2. PC closure and the `note.sample` stamp (crux row: PCs)

Two halves, and the stamp gates the closure.

**The bearing rule** (semantic change, decided as UX): under
trackerMode every note bears a sample — stamped from the prevailing PC
at first rebuild (free under no-legacy-data) and at foreign-MIDI
import. Inheritance freezes at stamp time: editing one note's sample
colours only itself, no longer re-colouring downstream inheriting
notes. `rebuildPCs` currently reads `entry.sample or 0` with live
inheritance; the stamp replaces that.

**The closure** then drops to [onset, next onset], channel notes, raw
order — not zero, because with dedup whether the successor *emits* a
PC depends on this note's value. Without the stamp the closure is
unbounded (any note may inherit from the prevailing PC), which is why
the stamp lands first.

Baseline: `pcs` 0.0ms on the dense take — the archive gated this on a
profile ever complaining. Landing it now is a coherence choice (no
O(channel) stage left standing), not a measured one; the stamp's UX
change should be judged on its own.

## 3. The end state — rebuild(∅) does literally nothing

Not landed: `tm:rebuild` (trackerManager.lua:4136) runs the full nest
and fires `'rebuild'` unconditionally. The terminal invariant: the
degenerate rebuild — empty dirt, no stale swing, not wholesale
(`didReload` false), no take swap — short-circuits **before** the
pipeline: no nest, no `clearSwing`, no `derivedInputs` clone, no
`'rebuild'` fire (the fire is ~10.4ms of tv re-placing an unchanged
frame). Empty dirt implies no staged ops, so the skipped
`clearStaging` is vacuous. The one fire that must survive is
`takeChanged`: a converged rebind carries no dirt but tv still needs
the bind signal. `fire` on a rebuild that *did* derive something stays
whole — that is the delta-signal successor, not this list.

## Out of scope — named successors

- **Output side**: a delta-shaped `'rebuild'` signal (*these columns
  changed*).
- **Write side**: `serialise` + `setEvts` + sidecars (~14+10+2ms on
  the dense edit); first commit `15a343d`.
