# Decision log

A list of all design decisions that bear on active work. One dated
entry each: what was chosen, over what, and why. Three or four lines,
not eight or ten.

- **2026-09-01** — A lane's whole authored population -- its on-take events and the parked ones that
  have left the take -- is published as frame.authoredEvents / tm:authoredLanes, and is what a
  renderer addresses. It merges the parked half into the column's own order rather than
  concatenating and re-sorting, so the note-before-PA tie-break at a shared onset survives; a lane
  holding nothing parked is answered with its own events table, which keeps the cell carry intact
  for the common lane. The three callers that hand-rolled that union -- the grid build, the pattern
  editor's readback and tm's own span-scoped walk -- now share it, and the readback stops deleting a
  parked note from a pattern body. The memo spans one pass only, since renderUnion mints all sixteen
  parked lists every rebuild; giving it renewLane's replace-only-on-change discipline would unlock
  the carry for parked lanes. tv's rowBounds reads both halves, one per bound, and that asymmetry is
  correct rather than an oversight. The col-local bound is lane order, which governs the tail clip,
  so it reads the whole population. The chan-wide same-pitch bound is settleOnset's seat collision,
  an mm question that a parked event cannot participate in, so it reads the on-take half. Two notes
  of one pitch on different lanes passing each other is what lanes are for.

- **2026-09-01** — A channel holds its authored events in two halves named for the side of the take
  they sit on: onTake is what mm holds, parked is what an fx replace window took off it. The old
  `columns` named the rendering rather than the side, and of its four parked siblings three were
  named for their event type while the fourth carried the category alone; they group as
  parked.notes/ccs/pb/pa, mirroring onTake's own names. The halves differ in representation --
  onTake by column, parked flat with the lane or CC number on each event -- because mm reads into
  lanes while one flat stash splits by type. Nothing about the population differs, so the grouping
  is by side of the take, not by shape. An event is a record; a cell is a place, a row x column
  position tv's grid draws which an event may occupy or contend for. tm has no places, so `cell`
  throughout it is now `event`, and the word is left to the view that owns it.

- **2026-09-01** — A tile loops the fx regions and the parked hosts they cover, and leaves the
  census out: a copied region's seats do not exist yet, so an absent entry is the true statement
  that the take carries none there -- the same one a freshly-authored region makes. The take walk
  copies authored events only, a copy tiling intent while the copied regions derive their own
  output. mapFxDocument answers each span with its images rather than one span, which is what lets a
  tile share the resize verbs' pass at all: none drops a record, one resizes it, several loop it,
  and the first image keeps the record's id while every later one mints its own.

- **2026-09-01** — The fx document's ids are minted in tm, one helper over both stores, and the view
  asks for a region's rather than minting it. The mint takes the higher of the store's high-water
  mark and its own counter, which is what a batch of mints needs and what the region paste and the
  park stager were each hand-rolling beside their own scan. tm owns both stores, so the mint that has
  to see them lives there even though authoring a region does not.

- **2026-09-01** — A length verb maps the whole document's logical time, and not the take alone: fx
  regions, the park stash and the realised-window census scale, clip or tile alongside the events.
  What a verb rewrites is intent, and realisation follows from it -- a region's span scales and its
  seats re-derive -- so a chain's own periods, being musical, stay put and a stretched region fills
  with more of them. A shrink clips a region to the new end, an OPEN ceiling being intent that no
  resize edits. One name for a logical span, ppq/endppq, is what lets the three keys share a mapper:
  startppq was a mixed pair and bought a field-name indirection at every site treating a region and
  a parked spec alike.

- **2026-09-01** — A region's membership is its lanes' whole authored population, parked cells
  included, over the column-only read it had: a parked cell is the note the author sees, so a
  neighbouring chain parking it must not silently drop a glide that aimed at it. Lane allocation
  keeps the column alone, since a parked host's own tiles already hold its lane and counting the
  host too would push its output off it.

- **2026-09-01** — **Source annotations are `pre`, `post` and `invariant`, each stating a
  predicate.** `--contract:` conflated the caller's obligation with the callee's guarantee, so a
  false line could not say whose bug it was; pre and post split that, and a module, having no call
  to attach to, takes only invariant. A predicate needs a non-trivial truth-value, so prose that
  constrains nothing goes to `--shape:` or `docs/`, and a line restating the body is worse than none
  — it holds tautologically today and fails under any rewrite. A table result carries its ownership:
  `fresh` unaliased and the caller's, `live` aliased and safely mutable, `unsafe` aliased, read-only
  and of ephemeral validity — which `--contract:` had no way to say at all.
- **2026-09-01** — The pass renders the parked half of every lane from the stash at its head, and
  one clip-and-window pass then serves the whole pipeline. The frame carries the previous pass's
  render, where a delete, a chain removal or a freeze has already landed in the document, so the
  second pass was reading the document late over reconciling anything the first could not know;
  parking itself moves a host between the halves of a lane and moves no window, since the clip
  counts both halves and the host keeps its uuid, span and targets across the move. Each reader asks
  the frame which half a host is in at its own moment, over an entry that follows its cell: nothing
  a chain can see distinguishes a restored host's stash cell from the column cell it re-enters, so a
  re-key would be unpinned weight. dirt.staleHosts, the journal's third axis, goes with the second
  pass, its only reader.

- **2026-09-01** — The clip is one function that owns its cache. clipEnd(cell, takeLenL) answers
  with the true clip, reusing the cached one where the rebuild's dirt cannot have moved it -- over a
  factory returning a gate the caller then combined with a reclip and a cache write, three steps at
  every call site and one cache with four writers. Cache and reset sit in a block exposing only
  clipEnd and forgetClipEnds. The per-channel hoist the factory existed for is not paid for:
  dirt.has is a table lookup and the journal caps a seed list at 64, so the gate now reads the
  lattice where it is documented rather than pre-digesting it. Fx-host staleness after a restore
  becomes the journal's third axis beside swing, not a channel set threaded through two signatures:
  it is dirt about the index rather than about the data, so both clipNoteHosts calls take no
  argument and what differs between them is what the journal holds. Verb and noun split:
  clipNoteHosts is the pass, noteHostClips the value it returns.

- **2026-09-01** — A lane's occupancy is its column union its parked cells, and one clip reads both
  halves. A window's end and a parked cell's render clip are the same number — the cell's own
  ceiling, clipped to the strict-next authored onset on its lane — so `clippedSpanEnd` answers for
  both, and `offTakeEnd`, the member-next map and one of the two uuid-keyed caches go with their
  duplicate dirt gate. The frame owns the parked half: it carries onto dirty channels too, so the
  clip reads a true lane from the pass's head, and the lane buckets are memoised against the list
  `renderUnion` replaces whole, which keeps the seek logarithmic where a scan would have gone
  quadratic in a region's members. A parked note now bounds a host window exactly as an on-take note
  does, closing the overrun the oddities register carried; parking moves no window, so the placement
  fixpoint has nothing left to close and its section goes.

- **2026-09-01** — The window set is one thing with two populations, not a set beside a flat list.
  windowSet(windows) is the set; buildFxWindows mints the pass's windows from regions, note hosts
  and parked hosts, and buildRealisedWindows replays the take's stored per-target list into the same
  doors, so the prior baseline answers in the same voice as the current one. The set answers in
  either frame -- covers on a logical onset, coversRaw converting a window's bounds once for the
  questions asked of mm records -- which retires nine open-coded window scans across the park
  stages. The shared body is named for what it is rather than for the door-table mechanism, which
  every closed-over table in the codebase has equal claim to. The persisted list becomes
  fxRealisedWindows, grouping with fxRegions and fxParked; realised in the sense of having landed on
  the wire, not the raw frame of docs/tuning.md.

- **2026-08-31** — One noun per thing in the window vocabulary. A **window** is the object — span,
  host (uuid and type), channel, targets. A **span** is the bare interval, the word `spans.lua` and
  the realisation targets already use, so nothing else is minted for it; the note-side pass computes
  spans (`computeNoteFxSpans`, `clippedSpanEnd`, `noteFxClipEnd`) and `windowSet` turns them into
  windows by attaching host and targets, gathering its three sources itself so the census stops
  being a step. A **host** is the note or region a chain hangs on, as `docs/generators.md` already
  had it, so `noteHost` becomes `hostType = 'note' | 'region'` — a note's span is clipped to the
  next lane onset where a region's is authored, a derivation rather than a second concept — and
  `producer` leaves tm entirely, keeping only its wiring sense of a graph node. Freeze reads
  coverage from the published set narrowed to its own uuid, sound because the gate has already
  refused any neighbour sharing a target in that span, so it builds no set of one.

- **2026-08-31** — A park window is one producer's span typed by one stream it parks, and every
  window a producer emits takes that producer's span, so the census entry and the flat window list
  are one fact in two shapes. windowSet holds the pass's windows as a record per producer --
  channel, span, host flags, and the targets its chain reaches -- and mints the flat list from it
  for the readers that scan one; generators.chainTargets names those targets, so a chain with two
  stages on one dest parks that stream once and prevWindows persists one entry where it held two.
  Freeze eligibility is a decision about what tm will do rather than rebuild output, so
  tm:freezeEligible and freezeRegion's gate both compute refusal from the published set and freeze's
  own census goes. A global region reaches the gate as its expansions, so a chain overlapping one is
  refused where the unexpanded census cleared it.

- **2026-08-31** — forgetCaches drops parkedClipEnd and fxHostWin on the branch a take swap or a
  wholesale re-read enters tm:rebuild. mm mints uuids per take, so an entry surviving that seam
  addresses an event of the take just left; today the wholesale dirt hides that by forcing every
  reader onto its recompute arm, which stops being checkable once the engine is another file. It
  lands without a spec: instrumenting both caches with a generation counter showed no cross-seam
  read anywhere in the suite, so nothing observable separates the two behaviours.

- **2026-08-31** — A window is clipped by the authored onsets on its lane, on the take or parked,
  and derived notes lie outside that population. One rule then covers an on-take host, a parked host
  and a parked member, and parking only moves a note between the two halves of the set, so the
  windows hold across the park stage and a rebuild computes them once.

- **2026-08-31** — The pipeline hands back only the fx maps that outlive it: fxRealisationByUuid,
  freezeRectByUuid and, until eligibility moves, freezeEligibleByUuid. fxTargetsByProducer and
  fxParkedByProducer have one reader each -- the realisation builder at the same tail -- so they are
  the pipeline's own locals and never reach tm, which cuts the installed set from five to three.
  fxNotesByProducer is handed in and mutated in place, since a frozen channel keeps its lists;
  tm_fx_gating_spec now pins that, and minting the map fresh each pass kills the case. Freeze
  eligibility is a decision about what tm is prepared to do, not derivation output: freezeRefused
  tests whether the rest of the census contests a producer's claims, and only the freeze operation
  turns that into a verdict, so tm:freezeEligible computes it on demand from the published
  footprints. That is its own item, since two of the three refusal arms test a note window the rect
  does not carry.

- **2026-08-31** — The stager's doors take the index's verb vocabulary: stager.add, stager.assign
  and stager.delete, with the parked triple keeping its suffix, since a nested stager.park.add sits
  a dot deeper than the maps read. The seed fold is stager.flushDirt, pairing with stager.flush --
  one empties the op accumulator into mm, the other the seed accumulator into the dirt journal, and
  the parked-only flush path calls the second alone.

- **2026-08-31** — The raw index's doors take mm's verb vocabulary -- index.add, index.assign,
  index.delete, index.move -- so the edit side spells staging and the index behind it the same way.
  The uuid re-read is index.sync, not reconcile: the file already spends that word on the
  predicted-versus-existing skeleton (reconcileDerived, reconcileFx, reconcilePCs), a different
  mechanism. index.raw(chan) is the list door, and the seat stamp keeps colEvtFor/stampColEvt beside
  the colEvt field they read and write; renaming that field to seat is a separate change.

- **2026-08-31** — Every frame operation now touches the frame's own state, the two pure ones having
  folded into the state ops they always accompanied: insertNoteCell never appeared without a
  renewLane on the line above it, at all four sites, and isSorted existed only as sortNoteColumn's
  guard. spliceCell renews then splices, orderLane scans then sorts, and noteColumnLess stays
  private with nothing pure exported at all. The fold also retires the silent failure that §
  Note-lane renewal names -- splicing into a lane nobody renewed is no longer expressible.

- **2026-08-31** — sortByPPQ leaves the frame handle for util, beside the seeks that assume the
  order it makes: five of its thirteen call sites in tm were frame columns and the rest scratch
  lists, while the same comparator stood written out longhand in five other modules. The note-column
  trio -- sortNoteColumn, insertNoteCell, isSorted -- stays on the frame, since all three close over
  the note-before-PA tie-break, which is the frame's own ordering rule. A pure function belongs to
  what it is about; cheapness at a module boundary, which was the only argument for hanging the sort
  on the handle, is not ownership.

- **2026-08-31** — The maps learn door tables: a `function tbl.name` at module scope, on a table
  other than the one the module returns, is a private `@fn tbl.name` and calls on it are intra-file
  `@call` edges. The extractor's guard was indentation, which a `do` block defeats, so
  trackerManager's frame operations earned no rows at all and every call on one sat under unresolved
  receivers -- the same blindness midiManager's stream verbs have had all along. The qualifier stays
  part of the name, as for a held function, since the declaration and every call site spell it the
  same way. makeStream's verbs sit a function deeper and need the nested-declaration work first.

- **2026-08-31** — The frame handle is a do-block over a private memo, not a factory closure like
  midiManager's makeStream: only the renewal memo can go behind a door, since fifty-seven sites read
  deep into channels and the engine splices into columns later stages read, so an accessor would
  hand out the mutable interior anyway for the cost of a call in the hottest loops. There is one
  frame per trackerManager, and the do-block form is what RAW INDEX and STAGER already are.
  rawThenLogical goes to the index rather than the frame: it orders the index's own lists, and its
  non-engine callers are the index build. The lane shed is renamed renewal -- renewLane,
  markRenewed, docs section Note-lane renewal -- since shed named neither the mechanism (the events
  table is replaced by a clone) nor the intent (announce the lane changed).

- **2026-08-31** — Phase 4 gives the frame a handle with direct access to `channels`, where the
  index and the stager get door tables: the frame's seven operations already take a frame or a piece
  of one as their first argument, so the engine's writes need no door, and the handle's `channels`
  field swaps each pass where tm mints the map. `index.byUuid` joins the index doors and `tm:byUuid`
  delegates to it, since tv and gm call the public method; that settles the first half of the
  split's open question about what `tm` covers. `fxNotesByProducer` is handed in and mutated in
  place, which the engine's rule allows, because a clean channel keeps its lists across passes and
  so the map is not the engine's to create.

- **2026-08-31** — `src/` gains a directory per page stack, with `coordinator` for the frame and
  `shared` for the rest: a reachability trace over require and util.instantiate edges put 50 of 59
  modules under exactly one page, and resolved all five straddlers to `shared`. Grouping by kind or
  by language says nothing the filenames do not, and a stack's JSFX sits with it because the
  coupling that bites is the Lua-JSFX lockstep. Requires stay flat names over a fanned
  `package.path`; dotted paths would have spelt the layout into 118 spec files, and a module's
  location is no part of the production shape specs consume. A lint over directories is owed, and
  until it lands nothing enforces the partition.

- **2026-08-31** — The dirt journal leaves as `dirt.lua` with its write verb already in it, merging
  two planned commits: the verb has no testable home until the module exists, and splitting them
  meant an interim assign-shaped door built to be deleted. `add` is the sole write and
  `has`/`wholesale` the reads, so the lattice's two rules hold in one place. Neither hand-written
  join it replaces is reachable through the public API today, so `dirt_spec` states the rules rather
  than pinning a regression. One journal per trackerManager rather than a module singleton, since
  specs instantiate tm repeatedly and phase 3's rebuild takes the same instance.

- **2026-08-30** — `spans.lua` and `curves.lua` stay two modules and share one doc,
  `docs/algebra.md`. Nothing uses curves without spans, but trackerManager uses spans at many sites
  with no curve in sight, so the smaller module stays a leaf other geometry can reach. One namespace
  would also stand `clip` on a span beside `slice` on a curve, the same idea on different objects,
  distinguished only by prefix.

- **2026-08-30** — The curve fold joins `curves.lua`: `sumStreams` and `foldChains` publish, and the
  four helpers under them turn private. The densify step passes in as a parameter, since it reads
  the take's resolution and the CC-interp setting; trackerManager keeps `ccGridStep` and now
  resolves it once per rebuild stage instead of once per sum. The fold's lone-record path returns
  the record's own curve, unclipped and not a copy, which is stated as an invariant now that the
  callers doing the clip sit in another file.

- **2026-08-30** — The pb seat pass's ramp test reads whichever stream owns the onset, so a
  generator's curve answers it exactly as an authored one does. Asserting instead that a window
  always ramps put a dual point on the tick before a curve's step, dragging the arrival value back
  across the whole preceding note -- portamento steps onto its anchor, and a retune makes that
  anchor a detune onset as well. A breakpoint standing on the onset now keeps its own shape, owning
  the segment that leaves.

- **2026-08-30** — The breakpoint-curve algebra leaves as `curves.lua`, publishing `interpolate`,
  `eval`, `slice`, the two half-open window rules and the two predicates. The module name carries
  the subject, so `evalCurve` and `sliceCurve` shed it as the span names did. `curveSample` and
  `mm:interpolate` leave midiManager outright, rather than leaving the delegate this morning's entry
  planned: trackerView reaches the algebra through `tm:interpolate`, so mm's only remaining callers
  were two specs, and the algebra is the oracle those specs wanted of it.

- **2026-08-30** — The half-open span algebra leaves as `spans.lua`, requiring only `util` and
  publishing `merge`, `mergeWindows`, `overlapping`, `intersects`, `clip` and `subtract`. The module
  name carries the subject, so the four names that carried it shed it. A module required under its
  own noun collides with the locals holding its data, and trackerManager's sixteen take role names
  instead: `spanSet` for a bare span list, `seedSpans` for the PC path's two-frame spans.

- **2026-08-30** — `firstAfter` and `firstAtOrAfter` join `util` keyed on `.ppq`, and stay distinct
  from `util.seek`. A key function earns its place at the third caller reading something other than
  ppq, and there is none. `seek` scans and answers an item where these bisect and answer an index,
  so one name over both would hide two contracts.

- **2026-08-30** — Interpolation is curve algebra, so `curveSample` and `mm:interpolate` move to
  `curves.lua` when the algebra leaves trackerManager, leaving `mm:interpolate` as a delegate for
  the view and the cents stream. The alternative, an interpolator argument threaded through six
  signatures, names in each of them the only value it ever takes.

- **2026-08-30** — The cheat-sheet draws a pathed command's route in a column of its own, between
  the keys and the labels, so the routes align down the box. The route chip binds nothing, yet a
  click on it focuses its row, which is how a command reached by its path alone is given a chord.

- **2026-08-30** — A pathed entry's route carries the menu key at its head, so it reads as the
  keystrokes that walk to the command: `/GQ` rather than `GQ`. A consumer draws the route as it
  stands, and composes no part of it.

- **2026-08-30** — The lotus menu's lookahead draws as a second line of the row, above the level and
  opening at the same column, in place of a box floating over the highlighted member. A highlighted
  group previews its own members there and a highlighted leaf its description, and a previewed
  keycap is washed, since its letter reaches nothing until the highlight is taken.
- **2026-08-30** — The PC pass re-derives `sampleShadowed` on every rebuild, so it counts as
  realisation and joins `REALISATION`; a park round-trip drops it instead of stashing a stale flag.
  Shadow marking now splits by seat: a raw-index record marks through `setCell`, while an fx-derived
  one writes its own spec, because `setCell` reads (chan, lane) off whatever it is handed and a bare
  spec sheds a note lane whose cells have not moved.

- **2026-08-30** — The menu's row is a strip rather than a box: it spans the window's margins as the
  toolbar and status bands do, ruled along its top edge in a colour role of its own, with no border
  or rounding. It is chrome furniture in the footer band, not an overlay laid over the body, and it
  reads as one. The cheat-sheet's box renderer still draws the lookahead panel; only the row's own
  ground stopped being one of its boxes.

- **2026-08-30** — A modal scope lifts page suppression in key dispatch: the walk reads the full
  keychain while one is up, rather than the root keymap alone. The modal's own passthrough filter
  is already the narrower of the two, and its keys are nobody's page bindings, so the editor page's
  standing suppression no longer eats the menu's arrows, Enter and Esc. `cmgr:isModal()` asks the
  question, beside the other top-of-stack accessors.

- **2026-08-30** — The menu's row draws through the cheat-sheet's chip renderer and in its colours,
  so a letter reads as a key in both places; only the fill under the highlighted member takes a
  colour role of its own. The drawing lives in menuRender.lua, which keeps menu.lua free of ImGui,
  so the walk's spec loads it without a fake.

- **2026-08-30** — The keycap chips and the box of chip rows they sit in draw through keycaps.lua,
  bound to a drawlist and a theme. A draw call reports where the chips landed, and the cheat-sheet
  decorates that geometry with its click map and its edit tags, so the module holds no interaction
  state and the menu draws its row and its lookahead panel through the same code. An edit tag
  therefore draws over the label it reaches into.
- **2026-08-30** — Chrome grows style scopes: pushStyle takes a spec of bare slot names and hands
  back a handle, popStyle unwinds what that handle laid down, and styled brackets a body so an early
  return cannot skip the pop. The scope is a handle, over a LIFO stack closed by a bare popStyle,
  because ImGui's colour and var stacks are independent and both popup sites interleave them.
  Colours arrive as names or {u32} tokens and a bare int raises, closing the hole PushStyleColor
  left in painter's discipline.

- **2026-08-30** — The lotus menu draws its letters as the cheat-sheet's keycaps, in the row and in
  the panel alike, since a menu letter is a key pressed. A row wider than the window wraps upward,
  so every title is drawn in full. One box sits above the highlighted member, carrying its title and
  its description line, and a group's children with their letters, so the lookahead and a leaf's
  line are one mechanism. That box stops at the window's top edge and slides to stay within its
  sides, covering the toolbar where a deep group needs the room.

- **2026-08-30** — The lotus menu's highlight moves with Left and Right, since a level draws as one
  row; Enter and Up take it, Down and Esc unwind. An unwind restores the index the descent was taken
  through, so stepping back up the path lands the highlight where the eye left it. The numeric
  prefix's exemption is now declared per entry as keepsPrefix, in place of the dispatcher's
  hardcoded beginPrefix name. The walk's own keys carry it, so an arrow or an Enter over a pending
  buffer leaves it for the leaf.
- **2026-08-30** — The fx strip's Period row becomes a picker over the ladder rather than a text
  box: the popup's own filter field is the custom entry, so a fraction the ladder never names is
  typed where a name would be typed, and the box's close-press bookkeeping (periodEdit, BOX_ENDERS)
  goes with it. Stacking the ladder under its three families then needed drawPicker's create row to
  stop leading every block -- createLabel may now name the block its text belongs to, a group being
  a destination only for the tier pickers and merely a sort here. timing.periodClass reads the
  family off the fraction, a factor of 3 in the denominator being a triplet and in the numerator a
  dot, so a typed period is placed like a ladder entry.

- **2026-08-30** — The stream record becomes a closure: makeStream() holds list, order, free,
  maxSlot, chans and sidecars as locals, so the six can only move together and only through its
  surface -- the module chunk's own pattern one level down. The surface splits in two: verbs (get,
  admit, release, insert, remove, ordered, inChan, the bucket splices) and lifecycle (seed, reset,
  compact, sortByPpq, reindex, plus rawList and sidecarGroup for the tables midiBlob holds by
  reference). admit is minted as release's mirror, so the free list has both directions in one
  place. orderEpoch follows the fields inside, which ends the false positive where a cc splice
  tripped a live note walk.

- **2026-08-30** — The keyQueue drain order is recorded as what ownership leaves undecided: the fill
  first, the cheat sheet and modal last, and in between a page's own body readers, the keychain walk
  and note entry, with the page placing the walk among them. The design doc collapses whole, so its
  open question -- whether pageSuppressed is better expressed as a cmgr scope with a passthrough --
  is dropped rather than carried.

- **2026-08-30** — curveEditor takes the answer rather than the queue: the host reads shift off the
  key queue and hands it down with the frame's other arguments, so the leaf editor holds no key
  state. The exclusivity is pinned by a scan in keyQueue_spec — only keyQueue.lua may name ImGui's
  GetKeyMods.
- **2026-08-30** — `sonority.relax` eliminates the linear system its stationarity conditions state,
  over sweeping Gauss-Seidel to a tolerance: the harmonic lock's floor puts the pull's strength on
  every diagonal, so the system is positive definite, the minimum unique and the answer exact rather
  than short by a residual. The suite drops from 14.6s to 9.9s, a production solve by about 2% --
  the relaxation is a twentieth of one. The beam's width and cap stay where they are: the cost gaps
  between roads stand three orders above the residual the sweeps left, so exactness buys a discrete
  choice nothing.

- **2026-08-30** — The wiring canvas's draft cancel takes Escape at the frame's mods, over the bare
  Mod_None the editor and sampler cancels use: a draft is begun shift-held, and the modifiers a
  gesture needs should not defeat the press that abandons it. The take also comes out of the
  cheat-sheet gate, which now wraps the mouse passes alone, since ownership answers the keyboard
  question for it.

- **2026-08-30** — A picker popup a page raises owns the key queue, under the same `picker` name the
  toolbar's picker claims under; the name covers every picker popup. Ownership replaces the
  focusState clause that gated commands while the popup was up, since a claim made under no name
  answers nil for the whole frame.

- **2026-08-30** — The editor page's Esc takes the press from the queue, and its modalHost:isOpen()
  gate goes: a sub-modal owns the frame, so the take answers nil without a gate to say so. The
  item-active guard stays, since Escape survives the fill's text-field claim on purpose, and a live
  InputText or a slider mid-drag cancels itself with it. The sampler's rename cancel claims the same
  way, which leaves wiring as the last direct reader.

- **2026-08-30** — The tracker's right-hand pane owns the key queue while either tab holds focus,
  over narrowing the fill's text-field claim so the palette could keep its arrows past a live find
  box. Left/Right from an *empty* find box drive the tree, and the fill cannot know the box is
  empty, so the narrowing has no rule to state; ownership does, and it takes `releaseReq` and the
  two `acceptCmds` terms with it.

- **2026-08-30** — mm holds each kind's slot table as one `stream` record -- list, order, free,
  maxSlot, chans, sidecars -- over the twelve twinned file-scope locals that were threaded through
  the slot helpers as arguments. `streamOf(evt)` becomes the sole site discriminating note from cc,
  bar the two boundaries where midiBlob wants the kind's name rather than its stream. `wireDirt`
  stays keyed by kind rather than joining the record, since `midiBlob.syncSlots` takes it whole.

- **2026-08-29** — The mini pattern editor's first frame is an ordinary input pass. The fx strip
  claims the press that opens the editor, and modalHost:draw runs later in the same frame, so the
  editor reads a queue that press has left; a press nobody claimed reaches the editor there as on
  any later frame. The item-active guard stays, since the fill's text-field claim is skipped on a
  frame a modal owns.

- **2026-08-29** — The fx strip's keyboard exits drop the session where they claim the press, over
  the frame-end request they had shared with the mouse. A claimed Escape cannot reach the page
  dispatch later in the frame, which was the deferral's only reason. The header buttons and the grid
  click keep it, since they fire mid-draw and the rest of the draw still reads the focus they would
  drop.

- **2026-08-29** — The commit and cancel claims live on `modalHost` as `takeEnter` and
  `takeEscape`, over a pair of file-local helpers per renderer. Every modal body already holds
  the host, and the host owns the `modal` name, so the Enter/KeypadEnter pair is written once
  and `arrangeRender` and the editor panes need no `keyQueue` of their own.

- **2026-08-29** — The tidy modal's Enter is claimed by the field it deactivates, over gating the
  footer on `IsAnyItemActive`. One reader acts on the press and claims it, so the footer's claim
  answers nil behind it, and the ordering the gate needed — reading the active item before the
  fields draw — goes with the gate.

- **2026-08-29** — A modal renderer's appearing-frame guard comes out in favour of the keychain
  walk's claim, over keeping both. The press that raised the modal has left the queue before the
  renderer first draws, so the guard has nothing left to block. The cost is that a modal raised by a
  mouse click on a frame that also carries an Enter reads it, which takes a click and a keystroke
  inside the same frame.

- **2026-08-29** — The sampler's open rename is a guard on the page's reader, not a fifth keyboard
  owner: the fill records no owner for it, and the field is not active on the frame it opens, so it
  blocks acceptCmds while it is up. Ownership settles at the fill, so a modal raised mid-frame gates
  nothing until the next one -- one frame's granularity is the price of reading the state once.

- **2026-08-29** — An open picker and an open status field outrank an open modal in the fill's
  precedence, over the modal-first order the four owners started with. A popup is raised over a
  modal rather than beside it, so it is nearer the user; without the reorder the shelf pickers
  inside the pattern editor would sit on a frame the modal owns, and every claim they made under
  `picker` would be refused. Ownership then covers what `patternEditor`'s `pickerIsActive` gate over
  its Escape/Enter fallback covered, so that gate goes.

- **2026-08-29** — REAPER's link is released by the same liveness test that reclaims abandoned
  session trees: a tree is held exactly when a session directory under its slug records a pid that
  still names a claude process. No separate record of who claimed the link is kept, so the two ways
  a claim outlives its session - the tree deleted along with it, and the tree surviving it - are
  answered by one predicate at SessionStart.
- **2026-08-29** — A modal renderer claims the keys it acts on where it draws, over declaring them
  to modalHost for the host to claim and dispatch. A custom kind decides its keys at draw time from
  the command manager's current bindings and from its own sub-state, which a declared key list
  cannot express; declaring would also put a second claiming mechanism beside the one every other
  reader uses. The prompt renderer drops EnterReturnsTrue with the same move: the field is read
  every frame, so the preview and the value Enter commits are the same text.

- **2026-08-29** — Ownership is settled at the fill, so the frame the cheat sheet opens on has no
  owner and any claimant may take from it. The sheet keeps its open-at-frame-start gate over
  dismissal, with ownership standing behind that gate rather than in its place. A capture the
  command manager has no binding token for is no chord: that press goes back to the queue, and
  capture stays armed.

- **2026-08-29** — The fill's claim on a live text field's keys is off while one of the four owners
  holds the frame. An owner takes the whole keyboard, a field it hosts included: the picker's filter
  is a live field, and an unconditional claim would take the arrows its cursor reads.

- **2026-08-29** — The tree REAPER falls back to is recorded in `Scripts/Continuum.home`, written by
  every claim and read by `__startup.lua` when the launcher is unreachable. Releasing the link
  cannot depend on SessionEnd: a `claude --worktree` session deletes the worktree hosting that hook
  before it fires, leaving the link naming nothing, which stops Continuum starting at all.
  `__startup.lua` runs at every REAPER launch and is the only Continuum code outside the link, so
  the repair belongs there and nowhere else.

- **2026-08-29** — Abandoned session trees are reclaimed by a sweep at SessionStart, keyed on the
  pid each session records when it starts. The SessionEnd hook still tears down its own session, and
  cannot be the only mechanism: a `claude --worktree` session deletes the worktree hosting that hook
  before the hook runs, and a run can be cut off partway. Liveness of the recorded pid decides which
  trees are abandoned; mtime could only guess.

- **2026-08-29** — Note entry takes the presses it enters from the keyQueue, which retires
  commandHeld: a press a command fired on has already left the queue, so the grid cannot see it and
  needs no per-key hold table. Backspace is claimed at the frame's modifier mask, since the chord
  and value gestures run under Shift and the press that steps them back carries it. A press the
  edit-key scan declines goes back to the queue, as a declining command's press does.

- **2026-08-29** — Reloading Continuum is a relaunch of its own ReaScript action, since a fresh Lua
  state is what re-reads edited source. reload() only flags the restart and returns, so the response
  file is on disk before the state is torn down. Starting an instance when none is running cannot go
  through the bridge at all, because nothing polls the spool then: a separate launcher script, kept
  alive by REAPER's __startup.lua, watches for a spawn marker and re-invokes the named command id
  the bridge records in spool/action.id. REAPER's web interface was rejected for that job, since it
  puts an HTTP listener in front of every action and the bridge's file transport rests on there
  being none.

- **2026-08-29** — The pattern editor claims Esc and Enter at Mod_None, so a modified Esc no longer
  cancels the modal. A reader names the mask it acts on, and the queue answers only for that mask.

- **2026-08-29** — The key dispatcher claims for whoever hosts it. `keyDispatch` reads a claimant
  off the focus state it is given, so the mini pattern editor, which draws inside the modal the fill
  recorded as owner, captures presses the coordinator's own dispatch may not. Ownership is part of
  the caller's account of its input situation, which is what that state table already holds, so it
  travels there rather than as a further argument.

- **2026-08-29** — Ownership of the key queue is a name the fill records, and a claim names itself:
  take and takeAny accept a claimant, which the four owning readers pass and every other reader
  omits. A handle the fill hands the owner was rejected, since the readers hold the queue as a
  module-scope dependency and would each need one delivered per frame. A claimant outside the four
  raises, because a typo would otherwise read as a key that quietly does nothing. The coordinator
  settles the precedence at the fill already, though nothing drains yet, so the composition each
  page's focusState builds today has one home to move to.

- **2026-08-29** — Eleven mechanisms across the input path encode "this keystroke is already spoken
  for", each rediscovered at the site that needed it, and five of them are one bug: a reader ran
  after a claimant that had no way to claim. One queue, filled from the named-key range at the top
  of the frame and drained by claim, replaces them. The drain order stays the call order; a
  two-phase frame draining in scope-stack order was rejected, since it buys three focus flags for a
  restructured frame across every page. A modal owns the queue for its frame rather than emptying
  the fill, because modalHost and help draw after the page body and a plain claimant there would be
  asked last.

- **2026-08-29** — A leaf's letter closes the menu before it invokes, so note entry's own pass over
  the key stream finds no sink to stand off from, and reads the letter still pressed as a note. Key
  dispatch now reports the captured letter in commandHeld, over gating that pass on the frame's
  consumed flag: commandHeld already says which keys are spoken for, and a walk that took a letter
  makes the same claim as a binding that fired on it.

- **2026-08-29** — The roster in cmgr_fluent_spec names every command the menu does not walk to, and
  fluency is one reason among several: a click-only route is another, and so is a verb the menu
  reaches by a better path — travel to the editor page asks for a choice of tab, so the menu offers
  the tabs and F10 keeps the bare switch. A claim about a mechanism takes a witness the spec builds:
  the occupancy rule for a level now runs on a synthetic two-node tree, so re-cutting a path in the
  real manifest moves nothing, while the cases about what a page offers keep the real declaration.

- **2026-08-29** — The slash typed into a numeric prefix leads two lives, so it appends to the
  buffer and opens the menu at once, and the key after it says which was meant: a digit continues
  the rational and dismisses the walk, a letter walks. finishPrefix drops a trailing slash for every
  caller, so an unfinished rational reads as its numerator and the leaf takes the prefix through the
  same freeze the keychain walk uses. The dismissal is a field on the scope beside its letter sink;
  invoking a no-op command gated on the menu's scope was rejected, since invoke bails a
  spring-loaded scope on any command it does not own, and a digit typed in region mode would disarm
  the mode.

- **2026-08-28** — A letter reaches the lotus menu through a sink the scope declares. Key dispatch
  offers a bare or Shift letter to the top scope's captureLetter ahead of the keychain walk, so the
  letter reaches no binding. The stack already answers what a key may reach, so key dispatch stays
  ignorant of the menu, and the mini tracker's own cmgr declares no sink.

- **2026-08-28** — A group is a member of its level where it or any descendant holds a reachable
  entry, so the sampler's Grid survives on the global swing verb alone while Column drops out. A
  level's leaves read by title: the surface unions the scopes on the stack, whose cheat-sheet groups
  the manifest orders one at a time, so declaration order fixes nothing across them. The path holds
  the nodes descended into rather than segment strings, which makes the level a lookup. Region mode
  changes no level, contrary to the design: it is spring-loaded rather than modal, and / is neither
  redirected nor kept alive, so opening the menu leaves the mode.

- **2026-08-28** — The menu reads the surface it walks off the stack as it opens, rather than
  passing every pathed command through its own modal scope. What it offers is then fixed for the
  walk, and what the modality blocks stays exactly the keys a letter would collide with. The page
  switchers pass through, so the coordinator closes the menu before a switch pops the page's scope.

- **2026-08-28** — The fluent/pathed split is pinned by a roster in a spec rather than by a flag on
  the entry. The manifest already declares the classification by omitting a path, and the roster is
  the second witness that makes the omission deliberate: a command is pathed or rostered, and one
  that is neither fails, naming itself. The four commands reached programmatically are rostered too,
  so the rule stays two-sided; a family minted in a loop is exempt, its members being fluent by
  construction.

- **2026-08-28** — Arrange's slots are takes rather than columns, so its Take level mirrors
  tracker's word for word and both pages reach take properties by /KP. Replace and advance modes
  stay fluent, since each reinterprets the drop that follows it, and the drops are fluent by
  construction. The sampler's load and rename head a Sample group of their own, which opens on that
  page alone; region's four verbs are all fluent, so region mode leaves the global menu standing.

- **2026-08-28** — A menu path names its leaf, not just the level it reads in: every segment but the
  last names a group, and the last is the command's title in the menu and the source of its letter.
  One declaration therefore carries the level, the word shown and the key that takes it, and the
  cheat-sheet's phrase stays free to differ from the menu's one word. Groups and leaves share one
  namespace of letters per level, and the load check pairs global's leaves with one scope's at a
  time, since two page scopes are never on the stack together and a letter they share is two menus
  rather than a collision.

- **2026-08-28** — The lotus menu's top level is named for what a command edits rather than for the
  model's axes: Edit, View, Grid, Tuning, Mirror and Page stand where Select, Column, Time, Pitch,
  Group and View stood. The tree is declared as manifest.tree beside the commands, and a separate
  installTree resolves the pathed entries, so the scope table keeps the name menu free for the modal
  scope the walk will push.

- **2026-08-28** — A figure a spec reads off the relaxation is pinned no finer than sonority.relax's
  tolerance settles it, and an aggregate looser still. Pinning further records where the sweep stops
  rather than what the objective states, and five figures across two specs had drifted into doing
  exactly that. Over-relaxation was measured and refused: at 1.55 it halves the sweeps a cold start
  takes, but the solve warm-starts, so a retune pays the extra multiply without the saving.
  Tightening the tolerance instead was refused for the same reason -- the sweep already settles a
  displacement inside a third of a pitch-bend step, so no accuracy bought there can reach the
  output, and the cost falls on the user.

- **2026-08-28** — A generated family rebinds as one. A captured chord's modifiers re-mask every
  member over its own unmasked base token, so the base is declared beside the member rather than
  inferred as a common prefix. The family takes a mask only where every chord it would claim is
  free: a collision refuses the whole capture, since rebinding part of a family would leave two
  names on one chord in one scope, which dispatch resolves arbitrarily.

- **2026-08-28** — The gesture the cheat-sheet swallows is gated at each page's own direct read of
  the mouse or key stream, not centrally: only the render knows which of its passes bypass the
  dispatcher coord suppresses. Each page anchors one body rect under the shared key `body`, so a
  flowed group places the same way over a grid, a canvas or a file browser.

- **2026-08-28** — The cheat-sheet group a command reads under is declared as the key its entry sits
  beneath in its scope's manifest, rather than as an argument to the entry or a marker between
  entries. Membership is then the entry's own fact, carried wherever the entry is read, and a page
  declares only where a named group draws.

- **2026-08-28** — The manifest declares its commands as an ordered list rather than a table keyed
  by name, so the order a command is declared in is a fact the declaration carries, and a consumer
  that groups commands reads that order rather than holding a list of its own. Keys are declared as
  binding tokens — the stable ASCII form a persisted rebinding already stores — so a declaration and
  an override spell a chord the same way, and manifest.lua needs no ImGui import.

- **2026-08-27** — A cheat-sheet group names its commands alone, and the label each row renders
  under is the command's manifest entry, read through cmgr:entry. The lookup returns the entry
  rather than the label, since the menu will want the same command's path from it. It raises on a
  name no manifest declares, in place of help's fallback to the bare command name for a victim on a
  scope the page never shows.

- **2026-08-27** — The page specs compare their own scope's declared and registered sets, rather
  than calling cmgr:auditManifests as they did. The audit is now strict — a scope that registers a
  command must declare a manifest — so a whole-tree audit inside a page spec trips on the tracker
  scope the harness always builds and the spec never declares. cmgr_manifest_spec still pins the
  audit itself; wiring has no page spec, so its correspondence rests on the load-time check alone.

- **2026-08-27** — A command name belongs to one scope. Arrange's follow-play command was registered
  as toggleFollowPlay, the name the tracker scope already held; cmgr.commands being flat, the
  tracker page's later registration took both the body and the gate, and Cmd+F on the arrange page
  reached nothing. It is now arrangeFollowPlay, which the manifest's one-name-one-entry check would
  have forced in any case.

- **2026-08-27** — The pattern editor's editing subset stays a list in patternEditor.lua and takes
  only its keys from the tracker manifest, rather than each entry flagging its membership. A flag
  would make the subset a fourth consumer of the entry, where the design admits three — bindAll, the
  cheat-sheet and the menu.

- **2026-08-27** — The manifest installs once from continuum's wiring rather than per render module
  at load, so the declared keys are in place before persisted overrides overlay them. The audit
  passes over a scope that declares no manifest, so the surface migrates one scope at a time.

- **2026-08-27** — Explode and freeze share one chord, Ctrl+E, with the caret's host picking the
  arm: freeze refuses on the master strip and explode refuses off it, so at most one is ever live
  and a second binding would only ever be dead. The eligibility gate sits in tv, composed from the
  stored region's channel and tm's realisation union, rather than as a second tm predicate beside
  freezeEligible: both facts are already published, and the button and the keystroke want the same
  answer before the atomic wrap opens a block.

- **2026-08-27** — A pbRange edit from the tracker status bar writes the track tier, not the take
  tier its neighbouring cells use. The range has to match the pitch-bend range of the synth on the
  track, so two takes played through one synth cannot sensibly disagree; octave and advance sit at
  take because they are per-take editing state. patternEditor's take-tier write stands, since its
  scratch take carries its own synth.

- **2026-08-27** — Explode stores the expansion verbatim, so it seeds no derivation dirt. The
  producer list the rebuild's passes read is the same before and after -- same channels, same spans,
  same uuids -- and the one rebuild it forces is for the output maps keyed by the stored region. The
  channel set comes from that region's realisation union, which is the set the master strip already
  ghosts, rather than a second read of the channels in use. A chain reaching no channel refuses,
  since exploding it would leave nothing behind and lose the chain.

- **2026-08-27** — Portamento anchors each glide on its successor's onset rather than sizing it from
  the host's window end. A glide sized from the window arrives wherever the window closes, which is
  not the successor where a host overruns a parked note; an onset costs nothing to read and cannot
  drift. Abutment gates the glide — a gap is a rest, and nothing slurs across a rest — so
  target='fixed', an ungated tail bend sharing the name, was dropped rather than gated into a second
  mode.

- **2026-08-27** — Freeze keeps refusing on the master channel rather than exploding a global chain
  itself. It would have to freeze sixteen producers, each with its own eligibility refusals, so
  partial failure would be the normal case and explode's all-or-nothing would not survive it. The
  route is to explode first, then freeze one of the sixteen.

- **2026-08-27** — A stored global region runs no producer of its own, so its uuid answers with the
  union of the producers it expanded into, and a realisation entry names the channels it realises on
  rather than one channel. A claimed target span is logical rather than raw, so the union merges
  back to the stored region's own span instead of holding one interval per channel's swing;
  tm:fxCurveAt therefore takes the channel it reads on as an argument, and converts at the sample
  point.

- **2026-08-27** — Generator periods stay tempo-synced; a millisecond period was considered and
  dropped. It wants a seconds-per-QN in the fx ctx, whose invariant admits resolution, pbRangeCents
  and nextSameLaneNote alone, and the expansion would then go stale on a tempo change that triggers
  no rebuild. The widget was the cheap half of the ask and the ctx the expensive half, so the widget
  landed alone.

- **2026-08-27** — A period is any fraction, typed in place, over a ladder the arrows walk by
  magnitude rather than by list position. The choice widget reads an unmatched value as its first
  option, so 7/19 displayed as 1/2 and arrowed from there; comparing QN lets an off-ladder period
  step from where it sits. Nothing typed joins the ladder, which is a navigation surface an accreted
  entry would tax on every later arrow.

- **2026-08-27** — A global fx chain expands onto the channels in use rather than all sixteen. A
  channel is in use when it carries an authored note, when the park stash holds a note taken out of
  it, or when it has a pb or cc lane of its own; derived output is no evidence, since a channel
  counted in on a chain's own emission would never leave the set. Expanding everywhere authored a
  curve on every empty channel — 160 pb events on a take holding one note.

- **2026-08-27** — An expanded producer's identity is its stored region's uuid joined to its channel
  with util.key. The key is opaque and persists into the window store and the park stash, so nothing
  splits it back apart: a reader wanting a global region's producers derives the sixteen keys
  forward.

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

