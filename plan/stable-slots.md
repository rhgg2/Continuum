# stable slots — plan

> Design: `design/stable-slots.md` — pure model, measurements refreshed
> 2026-07-25. This file carries the commit queue and the brief for what is
> next. Decisions taken in conversation belong in the design doc, not here.

## The shape

Three phases, strictly ordered. Phase 0 is specs only and changes no
production code; Phase 1 redefines what `loc` means; Phase 2 makes
serialise incremental on top of it.

One fact governs every profile taken against this programme: **the two
halves surface on different gestures.** `rebuild` is gated by
`indexStale()`, so only an add, delete or ppq move pays it, while
`serialise` is paid by every flush. A trace that does not name its gesture
cannot price either half — this was misread once already on 2026-07-25,
when a property-edit trace was compared against a ppq-move one.

## Now — Phase 0: pin what the migration must preserve

(empty — Phase 0 landed: the equal-ppq add rule and blob determinism are pinned and mutation-tested, and the rule's scope is settled in the design doc. Run /plan-next to promote Phase 1.)

## Queued

**Phase 1 — stable slots in mm.** `loc` becomes a stable slot id: sparse
`notes`/`ccs`, dense `noteOrder`/`ccOrder` injections, free lists, and
verbs that splice (`util.insertSorted`, added 2026-07-25, is the
primitive). `needsSort`, `needsCompact`, `stableByPpq`, `fullSortByPpq`,
`util.compact` and the reindex loop all dissolve; `rebuild` survives only
as the wholesale path `load` needs. Two questions the design leaves open
and Phase 1 must settle: the delete shape (immediate splice vs
tombstone-and-sweep, decided against the mid-iteration contract) and
chanIdx walk order (per-bucket order arrays vs on-demand re-derive,
measured rather than guessed). Target: `rebuild` ~8ms → ~0.1ms on a
ppq-moving gesture. One splice serves add and move alike, so the equal-ppq
rule becomes uniform on the way through: add the ppq-move cases to
`mm_sort_order_spec` once it is.

**Phase 2 — incremental serialise.** Persistent sorted key array and packed
chunk list; per-event key dirt reported at the three verb sites that
already call `markChan`; a slot-cap guard falling back to full
regeneration. Targets: `serialise` 16.3ms → ~1ms, `sidecars` 2.1ms → ~0,
and the `seenOnset` scan (0.75ms) confined to the full path.

## Landed

- 2026-07-25 mm: pin the equal-ppq add rule and flush determinism (Phase 0)

