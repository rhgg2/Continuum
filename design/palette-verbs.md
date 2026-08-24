# Palette verbs — prune and tidy

> opened: 2026-08-23 · status: in flight — plan/palette-verbs.md, at
> phase 2 (the commit)

**The arrange palette's buttons: prune drops every slot with no live
instance, and tidy re-groups the track's slot names into families.**

## Prune

Landed — see docs/arrangeManager.md § A slot outlives its takes and
docs/arrangePage.md § The palette buttons.

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

1. A row's combo lists the bases and a `(keep)` entry. Picking
   `(keep)` drops the slot from the assignment, so it holds the name it
   carries.

1. The base list is editable: an entry can be added, renamed or
   deleted. The rows re-preview as it changes, since they derive from
   the assignment each frame.

1. A rename carries the base's members, since the assignment holds
   names. A rename onto a name the list already holds merges the two:
   the renamed entry goes and its members join the survivor.

1. Deleting a base drops its members from the assignment, which pins
   them at the names they hold. A pinned member whose root is still the
   deleted name keeps that name like any other.

1. A blank name adds nothing and renames nothing, and an add of a name
   the list already holds does nothing.

1. The seed sorts the list and an edit leaves that order alone, so an
   added base joins at the end. A rename lands when its field loses
   focus, so a half-typed name merges nothing.

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

1. `av:tidyRows(trackIdx, assignment)` joins the track's MIDI slots to
   their keys, their assigned bases and their previewed names. The
   editor draws those rows and holds no join of its own.
