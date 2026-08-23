# Palette verbs — prune and tidy

> opened: 2026-08-23 · status: in flight — plan/palette-verbs.md, at
> phase 1 (prune)

**The arrange palette's buttons: prune drops every slot with no live
instance, and tidy re-groups the track's slot names into families.**

## Prune

1. **Prune** deletes every slot on the track with no live instance on
   the grid, much as `deleteSlot` does, by discarding the parked
   keeper and the pool's metadata.

1. Slot rows carry `parked`, so the count can be read off
   `trackSlots`. A confirm dialog names the consequences before
   anything is deleted.

1. Prune reaches both audio and MIDI slots.

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

1. A base's members are the slots assigned to it, together with the
   pinned slots whose root is that base. A name places a slot in a base
   whether or not the assignment did.

1. Members order by current ordinal, plain counting as ordinal 0, then
   by slot index — `variantFamily`'s order.

1. A pinned member holds its ordinal. Each unpinned member, in that
   order, takes the lowest ordinal no pinned member holds and no
   earlier member has taken. Ordinal 0 is the base plain, and the rest
   carry ` (var N)`.

1. Tidy therefore never gives a slot a name another slot holds.

1. The commit is one undo block.

## Where the naming lives

1. `am:tidySlots(trackIdx, assignment)` derives every name and writes
   it; the editor hands over the assignment alone. The ordinal rule 
   sits beside `variantFamily` and `nextVariantName`.

1. `am:pruneSlots(trackIdx)` deletes the parked slots and returns how
   many went.

1. Both reach the palette through `av`, which clears the palette focus
   where the focused slot no longer stands.

## Open

1. Whether the editor should let a base's members be reordered. The
   commit numbers them in the order they already stand in, and a
   reorder is a second feature.
