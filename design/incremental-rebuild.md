# incremental rebuild — programme status & residuals

> Master doc. The programme is substantially landed; this doc is now the
> ledger of what shipped and the record of what did not. Two slices are
> finished and archived (`archive/same-pitch-enforcement.md`,
> `archive/incremental-pbs.md`); the two with residuals stay live
> (`deferred-reindex.md`, `dirty-channels.md`). The enduring model lives
> in `docs/trackerManager.md` § Derivation dirt — read that first; this
> doc carries history and the open work.

## Goal & baseline

One edit on a large take (3070 notes, 6219 ccs, 9212 texts) cost ~100ms
at flush. The money was in four buckets:

| bucket | ~ms | attacked by | outcome |
|---|---|---|---|
| mm whole-model reindexes (2–3 per flush) | 21–32 | `deferred-reindex` | partial — one reindex per flush, but still the full one (gap 2) |
| pbs derivation (absorber reconciliation) | 16 | `incremental-pbs` | closed — stage 27.8ms → 0.4ms |
| walk stages (internals, ccs, projLogical, tails, fx, park) | ~33 | `dirty-channels` phase A/B | closed — internals 7.3 → 0.5, ccs 2.8 → 0.7 |
| write side (serialise, meta, sidecars, setEvts) | ~27 | out of scope | partly attacked anyway (gap 7) |

Bind-time cost — a full derivation pass over an unchanged take — was a
fifth target, and is the one bucket that went **entirely unaddressed**
(gap 3). `same-pitch-enforcement` bought no time; it was the correctness
net the others run under, and it landed in full.

## Shared model

(Canonical statement: `docs/trackerManager.md` § Derivation dirt.
Retained here because the gaps below lean on it.)

**Two axes of dirt.** Rebuild does two jobs and they invalidate
independently. *Materialisation* (columns, um index) is keyed by object
identity — mm's `wholesale` bit. *Derivation* (reconcile, synthesise,
write back) is keyed by content: a per-channel dirty set, fed by edit
verbs and config, zeroed by a take-hash match. The old three "levels" of
rebuild are just cardinalities of that set.

**I8 is the soundness oracle.** Rebuild converges in one pass (flush →
rebuild → flush is a fixpoint), so "no dirty source fired" ⟹ re-deriving
stages nothing ⟹ skipping is pure savings. Every gate in the programme
leans on this argument.

**Channel granularity is closure-free.** Every blast-radius rule (tail
clip/regrow, same-pitch nudges, absorbers, PC streams, fx windows) is
intra-channel, so a whole dirty channel over-approximates the closure
without fixpoint computation.

**The residual risk is a missed dirty source**, and its failure mode is
silent take corruption (an unseparated same-pitch collision). Hence the
net: mm enforces its own collision invariant at the modify unwind,
turning the worst case into a logged, self-repairing event.

## What landed

| slice | phases | commits |
|---|---|---|
| `deferred-reindex` | A–D (order self-sufficiency, hole-tolerant iterators, reindex-if-stale, defer to one unwind reindex) | `52bd301` `480c432` `07eac20` `96c6d9e` |
| `same-pitch-enforcement` | 1–5, complete | `7baa1b6` `4d08384` `23e5095` `c1de112` `55ac771` |
| `incremental-pbs` | stage 1, stage 1b, + the `streamValue` merge win | `8d29327` `76793d5` `6af36d2` |
| `dirty-channels` | spine, phase A gate, ds-key carry, phase B/B1/B2, parity harness | `c231f5a` `d03715b` `c3b9b58` `4115377` `c034529` `a4a4b4a` `1a7fb79` `a8b841f` `fe3573f` `81d0284` |

`incremental-pbs` stage 2 (seat-level windows) was **deliberately** dropped,
not missed: stage 1+1b took the pbs stage off the critical path entirely,
so the seat math it would have optimised no longer costs anything.

## Known gaps

Ordered correctness-first, then by size of win. Each is self-contained —
the archived slice docs are not needed to implement any of them.

### 1. Take-length dirty source — audited 2026-07-14, **closed**

The question was: *an arrange-side item resize reaches tm via which signal?*
If none marks all 16 channels dirty, a gated rebuild after a resize keeps
stale derivation on every clean channel.

**The source exists — it is the wholesale reload.** `mm:length()` is the
*source* length, i.e. the EOT marker's position, so any take-length change
necessarily rewrites the event blob. **External:** `trackerPage`'s per-frame
`MIDI_GetHash` watcher sees the drift → `tm:reloadFromReaper()` → `mm:load` →
`reload{wholesale=true}` → `mmReloaded` → `dirtyChan()`, all 16. **Owned**
(`setLength`/`rescaleLength`/`tileLength`): `mm:setLength` → `mm:reload` → the
same wholesale path. Verified live in REAPER — an item-edge drag moves the
hash, and so does an EOT-only change with no note touched — and now pinned in
`tm_tail_gating_spec`: a converged take, grown externally, re-derives the tails
on channels that were never edited.

No latent bug, then. The audit did turn up a real one next door, now fixed: the
shrink path stamped a concrete `endppqL` over `util.OPEN`, destroying authored
intent, and a re-grow could not reopen the tail. See `docs/trackerManager.md`
§ Length operations for the fix and the ordering knot behind it.

### 2. `deferred-reindex` Phase E — slim the unwind reindex — measured 2026-07-14, **dropped**

The plan was `rebuild(metadata, slim)`: keep compact + sort + `loc` recompute,
drop the `tokenIdx`/`eventsByUuid` reconstruction, on the grounds that the verbs
maintain both incrementally. The premise is sound (see below) but the win is not
there. **`tokenIdx` is 1.7ms of a 32.5ms edit** (gap 7's profile) — the sub-span
the slice targets. Its parent `rebuild` is 2.3ms, not the ≤11ms the plan assumed:
phases A–D took that bucket off the table more thoroughly than this doc realised.
And slim cannot take even all of that — the loop still runs to recompute `loc`,
so only the two hash-table inserts go. ~1.5ms, ~4%.

Against that stands real correctness surgery, which is the part worth keeping:

**`resolveCollisions` is not index-maintaining, and slim would expose it.** It is
the one non-verb, non-load mutator of the model. A kill nils `notes[n.loc]` and
`eventsByUuid[n.uuid]` but leaves the dead note's token in `tokenIdx`; a nudge
rewrites `n.ppq` — an *identity* field — without re-keying. Both are laundered
today by the from-scratch rebuild that its own `indexStale` triggers two lines
later. Slim that rebuild and the backstop starts leaving dangling tokens.

Making it maintain the index is fiddlier than it looks, because a collision *is*
the state where `tokenIdx`'s 1:1 map is broken: two notes share a token, the
second write shadowed the first, so the shadowed note is already absent from the
index — and a naive `tokenIdx[tokenOf(n)] = nil` on kill evicts the *other*
note's entry. The shape that works exploits the group being closed under (chan,
pitch): nudges only move ppq, so no token outside the group can be disturbed.
Clear each group member's owned token (identity-checked), resolve, re-register
the survivors. Relatedly, the re-key clears in `assignNote` and `assignCC` want
the same identity check (`if tokenIdx[oldTok] == evt`), for the same reason.

Paying that — on the one component whose failure mode is silent take corruption
— to buy 4% is a bad trade. Dropped. If a future slice makes the reindex hot
again, the analysis above is the entry price.

### 3. `dirty-channels` item 4 — the take-hash gate — landed 2026-07-14, **closed**

The bind-time bucket. Rebinding a take Continuum itself last wrote paid a full
derivation pass to stage zero writes. It now costs one `MIDI_GetAllEvts` and a
string compare. The model lives in `docs/midiManager.md` § Converged load and
`docs/trackerManager.md` § Dormant guard; pinned by `tm_rebind_gate_spec` and
`mm_signal_flow_spec`.

Three of the sketch above turned out wrong, and they are the interesting part.

**"Fire `wholesale=true, chans={}` — full reprojection, zero derivation."** That
path does not exist. Materialisation and derivation are *one* gate, not two:
under frame retention (B1) a clean channel's freeze is total — `rebuildInternals`
clones nothing for it, the CC walk clones nothing, `rebuildPA` projects nothing.
A channel's fx-derived notes, park restores and PA projections enter its columns
*from the derivation stages*, so materialising fresh columns while skipping
derivation yields a frame with every fx note missing. Skipping derivation
therefore means carrying the previous frame, which is sound only if that frame
was built from this same take. Hence the gate fires as `wholesale=false, chans={}`:
nothing was re-parsed, so no object is new, so there is nothing to re-materialise.
The wholesale blanket at the rebuild head is untouched — a genuine re-read still
dirties all 16.

**The hash.** Skipped: Lua string equality is a memcmp, and `MIDI_GetHash`'s
coverage of text events is not worth betting correctness on. The doc's own
fallback (stash the blob) is simply better.

**`configGen`.** A counter can only be bumped by a path someone remembered to
bump, and the paths that matter here fire *no signal at all*: take-scoped ds/cm
state rewound by an undo while `ps` watches only the bound take's slots, and the
`trackerMode` re-seed inside `bindTake`'s own suppression window. Both simply
refill their caches at the next `setContext`, unheard. So the bind diffs values
rather than counting events: `derivationInputs()` vs the `derivedInputs` each
rebuild stashes.

Two bugs fell out, neither introduced by the gate:

- **Swing authored while dormant was silently lost.** The rebind's blanket marked
  channels *dirty* but never marked swing *stale*, and only staleness drives the
  raw reseat — so the notes never re-realised. The bind-time diff answers with
  `markSwingStale(nil)`, which covers both.
- **`fakeReaper` hid take-length changes from the blob.** It emitted REAPER's
  trailing all-notes-off marker at offset 0 from the last event and discarded it
  on `SetAllEvts`, so a resize left the bytes identical — length lived outside the
  wire, unlike REAPER, where the marker sits at the source end (which is what gap 1
  verified live, and what `midiBlob.serialise` has always done). The gate read a
  resize as converged, and four length specs caught it. The fake now places its
  tail at the source end.

Still unmeasured against a real take: the win is a full derivation pass, but no
live number is recorded. Fold it into gap 7's re-profile.

### 4. fx dirt signal — the conservative row nobody else knows about

fx output regenerates every rebuild with no change tracking, so
fx-hosting channels are marked dirty **wholesale** on every rebuild. That
is a deliberate conservatism, and it is correct, but it means macro-heavy
takes get materially less of the gating win than the numbers above
suggest. This limitation is shipped and, until now, recorded only in the
design docs.

Giving fx its own dirt signal (hash the generator inputs per host?) retires
the wholesale row, and unblocks a queued follow-up: `rebuildPbs` currently
re-walks every cc via `mm:ccsRaw()` purely to find and clone the pbs, which
`rebuildCCs` already visits. Folding the clone into the cc walk buys ~0.4ms
but cannot be gated safely today — fx-activeness isn't resolved until the
later fx stage, so gating the cc-loop clone on pb-dirt alone would silently
miss fx-active channels and delete every absorber on them.

### 5. `deferred-reindex` follow-up — wrap load/config rebuilds in an outer `mm:modify`

Only the *flush* path nests the pipeline's commits inside an outer modify.
A rebuild fired by `configChanged` or `load` still runs each pipeline
commit as its own top-level modify — its own reindex, its own `flushTake`.
Wrapping the pipeline body in an `mm:modify` extends the deferral win to
those paths and collapses the multiple serialises; the extra `reload` fire
at unwind is harmless (the sole subscriber is reentrancy-guarded).

This also closes out the older mm-write goal of *rewriting the take at most
once per rebuild*: the flush path meets it today, these paths do not.

### 6. `deferred-reindex` follow-up — split hole-dirt from order-dirt

Micro-opt, no correctness content. `dirty` is boolean; assign-only commits
that move no ppq (value edits) need neither compact nor sort. Splitting the
flag lets the unwind reindex skip the sort when nothing moved, and skip
compaction when nothing was deleted.

### 7. Re-profile, and the undocumented write-side work — profiled 2026-07-14, **closed**

**A one-note edit costs 32.5ms; a 128-note grouped edit costs 52.2ms.** Measured
live through the bridge on a near-fixture take — 3193 notes, 4097 ccs, 7290
sidecars, 53EDO, no fx. Both edits are semantically null (each note assigned a
field's own current value), so they pay the full write path and change nothing.
The small one goes straight to `mm:modify` (one write, one dirty channel, averaged
over 5); the large one stages 128 `tm:assignEvent`s into one `tm:flush`, which is
the shape a grouped channel-1 edit actually produces. Not the take the 100ms
baseline was taken on, so this is same-order, not like-for-like; the shape of the
split is the finding, not the third digit.

| stage | 1 note | 128 notes |
|---|---|---|
| reload — all derivation (pbs, internals, regionPark, fire, tails, ccs, fx, …) | 11.0 | **12.5** |
| serialise (pack 4.0, sort 3.6, keys 1.3, concat 0.7) | 11.5 | 9.7 |
| setEvts | 5.4 | 8.3 |
| meta — `eventMeta` buckets | 0.3 | **7.3** |
| rebuild — the reindex (tokenIdx 2.3, sort 0.6, compact 0.2) | 2.3 | 3.2 |
| sidecars | 1.2 | 1.5 |
| verbs + tm staging | ~0 | 2.9 |
| **total** | **32.5** | **52.2** |

This lands on the original projection — "~30ms after phase B, at which point the
write side dominates" — and it does: **serialise + setEvts is 16.9ms on the small
edit, 52% of it.** That is the next programme, and `15a343d` ("cache rebuild
tokens and serialise chunks across flushes") is its first landed commit,
undocumented by any design doc. `serialise`'s own split (pack / sort / concat) is
the map for where to start. Fold `15a343d` into that doc when it is written.

Two further findings, both new buckets:

- **Derivation is flat in edit size** — 128× the writes moved `reload` by 1.5ms.
  Roughly 32ms of the 52ms fat edit is fixed cost with no relation to what was
  edited; the marginal cost of an actual note is ~0.15ms. See gap 8.
- **`meta` is 7.3ms on a fat edit** (0.3ms on a small one, which is why the
  programme never saw it), essentially all inside `eventMeta`'s `buckets` — 128
  dirty metadata entries at ~57µs each. Third-biggest span on the fat edit. Note
  `e441984` already attacked this once (585ms → 15ms at flush); it is cheap now
  but not free, and it scales with edit size where nothing else does.

### 8. The traversal floor — gating removed the derive cost, not the scan cost

Found by gap 7's profile, and the largest thing on this list. A one-channel edit
on a take with **zero fx notes** (verified live: 3193 notes, 11 channels in use,
no `fx` or `derived` note anywhere) still pays 11ms of `reload` — a third of the
edit. Not gap 4: there is nothing for the wholesale-fx row to mark.

**The proof is that derivation is flat in edit size.** One note dirtying one
channel costs 11.0ms of `reload`; 128 notes on the same channel cost 12.5ms.
Whatever `reload` is spending its time on, it is not the edit — it is the take.

The cost is the pipeline's own traversal, and the profile's shape is the second
tell — it is smeared thin across every stage (pbs 2.1, internals 2.0, regionPark
1.1, fire 1.0, tails 0.7, ccs 0.6, fx 0.5) rather than pooled in one, with a
further ~2.3ms outside any perf span. **Every stage still pays an O(all events)
walk to discover it has nothing to do.** The channel gate can't touch that: the
walk happens *before* the gate is consulted.

This does not invalidate `dirty-channels`: its stage-level wins are real and
measured (internals 7.3 → 0.5). What is left underneath is a different quantity,
and it rivals the write side (16.9ms).

#### The floor, measured — 2026-07-14

A rebuild with **zero dirty channels** — nothing to derive, every gated stage
skipping — costs 6.4ms on this take. That is the floor, isolated: no edit, no
derivation, pure traversal. Perf spans on the interstitial work account for all
of it, and the `nextInLane` fix below is measured against it.

| span | before | after |
|---|---|---|
| `fxWindows` (×2) | **2.82** | **0.64** |
| `fire` — subscriber notify, not derivation | 0.78 | 0.72 |
| `fx` | 0.52 | 0.46 |
| `internals` | 0.48 | 0.42 |
| `ccs` | 0.44 | 0.34 |
| `regionPark` | 0.40 | 0.32 |
| `pbs` | 0.38 | 0.32 |
| `pa` | 0.28 | 0.24 |
| `parkRegions` | 0.14 | 0.12 |
| `derivedInputs` | 0.12 | 0.10 |
| **total** | **6.42** | **3.76** |

#### Landed: kill `nextInLane`

`computeFxWindows` was 44% of the floor **on a take with no fx at all**. It built
a 3193-entry `nextInLane` map — a bucket pass plus a `strictNextMap` pass over
every note on all 16 channels — and it did so twice per rebuild. Both of its
outputs are only ever *read* for an fx note: `fxWindow` is guarded by `if
host.fx` at every read site, and `nextInLane` reaches exactly one consumer,
`slide(target='next')`, through `ctx.nextSameLaneNote`.

So the map is gone. `computeFxWindows` now clamps each host's window in a single
forward pass over the ppq-sorted column — chord-mates share an onset and so share
a successor, so it holds the open hosts and clips them together when a greater
ppq arrives. `nextSameLaneNote` builds the lane-next map lazily, per channel, on
first ask: a channel no slide queries never pays for it, and one that does pays
exactly what it paid before rather than a per-query rescan (the naive on-demand
scan is O(fx notes × column) — quadratic on a channel where every note carries a
generator).

Unbudgeted second win: **every other stage got faster too** (ccs 0.44 → 0.34, pbs
0.38 → 0.32, internals 0.48 → 0.42). Two 3193-entry hash allocations per rebuild
were putting the whole pipeline under GC load.

#### What is left — 3.76ms

- **`fxWindows` 0.64** — still two calls. The re-scan at `:3052` exists only
  because park/unpark/PA may have moved the columns; when nothing was restored,
  nothing parked and PA added nothing — the common case — call #1's result still
  stands. Halves it.
- **~2.1ms across the six gated stages**, each paying an O(all events) walk
  because the `dirtyChans` check sits *inside* the loop: `rebuildCCs` walks all
  4097 ccs to test `dirtyChans[cc.chan]` per event, `rebuildPA` likewise.
  Hoisting the gate needs a channel-bucketed event index in `mm`, which does not
  exist. Its own slice, and the bigger of the two.
- `fire` 0.72 is subscriber notification, not derivation — out of scope here.

#### A second floor: `meta`

Gap 7 read `meta` at 7.3ms over 128 dirty entries and called it the one bucket
that scales with edit size. Half right: a **one-note** edit with a single dirty
entry still pays 2.6ms, only 0.34ms of which is `buckets`. So `meta` has a fixed
cost of its own, invisible in the fat-edit reading. Unattributed as yet.

### 9. Housekeeping — shadow scaffolding

Every slice's validation plan said "run the full path in shadow, assert
parity, strip the scaffolding once parity holds, keep one permanent
gated-vs-full spec". The permanent spec exists (`a4a4b4a`,
`tm_gate_parity_spec`, extended by B2 to assert the carried grid equals a
forced full re-derive). No commit strips live shadow scaffolding — so
either it was never built, or it is still in the tree burning time behind a
perf gate. Check before closing.
