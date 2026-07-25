# stable slots — plan

> Design: `design/stable-slots.md` — pure model, measurements refreshed
> 2026-07-25. This file carries the commit queue and the brief for what is
> next. Decisions taken in conversation belong in the design doc, not here.

## The shape

Three phases, strictly ordered. Phase 0 is specs only and changes no
production code; Phase 1 redefines what `loc` means; Phase 2 makes
serialise incremental on top of it.

- Phase 0 — pins. Landed 2026-07-25.
- Phase 1 — stable slots in mm. ← in flight, three commits: 1a the ordered
  walk, 1b the flip, 1c the chanIdx walk order.
- Phase 2 — incremental serialise.

One fact governs every profile taken against this programme: **the two
halves surface on different gestures.** `rebuild` is gated by
`indexStale()`, so only an add, delete or ppq move pays it, while
`serialise` is paid by every flush. A trace that does not name its gesture
cannot price either half — this was misread once already on 2026-07-25,
when a property-edit trace was compared against a ppq-move one.

## Now — Phase 1a: the order injection becomes the walk

(empty — Phase 1a landed: `noteOrder`/`ccOrder` exist and every ppq-ordered read walks them, still as the identity. Phase 1b, the flip of `loc` to a stable slot, is next in Queued and needs the delete shape settled first. Run /plan-next to promote it.)

## Queued

**Phase 1b — flip `loc` to a stable slot.** Sparse `notes`/`ccs`, `noteFree`/
`ccFree`, and verbs that splice the order array (`util.insertSorted`, added
2026-07-25, is the primitive — note its lower-bound search lands *before*
equals, so the pinned add rule needs a non-strict comparator or a
second entry point). `needsSort`, `needsCompact`, `stableByPpq`,
`fullSortByPpq`, `util.compact` and rebuild's reindex loop all dissolve;
`rebuild` survives only as the wholesale path `load` needs. Settle first: the
delete shape (immediate splice vs tombstone-and-sweep, against the
mid-iteration contract) and whether any caller inserts mid-walk. One splice
serves add and move alike, so the equal-ppq rule becomes uniform — add the
ppq-move cases to `mm_sort_order_spec`. Specs asserting dense locs move with
it: `mm_reindex_if_stale_spec:83,98,110,114`, `mm_addressing_spec:39`,
`sidecar_reconcile_spec:84`, `mm_cc_reconcile_spec:160`. Target: `rebuild` ~8ms
→ ~0.1ms on a ppq-moving gesture.

**Phase 1c — chanIdx walk order.** `rawInChan` yields ascending slot, which
stops being ppq order after 1b. Measure per-bucket order arrays maintained by
the verbs (option 1) against an on-demand filtered walk of the global order
array (option 2) on HAMMERKLAVIER, then land the winner; `mm_chan_index_spec`
is the pin.

**Phase 2 — incremental serialise.** Persistent sorted key array and packed
chunk list; per-event key dirt reported at the three verb sites that
already call `markChan`; a slot-cap guard falling back to full
regeneration. Targets: `serialise` 16.3ms → ~1ms, `sidecars` 2.1ms → ~0,
and the `seenOnset` scan (0.75ms) confined to the full path.

## Landed

- 2026-07-25 mm: ppq-ordered reads go through an order injection (Phase 1a)
- 2026-07-25 mm: pin the equal-ppq add rule and flush determinism (Phase 0)

