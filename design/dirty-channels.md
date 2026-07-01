# dirty channels — one dirt spine for the whole pipeline

> Working design doc. Final leg of the incremental-rebuild programme
> (`incremental-rebuild.md`).
> `incremental-pbs.md` gates one stage; this generalises the dirt into
> a shared per-channel spine, extends the gate across the walk stages
> (phase A), and adds the take-hash gate so rebinding a converged take
> derives nothing. Retaining `channels[]` across rebuilds (phase B) is
> the stretch.

## Problem

Same profile as the siblings (3070 notes, 6219 ccs, ~100ms/edit).
After `incremental-pbs` and `deferred-reindex` land, the remaining
rebuild cost is the walk stages — internals 9.1 + ccs 7.3 +
projLogical 5.8 + tails 5.6 + fx 3.4 + regionPark 1.8 ≈ **33ms** —
paid wholesale for ~18.5k events regardless of what changed. And a
take *rebind* pays full derivation even when the take is
byte-identical to the converged state our last rebuild left it in:
generators re-run, tails re-clip, park re-reconciles — all to stage
zero writes.

## The model: two axes of dirt

The three rebuild "levels" (never-seen/external; rebind-unchanged; own
edit) are not modes — they are cardinalities of one dirty set, split
along the two jobs rebuild already does:

- **Materialisation dirt** — object identity. Keyed by the existing
  `wholesale` bit: mm re-parsed, every record object is new, so column
  reprojection and um's full `loadIndex` must run (the `didReload`
  switch, trackerManager.lua:2455-2457). Content-independent.
- **Derivation dirt** — a per-channel set `dirtyChans`. Fed by edit
  verbs and config, zeroed by a hash match. Skipping a clean channel's
  derivation is sound by I8: rebuild converges in one pass, so "no
  dirty source fired since the last rebuild" ⟹ re-deriving stages
  nothing.

So: wholesale foreign reload = both axes dirty; own edit = derivation
dirt only (in-place objects); hash-matched rebind = materialisation
dirt only.

## Why channel granularity is sound

Every blast-radius rule is **intra-channel**: tail clip/regrow
(same-lane and same-pitch), cross-lane same-pitch nudge cascades,
absorber reseats against lane-1, PC streams, fx windows (next
same-lane onset). A whole dirty channel therefore over-approximates
the closure — no fixpoint computation, no interval bookkeeping.
Verified per stage (2026-07-02):

| stage | per-channel evidence |
|---|---|
| internals | placement into `channels[note.chan]`; nudge groups per (chan,pitch) |
| CC walk | carrier routing `carrierRoute[cc.chan]` (:1220); reconcile per cc |
| externals | lane pack within channel |
| regionPark | `parkWindows.notes[chan]` / `.ccs[chan][cc]` (:1449, :1525) |
| fx | window pass per channel (:1617); `authoredPbByChan`, `fxRegionsByChan`, streams all chan-keyed |
| tails | same-lane / same-pitch groups within channel |
| pbs | `lane1ByChan` / `pbsByChan` (:2031, :2051) |
| PCs / PA / projLogical | per channel / per event |

No derivation step reads across channels. The couplings live in
*persistence* (the whole-take ds keys, item 3) and in `chan`-moves
(dirty both values).

## Scheme

1. **Shared dirt spine.** mm's verbs collect `evt.chan` per staged op
   (a chan assign contributes old and new); the `reload` payload
   (midiManager.lua:688) gains `chans` alongside `wholesale` (nil =
   all). tm accumulates into `dirtyChans` exactly as it captures
   `mmReloaded` (:2403): captured and cleared at rebuild head, config
   dirt merged by union (`staleSwing`-style for per-chan keys;
   `pbRange`/`temper`/`ccInterp`/`overlapOffset`/take-length → all
   16). Fires arriving while `rebuilding` do NOT re-enter the
   accumulator — the pipeline's own commits are converged output (I8)
   — but pipeline-internal movers (a tail-walk nudge) mark the
   *captured* set so later stages in the same rebuild see them. That
   resolves `incremental-pbs`'s open question about dirt surviving the
   flush → rebuild boundary; its verb-side dirty rows collapse into
   this spine, leaving only its stage-specific rows (fx-hosting
   conservatism, park moves).
2. **Phase A — gate derivation, keep materialisation wholesale.**
   `channels = {}` stays (:2419); every channel still
   clones/places/sorts/projects, so no lifetime or tv contract
   changes. The skip boundary sits *inside* each stage: the
   classify/route/project half always runs (columns must fill,
   carriers route out of columns, absorbers get `hidden`, parked
   members get render cells), the reconcile/synthesise/write half is
   skipped for clean channels. Per stage: CC walk skips the timing
   reconcile; regionPark skips `reconcilePark` and carries prior
   parked entries; fx skips generator runs (the window pass is
   read-only and stays); tails skips the clip/nudge computation; PCs
   mirrors `dirtyPcChans`; pbs is `incremental-pbs` stage 1.
   projLogical is pure materialisation and cannot gate here — fresh
   clones always need projecting.
3. **Whole-take ds keys merge, never replace.** `fxCarrier` (:1282),
   `fxParked` (:1489), `fxParkedCC` (:1563), and `extraColumns`
   persist as single chan-keyed values behind deepEq-then-assign. A
   gated rebuild computes only dirty channels' entries; every persist
   site must seed the new value with the prior entries of clean
   channels first. The failure is concrete: persist a carrier map
   missing clean channel 5 and the next rebuild's `carrierRoute`
   stops routing 5's carriers out of columns — generator-owned CCs
   leak into the view.
4. **Take-hash gate.** `flushTake` already holds the exact blob it
   wrote (:345); hash it and stash `(hash, configGen)` under the take
   GUID. `mm:load` hashes the `GetAllEvts` blob *before* parsing
   (:403); on match, fire `reload` with `wholesale=true, chans={}` —
   full reprojection, zero derivation. No per-take model retention,
   no eviction: the cache is two values per GUID. `configGen` is one
   global counter bumped by any derivation-relevant config change —
   convergence is relative to the config that produced it (edit the
   swing library while take A is unbound; rebind must derive). A
   stale gen just means one full derivation pass.
5. **Phase B (stretch) — retain `channels[]` across edit rebuilds.**
   Clean channels keep their projected columns; only dirty channels
   re-materialise, removing the ~2µs/event clone/sort/project floor.
   Token-safe (content-keyed; untouched events keep theirs; the um
   index already survives edits) but it changes the tv contract: the
   `rebuild` signal carries the dirty set so tv/tp scope their own
   rebuilds. Wholesale reloads still re-materialise everything — the
   hash gate never combines with retention (new objects). Separate
   slice, entered only behind phase A's proven shadow harness.

## Relation to the siblings

- **incremental-pbs** — phase A for one stage; lands first and
  validates the gate shape and the clean-path soundness argument this
  doc generalises. Its dirty-source table seeds the spine's rows.
- **deferred-reindex** — with gating, most rebuilds stage nothing, so
  the one slim unwind reindex is paid only when a stage actually
  wrote.
- **same-pitch-enforcement** — the net under every gated slice: a
  missed dirty source resolves loudly in mm instead of silently
  eating a voice. Lands before the walk-stage slices.

## Validation

- **Shadow compare per stage** (um-index pattern, perf-gated): run
  full derivation for skipped channels, assert zero staged writes and
  identical projected columns. One permanent gated-vs-full spec on a
  rich fixture (tuning + fx + swing + regions); strip the live shadow
  once parity holds.
- **Spec: hash-gated rebind.** Flush, unbind, rebind: all 16 channels
  derivation-clean, zero staged writes, projected columns identical
  to an ungated rebuild.
- **Spec: configGen.** Change the swing library while unbound; rebind
  hash-matches but must derive.
- **Spec: ds-key carry.** The carrier-leak red test — a gated rebuild
  dirtying channel 3 must not erase channel 5's `fxCarrier` entry;
  same shape for `fxParked`/`fxParkedCC`/`extraColumns`.
- **Spec: chan move dirties both channels.**

## Expected effect

Steady-state edit (one dirty channel): walk-stage derivation drops to
~1/16th of its share; combined with the siblings, flush ≈
materialisation (~22ms) + write side (serialise 14.2 + meta 7.8 +
sidecars 2.4 + setEvts 2.3 ≈ 27ms) ≈ **50ms, from 100**. Phase B
removes most of the materialisation → ~30ms floor, at which point the
write side dominates and the next programme is per-event serialise
memoisation — out of scope here. Rebind of a converged take: parse +
projection only, roughly half of today's bind cost.

## Open questions

- **Where the chans seed lives.** mm verbs (owns `modify`, catches
  every writer) vs um ops (tm-side, knows lane-1/detune semantics).
  Leaning mm for the spine, um for stage-specific refinement.
- **External take-length changes.** An arrange-side item resize
  reaches tm via which signal? Needs an explicit all-16 dirty source;
  audit before phase A.
- **Blob hashing in Lua.** A pure-Lua hash over a few hundred KB per
  flush may not be cheap; stashing the blob itself and using `==`
  (memcmp) is the fallback — memory cost is one blob per seen GUID.
- **fx dirt.** The conservative fx-hosting row from `incremental-pbs`
  applies to fx/tails gating too; if macro-heavy takes keep whole
  channels wholesale, fx needs its own dirt signal (generator inputs
  hash per host?) as a follow-up slice.
- **Dormant guard interaction.** `configChanged` while no take is
  bound bumps `configGen` but marks no channels; confirm the rebind
  path can't consume a stale gen written after the stash.
