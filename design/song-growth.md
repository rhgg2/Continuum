# Song growth — the tracker grows the arrangement behind you

> opened: 2026-08-16 · status: in flight — plan/song-growth.md, at phase 4

**The tracker learns which placement it is inside, from the playhead,
and gains the two verbs that grow the arrangement from there.**

## The tracker edits a slot, not a placement

A MIDI take on the grid is an **instance** of a **slot**. A slot is a
palette entry on a track — a pooled MIDI source, keyed by base62 and
named by whichever take carries its pool guid
(`docs/arrangeManager.md`); an instance is one placement of it, a media
item at a start QN with a rendered length. Dropping one slot four times
gives four instances of a single source, and REAPER propagates a MIDI
edit across all of them.

The tracker binds an instance and edits a slot. `tp:bind` takes the
take handle the arrange page's own cursor pointed at and hands it to
`tm:bindTake`; everything downstream writes the pool, so all four
placements change together. The handle is inert as an answer to *which*
placement: it names the item whose chunk was read, and any of the four
could have been that item without a single edit coming out differently.

An inert handle costs nothing while the tracker is a take editor, and
is the whole difficulty as soon as the tracker is asked to grow a song,
since a growth verb needs a place to grow from and the handle names an
item rather than a position. The answer was in hand and discarded:
`diveSelected` holds the instance the arrange cursor sat on, and passes
on the slot alone.

## The append point

Landed; the model is `docs/arrangeManager.md` § The append point, the
parking it falls back on § Parking, and the tracker's new take
`docs/trackerPage.md` § New take and unpooled duplicate. `vary` mints
its variant through that same parking.

## Rendered span and source span

Landed; the model is `docs/arrangeManager.md` § Rendered span and source
span.

## The tracker remembers its instance

Landed; the model is `docs/trackerPage.md` § The current instance, and
the seek `docs/arrangeManager.md` § Instances of a slot. The duplicate
and `vary` name the instance they create, and refuse where there is none.

## Loop to item

Landed; the model is `docs/trackerPage.md` § Loop to item and
`docs/arrangeView.md` § Loop to item. The duplicate moves the loop with
the instance it appends.

## What the grid draws

Landed; the model is `docs/trackerPage.md` § The play row and § The
cut. An unlit grid says the tracker is inside no placement, which is
the reading the duplicate and `vary` want for their refusals.

## Duplicate below

Landed; the model is `docs/trackerPage.md` § Duplicate below.

## vary

**vary** (Alt+Shift+→) replaces the current instance with an instance of
a fresh slot that has its own pool — a **variant slot**, carrying a copy of the
source's events and of the source's pool metadata. Edits then reach
that placement alone, and the original slot keeps its other instances.

A variant takes its parent's name with a bracketed ordinal: a variant
of `Bassline` is `Bassline (var 1)`, and the next is `Bassline (var
2)`. The next ordinal is the family's highest plus one, so deleting a
variant keeps its name out of circulation. A variant of a variant joins
the same family — varying `Bassline (var 1)` gives `Bassline (var 3)`
— since the departures from an idea are a list and not a tree.

The **family** is a slot's name and nothing else records it: the slots
on a track whose names share a **root**, the name with any bracketed
ordinal removed. A stored parent link would say one thing while the
palette showed another the moment a take was renamed in REAPER, and
the name is already the only place a slot's name lives
(`docs/arrangeManager.md` § Renaming and name drift).

A rename therefore edits the root. The field opens showing the whole
name with the root selected, so typing over it renames the whole
family and leaves each ordinal where it was: `Sausage (var 1)` and
`Sausage (var 2)` become `Kenneth (var 1)` and `Kenneth (var 2)`.
Editing the ordinal as well takes that slot out of the family, renamed
as typed with nothing else touched.

`vary` refuses on a slot with a single instance. Nothing propagates
there, so the verb would fork a source nothing else shares, and the
take is already yours to edit where it stands.

It is built from verbs that already exist, and gathers everything
before it mutates anything. Read the current instance's track, start
QN and natural length; mint the variant through
`am:mintParkedTake(trackIdx, name, len, srcTake)`, which gives the
fresh pool its own copy of the event metadata; delete the instance,
which parking leaves safe either way — the slot has siblings and the
item goes, or it has none and the item becomes that slot's keeper; and
drop the variant at the start QN, which moves its own keeper onto the
grid. One atomic block, one undo point, and the tracker rebinds to the
new take.

The tracker's unpooled duplicate retires with `vary`. It copied the
bound take into a fresh parked slot and asked for a name;
`duplicateBelow` then `vary` gives the same fork with a placement to
hold it, and takes the variant's name from its parent.

The two verbs compose: the duplicate says it once more, `vary` says this
one is different now. Each stands alone as well: a repeat you never
vary, or a placement you fork on passing without repeating it.

## Divergence is structural

One level down, inside a take, the same question has a different
answer. A group is a region with instances, an edit to one propagates
to every sibling, and `localMode` — a single global flag, set before
the edit — makes the edit a per-instance override instead
(`docs/groupManager.md` § localMode).

The flag works there because a group instance is a table with
`assigns`, `adds` and `deletes` in it: the edit is *routed* into the
instance rather than the pattern, and nothing structural happens. A
REAPER pool has no such layer. Two pooled items are one source; for one
of them to differ, a second source has to exist. Divergence is
structural, so it is a verb pressed once rather than a mode left on.

What would collapse the difference is a per-placement overlay —
transposition, a mute mask, a macro depth, riding the item and read at
realisation — which is how one pattern stays one pattern across a whole
song. It reaches well into the rebuild pipeline, and it belongs in
`design/pipe-dreams.md` rather than here.

## Open

- **Repool if unchanged.** `vary` has to be pressed before the edit
  that motivates it, at the moment it is least likely to be remembered.
  One repair is to change `duplicateBelow` so that it places an unpooled copy
  and folds that copy back into its source slot at the next bind, if
  events and metadata still match, so divergence is discovered rather
  than declared; it costs an equality test at every bind and the
  repooling machinery, and it surprises anyone who wanted a distinct
  slot holding identical content.
