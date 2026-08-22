# Song growth — the tracker grows the arrangement behind you

> opened: 2026-08-16 · status: in flight — plan/song-growth.md, at phase 1

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

A take has two extents, and they are routinely different. The **source
span** is the MIDI source's length, and the tracker derives its row
count from it — `grid.numRows = ceil(length / ppqPerRow)` over
`mm:length`, which reads `GetMediaSourceLength`. The **rendered span**
is the item's `D_LENGTH`, which arrange derives as `min(natural,
gap-to-next, source)` on every relayout, where the **natural length**
is the extent a take asks for and keeps across a move.

A take whose neighbour starts before its source would end is therefore
**cut**: the tracker draws rows the song never reaches. The natural
length makes this ordinary rather than exceptional, since growing a
take past its neighbour stores intent that takes effect when the
neighbour moves away; and a tracker that appends takes one after
another will meet cut instances often.

## The tracker remembers its instance

**The tracker holds one instance of the bound slot, and every verb here
acts from it.**

1. The instance is session state on the tracker page, not a position
   read afresh each frame. A remembered instance is stable: it survives
   an edit, a rebind and a page switch, where an answer recomputed from
   the play head or the edit cursor would move under the verbs between
   one frame and the next.

1. Three gestures write it. A command that knows the placement names
   one — the dive hands over the instance the arrange cursor sat on,
   and `again` and `vary` name the instance they create. The play head
   entering an instance of the bound slot makes that instance current.
   A slot change that names nothing seeks one.

1. Leaving an instance writes nothing. The state is sticky, so playback
   running into a gap, over another slot's take, or off the end of the
   song leaves the tracker where it was.

1. The seek runs from a reference position — the outgoing instance's
   start, or REAPER's edit cursor when there is no outgoing instance.
   It takes the instance containing that position, else the first
   instance in the direction of travel, else the first in the other
   direction. `prevTake` travels backwards and every other gesture
   forwards, matching the grid, where time runs down the page.

1. At most one instance can contain a position. A pool never spans
   tracks — `docs/arrangeManager.md` § Pools never span tracks records
   the undo defect that made this structural — so every instance of a
   slot sits on one track, and `relayoutTrack` caps each item's
   `D_LENGTH` at the gap to its neighbour, so items on a track never
   overlap.

1. The instance is nil only where the slot has no live one, its single
   take parked on scratch. `again` and `vary` refuse, and the grid
   draws no caret.

1. F6 is the first thing this repairs. `playFromTop` seeks to the start
   of the bound take, which is whichever instance `takeForSlot`
   resolved; with instances at bar 0 and bar 8, diving into the second
   and pressing F6 plays from the first. It plays from the current
   instance instead.

## Loop to item

**Loop to item** is a toggle — cm at the global tier, beside
`arrangeFollowPlay` — that brackets the current instance whenever the
tracker binds a take.

1. It sets the transport loop to the instance's rendered span, turns
   REAPER's repeat on, and moves the edit cursor and the play head to
   the span's start. A loop range with repeat off plays through and
   keeps going, so without the repeat the toggle would set a range that
   never loops. The transport stays where it is when the play head is
   already inside the span.

1. Moving the transport is what separates it from the dive. Diving
   changes what the tracker edits and leaves playback alone; loop to
   item is a transport command, and the placement it brackets is the
   one you hear next.

1. It writes when a gesture moves the current instance — a dive, a slot
   change, `again` — and not per frame. Play-head entry moves the
   instance and writes nothing, since bracketing there would pull the
   transport back to the start of a placement already sounding. A loop
   set by hand — the arrange page's Ctrl+B / Ctrl+E, or a drag in
   REAPER — survives until the next such gesture, in the discipline
   `av:followPlay` already keeps, where a manual scroll suspends the
   follow until the next play or seek.

1. Turning it on brackets the current instance at once; a toggle whose
   first effect waited for the next gesture would read as inert.
   Turning it off leaves the loop where it stands.

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
- **Whether the cut is a line or an end.** Drawing a line across a grid
  that continues is one reading; stopping the grid at the rendered span
  is another, and that one loses the rows a later move would bring back
  into play.
- **The caret while stopped.** The caret maps the play head, so a
  stopped transport leaves the grid unlit even where the tracker knows
  its instance. Marking where playback would start is the other
  reading, and it puts a second mark on a grid that already carries the
  tracker's own cursor row.
