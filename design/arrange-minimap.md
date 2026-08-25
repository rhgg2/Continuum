# arrange mini-map — navigation from the tracker

> opened: 2026-08-23 · status: in flight — plan/arrange-minimap.md, at
> phase 5 (the transport driven)

**Draw a mini-map of the arrange view in the tracker palette, marking
the current instance.**

## The pane

Landed — the model is in `docs/trackerRender.md` § The mini-map.

## The mark

Landed — the model is in `docs/trackerRender.md` § The mini-map.

## The raise

Landed — the model is in `docs/trackerRender.md` § Palette tabs and
`docs/trackerPage.md` § The current instance.

## The pin

Landed — the model is in `docs/trackerRender.md` § Palette tabs.

## The walk

Landed — the model is in `docs/trackerPage.md` § The walk.

## Landing

Landed — the model is in `docs/trackerPage.md` § The walk, § The track
step's landing, § Deleting the instance.

## What the tracker may see

Landed — the model is in `docs/arrangePage.md` § The take enumerator.

## The transport shown

Landed — the model is in `docs/trackerRender.md` § The mini-map.

## The transport driven

Landed — the model is in `docs/trackerRender.md` § The mini-map and
`docs/trackerPage.md` § Loop to item.

## The travel

1. A click on a box makes its instance current.

1. Landing is the walk's pair — `tv:nameInstance` for the placement,
   `tv:selectSlot` for its slot — with the track as well where the box
   sits on another, as the dive carries it.

1. Unlike the walk, the click crosses tracks: every box in the window
   is a stop.

1. The click takes no keyboard focus, as the tab click and the pin take
   none.

## The chase

1. A **follow** toggle, a checkbox on the tracker toolbar beside loop
   to item, has the tracker chase the play head. It is off by default.

1. Off, the current instance moves on the head's entry into an instance
   of the bound slot, as it does today, and no further.

1. On, entry into any slot's take carries the tracker to it, selecting
   the slot as the walk does.

1. On, the map's window pages off the play head rather than the current
   instance's start, so the head stays on the page through an instance
   longer than one.

1. The head in a gap, or off the end of the song, leaves the tracker
   where it was.
