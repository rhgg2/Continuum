# rebuild commit cadence — mm:batch made deferral cheap; is it still earning it?

> opened: 2026-07-29 · status: findings recorded; spike not run
>
> One-off working doc. No plan/ entry; the phases below are small
> enough to drive from here.

## Problem

`tm:rebuild` stages its nine pipeline stages through ten `mmBatch()`
accumulators (`reseats` :2071, `ccWrites` :2307, `extWrites` :2468,
region-park `batch` :2562, `wires` :3452, `clampWrites` :3835,
`pbWrites` :4155, `stampWrites` :4476, `deferred` :4618), each
committing once, late. That cadence was designed when a commit meant a
take reprojection. It doesn't any more: `mm:batch` (`midiManager.lua`
:1074) holds one nest open across the whole pipeline, and the
expensive work moved to the unwind.

The deferral now costs something it didn't before. Stages that stage
early and commit late must thread their own uncommitted state
alongside the index that can't see it — `trackerManager.lua:3836`
says so outright:

> Restores are column-only until this walk's deferred commit lands
> them in mm; until then they walk as extra inputs alongside the
> index, cell backref included.

So the question is which of the ten still need to be batched, and
which are paying that price for a cost the nest already absorbed.

## Findings

### What the nest absorbs (verified by reading)

Inside `mm:batch` every `mm:modify` runs at depth ≥ 2, where
`enterNest` skips its reset (:1029) and `leaveNest` returns at :1039.
Once per rebuild, regardless of commit count:

- `flushTake` — serialise, `MIDI_SetAllEvts`, undo mark
- `MIDI_Sort` — and only when the transport is rolling (:549)
- `flushMetadata` — one `eventMeta` keys-set round-trip
- `resolveCollisions` — the same-pitch backstop
- the wire splice: `wireDirt` keeps the **first** touch per slot across
  the nest (:1007), so repeat gestures on a slot coalesce however they
  are grouped

Splitting siblings is safe: `flushPending` is sticky across the nest,
and `modify` checks `dirty` (:1062) *before* firing reload (:1065), so
the re-entrant path can't wipe a mark that hasn't been read.

### What an extra commit still costs

In mm, almost nothing: a `liveTake()` → `ValidatePtr2`, one
`fire('reload')` payload, three perf pairs. The single subscriber
(`trackerManager.lua:4852`) does nearly nothing during rebuild —
`absorbReloadDirt` is gated off by `rebuilding`, and `tm:rebuild`
bounces off its own guard at :4736.

The real per-commit cost is in **um, not mm**: `mmBatch.commit` wraps
its reconciles in `withDeferredSort` (:1963), which sorts each touched
rawIndex list once per commit. N commits ⇒ up to N sorts of the same
list. Bounded by `idxReconcile`'s fast path (:976): a commit of pure
field updates flags no list and sorts nothing. Only adds and reseats
pay.

### Two staging doors, opposite visibility

This is the crux, and it is easy to get backwards.

- **The stager** (`addLowlevel` :1077, `assignLowlevel` :1092,
  `deleteLowlevel` :1107) maintains rawIndex at *stage* time. Commit
  timing is invisible to later readers. This is the command path.
- **`mmBatch`** (:1939) is a plain accumulator — `del`/`assign`/`add`
  are bare `util.add`. rawIndex learns nothing until `commit()` runs
  `idxReconcile` over the touched uuids, *after* the `mm:modify`.

The pipeline stages through `mmBatch`. So a stage's staged ops are
absent from `rawIndexFor(chan)` — the walk's working set (:815) —
until that batch commits. That absence is what :3836 works around.

### Stale rationale in situ

`trackerManager.lua:3891` and :4617 both justify deferral as "one
mm:modify / one MIDI_Sort". Under the nest that is no longer true:
MIDI_Sort is once per unwind either way. What survives is the
*ordering* half — canonical delete-first, so no transient same-pitch
overlap reaches `assignNote`'s seat-key guard or the backstop. These
comments read as cost constraints and are actually ordering
constraints; they should say so.

## What is load-bearing, and what is assumed

Only two things plausibly constrain cadence:

1. **Ordering.** `clampWrites` before `deferred` (:3888) so seat keys
   settle before the clip pass; delete-before-add within a batch.
2. **Sort churn**, for batches whose ops are adds or reseats.

Both are claims about the code, not measurements of it. Untested:

- **H1** — that each batch's ordering constraint is real. Nine of the
  ten have no comment defending their cadence at all.
- **H2** — that committing earlier actually simplifies a stage, rather
  than moving the complexity. :3836 suggests it does for the tail
  walk; that is one site, not a pattern.
- **H3** — the magnitude of sort churn. Unmeasured.

## Plan

0. **Spike, before deciding anything.** In the spike worktree, move
   each `mmBatch` commit to its natural stage boundary — one batch at
   a time — and run `lua tests/run.lua`. The artefact is a table in
   this doc: batch → what broke, or nothing did. That converts H1 from
   a reading of the code into a fact about it, and tells us which
   batches are candidates at all. Spike code is discarded.

1. **Comment corrections** (:3891, :4617). Wrong today regardless of
   what the spike finds — they cite a cost the nest removed. Restate
   as the ordering constraint they actually are. Independent of
   everything below; can land first.

2. **Per-batch cadence changes**, driven by the spike table. Each is
   its own commit, red-first where a spec can pin the ordering rule
   that justified the old cadence. Batches that broke under the spike
   keep their cadence and gain a comment saying *why* — the gap that
   let the stale rationale stand.

3. **The tail walk's side inputs.** Only if step 2 lands `deferred`
   and `clampWrites` earlier: retire the parallel threading at :3836
   so the walk reads one index. This is the payoff; it is also the
   step most likely to reveal that H2 was optimistic.

## Loose end

`mm:modify` sets `dirty = false` at entry (:1060) and reads it at
:1062. Siblings under `mm:batch` are safe, and the re-entrant reload
fire is after the read. But a modify nested *inside* another modify's
`fn` would clear the outer's structural mark before the outer reads
it, and the outer's writes would never set `flushPending`. No such
path found today. If step 2 turns any current sibling into a nested
call, this becomes reachable — worth a guard then, or a spec pinning
it closed now.
