# incremental pbs — dirty-scoped absorber reconciliation

> First slice of the incremental-rebuild programme
> (`incremental-rebuild.md`): the absorber pass (`rebuildPbs`) only.
>
> **Status.** Stage 1 (channel gating, `8d29327`) and stage 1b (carry the
> pb view column, `8591036`) landed. The pbs stage went **27.8ms → 0.4ms**
> on the 3070-note fixture, taking it off the critical path. Stage 2
> (seat-level windows) is therefore deferred indefinitely — stage 1+1b
> already cleared the problem. The residual 0.4ms is addressed in
> § Deferred, itself blocked on fx dirt tracking.

## Problem

On a large take (3070 notes, 6219 ccs, 9212 texts), one edit costs
~100ms at flush; `pbs` is the biggest rebuild stage at **27.8ms** —
~16ms of derivation plus ~12ms of nested commit (mm's whole-model
reindex at 11.0 + verbs 1.1), paid because the wholesale pass stages
writes on every rebuild.

The pass is wholesale **by design** (03f0a23 retired um's per-edit
absorber upkeep — `reconcileBoundary` / `retuneLowlevel` /
`forcePb`/`markFake`): only the post-walk lane-1 layout is correct
input, since nudges, reswing reseats, and the delay clamp move lane-1
onsets after um's edit ran. That rationale still holds.

## Non-goals

- **No per-edit upkeep in um.** Reconciliation stays in `rebuildPbs`,
  post-walk, single-site. We resurrect 03f0a23's *interval math*, not
  its location.
- **No general `channels[]` persistence.** Columns still rebuild from
  scratch each rebuild — *except* the pb view column, which stage 1b
  carries forward (profiling forced it). Persisting the rest is a
  separate, larger project (`dirty-channels.md` phase B).
- **Other stages** (internals, ccs, tails, projLogical) — later slices,
  same pattern (`dirty-channels.md`).

## Stage 1 — channel gating (`dirtyPbChans`)

Like `dirtyPcChans`, but tm-scope rather than um-scope: um's set
clears at flush, while pb dirt must survive into the rebuild that
follows and absorb marks from rebuild-internal movers. Marked at every
site that can change a channel's pb-relevant state, consumed and
cleared at the end of `rebuildPbs`.

A channel's absorber derivation depends on: its lane-1 onsets and
detunes, its pb stream, its replace windows, resolved swing, and the
raw↔cents conversion params. So the dirty sources are:

| source | marks |
|---|---|
| wholesale reload / take swap | all 16 |
| `pbRange` config change (`ccInterp` is item-chunk data, re-read only at load) | all 16 |
| `tm:markSwingStale` (mirrored at mark time; staleSwing itself clears before the pbs pass) | chan |
| um verb: pb add / assign / delete | chan |
| um verb: lane-1 note add / delete | chan |
| um verb: note assign touching `detune` or `ppq` (delay maps to ppq upstream) on lane 1 | chan |
| um verb: note `chan` change (lane 1) | both chans |
| um verb: `lane` assign crossing the lane-1 boundary | chan |
| `voicing.nudgeOnsets` moving a lane-1 note in the tail walk (internals reseat rides markSwingStale; flush pre-clip rides the um verbs) | chan |
| `rebuildRegionPark` parking / restoring a lane-1 note | chan |
| fx: `noteLive[chan]` has lane-1 entries, or `replacePb[chan]` non-empty | chan (conservative) |

The fx row is deliberately coarse: fx output regenerates every rebuild
with no change tracking, so fx-hosting channels stay wholesale until fx
grows its own dirt signal. A channel that was fx-active stays dirty for
one rebuild after fx vanishes (`hadFxPb` trailing dirt), so a removed
region's derived seats get deleted. Everything else is exact.

### The clean-channel path

`rebuildPbs` does two jobs per channel; only one is gated:

- **Derivation** (replace-window mapping, onset/seat computation,
  densification, anchor, absorber matching, consolidated assign) —
  **skipped** for clean channels. Skipping must cover the *matching*
  step too: running it with an empty `seats` table would read as
  "delete every absorber". The clean path stages nothing.
- **Materialisation** (clone from `mm:ccsRaw`, sort, the `detuneOf`
  linear merge, column projection with `hidden`/`detune`/cents) — was
  left running here on the assumption it was "linear and cheap".
  Profiling falsified that (§ Stage 1b): the clone dominates, so stage
  1b gates materialisation too and carries the view column forward.

**Why skipping is sound:** rebuild converges in one pass (I8 — flush →
rebuild → flush is a fixpoint). After rebuild N writes a channel's
absorbers, rebuild N+1 derives the identical seat set and stages
nothing. So "no dirty source fired" ⟹ the mm-side pb stream is already
the fixpoint, and re-deriving it is pure waste.

**Payoff shape:** a typical edit dirties one channel, so derivation
drops to ~1/16th of its share; and when *no* channel stages writes,
`pbWrites.commit()` is a clean no-op — the nested mm reindex (~11ms)
vanishes with it.

### Validation

Same pattern that carried the um-index migration: a perf-gated shadow
mode that runs full derivation for channels the gate skipped and
asserts (a) zero staged writes, (b) identical projected pb column.
Keep one spec on a rich fixture (tuning + fx + swing + replace windows)
exercising gated-vs-full permanently; strip the live shadow scaffolding
once parity holds. The failure mode of a missed dirty source is silent
wrong wire raws — the shadow compare is the only honest detector.

### Stage 1b — carry the pb view column

Stage 1 gated *derivation* but let *materialisation* run, assuming the
projection was cheap. Profiling (8.6ms stage) put the residual at 4.2ms
of `util.clone` over **every pb in the take**, every rebuild — the view
column rebuilt from scratch.

Each pb needs two live copies in different timing frames: the realisation
copy (raw ppq, mm-owned, already persistent across rebuilds) and the view
copy (logical ppq, rewritten by `projectLogical`). Only the view copy was
being re-cloned.

Fix: carry `channels[chan].columns.pb` across the rebuild-entry wipe
(`columns = { notes={}, ccs={}, pb=<prior> }`). A clean channel reuses
it; the clone and the whole per-chan derive/project body are gated on the
same dirt, so only dirty channels clone. `projectLogical` re-runs on a
carried column but is idempotent for pb (rewrites `ppq := ppqL`; pbs
carry no delay/endppq).

Sound by I8: a clean channel's raw pbs, detunes, and swing are unchanged,
so the projected column equals a full rebuild's. Every input that could
change it already marks the channel dirty — including the document-data
edits (`extraColumns`, `noteDelay`) that arrive as `dataChanged` rather
than um verbs, which now `dirtyPb()` at their rebuild site.

Only if profiling after stage 1 shows single-channel derivation still
hurts (dense pb streams: the seat math, not the projection, dominates).
This is where 03f0a23's interval math comes back, translated to the
post-walk frame:

| 03f0a23 (um, edit-time) | here (rebuildPbs, post-walk) |
|---|---|
| `retuneLowlevel` over `[P, nextRealChange)` | raw-rewrite interval: a detune change at P re-vals pbs in `[P, nextLane1Onset)` — the detune shadow |
| `reconcileBoundary` at both endpoints | recompute onset-ness of the first lane-1 note at/after each window edge (detune-differs-from-predecessor is pairwise) |
| move = delete+add with `needFakeAtOld` | move dirties the **union** of old and new windows before diffing |
| (n/a) | replace-window edit dirties the region's whole scope — the fx-region exception |

Mechanics:

- **`seatCache[chan]`** — persist the derived seat table across
  rebuilds. Incremental derivation = recompute seats only for onsets
  inside the dirty window W, then diff against the cached seats in W.
  Seats outside W are untouched by construction.
- **W closure** — seed from the dirty events' ppqs; expand to
  `[prevLane1Onset, nextLane1Onset)` around each seed (old *and* new
  positions for moves); widen to any densified segment or replace
  window intersecting it; re-anchor if W contains the channel's first
  onset (I2a).
- **Windowed matching** — absorbers are identity-free, so a diff
  confined to W is safe: fakes at unchanged in-W seats are consumed in
  place (already the existing "consume any already at a seat" path);
  surplus in-W fakes delete; deficits add. Out-of-W absorbers are never
  candidates.
- **Windowed assign** — the consolidated assign loop runs only over pbs
  in W ∪ the detune-shadow intervals of changed onsets.

## Orthogonal cheap win (do alongside stage 1)

`streamValue` and `spanAround` linearly scan `realPbs` per call, and
they're called per onset — O(onsets × pbs) per channel. The `detuneOf`
merge two screens down already shows the fix: both lists are ppq-sorted,
so a single merge-walk computes every onset's bounding pair. Worth
doing regardless of incrementality; it may shrink the stage enough to
defer stage 2 indefinitely.

## Deferred — fold pb extraction into the cc walk

After stage 1b the whole pbs stage is ~0.4ms, all of it the residual
`pbsRaw` walk: `rebuildPbs` re-walks every cc via `mm:ccsRaw()` to find
and clone the pbs. That walk is redundant — `rebuildCCs` already visits
every cc, computes `tokenOf`, and reseats each pb's swing in place. The
clean move is to clone the pbs there (like it clones cc/at/pc, applying
`movedPpq`/`movedPpqL` so `origTok` is the reseated token) and return
them, sparing `rebuildPbs` the second full-cc traversal.

Blocked on fx dirt tracking. The clone needs the same dirt gate the
per-chan loop uses, but `rebuildCCs` is the `ccs` stage — fx-activeness
(`fxLane1`, `replacePb`) isn't resolved until the later `fx` stage, and
fx channels aren't in `dirtyPbChans` by design (the fx row stays
wholesale). Gating the cc-loop clone on `dirtyPbChans` alone silently
misses fx-active channels: e.g. toggling a lane-1 note's `.fx` flag
makes the channel fx-active but doesn't `dirtyPb` (`fx` ∉ `PB_GEOMETRY`),
so no clone is taken, and `deriveChan` then reads empty pbs and deletes
every absorber on the channel. Revisit once fx grows its own dirt signal
(retiring the wholesale fx row) — then the cc-loop extraction gated on
pb-dirt falls out for free. It buys ~0.4ms, so it waits on that larger
change rather than driving it.

## Open questions

- Split of the ~16ms derivation between seat math, matching, and the
  consolidated assign — add sub-timers inside `rebuildPbs` before
  committing to stage 2.
- Whether fx-hosting channels are common enough in practice that the
  conservative fx row erases the win on macro-heavy takes.
