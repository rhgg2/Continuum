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

### 2. `deferred-reindex` Phase E — slim the unwind reindex

Phases A–D collapsed 2–3 reindexes per flush into one, but that one is
still the *full* from-scratch reindex. Phase E: `rebuild(metadata, slim)`
keeps compact + sort + `loc` recompute but drops the
`tokenIdx`/`eventsByUuid` reconstruction — the verbs already maintain both
incrementally (add, assign re-key, delete). Modify-path/unwind and
`reindexIfStale` pass `slim=true`; `mm:load` keeps `slim=false`, since its
dedup/unify paths genuinely need from-scratch.

Worth doing: the index reconstruction is over ~12k string keys and is a
large share of the ≤11ms reindex, so the slice as it stands has banked
perhaps half its available win. Validate by shadow-compare (run the
from-scratch reindex alongside, assert identical arrays / `loc`s /
indices), strip the scaffold at parity, keep one permanent gated-vs-full
spec.

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

### 7. Re-profile, and the undocumented write-side work

**No end-to-end number has been recorded since the programme began.** The
stage-level wins are measured and real (pbs 27.8 → 0.4, internals 7.3 →
0.5, ccs 2.8 → 0.7), but nothing states what one edit on the fixture take
costs now against the 100ms baseline. The original projection was ~50ms
after phase A and ~30ms after phase B, at which point the write side
dominates. Re-profile the same fixture before declaring the programme
closed — every remaining gap should be prioritised against that number, not
against the projections.

Relatedly, `15a343d` ("cache rebuild tokens and serialise chunks across
flushes") began attacking the write-side bucket that this programme had
declared out of scope. It is undocumented by any design doc. Per-event
serialise memoisation was always meant to be the *next* programme; fold
what landed into that doc when it is written.

### 8. Housekeeping — shadow scaffolding

Every slice's validation plan said "run the full path in shadow, assert
parity, strip the scaffolding once parity holds, keep one permanent
gated-vs-full spec". The permanent spec exists (`a4a4b4a`,
`tm_gate_parity_spec`, extended by B2 to assert the carried grid equals a
forced full re-derive). No commit strips live shadow scaffolding — so
either it was never built, or it is still in the tree burning time behind a
perf gate. Check before closing.
