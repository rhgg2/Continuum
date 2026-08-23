# Song growth — plan

> source: `design/song-growth.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The current instance** (§ The tracker remembers its instance,
   § Rendered span and source span, § Loop to item) — the tracker remembers
   which instance of the bound slot it is in, written by the dive, by the play
   head entering one, and by a seek on slot change; F6 is its first consumer
   and loop to item its second. — landed 2026-08-22, four commits plus
   the docs transfer.
2. **Phase 2 — What the grid draws** (§ What the grid draws) — the play-row
   caret from `(playQN − instanceStartQN)` over `ppqPerRow`, and the cut line
   where the rendered span ends before the source does. — landed 2026-08-22,
   two commits.
3. **Phase 3 — The append point and duplicate below** (§ The append point,
   § Duplicate below) — one rule for where a take below goes and what happens
   with no room: a minting verb parks, a placing verb refuses. The tracker's
   new take stops parking by default, and its duplicate below follows on the
   same rule. — landed 2026-08-23, three commits.
4. **Phase 4 — vary** (§ vary) — the current instance replaced by an instance
   of a fresh variant slot named `<parent> (var N)`; refused on a slot with one
   instance; one atomic block, rebind; a rename carries the family; the
   tracker's unpooled duplicate retires. ← in flight

## Landed  (newest first; prune below ~4)

- 2026-08-23 am: vary replaces an instance with one of a fresh variant slot (§ vary)
- 2026-08-23 tracker: duplicate below appends another instance of the bound slot (§ Duplicate below)
- 2026-08-23 tracker: the new take places at the append point (§ The append point)
- 2026-08-23 am: append at the rendered end, park for want of room (§ The append point)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)
- A rename edits the root: `am:renameSlot` rewrites the root across every
  slot on the track sharing it, each keeping its own ordinal, when the
  submitted ordinal matches the slot's own; a changed ordinal renames that
  slot alone and takes it out of the family. The rename fields open with
  the root selected — tracker take properties and the arrange palette,
  through an EEL `SelectionStart`/`SelectionEnd` callback (the picker
  idiom at `chrome.lua:609`, parameterised with `Function_SetValue`).
  `am_spec`, `docs/arrangeManager.md` § Renaming and name drift.
- `tv:vary()` on Alt+Shift+→, with a menu row beside duplicate: selects the
  variant slot, so the tracker rebinds, and names the new take as the
  current instance, so loop to item follows it. Refuses in silence with no
  current instance. One undo point through the command table's undoDesc.
  `tracker_page_spec`, `docs/trackerPage.md` § vary.
- The tracker's unpooled duplicate retires: `tv:duplicateBoundUnpooled`,
  `duplicateUnpooledTake` and its Cmd+Shift+Enter binding and menu row.
  Arrange's own unpooled duplicate stays, and `am:duplicateUnpooledBelow`
  with it. `docs/trackerPage.md` § New take and unpooled duplicate.
