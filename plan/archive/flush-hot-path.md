# flush hot path — plan

> No design doc: this work was designed in conversation (2026-07-26) and
> this file is the record. Decisions below are settled; if one needs
> reopening, do it here and say so.

## The problem

After stable-slots closed, a one-note edit on the dense take profiles at
`flush 29.0ms`. Two spans account for ~18 of it, and both do work
proportional to the whole take for an edit proportional to one note:

- **~9.8ms outside `mm`.** `perf.start('flush')` is at
  `trackerManager.lua:1328` and `perf.start('mm')` at `:1373`; the only
  substantial thing between them is the same-(chan,pitch) collision scan
  at `:1332-1348`. For `committed 1` it iterates all of `byUuid`, buckets
  8438 notes by `util.key(chan, pitch)`, and runs `voicing.resolveGroup`
  on every bucket — which `table.sort`s each group through a closure
  (~60k comparisons) and does 8438 `onsetOf[n]` hash writes. It then
  throws all of it away: a one-note edit yields no kills.
- **`place` 7.8ms**, the dominant term in `fire` 8.7 (the tv rebuild).

Measured on the live take (read-only probe, 2026-07-26): **every event is
on channel 1** — 8438 notes across 10 lanes (2809/2431/1486/1025/378/171/
90/37/8/3), 1654 CC64 plus ~30 other ccs, channels 2–16 empty. So
`dirtyChans`, the whole per-channel dirt spine interval-dirt built, buys
nothing here: the only channel that ever goes dirty is the only channel
there is, and it holds the entire take.

This is the same shape of fix the two closed programmes made, one layer
out. interval-dirt made the *rebuild* consume per-event dirt instead of
re-deriving channels whole; stable-slots made *serialise* splice a
persistent wire instead of repacking it whole. What is left is the two
spans either side of them, and item A is a named open successor from
`design/archive/interval-dirt-closing.md` § Out of scope — "a
delta-shaped `'rebuild'` signal (*these columns changed*)", whose own
note already measured this: "the fire is ~10.4ms of tv re-placing an
unchanged frame".

## Decisions

**D1 — `place` is ~100% redundant projection calls, and that is fixed
first (item C).** Each event in the place loop
(`trackerView.lua:3838-3861`) calls `ctx:ppqToRow`, then `ctx:isOnGrid`,
then `cellRowOf`. But `isOnGrid` internally calls `snapRow` → `ppqToRow`
→ `round` → `rowToPPQ`, and `cellRowOf` → `ppqRowOf` calls `isOnGrid`
*again* and then `snapRow` or `ppqToRow` again — ~16 Lua calls per event
to produce three numbers. At ~10,100 events that is ~165k calls, and
7.8ms / 165k ≈ 47ns, about right for a Lua method call. So the
projection overhead essentially *is* the span.

One `ctx:placeRow(ppq, chan) -> row, y, onGrid` computes the row once and
derives the rest. It keeps the on-grid threshold owned by viewContext,
whose `--contract:` at `viewContext.lua:74` explicitly forbids callers
re-implementing it from `rowToPPQ` — so the collapse goes *into* that
module rather than inlining the arithmetic at the call site.
Also: `startRow` is computed unconditionally today but only used when
`evt.endppqC` exists, and `onGrid` only matters inside the
placed-and-unoccupied branch.

**D2 — the flush collision scan reads `rawIndex`, not `byUuid` + `adds`
(item T1).** `rawIndex[chan].notes` is already sorted raw-then-logical,
which is exactly `resolveGroup`'s `(ppq, ppqL)` sort key, and
`addLowlevel` already calls `rawIndexInsert` (`:959`) so staged adds are
in it before flush — meaning the separate `adds` pass at `:1337` looks
redundant too. Bucketing a sorted walk by pitch yields sorted buckets for
free. Cost drops from (8438 hash iterations + 8438 `util.bucket` calls +
~60k closure comparisons + 8438 hash writes) to a single array walk.

The equivalence `rawIndex.notes ≡ {byUuid notes} ∪ {staged adds}` is
inferred from `addLowlevel` (`:956-961`), `assignLowlevel`'s reseat
(`:978-985`) and `idxReconcile` (`:905-921`); it is the first thing the
commit's spec must pin, not assume.

**D3 — `voicing` gains a sorted entry point; it does not gain a boolean.**
`resolveGroup` sorts in place deliberately: same-pitch-enforcement Phase 1
(`design/archive/same-pitch-enforcement.md:153-162`) made the sort
unskippable so "callers can't skip the ordering the policy needs". A
`presorted` flag would defeat exactly that. Instead `voicing` exposes a
sibling — `resolveSorted(group)`, contract: *the caller guarantees
(ppq, ppqL) order* — and `resolveGroup` becomes sort-then-`resolveSorted`.
The guard's intent survives, because the sorted door still names the
ordering it requires; what changes is that a caller holding an
already-ordered list can say so, once, at a named seam.

**D4 — this scan is an optimization, not the invariant.**
same-pitch-enforcement § 5 reclassified all three tm separation sites
(this one included) from load-bearing to optimization when mm's
write-path backstop landed: a missed collision is now detected and
resolved at mm's `modify` unwind, visibly and with provenance, instead
of silently corrupting the take. That materially de-risks T1 — a parity
bug shows up as a logged backstop firing, not as an eaten voice — and it
is why narrowing the scan is a reasonable thing to do at all.

**D5 — the tv cell carry sheds per lane, keeping table identity as the
key (item A); the version stamp is rejected.** `prevBuilt` keys on
`col.events` table identity, and `exciseNotes` (`:1869`) does
`col.events = kept` for **every** lane on a dirty channel whether or not
it removed anything — so one edit sheds all 10 lanes and re-places all
8438 notes. The cc path already does this precisely and says so at
`:2076-2078`: *"tv's cell carry keys on events-table identity (same table
=> reuse built cells), so a spliced column must shed its carried table —
exciseNotes' `col.events = kept` is the note-path twin."* The note path
is the blunt twin. A threads the same `touched[col]` discipline through
it, so the two paths read as one pattern.

The rejected alternative was an explicit `col.version` bumped by tm and
keyed on by tv. It is the more honest protocol — today the cache key is
an accident of whether someone happened to allocate a new table — but it
changes the tm/tv boundary and touches both paths to fix one, and the cc
path is already correct under the existing protocol.

**D6 — the bluntness is currently load-bearing, so A is shed-discipline
work, not a one-line conditional.** `insertNoteCell` (`:1932`) mutates
`col.events` **in place**, which is safe only because excise already
handed that lane a fresh table. Making excise conditional without moving
the shed to the mutation sites would carry stale cells. The failure is
asymmetric — too pessimistic costs a re-place, too optimistic silently
renders stale cells — so the commit's real content is enumerating every
in-place mutator of a note lane's `events` (excise, `insertNoteCell`,
the append at `:1934`, the park PA excise at `:2562-2569`, the tail walk,
the PA projection, externals) and giving each one the shed. That
enumeration is the risk and the bulk of the work.

**D7 — order is C, T1, A.** C and T1 are self-contained and low-risk and
go first; A is the structural one. Not doing: **T2**, skipping the scan
when a flush stages no note ops (free only for cc/pb-only gestures);
**T3**, localising the scan to touched (chan,pitch) clusters — the one
that scales past 8438, but the `onsetOf[prev] + 1` cascade means a
verdict can depend on notes further out than the same onset, and
`rawIndex` is flat per channel with no pitch key. T3 wants a design doc.

## Targets (estimates, to be checked by the exit measurement)

Baseline `flush 29.0` / `mm 19.2` / `reload 12.2` / `fire 8.7` /
`place 7.8`, one-note edit on the dense take.

| after | place | the ~9.8 gap | flush |
|---|---|---|---|
| C | **4.5 measured** (est ~2) | 9.8 | ~23 |
| C+T1 | 4.5 | ~3–4 | ~17 |
| C+T1+A | ~0.3–0.7 | ~3–4 | ~15.5 |

The residue is then `setEvts` 4.1 (REAPER's), `internals` 2.6, `meta`
0.8, `serialise` 0.8.

**C measured (2026-07-26): `place` 7.8 → 4.5, not the estimated ~2.** The
collapse itself landed — one `ctx:placeRow` per event where there were
three calls — so D1's "projection overhead essentially *is* the span" was
only ~40% right. The residue is the loop's own floor: ~10,100 `ipairs`
steps, the `cells`/`offGrid` stores, a `util.add` per tail, plus the four
calls `placeRow` still makes internally (`ppqToRow`, `rowToPPQ`,
`util.round`, and the dispatch itself). Deliberately not chased: A stops
the loop running over clean lanes at all, so it takes the same span to
~0.3–0.7 without micro-optimising a loop that is about to stop
executing. If A underdelivers, inlining the arithmetic inside `placeRow`
(keeping both clamps, and legitimate there because `viewContext` owns the
threshold) is the next lever.

**T1 measured (2026-07-26): `collide` ~4ms, i.e. the table's ~3-4, not the
Done paragraph's "under ~1ms" — those two never agreed and the table was
right.** A live read-only probe splits the residue: ~0.83ms to bucket
8437 notes by pitch and ~1.62ms inside `resolveSorted`, over 73
multi-note buckets yielding 0 kills. So what is left is not overhead
around the work, it *is* the work — one linear pass per note plus a
`voiced`/`onsetOf` pair per group — and no amount of tightening this
shape removes it, because the shape still asks every note in the take
about an edit that touched one. That is exactly T3's case (localise to
touched (chan,pitch) clusters), and it stays parked pending its design
doc: the `onsetOf[prev] + 1` cascade means a verdict can depend on notes
further out than the same onset.

**A measured (2026-07-26): `place` 4.4 -> 1.7, `flush` 21.0 -> 17.2.** Warm
one-note edit, measured either side of a script reload in one session, so the
two are comparable to each other but not to the table's 29.0 baseline (a colder
earlier session -- the pre-A warm flush read 21.0 where the C+T1 row predicted
~17). `place` lands just above the revised 1.2-1.6 band, which is the shed
working as designed: lane 1 holds 2809 of the 8438 notes and still sheds, so tv
re-places it and carries the other nine lanes. Post-A there is no dominant term
left: `mm 13.4` splits into `reload 6.8` (`fire 2.9` > `place 1.7`, `internals
2.8`, `pbs 0.8`), `setEvts 4.3` (REAPER's) and `serialise 1.0`, with `collide
3.8` alongside. That answers the queued exit measurement; the next levers are T3
(`collide`, parked pending its design doc) and sub-lane carry.

One measuring trap found on the way: the *first* flush after a script reload
pays `serialise 38.8` (`pack 22.3`), stable-slots building the persistent wire
from scratch. "Discard run 1" now has a second reason beyond GC.

## Landed  (newest first; prune below ~4)

- 2026-07-26 tm: the note path sheds a lane only when its contents change (A)
- 2026-07-26 tm: the flush collision scan walks rawIndex (T1)
- 2026-07-26 tv: collapse the place loop's projection calls into ctx:placeRow (C)

## Now

(closed 2026-07-26 — C, T1 and A all landed and measured.)

## Queued (one-liners)

(empty — **Exit measurement** was discharged in place rather than promoted:
the "A measured" paragraph under Targets carries the re-profile, the
comparison against the target table, and the verdict that no dominant span
remains. The two levers it names — T3, parked pending its own design doc, and
sub-lane carry — are outside this plan.)
