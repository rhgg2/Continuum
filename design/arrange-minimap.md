# arrange mini-map — navigation from the tracker

> opened: 2026-08-23 · status: in flight — plan/arrange-minimap.md, at
> phase 1 (the pane)

**Draw a mini-map of the arrange view in the tracker palette, marking
the current instance.**

## The pane

1. The **mini-map** is a third tab in the tracker's right-hand palette,
   beside parameters and fx (`docs/trackerRender.md` § Palette tabs).

1. It draws the arrangement in the arrange page's own terms: one
   column per track, time running down the page in QN
   (`docs/arrangePage.md` § Grid is hand-drawn).

1. The map is a window on the arrangement — the current instance's
   track and its neighbours, over a time region around it.

1. An **instance** is one placement of a slot
   (`docs/arrangeManager.md` § Instances of a slot). It draws as a
   filled box in its slot's colour under the grid's 1px border, as on
   the grid, and nothing else: no notes, waveforms, or names.

1. The boxes sit on a grid at the arrange page's own cadence — a ruled
   cell every 4 QN, the bar and phrase cells tinted as the grid tints
   their rows, and a rule down each column boundary. A gutter runs down
   the left, the grid running out into it; to the right the grid
   reaches as far as the track list and no further.

## The mark

1. The current instance (`docs/trackerPage.md` § The current instance)
   carries **the mark** — the focused fill the arrange grid gives the
   take under its cursor.

1. Nothing is marked when the bound slot has no live instance, its
   single take parked on scratch.

## The raise

1. Gestures that move the current instance — a dive, a slot change, a
   walk, again and vary — **raise** the map tab, outranking the
   derivation that would otherwise pick parameters or fx
   (`docs/trackerRender.md` § Palette tabs).

1. A raised map **falls** at the next command.

1. A raise takes no keyboard focus. The grid keeps the keys, as it
   does under a tab click.

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

1. **Alt-Tab** and **Alt-Shift-Tab** walk the current instance forward
   and back along its own track. Forward is down the page, the
   direction time runs.

1. A **stop** is one instance. The walk visits the track's instances
   in start order and holds at the ends, neither wrapping nor crossing
   to another track.

1. A gap between instances earns no stop. The tracker stands in an
   instance, not on a row, and has no state for standing between two.

1. The walk refuses in silence where the tracker is in no instance, as
   duplicate below and stepping the family do (`docs/trackerPage.md` §
   Duplicate below, § Stepping the family).

## Landing

1. A walk **lands** on the instance it stops at: `tv:nameInstance`
   names it, so it is current at the next resolve and loop to item
   brackets it.

1. Where that instance belongs to another slot, `tv:selectSlot`
   selects it and the tracker rebinds on the next frame — the pair a
   family step already uses (`docs/trackerPage.md` § Stepping the
   family).

1. A rebinding landing resets the caret to (0,0). Instances of one
   slot share a take, so a walk within one slot's instances rebinds
   nothing and the caret holds.

## What the tracker may see

1. The arrange facade (`docs/arrangePage.md`) gains an enumerator:
   the instances across a span of tracks and QN, in the take shapes
   the arrange grid paints from.

## Open

1. Whether a raise is suppressed while a palette pane holds the
   keyboard. A raise arriving mid-keystroke in the find box would
   otherwise take the pane out from under it.

1. Clicking the map to travel. A click on a box would set the current
   instance, reaching the walk's destination by another route.

1. Whether the map draws anything of the transport. The play head
   crossing it is the one thing a mini arrange usually carries.
