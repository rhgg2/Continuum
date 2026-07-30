# rebuild commit cadence — mm:batch made deferral cheap; is it still earning it?

> opened: 2026-07-29 · status: in flight — `plan/rebuild-commit-cadence.md`
>
> Findings under § Findings are from reading. § Spike results are
> measured, and they retire most of § Plan — read them first.

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

## Spike results

Run 2026-07-29 in the session spike worktree, detached at `84f92a0`.
Baseline 2198 passed / 0 failed.

### Nine of the ten already commit at their own stage boundary

`reseats` (2071→2108), `ccWrites` (2307→2329), `extWrites`
(2468→2491), region-park `batch` (2562→2887), `wires` (3458→3469),
`clampWrites` (3841→3896), `pbWrites` (4161→4472), `stampWrites`
(4482→4504), `pcWrites` (4548→4579) each commit at the end of the
function that populates them. There is nothing to move. Only
`deferred` — created at 4624 in `rebuildPipeline`, committed at 3899
inside `rebuildTails` — crosses a stage boundary. H1 has one subject,
not ten.

### `deferred` can move; the lazy closure is removable

`:2671`'s `addLazy` defers the restore's add so the closure can read
`rec.ppq`/`rec.endppq` after the tail walk. `rec.ppq` is in fact known
eagerly (set at `:2664`); only `rec.endppq` is not.

Adding eagerly against the region-park `batch` — provisional raw end
from the logical ceiling, `realised` set at seat time — lets the walk's
existing write-through (`:3533`, `deferred.assign(backing, { endppq =
rounded })`) correct it, since `boundNote` already assigns whenever
`rounded ~= e.endppq`. Measured identical to HEAD, mm and column both.

So step 3 is not refuted. The restores *can* precede the walk; the
second commit fixes up what the first could not know.

2026-07-29 — but "identical" does not survive a fixture that looks.
Reconstructed from this description and run against
`tm_park_restore_end_spec`, the eager add loses `endppqC` on its own,
with the `restoredByChan` threading still in place. `frontierTails`
resolves a restore seed by uuid before falling back to a seat scan
(`:3757`): once the restore is in mm ahead of the walk, `tm:byUuid`
returns the index entry, which carries no `colEvt`, and the extras rec
never enters `disturbed`. At HEAD that lookup misses and `seatMatches`
finds the rec, which is the only reason the threading works at all.

So the eager add subsumes E4b rather than sitting orthogonal to it, and
phase 2 cannot land before the backref is resolvable by uuid. Phases 2
and 4 are one change.

### But the parallel threading is about the cell backref, not the end

`:3842` says "cell backref included" and that is the whole of it.
With the restores eagerly added, dropping the `restoredByChan` seeding
leaves the walk reading index entries, which carry no `colEvt` — mm's
clone never carries um's fields (`midiManager.lua:961`). `:3536`'s
`setCell` is then skipped and the cell's `endppqC` stays `nil` where
HEAD sets `240`. mm is right and the column is wrong.

Untested candidate: thread a `uuid → colEvt` map instead of the parallel
extras list, so the walk reads one index and still resolves the
backref. That is the shape the payoff would have to take.

2026-07-29 — superseded by D3: the map exists already and is called
`stampColEvt`. No new conduit is needed.

### The suite does not discriminate any of this

All four variants ran **2198 passed, 0 failed**:

| # | change | mm end | cell `endppqC` |
|---|---|---|---|
| E3 | `deferred.commit()` before `clampWrites.commit()` | 240 | 240 |
| E1 | restores commit at regionPark, closure unchanged | 240 | 240 |
| E4 | eager add + provisional end, walk fixes up | 240 | 240 |
| E4b | E4, parallel threading dropped | 240 | **nil** |

E4b is a real silent regression. E3 inverts the ordering rule `:3894`
asserts and nothing notices. E1 is genuinely behaviour-identical — but
only because these fixtures put logical and raw in the same frame
(`ppq=0`, no swing) and never clip a restored note short of its
authored ceiling, so the deferred read has nothing to read differently.

Nine restores across five specs execute the path — `tm_macro_spec` G2
and G2b, `tm_fx_region_spec` "removing the region restores the parked
chord to the take" and "park round-trip carries arbitrary authored
metadata", `vm_fx_ui_spec` removeFxStage, proven by raising from inside
the closure and watching exactly those five go red. None asserts the
restored note's end, and none puts a restore in a swung channel or
under a clipping neighbour.

So H1 cannot be converted by pass/fail here: "nothing broke" and
"nothing was looking" read the same. Every result above was obtained by
instrumenting the value, not the verdict.

2026-07-29: it discriminates E4b now. `tm_park_restore_end_spec` puts a
restore in a c58 channel — logical onset 120 bows to raw 139, ceiling
360 to raw 379 — and asserts the restored note's mm `endppq` (379) and
its cell's `endppqC` (logical 360) in one case, so the two frames carry
different numbers and neither a swap nor a `nil` can pass. Reconstructed
E4b in the spike goes red on `endppqC` alone with mm still green — the
table's shape, now a verdict rather than an instrumented value — and it
is the only red in the suite.

## Decisions

**D1 — coverage before cadence (2026-07-29).** No change to this
pipeline's commit cadence lands before a park-restore fixture that can
tell cadences apart, and that fixture's acceptance criterion is that it
goes **red** under § Spike results' known-bad variants — not that it
goes green. HEAD is already correct here, so a passing fixture is
consistent with having no teeth at all; four variants including a real
silent regression all passed the standing suite. This rules out
treating that suite's green as a baseline for anything below, and it is
why the fixture is a phase rather than a task inside one.

**D2 — one fixture carries all three variants (2026-07-29).** The
ordering rule at `trackerManager.lua:3894` is pinned by the clipped
case of the phase 1 fixture, not by a spec of its own. Clipping is the
pass whose seat keys the rule exists to let settle, so an inverted
commit order (E3) and an uncorrected restored end fail at the same
assertions; a second spec would restate the first. The cost is that the
rule is pinned by a case whose name is about ends rather than ordering,
so the case says which rule it holds down.

**D3 — the backref conduit already exists (2026-07-29).** § But the
parallel threading names a `uuid → colEvt` map as the shape the payoff
would take. It is not needed: `trackerManager.lua:990`'s `stampColEvt`
*is* that map — columns file their live cell onto the index entry as
they seat it — and `:4703` already stamps exactly these restores, one
stage after the walk that wants them. Moving the add to the region-park
batch moves the stamp to just after `:2887`'s commit, and the walk then
meets a restore as an ordinary seated entry carrying `colEvt` and
`realised`, so `:3533`'s write-through and `:3536`'s `setCell` both fire
unchanged. The pb restore at `:2860` has worked this way all along, one
screen above the note restore that defers; § Spike results reasoned
about the note path without the sibling in view.

Spiked 2026-07-29 at `8150247`: **2200 passed, 0 failed**, net −10 lines
in one file. Two controls establish that the green is watched rather
than quiet, each the only red it produces:

| control | red |
|---|---|
| seat stamped, `realised` withheld | restored end 619, expected 379 — case 2 alone |
| `realised` set, stamp withheld | `endppqC` nil in **both** cases — the E4b signature |

So each half of the mechanism is load-bearing and the phase-1 fixture
sees both. Consequences: phase 2 is one commit rather than a threading
rewrite, and `mmBatch.addLazy` (`:1946`) loses its last caller.

2026-07-30 — and `rebuildRegionPark`'s `deferred` parameter goes with
it: `addLazy` was that function's only use of the batch. Its return
value goes too, since the post-commit stamp moves inside the function
and the pipeline needs nothing back. Compiled into the plan's phase-2
item 1 brief.

**D2 revised — the clipped case cannot carry E3 (2026-07-29).** The
second half of D2 is wrong. `clampWrites` fills only from
`settleOnset` (`:3506`), which fires only when `voicing.separateOnset`
finds a same-pitch onset collision. A neighbour that clips a restored
tail is at a different pitch and a later seat, so the clamp batch is
empty for that channel and swapping its commit with `deferred`'s is a
no-op by construction — green because there was nothing to order, not
because the order held. Manufacturing the collision would need an
on-take note the walk nudges off the seat the restore is taking, and a
nudge is final where it lands, so a park/restore round trip does not
recreate one. So `trackerManager.lua:3894`'s ordering rule stays
unpinned. Accepted rather than chased: nothing on this programme
inverts it — the merged eager-add phase does not change commit order,
and the comment phase changes no behaviour. A case whose *name* is
about ordering is the way to pin it if that changes.

**D4 — phase 2 consumed the backref constraint (2026-07-30).** § But
the parallel threading named the cell backref as what the `deferred`
batch was really paying for, and phase 2 removed it: with the restores
added eagerly and seat-stamped, `deferred` carries only `reconcileFx`'s
fxNote del/add and `boundNote`'s `endppq` assigns, and an fxNote rides
bare — there is no `colEvt` left to resolve. What the deferral buys now
is one op instead of two: a fresh spec is unrealised during the walk, so
the clip at `trackerManager.lua:3530` mutates the spec table in place
and stages no assign, where an add at the end of `rebuildFx` would land
it unclipped and need one to correct it. Delete-first still holds (no
transient same-pitch overlap). The `MIDI_Sort` the old comment cited was
never the reason — the nest absorbs it. Compiled into phase 3.

## Plan

> Superseded in part by § Spike results: step 0 has run; step 3 stands
> but changes shape (eager add, backref threaded by uuid); step 2 has
> no green baseline to lean on until a discriminating restore fixture
> exists.

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
