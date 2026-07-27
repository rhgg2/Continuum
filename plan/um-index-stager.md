# um: index vs stager — plan

> No design doc: this work was designed in conversation (2026-07-26)
> and this file is the record. Decisions below are settled; if one
> needs reopening, do it here and say so.

## The problem

The `-- UPDATE MANAGER` block in `trackerManager.lua` (774–1482) began
as a stager — accumulate mm-facing ops, commit them in one `mm:modify`
— and grew three more tenants without regard for the structure. It now
holds: the raw index (`rawIndex`, `byUuid`, `fxHosts`, the `colEvt`
seat stamp, `idxReconcile`, `withDeferredSort`); the stager proper
(`adds`/`assigns`/`deletes` and the realisation verbs); the dirt
journal (`seeds`, `snapshot`, `absorbReloadDirt`); and parked staging
(`parkedEdits`, `flushParked`), whose data path is ds rather than mm
and which shares only the flush moment. Four tenants, four lifetimes,
four sets of clients.

The surface reflects the drift rather than the name. Of the 19
upvalues the block exports, 9 are index read-surface, 7 are stager, 3
are lifecycle. The index has ~40 external readers and every one of
them is in the REBUILD sections; the write verbs have ~10, nearly all
tm's own forwarders. The interface grew large because the rebuild
pipeline reads um's index — the index lives inside um only because um
is what keeps it true.

Underneath that sits a contract question. Index entries are live
shared records the rebuild mutates in place, so a module boundary
would publish a leak rather than close one. Measuring the actual
mutation set makes it tractable: three field writes from two stages —
`e.ppq` in `settleOnset` (the only one that stains a sort key),
`e.endppq` in `boundNote`, `entry.sample` in `stampSamples`.
Everything else that looked like entry mutation isn't: `rebuildPbs`
already clones at the boundary, `rebuildInternals` writes to mm's own
column clones, and `colEvt`/`realised` already go through
`stampColEvt`. The privilege is narrow and necessary; it is just
undeclared, with the repair (`resortRawNotes`) remembered by hand at
one call site.

## Decisions

**D1 — split in place, two `do ... end` blocks, not a module.** An
index block exporting the read/reconcile surface, a stager block
exporting the write verbs and park, with the dependency arrow one way:
staging calls index, never the reverse. Extracting an `eventIndex.lua`
was considered and rejected for now — it would make the
record-sharing contract public before it is sound. Revisit only after
D2 has settled who may mutate an entry.

*Amended 2026-07-26:* the arrow costs seven new index exports —
`rawIndexInsert`, `rawIndexRemove`, `rawIndexRefile`, `forgetUuid`,
`loadIndex`, `detuneAt`, `forEachAttachedPA` — and moves one piece of
logic rather than only re-nesting: `assignLowlevel`'s index upkeep
(the migrated/reseated test, the remove-then-place, the fx-toggle
refresh) becomes `rawIndexRefile`. The alternative was exporting
`rawIndexListFor` and leaving that body in the stager, which keeps the
diff purely mechanical but publishes the type→list mapping to the
half that shouldn't know it. Refile wins because the shape stays
inside.

**D2 — mediated writes: `setRaw(entry, field, value)`, mirroring
`setCell`.** `setCell` (trackerManager.lua:139) is already this pattern
for column cells: skip the no-op, maintain the derived invariant when
the value actually changes. `setRaw` knows which fields are sort keys
and flags the containing list when one moves. `withDeferredSort` stops
being insert-only and becomes the single place order is restored, for
inserts and moves alike. Not a new mechanism — the existing one
applied to the other structure.

**D3 — `resortRawNotes` is retired, not kept as a backstop.** It is a
caller-remembered repair for exactly the stain D2 makes structural;
keeping both would leave two ways to be correct. The `anyNudge` flag
goes with it.

*Amended 2026-07-26:* `anyNudge` survives, narrowed. It gated two
repairs, not one — um's index list *and* the walk's own scratch list —
and only the first becomes structural. `linearTails`'s merged `notes`
and `frontierTails`'s `extras` belong to the walk, not to um, so
nothing can flag them; dropping the gate would put an unconditional
whole-channel sort on the dense path every pass, which is the cost the
flag exists to avoid. What goes is its role as the index repair's
trigger, and the `resortRawNotes` call it guarded.

**D4 — no runtime enforcement; a spec is the backstop.** A metatable
proxy was considered and rejected on three grounds: `__newindex` does
not fire for keys that already exist, so it would miss the exact write
that matters; catching it needs shadow-table storage with `__index` on
every read, taxing the hot path the sharing exists to protect; and the
repo does not use metatables this way. Instead, a spec asserts after a
full rebuild that every `rawIndex` list is sorted under
`rawThenLogical` and every entry's `ppq` agrees with mm — extending
`tm_raw_index_order_spec`, which already pins the insert/reseat
mechanics. The contract is declared and checked, not enforced; say so
plainly in the docs.

*Amended 2026-07-26:* the literal form — "every rawIndex list is
sorted" — is not reachable from a spec. `rawNotes`/`rawPbs`/
`rawIndexFor` are file-local upvalues with no caller outside
`trackerManager.lua`, and the harness has no introspection door, so
asserting list order directly would mean publishing a read accessor
whose only caller is a spec — and publishing it would make the
record-sharing contract public, which is exactly what D1 deferred. So
the sortedness half is checked *through a consumer*: stain the index
with a real nudge and catch a binary-seek reader answering from the
stale order. The agreement half stays literal, since `tm:byUuid` is
public and returns the live entry. Narrower than the exhaustive check,
and it carries a vacuity risk — paid off by proving the case red with
`setRaw`'s re-true removed.

**D5 — `reconcilePcs` and the flush collision scan move out to the
pipeline.** Both are derivation logic that happens to run at flush
time; neither is staging. With them gone, `flush` also stops calling
`tm:rebuild` on its parked-only path — a stager driving the rebuild is
the layering inversion in miniature, and it currently forces a second
exit that duplicates the `postflush` fire.

*Amended 2026-07-27:* "the pipeline" means **out of the stager**, not
into `rebuildPipeline`, and the two tenants part company. The collision
scan cannot move into the rebuild: it runs pre-commit precisely so tm's
kill verdicts land before mm ever sees a same-pitch collision, which is
why the backstop "fires ~never" (`midiManager.lua:1040`) and why docs §
Separation can say tm's site is not load-bearing for take integrity.
After the commit, mm's `resolveGroup` would always pre-empt
`voicing.resolveSorted`. So the scan hoists to file scope as derivation
the stager calls, and stays where it runs.

`reconcilePcs` goes the other way: the pipeline already *has* that
stage, so the move is a deletion. Measured 2026-07-27 — short-circuiting
the flush-time pass leaves the suite at 2179/2180, and the one failure
is a value change the target case's own comment calls incidental, in
the direction of the documented bearing rule. It also retires the
stale-loc bug class pinned at `tm_pc_synthesis_spec.lua:112`, whose
victim was the flush-time reconcile itself. D5 is therefore three
commits, deletion first.

**D6 — the three read accessors collapse to one.** `rawNotes(chan)`
and `rawPbs(chan)` are `rawIndexFor(chan).notes`/`.pbs` spelled
differently, while `.pcs`/`.pas`/`.ccs` have no typed accessor at all;
callers use both spellings. One door. This churns ~30 call sites, so
it lands as its own mechanical commit rather than riding inside the
split.

**D7 — the two `pairs(byUuid)` full scans are fixed first.**
`forEachAttachedPA` scans every event in the take to find one
channel's PAs at one pitch, and `reconcilePcs` scans it again to
collect one channel's notes; `rawIndex[chan].pas`/`.notes` are exactly
those lists, per-channel and sorted. Independently justified, so it
goes in before the structural diff rather than tangled with it.

*Amended 2026-07-26:* not quite behaviour-preserving, and the
difference is wanted. `byUuid` holds only realised events, while
rawIndex holds realised **plus** staged adds — which is why
`reconcilePcs` needed a second loop over `adds` to approximate the
union. Reading rawIndex makes that loop redundant, and it also widens
`forEachAttachedPA`: a PA added and not yet flushed becomes visible to
its host's resize and delete. A staged PA is attached, so it should
follow its host; the old blindness was an artefact of scanning the
wrong table. Record order also becomes deterministic (raw-then-logical
instead of `pairs`), which settles a same-ppq/same-lane PC tie that
was previously arbitrary.

## Landed  (newest first; prune below ~4)

- 2026-07-27 tm: hoist the flush collision scan out of the stager (D5)
- 2026-07-27 tm: delete the flush-time PC reconcile (D5)
- 2026-07-26 tm: split the update manager into raw index and stager (D1)
- 2026-07-26 tm: pin the walk's index re-true with two specs (D4)

## Now

(empty — D5's second of three landed; next is `flush` getting one exit and the rebuild drive moving up to `tm:flush`. Run /plan-next to promote it.)

## Queued (one-liners)

1. `flush` gets one exit and stops driving `tm:rebuild` on the
   parked-only path; the drive moves up to `tm:flush`. Ordering risk:
   `postflush` currently fires *after* that rebuild, and
   `groupManager.lua:586` subscribes (D5, third of three).
2. Collapse `rawNotes`/`rawPbs`/`rawIndexFor` into one accessor (D6).
3. Docs: `docs/trackerManager.md § Update manager` describes the index
   as the primary structure and states the mutation contract.
