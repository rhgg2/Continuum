# Decision log

A list of all design decisions that bear on active work. One dated
entry each: what was chosen, over what, and why. Three or four lines,
not eight or ten.

- **2026-08-23** — Take properties act on the bound take throughout. The name half read its slot
  from the tracker's (track, slot) selection while the length half wrote to tm's bind, so the modal
  opened from arrange — which binds off the selection — renamed whichever slot the tracker last sat
  on. am:slotOfTake reads the slot off the bind, live or parked, and the selection no longer enters
  into it.

- **2026-08-23** — A family holds one slot with the root plain, and two slots holding it plain are
  namesakes rather than a family: neither carries the other's rename, though the variants follow
  either. Carrying every slot that shares the root renamed two same-named takes together, which is
  commoner in practice than a genuine family; a variant, by contrast, is unambiguous. The rule also
  subsumes the unnamed slot, which would otherwise share its empty root with every other. See
  docs/arrangeManager.md § Renaming and name drift.

- **2026-08-23** — The tracker's take-properties name field renames the slot the tracker is on
  rather than the take it is bound to, and every rename reaches the parked keeper as well as the
  live instances. A pooled slot's name can then only split through a rename made in REAPER, which
  stays the one accepted source of drift; tm:setName and mm:setName retire with their last caller.
  An unnamed slot has no family, since every unnamed slot on a track shares its empty root. See
  docs/arrangeManager.md § Renaming and name drift.

- **2026-08-23** — am:vary drops its variant naming no length, so the parked keeper's own length —
  the source's natural length — carries, and relayout caps it at the neighbour. The alternative was
  to replay the replaced instance's rendered length, which would have made the variant born
  pre-truncated rather than cut short by the same neighbour that cut its parent. See
  docs/arrangeManager.md § Variants.

- **2026-08-23** — A variant slot's family is its name and nothing else records it: the slots on a
  track whose names share a root, the name with any bracketed ordinal removed. A stored parent link
  on the pool would say one thing while the palette showed another as soon as a take was renamed in
  REAPER, and the name is already the only place a slot's name lives. A rename therefore edits the
  root and carries the family; editing the ordinal too takes that slot out of the family. See
  design/song-growth.md § vary.

- **2026-08-23** — The tracker's repeat verb is named duplicateBelow rather than again. It is the
  arrange page's pooled duplicate below seen from inside a placement, and the tracker already
  carries duplicateUnpooledBelow, so one name serves both pages and the pair reads together.
  design/song-growth.md § again is renamed to match; vary keeps its name.

- **2026-08-23** — The tracker's new take hands am:newTakeBelow the name and length its modal asked
  for, and the verb measures the free span against that length rather than the source instance's
  natural length. A take being minted has no natural length except the one asked for, so the room
  test and the take it makes agree.

- **2026-08-23** — The two minting below-verbs return (slotIdx, take), the shape createAndDropMidi
  and mintParkedTake already answer in, over a third return saying whether the take parked;
  am:isParkedTake reads that off the take. Arrange's unpooled duplicate opens take-properties
  whether the clone placed or parked, since the name prompt is the point of the command; only the
  focus move and the cursor advance need the clone on the grid.

- **2026-08-23** — The takeId memo lives one build, dropped by invalidate(), rather than being keyed
  weakly per take. REAPER hands out take pointers as light userdata, which Lua never collects, so
  the weak table dropped nothing: a recycled pointer answered with the dead take's pool guid, and a
  fresh instance wore another slot's identity, colour and metadata. Pointer reuse can only follow a
  deletion, and every deletion either invalidates or moves the project state count, so the build
  boundary is the cheapest lifetime that is correct.

- **2026-08-23** — Bare cursor nav in arrange clears the selection, reversing the earlier split
  where caret and selection moved independently. An edit after an arrow key should act where the
  caret is, not on a block left standing off-screen. The clear sits in the nav commands rather than
  in setCursor: an edit's own caret move — nudge following its take, the advance after a drop, the
  duplicate landing on its copy — keeps the selection.

- **2026-08-22** — The tracker's play row is a fractional row, so the caret slides rather than
  steps. It dims where the play head is inside a sibling instance of the bound slot: the row is
  still the row being heard, since the instances of a slot share one take, and the mute says the
  placement sounding is not the placement bound. The case is the loop-to-item workflow — a loop
  rolling inside one instance while a dive pins the tracker to another, where entry never fires
  again and the caret would otherwise draw nothing.

- **2026-08-22** — The cut is drawn as a line across a grid that continues below it, rather than by
  stopping the grid at the rendered span: the rows below come back into play as soon as the
  neighbour moves away. The play row is a one-pixel yellow line and the cut a two-pixel
  grey dotted one, both across the whole grid pane, and a stopped transport draws no play row, since
  the mark maps the play head and the cursor row already says where the tracker is.

- **2026-08-22** — Loop to item comes as a pressed verb as well as a toggle, on Cmd+L in both page
  scopes, with the toggle moving to Ctrl+L: the verb is the more frequent gesture, so it takes the
  prime key. On the arrange page the verb targets through the page's rule for its take verbs — the
  selection where one is held, else the take under the cursor — rather than the cursor alone. A
  selected block then loops in one press, and the page keeps one targeting rule across all its
  verbs.

- **2026-08-22** — The loop-to-item toggle brackets the current instance as it comes on, rather than
  waiting for the next gesture that moves the instance: a toggle whose first effect waited would
  read as inert. Bracketing a span the play head already sits inside sets the range and leaves the
  transport alone, so arming while the placement sounds does not restart it.

- **2026-08-22** — Loop to item brackets when a gesture moves the tracker's current instance — a
  dive, a slot change — and not when the tracker binds a take. A slot's take handle is its first
  instance's, so it does not change between instances of one slot, and a bind-triggered bracket
  would miss every move within a slot. Play-head entry is excluded too, since bracketing there would
  pull the transport back to the start of a placement already sounding. The toggle is a cm key the
  tracker reads directly, with no arrangeView accessor, because nothing on the arrange side reads
  it.

- **2026-08-22** — The tracker remembers which instance of the bound
  slot it is in, over resolving one from the play head each frame,
  rather than a play-head rule that refuses whenever the transport is
  stopped. A remembered instance survives an edit and a rebind. A
  directional seek supplies the instance on a slot change — forwards,
  or backwards for prevTake — so stepping through slots walks the song
  instead of oscillating around a point.

