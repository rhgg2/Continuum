# Decision log

A list of all design decisions that bear on active work. One dated
entry each: what was chosen, over what, and why. Three or four lines,
not eight or ten.

- **2026-08-24** — The arrange palette carries one verb, prune, which forever-deletes every slot on
  the track with no live instance, behind a confirm naming the count. The rename and del buttons
  went at the same time: Cmd+Backspace and Ctrl+Delete already reach the cursor take's slot, and the
  buttons only added a second route from the palette focus. av:pruneSlots drops that focus when the
  slot holding it went, and returns nothing — the confirm names the count from the slot list it
  already holds, before anything is deleted.

- **2026-08-23** — An edge mark says only that an edge is trimmed — a bare ellipsis leading the
  take's name above the head, and one on the box's bottom row below the cut. How many beats each
  hides is read in the status bar, off the take under the cursor. The count used to sit in the mark,
  which spent two of a small box's rows on figures wanted only when an edge is about to move; by
  then the caret is on the take anyway, so the status bar is where they belong.

- **2026-08-23** — Split cuts a take at the caret into two pooled halves: the upper half's natural
  comes in to the cut, and the lower half is a clone placed there with a head to match, inheriting
  the natural the original had. Inheriting it holds the pair's end where the whole take's was, where
  OPEN for the lower half would silently lengthen a take shortened by hand. The verb is
  single-target on Ctrl+S, unlike the nudge and resize keys, which act across a selection. The caret
  holds, so it lands on the lower half's start row with the head armed, and the resize keys go on to
  move the seam just made. See docs/arrangeManager.md § The take's window.

- **2026-08-23** — mm measures a take's length and time signatures from the source origin rather
  than from the item, so a head-trimmed instance sizes and scans the source it actually edits;
  measured from the item, both were out by the head. Handing the item extent to arrange's relayout
  instead was the alternative, and it was left alone, since relayout runs from buildState and
  re-derives every D_LENGTH anyway — mm's write only keeps the item right until the next arrange
  build. A source shrunk to inside the head floors the item at its start, the floor relayout already
  uses. See docs/arrangeManager.md § Rendered span and source span.

- **2026-08-23** — Arrange's unpooled duplicate retires too, so neither page carries one.
  duplicateBelow leaves the caret on the copy and next-variant past the last of the family forks it
  onto a slot of its own: the same fresh pool, named from the parent root instead of through a
  prompt. Lost with it is forking a take with no room below it, which parked the clone. The rePool
  arm of cloneMidiItem and take-props' focusName were its only users and go too.

- **2026-08-23** — A dive carries the caret between the arrange and tracker pages in both
  directions, in project QN, each page working out its own row from it. The alternative was the
  sticky arrange cursor the return leg had before, which pointed at the take the dive began on after
  any hop to another track or slot. Both legs measure from the instance's source origin and clamp to
  its rendered span, so the row sits in the frame the cut lines are drawn in and the arrange cursor
  always lands on the take it came from. REAPER's edit cursor is untouched, since moving it would
  change what the transport plays and discard a loop set by hand. See docs/trackerPage.md § The
  caret across the dive.

- **2026-08-23** — The arrange resize keys move whichever edge the caret stands on: the head when it
  is on the take's start row, the tail everywhere else. Two more commands for the top edge were the
  alternative, and the modifier space is nearly full. A nearest-edge rule was rejected for its tie
  on the middle row of every even-length take, which is every power-of-two pattern. The caret rides the
  head it moved, and a tail shrink stops short of the start row, so an edit never rearms the other
  edge. See docs/arrangeView.md § Nudge and resize.

- **2026-08-23** — A take's head — the QN of source it skips — is REAPER's take start offset rather
  than a second key in ds beside the natural length. REAPER keeps a MIDI take's offset beat-locked
  and maps source ppq 0 through it, so MIDI_GetProjQNFromPPQPos(take, 0) reads the origin exactly
  under any tempo map, and an edge dragged in REAPER's own arrange view is picked up for free.
  Natural length stays measured from that origin, so trimming a head moves the start edge alone and
  leaves the end where it was. Pooled siblings keep one POOLEDEVTS identity across differing
  offsets, which is what lets an instance be split without minting a slot. See
  docs/arrangeManager.md § The take's window.

- **2026-08-23** — Tab and Shift+Tab step the arrange caret between the stop rows of its own column:
  each instance's start, and the first free row after it. Stopping only at starts would need a
  special case to reach the append point past the last take. Holding both rows in a set collapses
  the shared boundary where takes abut, so a solid run still costs one press per take, and a gap
  earns a stop where the next drop would land.

- **2026-08-23** — Ctrl-` toggles arrange's drop advance between arrangeAdvanceBy rows and the
  length of the take just placed, so a run of drop keys lays takes end to end whatever their
  lengths. The length read is the clipped one: relayout truncates a placement at its downstream
  neighbour, and the caret belongs where the take stops sounding. The fixed step stands behind the
  toggle rather than being replaced, so Ctrl+digit stays live while the mode is armed and the status
  line shows both.

- **2026-08-23** — The tracker's unpooled duplicate retires. duplicateBelow followed by vary gives
  the same fork, with a placement to hold it and a name taken from the parent slot, so the tracker
  no longer mints a parked clone of its own. Arrange keeps its unpooled duplicate, which is the way
  to fork a take without placing it. See docs/trackerPage.md § Stepping the family.

- **2026-08-23** — Arrange binds Super+U to replace mode, shadowing the global universal-argument
  prefix. No arrange command reads a prefix, and while one is open the digit keys feed its buffer
  instead of dropping slots, so the page lost nothing it used. Replace picks its targets the way
  every other arrange edit verb does: a held selection replaces as a block and passes to the
  replacements, while a cursor-driven replace leaves nothing selected.

- **2026-08-23** — Alt+Shift+←/→ step a placement along its family, and vary is the forward step
  off the last of it. Vary on a key of its own minted a variant per press, so a placement that had
  already forked could only fork again; stepping makes the family a dial the placement turns, and
  the walk loses nothing, since a variant left with no instance parks rather than dying. See
  docs/arrangeManager.md § Variants.

- **2026-08-23** — Wrapped labels break to balance the lines rather than fill them: a line costs the
  square of its slack, and the cheapest split wins. Greedy first-fit orphaned the tail, breaking
  "Bassline (var 1)" after the bracket; the squared cost also settles how many lines to use.
  Arrange's header band grows from one line to three to fit the visible track names, while its
  palette header stays at one — the two dividers no longer line up, but the palette reads the same
  on every page.

- **2026-08-23** — Arrange's pooled duplicate ends with nothing selected: the copy lands, the
  selection clears, and the caret advances onto it. Selecting the copy, as it did before, chained a
  run of presses only when the run started from the caret — a held selection pinned every press to
  the same source, which refuses for want of room. The caret now carries the chain alone. vary joins
  duplicate on the arrange page, both under the tracker's keys (Alt+Shift+down, Alt+Shift+right).

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
  docs/arrangeManager.md § Variants.

- **2026-08-23** — The tracker's repeat verb is named duplicateBelow rather than again. It is the
  arrange page's pooled duplicate below seen from inside a placement, and the tracker already
  carries duplicateUnpooledBelow, so one name serves both pages and the pair reads together. vary
  keeps its name.

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

