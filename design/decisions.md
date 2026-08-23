# Decision log

A list of all design decisions that bear on active work. One dated
entry each: what was chosen, over what, and why. Three or four lines,
not eight or ten.

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

