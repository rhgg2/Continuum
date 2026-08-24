# arrange mini-map — navigation from the tracker

> opened: 2026-08-23 · status: in flight — plan/arrange-minimap.md, at
> phase 3 (raise and pin)

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

1. The **pin key**, Alt-M, **pins** the map up: it becomes the tab
   shown by default, in place of the derivation between parameters and
   fx (`docs/trackerRender.md` § Palette tabs).

1. The other tabs still override that default — a click on either, or
   Super-R and Super-X.

1. Pressed again, the pin key drops the pin.

1. Unlike Super-R for parameters and Super-X for fx, the pin key gives
   the palette no keyboard focus.

## The walk

Landed — the model is in `docs/trackerPage.md` § The walk.

## Landing

Landed — the model is in `docs/trackerPage.md` § The walk, § The track
step's landing, § Deleting the instance.

## What the tracker may see

Landed — the model is in `docs/arrangePage.md` § The take enumerator.

## Open

1. Clicking the map to travel. A click on a box would set the current
   instance, reaching the walk's destination by another route.

1. Whether the map draws anything of the transport. The play head
   crossing it is the one thing a mini arrange usually carries.
