# deferred reindex — one mm reindex per flush

> Working design doc. Companion to `archive/incremental-pbs.md`: same programme
> (`incremental-rebuild.md`), mm-side slice. Stop paying mm's whole-model reindex at every dirty
> `modify`; pay one slim reindex at the outermost unwind.
>
> **Status.** Phases A–D landed (2026-07-02). **Phase E — slimming the unwind
> reindex — never landed**, so the one remaining reindex is still the full
> from-scratch one; both follow-ups below are also open. Tracked as gaps 2, 5
> and 6 in `incremental-rebuild.md`.

## Problem

Same profile as `archive/incremental-pbs.md` (3070 notes, 6219 ccs, ~100ms per
edit at flush). mm's internal `rebuild` (midiManager.lua:275) runs at
every dirty `mm:modify`: once after tm's flush verbs (~10ms), then once
per dirty nested commit inside the rebuild pipeline — pbs ~11ms, tails
sometimes another. **21–32ms per flush is spent re-deriving the same
state for ~12k events**, and each run reconstructs indices the verbs
never let go stale.

## What the reindex actually provides (verified)

`rebuild(metadata)` does four things: compact the sparse arrays
(deletes nil their slot), stable-sort by ppq, recompute `loc`, and
reconstruct `tokenIdx`/`eventsByUuid` from scratch. The last is
redundant on the modify path — every verb maintains both incrementally
(add files :769/:861, assign re-keys :744/:839, delete removes
:941/:948). Between verbs and the reindex, mm state is *sparse but
stable*: deletes leave holes without shifting survivors, adds append
with a fresh `loc`, so `loc`-based access and `mm:byToken` stay exact
throughout a deferral window. Only compaction, order, and (post-sort)
`loc` are deferrable state.

## Scheme

1. **Mark stale, reindex at unwind.** `mm:modify` at any depth sets a
   stale flag instead of calling `rebuild(nil)`; the outermost unwind
   runs one reindex before `flushMetadata`/`flushTake`. Arrays are
   therefore always compact + sorted *between* top-level modifies;
   staleness is only ever observable mid-pipeline.
2. **Hole-tolerant iterators.** `mm:notes()`, `mm:ccs()`, `mm:ccsRaw()`,
   `mm:events()` currently stop at the first nil; under deferral a
   mid-pipeline delete would silently truncate every later iteration.
   All four skip nils up to the `noteCount`/`ccCount` high-water marks.
3. **Slim modify-path reindex.** Compact + sort + `loc` only; skip the
   `tokenIdx`/`eventsByUuid` reconstruction (verb-maintained). The
   from-scratch version remains for `load`, whose dedup/unify paths
   genuinely need it.
4. **tm order self-sufficiency.** Two sorts make the pipeline
   independent of mm array order at its head (which the stretch —
   deferring the *outer* reindex too — requires):
   - sort each channel's note `col.events` before `rebuildFx`;
   - sort the gathered per-window `pa`/`cc`/`at` streams in
     `channelStreams` (pb is already sorted upstream).

   This also fixes a latent inconsistency that exists today: externals
   append unsorted at the column tail (trackerManager.lua:1377), so
   generator input order already deviates from sorted.
5. **Forced reindex before `loadIndex`.** um's full index reload
   (trackerManager.lua:785, wholesale path only) documents its reliance
   on sorted `mm:events()`; it reindexes-if-stale first.

## Audit record (2026-07-02)

**Signal audit — clean.** The only production subscriber to mm's
`reload` is tm (trackerManager.lua:2531), whose `tm:rebuild` is
reentrancy-guarded; nested `wholesale=false` fires cannot expose stale
arrays to anyone else. The `mmReloaded` capture at rebuild head (:2415)
is unaffected.

**Order audit — every pipeline pass either self-sorts or is
order-independent:**

| pass | why safe |
|---|---|
| `rebuildInternals` | per-note partition; sorts reseat list (:1192) |
| CC walk | per-cc dispatch; carrier routing dict-keyed |
| `rebuildExternals` | sorts `external` (:1357); `noteColumnAccepts` full scan |
| `rebuildRegionPark` | coverage full-scans; `realiseParked` sorts groups (:1397); restores re-sort touched columns (:1481, :1560) |
| `rebuildPA` | active-voice match unique by single-voice invariant; fallback per-column boolean |
| `rebuildFx` window pass | `col.events` sorted at entry (Phase A); `byLane` groups inherit the order |
| `rebuildTails` | unconditional `sortAll()` (:1969) |
| `rebuildPbs` | sorts `lane1ByChan` (:2045) and `pbsByChan` (:2067) |
| `rebuildPCs` | buckets by ppq, winner by explicit lane sort (:152) |
| reconciles (`fxKey`, carrier, PC) | key-matched via `reconcileDerived`, never order-matched |
| `projectLogical` | sorts every column |

**Breakers found (all addressed by the scheme):**

- Hole truncation at `ccsRaw` reads downstream of deletes: PA dispatch
  (:1597, after regionPark's cc parking), absorber snapshot (:2052,
  after park/tails), PC re-projection (:2351, after its own dels).
  → item 2.
- `flushTake` (`ipairs` + delta-encoded serialise) and `loadIndex` need
  compact + sorted. → items 1, 5.
- Generator input order: `eachWindowNote`/`channelStreams` feed
  generators in `col.events` arrival order, and derived-lane allocation
  is emission-order-dependent ("emission order → deterministic →
  G4-stable", :1721). `fxKey` carries no lane, so an order flip would
  silently reallocate derived lanes between rebuilds. → item 4.

## Validation

- **Shadow compare** (um-index migration pattern, perf-gated): at each
  unwind, run the from-scratch reindex in shadow and assert the slim
  path produced identical arrays, `loc`s, and indices. Strip once
  parity holds.
- **Spec: generator lane stability** — two rebuilds over an identical
  macro-heavy fixture allocate identical derived lanes.
- **Specs: hole regression** — PA survives region-park cc deletes;
  absorber snapshot and PC re-projection see the full stream after
  mid-pipeline dels.

## Expected effect

Per flush: 2–3 reindexes (~21–32ms) collapse to one slim one (≤11ms;
less once item 3 lands — the index reconstruction over 12k string keys
is a large share). Combines with `archive/incremental-pbs.md`: once the
absorber pass stages nothing on clean channels, its nested commit
disappears entirely and the unwind reindex is only paid when some
pipeline stage actually wrote.

## Implementation

Phased so the risky switch lands last. Today `rebuild(nil)` runs inside
every dirty `mm:modify` (midiManager.lua:685), so the arrays are compact
+ sorted whenever the pipeline or a consumer reads them. Deferral removes
that guarantee — the whole `tm:rebuild` pipeline (fired by `reload` at
:690) then runs against sparse-but-stable, unsorted arrays until the
single unwind reindex. So each prep phase makes the pipeline tolerate
that state while remaining a behavioural no-op today (arrays are still
compact + sorted when it runs); the flip becomes load-bearing only at
Phase D. Every phase lands green with a pinning spec.

- **Phase A — tm order self-sufficiency (item 4). ✅ landed.** Two sorts so the
  pipeline head stops depending on mm array order:
  - `rebuildFx` entry: sort each `channels[chan].columns.notes` col's
    `col.events` by ppq — covers `eachWindowNote` (:1675),
    `allocateRegionLanes` (:1725), `channelStreams` (:1698).
  - `channelStreams` (:1694): sort the gathered `pas`/`ccs`/`ats` before
    returning; `pb` is already sorted upstream.

  Also fixes a latent bug today: externals append unsorted at the column
  tail (trackerManager.lua:1377). **Pin:** generator lane stability.
  Lands independent of everything.
- **Phase B — hole-tolerant iterators (item 2). ✅ landed.** `mm:notes` (:711),
  `mm:ccs` (:779), `mm:ccsRaw` (:790), `mm:events` (:957) skip nils up to
  the `noteCount`/`ccCount` high-water marks instead of stopping at the
  first hole. No-op today. **Pin:** hole-injection spec.
- **Phase C — reindex-if-stale scaffolding (item 5). ✅ landed.** Add
  `indexStale` (cleared at the end of `rebuild`), `mm:reindexIfStale()`,
  and call it at the head of tm's `loadIndex` (trackerManager.lua:781)
  before it walks `mm:events()`. Inert while nothing sets the flag —
  `loadIndex` verifiably reindexes nothing today. Makes Phase D a
  one-line switch. **Pin:** `mm_reindex_if_stale_spec` — the call is a
  no-op on compact state and after a compacting modify.
- **Phase D — defer to one reindex at the unwind (item 1). ✅ landed.**
  The flip. In `mm:modify` (:684-687) replace `rebuild(nil)` with
  `indexStale = true`; at the outermost unwind (`modifyDepth == 0`, :692)
  run `if indexStale then rebuild(nil) end` before
  `flushMetadata`/`flushTake`. Went straight for full deferral (outer +
  nested), which A/B/C make safe. **Pin:** `tm_deferred_hole_spec` — the
  three ccsRaw consumers each read past a hole a mid-pipeline delete
  leaves before their survivors: PA dispatch (:1598), absorber snapshot
  (:2063), PC re-projection (:2362). Each is red-checked to truncate
  (to `[]`) if the hole-tolerance is reverted.
- **Phase E — slim the unwind reindex (item 3).** `rebuild(metadata,
  slim)`: `slim` keeps compact + sort + `loc` recompute but drops the
  `tokenIdx`/`eventsByUuid` reconstruction (:280, :283-284, :289-291) —
  the verbs maintain both incrementally. Modify-path/unwind and
  `reindexIfStale` pass `slim=true`; `mm:load` keeps `slim=false` (dedup
  /unify needs from-scratch). **Validate:** shadow-compare per Validation
  above; strip the scaffold at parity, keep one permanent gated-vs-full
  spec.

## Follow-ups (after Phase E)

- **Wrap the load/config rebuild paths in an outer `mm:modify`.** Only
  the flush path nests the pipeline's commits inside an outer modify; a
  rebuild fired by `configChanged` or `load` runs each pipeline commit as
  its own top-level modify — own reindex, own `flushTake`. Wrapping the
  pipeline body in a `mm:modify` extends the win (and collapses the
  multiple serialises) to those paths; the extra `reload` fire at unwind
  is harmless (sole subscriber is guarded). Separate behavioural change
  from deferral, so deferred to keep this slice tight.
- **Split hole-dirt from order-dirt.** `dirty` is boolean; assign-only
  commits that move no ppq (val edits) need neither compact nor sort.
  Splitting lets the unwind reindex skip the sort when nothing moved (and
  the slim reindex skip compaction when no deletes occurred — same
  split, cheaper still). A micro-opt on top of D/E, not needed for
  correctness.
