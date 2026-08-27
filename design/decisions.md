# Decision log

A list of all design decisions that bear on active work. One dated
entry each: what was chosen, over what, and why. Three or four lines,
not eight or ten.

- **2026-08-27** — A stored global region's uuid resolves to the union of its sixteen expanded
  producers, so the ghost overlay reads a channel per derived note rather than one per entry.
  Expansion leaves the stored region with no producer of its own, and the master strip is the
  chain's only surface: the caret there would otherwise ask what the chain realises and be told
  nothing.

- **2026-08-27** — A global chain's precedence is realised at expansion rather than as an ordering
  rule on stored fxRegions. The pipeline's head snapshot emits each channel's own regions in storage
  order and its expanded producers after them, so one seam holds the truth that a global comes last.
  The alternative normalises the array at all five region write sites, and buys only that storage
  reads as the order it claims to be.

- **2026-08-27** — Channel select stands on the master channel, where mute, solo, parameter
  automation and freeze refuse. Selecting a channel names its columns rather than a channel on the
  wire, and clicking the master banner is the mouse route onto the strip -- the only route by which
  a global region is authored with the mouse, since region creation takes its channel from the
  column the selection starts in.

- **2026-08-27** — Test-only generator kinds register into the production registry from
  tests/fixtures/testKinds.lua, and `sine` lives on there as the continuous-augment stand-in the fx
  plumbing specs use. Keying those specs on a production kind makes every change to it a spec edit,
  on assertions that were never about it; a fixture kind keeps the registry itself as the seam under
  test.

- **2026-08-27** — A generator body is sized in beats of the take that asks for it, never in ticks.
  REAPER's ticks-per-QN is a global setting rather than the project's, so a wave seeded at a fixed
  960 opened the curve editor on a fourteenth of a beat in a 12288-ppq session. The reset a saw
  needs stays one tick wide in the body, and the tiling holds emitted breakpoints a tick apart when
  a fast period squeezes the cycle below one -- the squeeze is the tiler's problem, not the wave's.

- **2026-08-27** — The sine generator folds into the LFO as a wave param. A named wave (sine,
  triangle, square, saw) stores no body and expands from a seed the kind draws for itself; editing
  the curve is what stamps that seed and flips the stage to custom, so exactly one of the two is
  authoritative and the wave row says which. Storing wave and body side by side was the alternative,
  and leaves two shapes with a claim on what sounds.

- **2026-08-27** — A canvas popup opens from its own render function rather than from the input that
  fills its slot: ImGui keys a popup's id to the window current when OpenPopup runs, and the N-key
  command runs in the page body, outside the canvas child where the popup begins. The add-FX picker
  drops its node at the cursor clamped into the visible canvas, and anchors the popup on that same
  point, so a cursor over the palette or off the window still spawns a node in view.

- **2026-08-27** — wiringRender's design constants sit in one tiered table, `UI.NODE.W` and
  `UI.FADER.TOP_DB`, rather than 64 main-chunk locals. Lua caps a function at 200 locals and the
  chunk was on that ceiling; the table frees 63 registers. Nesting stops at one level, so FADER is
  a tier beside WIRE rather than under it, and the tiers double as the file's vocabulary.

- **2026-08-27** — A canvas phase whose helpers are private to it is declared `local name do ... end`,
  with the helpers inside the block. wiringRender's main chunk sits on Lua's 200-local ceiling, and the
  block releases the helpers' registers at its end, so the phase costs one local rather than seven.

- **2026-08-26** — A canvas phase that produces a gate for a later phase returns it, rather than
  writing it to the frame. The frame carries what several phases read; faderConsumed has one reader,
  so it passes as a value.

- **2026-08-26** — The wiring canvas frame carries what crosses a phase boundary, not everything a
  phase computes. Hover resolution's sticky and draft-source hits are consumed by its own overlay
  dedup, so they stay locals while sourceHit and targetHit go on the frame.

- **2026-08-26** — Stage 3's eight phases fix the order renderCanvas runs in, not the function
  boundaries it decomposes into. The frame carrier and the head phases land as three functions
  covering four listed phases: the gesture's inject hook writes over the view lists and the
  selection reads its result, so the two belong to one gather.

- **2026-08-26** — An inject hook may clear its gesture by returning false, as update does;
  busDraft's preview needs it when the node the draft hangs off has vanished. Folding busDraft into
  the one gesture variable also stops its drop click falling through into the mousedown chain, so
  dropping a bus no longer arms a band or a node drag on the same press.

- **2026-08-26** — A wiring gesture mode declares `escCancels = true` rather than carrying a
  `cancel` hook. Both draft modes cancel by clearing and do nothing else, so a hook would be an
  empty closure; a mode that later needs teardown can grow one.

- **2026-08-26** — A fader drag counts as a live gesture in the wiring guard chains, so a
  neighbouring wire end no longer highlights under the strip and RMB no longer opens a menu
  mid-drag. The alternative, excluding faderDrag from the chains, keeps a mode that is a gesture
  everywhere except where the code asks whether one is live.

- **2026-08-26** — The wiring gesture hooks read a frame table rather than closing over
  renderCanvas: one inject call site sits immediately before the geometry pass, and the frame
  carries results back out — band writes the previewed selection, the splice search writes the
  target the highlight and the commit share.

- **2026-08-26** — Both edges of an arrange take grab under the mouse: a band at the start trims the
  head, one at the end moves the tail, and each caps at a third of the take so even a one-row take
  keeps a strip to move by. The head band is MIDI only, am:trimHead refusing audio. A drag ghost
  carries its own headQN, so head, window and cut partition the source in flight and both edge
  ellipses follow the edge that actually moved.

- **2026-08-26** — An editable status cell's hit box takes the band's padding above and below it, so
  the footer tiles with no dead strip and a pointer flung at a bar on the window's bottom edge lands
  on the control rather than beside it. The padding is read from the window being drawn into rather
  than imported, so the coordinator keeps the constant.

- **2026-08-26** — What belongs in which chrome band is settled by reach against check rather than
  by datum against mode: the toolbar holds what a pointer is aimed at, the status bar what is
  glanced at. The tracker's Loop, Follow and Graph move down as one flags cell — each is checked far
  more often than flipped, and two carry keys. Three headed segments cost ~290px in the band that
  wraps, against ~190 for the cell, and the toolbar is three segments lighter. Track and take stay
  up, being reached for constantly.

- **2026-08-26** — A status cell's control is selected by `edit` alone, where `set` and `edit` were
  both required and always agreed. A flags cell has no single value to write, so it carries no `set`
  and the redundancy had to go one way or the other; keying on `edit` keeps one discriminator.

- **2026-08-25** — Arrange's beats-per-row keeps two routes, not three: the status cell and the zoom
  keys. The Super+Z prompt modal existed because the toolbar stepper was clumsy for fine values, and
  a click on the cell now does that job.

- **2026-08-25** — A status segment's declared width is its value box, not the whole cell: the label
  is measured and the box follows it, so renaming a label moves the value rather than shrinking it.
  A picker popup pushes its own ink before BeginPopup, since it opens over two grounds of opposite
  text colour and only the toolbar's styles are ambient.

- **2026-08-25** — Chrome drawn on both bands — segment labels and vertical rules — takes its ink
  from the ambient Col_Text and dims it, rather than from the separator swatch, which is tuned for
  the parchment band and also draws the grids. A lighter inner well is reserved for editable status
  cells, so a box marks what can be changed instead of decorating every cell.

- **2026-08-25** — The arrange page draws its play head the way the tracker does — a yellow line
  across the pane at the play row — rather than a triangle in the gutter, so one ink means the same
  thing on both pages. The REAPER edit cursor loses its triangle altogether: it steers loops and
  seeks, but the page has its own blinking caret for where you are, and a second marker only
  competed with it. editCursorQN stays; only its rendering went.

- **2026-08-25** — The tracker's follow toggle reads the bound track rather than the bound slot, so
  the play head carries the tracker across slots as the walk does. It stays entry rather than
  gesture — no loop bracket, no map raise — and turning it on reads the head's placement as an
  entry, so it lands at once rather than waiting on the next crossing. The grid pages once per
  crossing rather than scrolling continuously, leaving the caret in charge within a page: the move
  hook draws the view back to the caret, and the follow leaves it there until the head crosses
  again.

- **2026-08-25** — A click on an arrange mini-map box lands through tv:selectTrack whatever track
  the box sits on, rather than branching on whether it is the bound one: selectTrack already writes
  the slot, so the branch bought nothing, and the travel is then the dive's pair without its QN. A
  box is a stop on the walk's terms, only a MIDI take in a slot, since the map draws audio items and
  slotless takes too while the tracker's selection reaches MIDI slots alone. The hit test stays in
  the renderer, over the rects it struck, so a box floored to the 2px minimum is as clickable as it
  is visible.

- **2026-08-25** — Dropping loop to item clears the transport loop, reversing the rule that turning
  the toggle off left the loop where it stood. The clear lives in tv:setLoopToItem, so the toolbar
  checkbox, Ctrl+L and Esc's clearLoop command all release the loop by the same path, and the gutter
  sweep writes its own range over the clear its drop causes. The arrange page's Esc still clears the
  range alone: the toggle belongs to the tracker.

- **2026-08-25** — A loop swept in the tracker mini-map's gutter drops loop to item, so no later
  gesture brackets over it. The toggle's standing rule — a loop set by hand survives only until the
  next gesture — holds for loops set anywhere else. The map's 4 QN snap cell goes into
  tv:mapLoopCand as an argument rather than living in tv, as the window's columns and depth already
  do, so a zoomable map moves one constant.

- **2026-08-25** — The arrange mini-map takes the transport through tv:mapWindow rather than reading
  the arrange facade in the renderer. The window already carries every QN fact the map draws from,
  and only the window has a spec, so a fact routed through the renderer could not be pinned. The
  window drops a play head or a loop range that misses it, but hands the loop's ends over untrimmed,
  leaving the clip to the pane.

- **2026-08-25** — A param binding is the track's, not the take's: the filter bank, the bus code and
  the plink it realises are all per track, so a second take binding the same param minted a rival
  bus code, and the single plink per target went to whichever was written last — the first take's
  column then drove nothing. The cc column follows from the binding rather than from each take's
  extraColumns, and an already-bound target answers with the lane it has, refusing another channel.
  columnDisplay moves to track scope with it: a bound column's display flags are the same fact one
  layer down.

- **2026-08-25** — The mini-map's raise is written at the resolve's gesture flag rather than at
  tv:nameInstance: a serial read inside a command body is stale for the dive, which invokes
  switchPage after naming, and nameInstance never sees the slot step. The raise falls at the next
  command other than the transport and the walk, a name set held in tv and read at the lapse, since
  cmgr:wrap cannot reach the transport commands, which continuum registers after the pages are
  built.

- **2026-08-25** — The mini-map's pin ranks under a tab override and over the derivation, and never
  lapses on a caret move, so an override falling away reveals the pinned map. Super-X therefore
  claims the fx tab with an override of its own rather than clearing one, keeping a live fx session
  over the pin.

- **2026-08-24** — A drop places a fresh instance at its pool's full length, over inheriting the
  sibling it clones from: the item state chunk carries the take's window across — the stored natural
  as a P_EXT blob, the head as D_STARTOFFS — so one resized instance made every later drop of that
  slot come in short. dropInstance clears both on the clone. Unparking is exempt, since it moves the
  keeper itself rather than cloning it, so the window it returns with is its own.

- **2026-08-24** — The mini-map's time window pages, over centring on the current instance: a stride
  of the pane's depth less one bar, and the window is the page that stride lands the instance's
  start on. So a walk moves down a still window and steps to the next page on reaching the last bar,
  which reappears at its head, rather than dragging the map under a pinned mark. Paging from QN 0
  keeps the window a function of the start alone, with no remembered position to drift; and the
  start always falls within a stride of the top, so an instance taller than the page needs no case
  of its own.

- **2026-08-24** — A track step lands on the placement nearest the current instance, ranked by
  overlap first and gap second, over restoring the track's last-viewed slot: the mini-map shows the
  neighbouring tracks against the instance you are in, so a step across should land where the eye
  already is. The last-viewed slot stays the fallback for a step with no instance to measure from.

- **2026-08-24** — The walk lands by naming its stop and selecting that stop's slot, with no caret
  write of its own, over resetting the caret at a crossing landing: a slot change swaps the bound
  take, and the rebuild resets the caret to row 0 already. A walk within one slot rebinds nothing
  and keeps its row. Only a placement carrying a MIDI take in a slot is a stop, so an audio item, or
  one dropped on the track outside Continuum, is passed over.

- **2026-08-24** — The mini-map's window is computed on tv in columns and QN, the pixel constants
  held by the renderer, over tv returning pixel rects: gridPane already measures the tracker's
  viewport in cells and hands tv:setGridSize the counts, so the pixels stay in the one layer that
  has them.

- **2026-08-24** — The mini-map's palette tab is labelled `map`, not `mini-map`: three equal cells
  across the 200px pane leave about 63px each, which the longer word overruns.

- **2026-08-24** — A text field whose value a button reads is drawn without EnterReturnsTrue, and
  its Enter is caught with IsItemDeactivated plus the Enter keys. ReaImGui hands the buffer back
  only on a frame the call returns true, so under that flag the field reads blank to every gesture
  but Enter, and the button beside it commits nothing. The flag stays where Enter is the only way to
  commit — the sampler's slot rename and modalHost's prompt.

- **2026-08-24** — The tidy editor's base list is edited by three verbs on av — tidyAddBase,
  tidyRenameBase and tidyDropBase — which mutate the (bases, assignment) pair the modal holds and
  read no project state, so am stays out of it. The assignment holds base names, so a rename carries
  the base's members and a delete pins them; a rename onto a name the list already holds merges the
  two, the survivor keeping its place. A rename lands when its field deactivates, and the footer's
  Enter is gated on IsAnyItemActive read before the fields are drawn — read after, the field has
  already deactivated, and one Enter would commit the whole tidy.

- **2026-08-24** — The tidy editor's rows come from av:tidyRows, which joins the track's MIDI slots
  to their keys, their assigned bases and the names am:tidyNames previews. The modal draws those
  rows and holds the assignment alone, so only the ImGui stands outside the tests. A row's combo
  carries a (keep) entry beside the bases; picking it drops the slot from the assignment, which pins
  the name the slot holds.

- **2026-08-24** — A tidy's naming splits in two: am:tidyNames derives the name each MIDI slot ends
  up with, keyed by slot index, and am:tidySlots writes the ones that differ. The map is total over
  the track's MIDI slots, a pinned slot mapping to the name it already holds, so an editor row shows
  its name without asking whether the tidy touches it. Keying the preview by id would save tidySlots
  a translation, but the editor holds slot indices and the assignment is keyed by them already.

- **2026-08-24** — A base two or more slots carry plain is ambiguous, and every slot under it seeds
  pinned; the base still stands in the seeded list, so the editor is where the choice between
  namesakes gets made.

- **2026-08-24** — Tidy's assignment is a plain map from slot index to base, and a slot the map
  omits is pinned. An explicit pinned flag reads better at the call site, but it adds a shape where
  an absence says the same thing; the editor builds the map by dropping the rows the user pinned. am
  wraps no undo block for the commit — every arrange undo block sits at the view or render layer, so
  the editor's commit supplies it.

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

