# Palette verbs — prune and tidy

> opened: 2026-08-23 · status: in flight — plan/palette-verbs.md, at
> phase 2 (the commit)

**The arrange palette's buttons: prune drops every slot with no live
instance, and tidy re-groups the track's slot names into families.**

## Prune

Landed — see docs/arrangeManager.md § A slot outlives its takes and
docs/arrangePage.md § The prune button.

## Bases

1. A **base** is a name a group of slots share. After a tidy each base
   names one family: one member holds it plain and the rest carry
   ` (var N)`.

1. Tidy's input is an **assignment** of the track's MIDI slots to bases.
   A slot may instead be **pinned**, which fixes the name it has.

1. The base list is seeded from the distinct roots in use on the
   track, `util.variantRoot` of each slot's name. Entries can be
   added, edited, or deleted; deleting one pins its members.

1. Audio slots take no part in an assignment, since `variantFamily`
   applies to MIDI slots only.

## The editor

1. Tidy opens a modal editor, holding the base list above and one row
   per MIDI slot below, containing the slot's key, its current name,
   the base it is assigned to, and the name it will thus be given.

1. A slot seeds to the base matching its current root. An unnamed slot
   seeds pinned.

1. An **ambiguous base** is one two or more slots hold plain. Every
   slot carrying that base seeds pinned.

## Committing an assignment

Landed — see docs/arrangeManager.md § Tidy. The editor's commit wraps
it in one undo block.

## Where the naming lives

1. `am:tidyNames(trackIdx, assignment)` derives the name every MIDI slot
   will carry and `am:tidySlots` writes it; the editor hands over the
   assignment alone, and shows the derived names in its rows. The ordinal
   rule sits beside `variantFamily` and `nextVariantName`.

1. Tidy reaches the palette through `av`, which passes it to am; a
   rename leaves every slot standing, so the palette focus holds.

1. The assignment is a plain map from slot index to base. A slot the
   map omits is pinned.

## Open

1. Whether the editor should let a base's members be reordered. The
   commit numbers them in the order they already stand in, and a
   reorder is a second feature.
