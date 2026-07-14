# incremental rebuild — programme status & residuals

> Master doc, **closed 2026-07-15** — every gap below is landed, dropped,
> or deliberately deferred. This doc is the ledger of what shipped and the
> record of what did not; the whole programme is archived alongside its
> four slice docs (`same-pitch-enforcement.md`, `incremental-pbs.md`,
> `deferred-reindex.md`, `dirty-channels.md`), which are kept for their
> history. The enduring model lives in `docs/trackerManager.md` §
> Derivation dirt — read that first.
>
> One gap (4, the fx dirt signal) is deferred rather than done, because a
> successor project — dirt as **ppq intervals** rather than whole channels
> — subsumes it. That project is live at `design/interval-dirt.md`.

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

All resolved. Ordered correctness-first, then by size of win; each was
self-contained — the archived slice docs are not needed to read any of
them. Kept in full because the *reasoning* is the asset: several were
closed by measuring rather than by coding, and gap 2 was dropped outright
once measured.

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

### 4. fx dirt signal — deferred 2026-07-15, **subsumed by interval dirt**

fx output regenerates every rebuild with no change tracking, so
fx-hosting channels are marked dirty **wholesale** on every rebuild. That
is a deliberate conservatism, and it is correct, but it means macro-heavy
takes get materially less of the gating win than the numbers above
suggest. This limitation is shipped.

The obvious fix — give fx its own dirt signal, hashing the generator inputs
per host — is **deliberately not being built**. It would add a second dirt
axis to plumb alongside `dirtyChans`, and the successor below deletes it
again. Two mechanisms wired together where one suffices.

It also blocks a queued follow-up, which stays blocked: `rebuildPbs`
re-walks every cc via `mm:ccsRaw()` purely to find and clone the pbs, which
`rebuildCCs` already visits. Folding the clone into the cc walk buys ~0.4ms
but cannot be gated safely today — fx-activeness isn't resolved until the
later fx stage, so gating the cc-loop clone on pb-dirt alone would silently
miss fx-active channels and delete every absorber on them.

#### The successor: dirty ppq intervals, not dirty channels

A separate project, not a residual of this one, and it is **live** at
`design/interval-dirt.md` — read that, not this summary.

In one line: make the dirt unit a **ppq interval within a channel** rather
than the whole channel, and fx needs no dirt signal of its own — a host
regenerates exactly when a dirty interval intersects its window, which
`computeFxWindows` already computes as a per-host logical-ppq extent. The
channel model is then the degenerate case (interval = whole channel), which
is what makes the migration tractable. The hard part is forward propagation:
intra-channel is not ppq-local, so a dirty interval is the *seed* of a blast
radius rather than the radius itself.

### 5. `deferred-reindex` follow-up — nest the whole pipeline in one mm unwind — landed 2026-07-14, **closed**

Only the *flush* path nests the pipeline's commits inside an outer modify. A rebuild fired by
`configChanged` or `load` still runs each pipeline commit as its own top-level modify — its own
reindex, its own `flushTake`. Wrapping the pipeline body in an `mm:modify` extends the deferral
win to those paths and collapses the multiple serialises. This also closes out the older mm-write
goal of *rewriting the take at most once per rebuild*: the flush path meets it today, these paths
do not.

Filed as a follow-up; the audit says it is bigger than that. **`tm:rebuild`'s pipeline has nine
`mmBatch` commit sites** — `reseats`, `ccWrites`, `extWrites`, regionPark's `batch`, `wires`
(which is *inside a loop*), `clampWrites`, `deferred`, `pbWrites`, `pcWrites`. Every one that
stages anything is, on these paths, a top-level modify, and every top-level unwind pays a reindex
(3.1ms, gap 6's live reading) **and** a full `flushTake` (serialise 8.7 + setEvts 5.1 + sidecars
1.2 ≈ 15ms warm). So a bind that re-derives pbs, PCs, tails and fx plausibly reprojects the whole
take five or more times — 100ms+ of pure redundancy, and it lands on take-bind and import, which
the user feels.

**The flush path is the existence proof.** The pipeline already runs entirely nested inside
`flush`'s modify on every edit, with commits that neither reindex nor flush. That regime is the
common and well-tested one; `load` / `configChanged` are the odd paths out. Wrapping makes the
rare path behave like the hot one. `mm:events()` is already protected on the load path —
`loadIndex` (`trackerManager.lua:1143`) calls `mm:reindexIfStale()` at its head, and its comment
already cites this item.

**The trap, and it fails silently.** `rebuilding = false` (`trackerManager.lua:3124`) must stay
*outside* the wrapper. The wrapper's own unwind fires `reload`, and tm's subscriber both re-enters
`tm:rebuild` and folds `info.chans` into `dirtyChans`. With `rebuilding` already false at that
moment you get a second full rebuild *and* the pipeline's own writes read back as external dirt —
the exact I8 violation `dirty-channels` exists to prevent, surfacing as "everything re-derives on
the next edit".

**Outcome, on the Hammerklavier bind (8437 notes, 1685 ccs): 539ms → 454ms, and take
reprojections 3 → 2.** The audit above over-priced it. Only two of the three top-level modifies
were flushing, not five-plus, and the reindex they each paid is the cheap half: the expensive
shared cost is the metadata round-trip (`meta` 106ms, nearly all `buckets`), which is one keyset
write of every dirty entry *however many unwinds it lands under* — collapsing the unwinds doesn't
shrink it. The two survivors are structural, not accidental: `mm:load`'s own normalisation flush
(dedup + collision repair, before tm ever sees the take) and the pipeline's single one. That is
the old mm-write goal — *rewrite the take at most once per rebuild* — finally met on every path.

**It is not an outer `mm:modify`, and it can't be.** `mm:modify` fires `reload` on every unwind
whether or not its `fn` wrote anything, so a modify wrapper announces a mutation that never
happened — on every rebuild, including converged ones that stage nothing, and including every
keystroke edit (where it nests at depth 2). Four `mm_signal_flow_spec` cases catch it. Gating the
fire on `dirty` is not available either: metadata-only gestures set no `dirty` (`midiManager.lua`,
the `flushPending` line) and still need the `reload` to drive tm's rebuild.

What tm needs from mm is not a gesture but a **nest**. `mm:batch(fn)` holds `modifyDepth` open
across the caller's own modifies so their unwinds stay nested, then runs the outermost unwind
once; `enterNest` / `leaveNest` factor out of `mm:modify` so both doors share one definition of
it. It takes no lock (a bare write inside it still trips the assert), writes nothing, and fires no
reload — mm's signal stream is unchanged, which is why the four specs pass untouched. It also
*propagates* errors rather than `pcall`-and-print, so the cost this item used to file — "wrapping
turns a derivation exception into a print over a half-derived model" — never materialised.

The pipeline is now `rebuildPipeline(didReload)`, a named function rather than 85 lines indented
into a closure, and `tm:rebuild` reads as guard → carry the clean channel frames → one nest →
drop the guard → fire.

**Not a blocker, but it corrects the record:** `rebuildTails`' comment at `trackerManager.lua:2573`
("clamps reindex colliding same-pitch onsets separately") describes a mechanism that isn't there.
The separation is done by `mm:assign`'s in-verb `tokenIdx` re-key plus `mmBatch`'s `idxReconcile`,
both depth-independent — as they must be, since the flush path already nests that very commit.

The measurement protocol, for reuse: gap 3's take-hash gate means a *converged* rebind stages zero
commits and shows nothing at all — it needs a genuinely re-deriving rebuild, i.e. a foreign-take
bind. Arm `perf`, count `flushed` fires, time `mm:load` (the bind runs inside it: load fires
`reload`, whose subscriber is `tm:rebuild`).

### 6. `deferred-reindex` follow-up — split hole-dirt from order-dirt — landed 2026-07-14, **closed**

Filed as a micro-opt. It is not one — but only because the framing above misses its own
third case. `indexStale` was set by the blanket `if dirty` at the modify unwind, i.e. by
*any* structural write. Two flags replace it, and they describe the arrays rather than the
write:

| the commit contains | array state | reindex |
|---|---|---|
| a delete | sparse — a hole at `evt.loc` | `needsCompact`: compact, then the index loop |
| an add, or an assign that moves `ppq` | dense, out of ppq order | `needsSort`: sort, then the index loop |
| an assign touching neither | **untouched** | **skipped entirely** |

The index loop — `loc`, `tokenIdx`, `chanIdx`, `eventsByUuid`, 2.3ms of the 3.1ms reindex —
runs whenever either fixup does, because both move every `loc`. That is exactly why the
split *as filed* is worth so little: it buys the 0.6ms sort or the 0.2ms compact, in the
narrow case where only one kind of dirt fired. The win is the third row. An assign touching
only `vel` / `pitch` / `chan` / `muted` / `endppq` / a cc value leaves the array dense and
still ppq-ascending, so the whole reindex is dead work: `pitch` and `chan` are in the token
but not the sort key, and `endppq` is in neither.

It pays on the hot path. Gap 7's one-note edit *is* a value-only assign, so the reindex it
attributes to `rebuild` now costs nothing — as does every rebuild whose only commit is tail
clips, which is most of them. A delete still compacts; an add or a note move still sorts.

#### Measured — 2026-07-14

Warm, live through the bridge, on a 3195-note / 3974-cc / 7169-text take (the fixture family
gap 7 profiled). Both edits restore what they touch, so neither changes the take.

| edit | `rebuild` | flush |
|---|---|---|
| value-only assign (a note's vel to its own value) | **absent — not entered** | 27.2ms |
| ppq move (+1 logical, then back) | 3.1 (`tokenIdx` 2.6, `sort` 0.5, **no `compact`**) | 31.6ms |

The gate fires. **3.1ms of a ~30ms edit** goes on every value-only edit, and the two-flag
split earns its keep in the same reading: the ppq move sorts but does not compact, so a delete
will compact but not sort. (`serialise`'s own `sort` span, midiBlob.lua:269, is unrelated and
still there — don't read it as the reindex's.)

Second-order, and the pleasing part: gap 8 bought its `reload` win by paying **+0.9ms at the
reindex** (`tokenIdx` 1.8 → 2.6). On a value-only edit that cost is now zero, so the per-channel
index's trade got strictly better after the fact.

What is left is the write side, exactly where gap 7 left it: **serialise 8.7 + setEvts 5.1 =
13.8ms, 51% of the edit.**

What changed underneath is that **the verbs' incremental index maintenance is now
load-bearing** on the skipped path rather than laundered by the from-scratch rebuild behind
it. `mm:assign` re-keys `tokenIdx` in-verb and brackets a chan move with `indexDrop` /
`indexPut`, so it was already correct; it just never had to be. The two mutators that write
outside the verbs mark themselves, so gap 2's ruling stands untouched: `resolveCollisions`
sets both flags bluntly (it kills *and* nudges — the backstop gets no correctness surgery to
save a millisecond), and load's dedup sets both before its own rebuild. `mm_reindex_if_stale_spec`
pins the gate per verb class; `mm_chan_index_spec` gains the parity case with no reindex
behind it.

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

### 8. The traversal floor — attacked 2026-07-14, **closed**

Gating removed the derive cost, not the scan cost. Found by gap 7's profile, and
the largest thing on this list; the floor is now 1.15ms and what is left of it is
not derivation. Two cuts landed — `nextInLane`, then the per-channel index.

The original finding, kept because the reasoning is the entry price for the fixes. A one-channel edit
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
of it, and the two fixes below are measured against it.

Columns: **(a)** as found; **(b)** after `nextInLane` died; **(c)** after the
per-channel index. All warm — a cold Continuum reads ~30% high across every
span, which is how the retracted `meta` finding below got made.

| span | (a) | (b) | (c) |
|---|---|---|---|
| `fxWindows` (×2) | **2.82** | 0.64 | 0.34 |
| `fire` — subscriber notify, not derivation | 0.78 | 0.72 | 0.53 |
| `fx` | 0.52 | 0.46 | 0.07 |
| `internals` | 0.48 | 0.42 | **0.00** |
| `ccs` | 0.44 | 0.34 | **0.00** |
| `regionPark` | 0.40 | 0.32 | 0.01 |
| `pbs` | 0.38 | 0.32 | **0.00** |
| `pa` | 0.28 | 0.24 | **0.00** |
| `parkRegions` | 0.14 | 0.12 | 0.08 |
| `derivedInputs` | 0.12 | 0.10 | 0.09 |
| `tails` / `projLogical` | — | — | **0.00** |
| **total** | **6.42** | **3.76** | **1.15** |

The six gated stages now read *literally zero*: they are no longer entered for a
clean channel, so there is nothing left to shave. `fire` is 46% of what remains
and it is subscriber notification, not derivation.

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

#### Landed: the per-channel event index

The gate was never really *inside* the loop — the loop was in the wrong place.
`tm:rebuild` walked mm's 4097-entry cc array **six separate times** (`rebuildCCs`,
`rebuildRegionPark`, `rebuildPA`, `rebuildFx`'s authored-pb pass, `rebuildPbs`,
`rebuildPCs`) plus the note array once: ~28,000 event visits to find, on a
one-note edit, the ~370 events on one channel.

A tm-side snapshot cannot fix that. The pipeline **writes to mm mid-rebuild** —
`regionPark` deletes parked PAs and pbs, `rebuildPCs` explicitly re-reads mm
*after* its own commit — so any head-of-pipeline cache is stale by the time half
the stages run. The index has to live in mm, under mm's own verbs.

So `mm` now keys events by channel: `chanIdx[kind][chan].byLoc[loc] = evt`, behind
`mm:notesRaw(chan)` / `mm:ccsRaw(chan)`. Three things made it cheap:

- **Every event already carries `.loc`**, so the bucket is a sparse map — O(1)
  insert, O(1) delete, no array shuffling.
- **The maintenance hooks already existed.** mm brackets `assign` and `delete`
  with `markChan` at exactly the three points the index needs (old chan, new chan,
  delete); they were there for the reload signal.
- **Order-independence was already paid for** by `deferred-reindex` Phase A. The
  bucket yields ascending `loc`, hole-tolerant — one channel's slice of exactly
  what the whole-array walk yielded, in the same order — so within a channel
  nothing moved. Across channels the walk becomes channel-major, which no consumer
  can see: all nine key their output per channel.

The index is keyed on **chan alone**, which makes its invalidation surface strictly
smaller than `tokenIdx`'s: `resolveCollisions`'s ppq *nudge* — the thing that
silently breaks `tokenIdx` (gap 2) — cannot disturb it. Its *kill* can, and that is
laundered by the from-scratch reconstruction at the reindex, exactly as `tokenIdx`
is. `mm_chan_index_spec` pins the whole net: per-channel walk ≡ filtered whole-array
walk, record-for-record, across add / delete / chan-move / metadata-only assign /
backstop kill, and both mid-modify (verbs maintaining) and post-unwind (reindex
reconstructing).

A latent quadratic died with it: the pb sweeps at `:2046` / `:2075` walked all 4097
ccs *per created or removed fx window*. Now O(that window's channel).

**It is not free.** The reindex reconstructs the index every flush, and that costs
**+0.9ms** (`tokenIdx` 1.8 → 2.6) against a **−2.4ms** `reload` win (10.0 → 7.5) on
a one-note edit. Net ≈ −1.5ms of 37ms. Three shapes were tried — lazy sort,
append-in-order, inlined bulk seat — and none moved it, so the cost is inherent to
touching 7290 events, not a code-shape defect. Keying by event instead of `loc`
would let the reindex skip the rebuild entirely, but then the collision backstop
and load-time dedup — which kill events *outside* `mm:delete` — would have to
maintain the index themselves. Gap 2 already ruled on that trade: correctness
surgery on the backstop, whose failure mode is silent take corruption, is not worth
a millisecond. The laundering stays.

#### What is left — 1.15ms

- **`fire` 0.53** — subscriber notification, not derivation. Out of scope here,
  and now the largest single item in the floor.
- **`fxWindows` 0.34** — still two calls, still scanning all 16 channels' columns
  (parking and recognition need the complete window set). The re-scan at `:3070`
  exists only because park/unpark may have moved the columns; when nothing was
  restored and nothing parked — the common case — call #1's result still stands.
  Halves it. Small, and no longer obviously worth the plumbing.

#### Retracted: the `meta` "second floor"

This doc previously recorded that `meta` pays 2.6ms on a one-note edit with a
single dirty entry, and called it an unattributed fixed cost. **That was a
measurement artifact** — a cold Continuum, before the caches and GC settle. Every
warm run reads `meta` at **0.32ms** per flush, essentially all of it `buckets`.
Gap 7's fat-edit reading (7.3ms / 128 entries) stands; there is no fixed floor
under it. Warm the instance before believing any span in this doc.

### 9. Housekeeping — shadow scaffolding — checked 2026-07-15, **closed**

Every slice's validation plan said "run the full path in shadow, assert
parity, strip the scaffolding once parity holds, keep one permanent
gated-vs-full spec". The permanent spec exists (`a4a4b4a`,
`tm_gate_parity_spec`, extended by B2 to assert the carried grid equals a
forced full re-derive). No commit strips live shadow scaffolding because
**none was ever built** — the tracker stack has no shadow/parity path in
production (the only `shadow` names in tm are sample-shadowing and
swing-slot shadowing, both unrelated). Nothing to strip; the parity spec
stands as the permanent net.
