# Song growth — the tracker grows the arrangement behind you

> opened: 2026-08-16 · status: in flight — plan/song-growth.md, at phase 2

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

## Both take-creating commands park

Two tracker commands create takes: `newTakeBelow` (Super+Enter), which
asks for a name and a length; and `duplicateUnpooledBelow`
(Super+Shift+Enter), which copies the bound take into a fresh pool.
Both route through the arrange facade to `am:mintParkedTake`, which
creates the item on the shared scratch track — hidden, muted, off the
grid. Parking is where a slot's takes go rather than where they die:
deleting a slot's last live instance parks that item too, as the slot's
**keeper**, so a palette entry outlives its placements.

The tracker can therefore grow the palette and not the song. A new take
is silent until you leave for the arrange page, put the cursor
somewhere and press its slot key; and that same page switch is the only
way to repeat a take you are happy with. The machinery is not missing:
the arrange facade already publishes `dropSlot`, and the tracker calls
it from nowhere.

## Rendered span and source span

Landed; the model is `docs/arrangeManager.md` § Rendered span and source
span.

## The tracker remembers its instance

Landed; the model is `docs/trackerPage.md` § The current instance, and
the seek `docs/arrangeManager.md` § Instances of a slot. `again` and
`vary` name the instance they create, and refuse where there is none.

## Loop to item

Landed; the model is `docs/trackerPage.md` § Loop to item and
`docs/arrangeView.md` § Loop to item. `again` moves the loop with the
instance it appends.

## What the grid draws

The grid gains two marks. The **play row** is a caret on the row the
playhead occupies within the current instance; the cut is drawn as a
line across the grid where the rendered span ends, when it ends before
the source does. Between them they say where you are and how much of
what you see is heard. The caret never passes the line, since below it
there is no sounding instance to be inside, and the line is what keeps
that from reading as a fault.

The caret marks metric position rather than any channel's onset. Swing
resolves per channel over a global composite — `tm:toLogical(chan,
ppqI)` inverts the global shape and then the column's — so one realised
instant inverts to a different logical ppq per channel: at a given
moment channel 1's row 4 has fired and channel 2's has not, and there
is no single sounding row to point at. The caret therefore maps the
playhead through the grid's own metric, `(playQN − instanceStartQN)`
over `ppqPerRow`, and swung notes sound around it, since swing
displaces a note from the metric grid rather than moving the grid.

With no current instance there is no caret, and that is the reading the
refusals want: an unlit grid says the tracker is not inside a
placement, so `again` and `vary` will decline.

## again

**again** appends a pooled instance of the bound slot immediately after
the current one, binds the tracker to it, and with loop to item on
moves the loop onto it — so the transport keeps rolling and the repeat
is what you hear next.

The append point is the current instance's rendered end, and `again`
refuses unless the free span from there is at least the take's natural
length. Appending into a shorter gap would give a repeat truncated by
its neighbour, which is a different sound from the one being repeated;
and refusal is the rule rather than a placeholder, since making room by
pushing the rest of the track down is a larger change than this design
carries.

Nothing is added to the palette. Four presses give four instances of
one slot, which is what lets a column of repeats read as A A A A rather
than as four sources that happen to agree. The verb is one
`util.atomic` block: one item created, one undo point.

## vary

**vary** replaces the current instance with an instance of a fresh
slot that has its own pool — a **variant slot**, carrying a copy of the
source's events and of the source's pool metadata. Edits then reach
that placement alone, and the original slot keeps its other instances.

A variant takes its parent's name with a bracketed ordinal: a variant
of `Bassline` is `Bassline (var 1)`, and the next is `Bassline (var
2)`. The palette then reads as a list of ideas with their departures,
rather than as a list of sources that happen to resemble one another.

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

The two verbs compose into **again, but…** — `again` says it once more,
`vary` says this one is different now. Each stands alone as well: a
repeat you never vary, or a placement you fork on passing without
repeating it.

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
  One repair is to change `again` so that it places an unpooled copy
  and folds that copy back into its source slot at the next bind, if
  events and metadata still match, so divergence is discovered rather
  than declared; it costs an equality test at every bind and the
  repooling machinery, and it surprises anyone who wanted a distinct
  slot holding identical content.
