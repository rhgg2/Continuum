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

**Why first.** Both pins describe behaviour that is currently an *accident*
of sorting, and Phase 1 replaces the sort with splices. Pin them while the
old mechanism still produces them, so the migration converges on a stated
rule rather than mimicking whatever fell out. Phase 0 touches no production
code, so it lands on its own with no risk.

**Pin 1 — equal-ppq order.** The rule:

> A new or ppq-moved event inserts after all existing events at that ppq.

Today `stableByPpq` preserves array order among equals and array order
encodes insertion history, so an *add* almost certainly already obeys the
rule: `util.add` appends, the stable sort keeps it last. A *ppq move*
probably does not — the moved event keeps its array position, which may sit
before the events it is joining, and the stable sort will faithfully
preserve that.

**Establish which cases are green before writing the rest.** If the move
case is red that is a decision, not a bug: either make it true now (the
move verb re-seats the event after its equals) or restate the rule to match
today's behaviour and carry the restatement back into the design doc.
Don't leave it implicit — Phase 1's binary search has to target a stated
rule, and this is the doc's own named hard part.

Cases, in `tests/specs/mm_sort_order_spec.lua` (confirm that is the right
home; `tm_raw_index_order_spec` is the tm-side analogue and is not):

1. Add note B at a ppq already holding note A → the raw walk yields A then B.
2. Move note C onto that ppq → A, B, C.
3. The same two for ccs, which sort on the same path.
4. The order survives to the wire: serialise emits A's chunks before B's at
   equal ppq and rank.

**Pin 2 — blob stability.** Flush twice with no intervening edit; assert
the two blobs are byte-identical. Home: `mm_flush_spec.lua`, which already
reaches `MIDI_GetAllEvts` through the fake. The zero-write fixtures pin
write *counts*; nothing yet pins write *content*, and Phase 2's entire
safety argument is "the incremental path reproduces the full path byte for
byte" — which needs a baseline that the full path is itself deterministic.

**Done looks like.** Suite green, both pins mutation-tested: break the
stable sort's tiebreak and pin 1 fails; make a packed chunk depend on flush
count and pin 2 fails. The equal-ppq rule is written down in
`design/stable-slots.md` in whatever form the measurement settled.

**Not in Phase 0.** No production change — unless the move case forces the
small one described above, in which case it is the only one.

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
ppq-moving gesture.

**Phase 2 — incremental serialise.** Persistent sorted key array and packed
chunk list; per-event key dirt reported at the three verb sites that
already call `markChan`; a slot-cap guard falling back to full
regeneration. Targets: `serialise` 16.3ms → ~1ms, `sidecars` 2.1ms → ~0,
and the `seenOnset` scan (0.75ms) confined to the full path.

## Landed

(nothing yet — Phase 0 is the first commit)
