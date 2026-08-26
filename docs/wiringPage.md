# wiringPage / wiringRender

The wiring page is split in two, mirroring the tracker and arrange
stacks:

- **wiringPage** is the controller — the object `coordinator` drives. It
  constructs the stack (`rm`/`wm` stay local, only `wv` leaves), owns the
  page lifecycle (`bind`/`unbind`/`enableLive`/`tick`), and delegates
  every render call to the renderer.
- **wiringRender** renders the canvas, reads keyboard / mouse, and owns
  the `wiring` command scope and the add-FX picker. It is handed `wv`
  only and never reaches `wm`/`rm` — what was a discipline (the page kept
  no `wm` reference) is now structural: `wm` isn't in the renderer's
  scope.

Source `--invariant:` lines fix the renderer's boundaries — render+input
only (no `wm` reference), the renderer owns every pixel — and the
controller's (project-wide, `bind()` takes no take). This doc carries
the *why* those don't: the gesture state machine and the canvas draw
order.

## Project-wide

One of two project-wide pages (arrange is the other). `bind()` takes no
take and never re-keys cm, so switching to or from wiring leaves the
tracker take and the sampler track untouched. There is no per-take
wiring state to save or restore — the graph is project-scoped.

## The gesture state machine

Editing flows through one page-local variable, `gesture` — nil when
idle, otherwise a table carrying its `mode` and that mode's payload. The
state is ephemeral, never persisted, and at most one gesture is live at
a time.

A parallel `modes` table holds the hooks, and a mode declares only the
ones it needs:

- **`inject(g, frame)`** runs before the frame's geometry pass and writes
  the gesture's in-flight state over the view lists — a dragged node's
  pos, a dragged tag's offset, a synthetic buss bar. One geometry pass
  then serves both the preview and the frame that commits it, so the two
  cannot drift.
- **`update(g, frame)`** runs after hover resolution, where the drop target
  is known: it ticks the gesture and commits it on mouseup.
- **`escCancels`** binds Esc to dropping the gesture. Only the two drafts
  declare it, and neither has teardown beyond the clear, so a flag serves
  until a mode needs a hook.

Either hook clears the gesture by returning false. `frame` is the
canvas's per-frame carrier, built by `beginFrame` and extended by each
phase that follows: painter, canvas origin, mouse, view lists,
selection, geometry and hover. The hooks read it, and inject's transients are
written back into it.

Mousedown resolves the modes it can start in a fixed precedence:

> **shift-hover (new wire) > wire-end-hover (redraft) > source tag >
> node body (drag) > buss bar > empty canvas (band).**

A node body under a bar still wins, so the bar catches only the presses
no node claims. An M/B badge click and a click on a chevron or between
list rows both sit ahead of the chain and consume the press without
starting anything. While a gesture is live, wire-end, source-tag and
triangle hover are all suppressed, so nothing under the cursor competes
with the drag.

The seven modes:

- **`nodeDrag`** — mousedown on a node body. Maps every node under the drag
  (the grabbed one alone if unselected, else the whole selection) to its
  origin pos; each redraws at `start + (mouse − mouseStart)` while the
  button is held. Mouseup commits the set in one `moveNodes` — one
  mutate, one signal — unless the drag splices (below).
- **`band`** — mousedown on empty canvas, drawn as a translucent rect.
  Mouseup with movement replaces the selection with the intersected ids;
  mouseup without movement (a click) clears it.
- **`wireDraft`** — the start of any wire-end-following drag, from one of
  two paths:
  - *shift-hover on a port* → **forward draft**: `cursorEnd='to'`, the
    kept end pins the source, the cursor floats the destination,
    `forbidden = ancestors(keptId)`.
  - *drag a source-palette row* → **forward draft** with `fromPalette=true`:
    type-agnostic (the drop port's kind decides the edge); `forbidden` is
    empty because a source has no ancestors. The row is the drag handle —
    sources have no canvas body.
  - *unmodified click on a wire's end-region* → **redraft**: `cursorEnd`
    matches the grabbed side, the kept end is the opposite one, and
    `edgeIdx` indexes the edge being moved. `forbidden` is
    `descendants(kept)` when the source end is grabbed and
    `ancestors(kept)` when the dest end is — so neither retarget can
    close a cycle.

  `forbidden` is consulted at hover time (cycle-blocked targets get no
  visual encouragement) and again at the mouseup commit. Cleared on
  commit / delete / cancel / Esc.
- **`tagDrag`** — mousedown on a source's tag. The tag follows the cursor,
  and mouseup past the click threshold writes its position as an offset
  from the consumer node it hangs off.
- **`busDraft`** — a bar glued to the cursor, armed from the node menu and
  dropped by a canvas click (*Buss gestures*).
- **`busDrag`** — move or resize a committed bar (*Buss gestures*).
- **`faderDrag`** — the mid-wire fader's knob drag. It declares no hooks:
  the per-frame poke and the release commit stay inline with the fader
  overlay, between the two hover passes their result feeds. Its role in
  the machine is only to mark a gesture live.

Two inputs resolve at the canvas but hold no state, so they are not
modes:

- **Double-click a node body** dives: a Continuum Sampler node opens the
  sample page bound to its track (via `diveToSampler`); any other fx node
  floats its REAPER FX window. The first click's no-op body-drag has
  already committed, so a `dblConsumed` flag stops the second press from
  re-arming a drag.
- **Right-click** resolves triangle → wire menu, node body → node menu
  (Delete node), empty canvas → FX picker.

### Splice on drop

A lone dragged node whose **body covers a wire's triangle** splices into
that wire on mouseup: the wire re-points onto the node's audio pair 1, a
fresh leg carries the signal on to the old destination, and the node
snaps to the triangle it was dropped on. The wire's gain stays on the
input side and the new leg is unity, so the splice changes only what the
effect does — everything downstream hears the same level as before.

The offer is made only where it can be taken (`wv:spliceable`): the node
needs a free audio pair 1 both ways, it can't be either end of the wire,
and it can't already sit downstream of it. Eligible or not decides the
highlight as well as the commit, so an unhighlighted wire is a promise of
nothing and the drop is a plain move. The whole target wire highlights,
drawn in the wire layer rather than over the node pass: the bodies at its
ends and the dragged body itself overpaint it, so the highlight reads as
a wire and not as an overlay. Where the body covers several triangles the
one nearest the cursor wins. Audio only — MIDI wires carry no gain, so a MIDI splice
would be its own gesture.

### The wire end leads the cursor

A redraft grabs a wire's end-region, not its endpoint, so snapping the
wire to the cursor would jump it. `computeDraftEnd` holds the end at its
old position and decays the gap to the cursor over `WIRE_GRAB_DECAY` px
of travel, ratcheting on furthest travel so dragging back toward the
start can't re-inflate it. The **decayed end, not the cursor**, drives
the draft visual *and* the hit-target / drop-eligibility checks: a
redraft that hasn't moved reads as still pointing at its original target
and detaches only once the end leaves that node. Empty-canvas drop —
which deletes the wire — is judged by the end too.

### Spillover engagement and pinning

Audio nodes past one port carry a chevron handle whose dropdown lists
ports by name. `listOpenId` and `engagedId` exist to stop that popout
flickering between nodes when two bodies' hover rects overlap: the
engaged node is probed before the per-node scan, and the list engages
only once the cursor has *crossed the chevron* — cursor-in-list without
a prior crossing does not open it. `pinned` records ports the user has
promoted to standing chips (clicking a list row, or starting a draft
from one); `sticky` keeps a pinned node's port row visible after the
pinning click, until shift-release or until natural hover returns to
that node. Both survive binds but not project loads — lifting them into
`wm` so they round-trip with the graph is future work.

### hoverFreeze

After a drag-drop mouseup the source-side popout would otherwise snap
onto whatever node sits under the cursor at drop time, reading as a
flicker. `hoverFreeze` captures the drop position and suppresses
shift-hover until the cursor next moves — *or* until the next click,
which is deliberate enough to mean "start the next wire here": chaining
wire after wire from the just-dropped node needs no jiggle between them.

## The port band

Wire creation is a shift-held gesture: with shift down, hovering a node pops a
**port band** on whichever of the top/bottom face is nearer the cursor (the
left/right faces are never used — wires run vertically). The band's layout
encodes two ergonomic bets:

- **Port 1 is the body, not a chip.** Its wire endpoint is the node body itself,
  so the overwhelmingly common path ("just use Main") needs no aim at a small
  target. Chips appear only for ports 2..N; the MIDI keyboard lives *inside* the
  body at its middle-right edge (painting over the label when active), not in
  the band. A node with one audio port and no MIDI gets no band at all — the
  body catches the default-port hover directly.
- **Chip promotion bounds the band.** For 2..5 audio ports the band shows a chip
  per port. Past five (`PORTS_PER_ROW`) it shows only the chevron **handle** and
  chips for ports that *already carry a wire*; unwired ports live in the
  handle's by-name dropdown. So a 32-out plugin starts as a clean body + one
  handle and grows chips only where wires actually land — the band never blows
  up to fit the worst-case plugin.

Drag-start fixes the wire kind (body/chip → audio from that port; keyboard →
MIDI; dropdown row → audio from the named port, promoted to a chip on commit).
**Cycle-forming targets are suppressed**: the source node and its transitive
ancestors get no hover affordance, since a wire to any of them would close a
loop — the same `forbidden` set the redraft gesture uses (see *The gesture
state machine*). The flicker-free engagement and port-pinning mechanics are
under *Spillover engagement and pinning*.

## Canvas draw order

The canvas is a strict z-stack, and several effects depend on the order:

1. **Existing wires** (bottom), the splice highlight painted over them,
   both overpainted at the node edge by step 4 so they read as emerging
   from behind the body.
2. **Popup sleeves** — the pale port-row backgrounds — before the nodes,
   so the body overpaints their overlap and so wires entering an engaged
   node's popout are occluded.
3. **The in-flight draft wire**, above the sleeves: the wire being dragged
   always reads on top of every popout decoration, where existing wires
   (below the sleeve) do not.
4. **Node bodies**, overpainting wire and draft edges.
5. **Wire-end highlight**, after the node pass — nodes overpaint wires, so
   an in-pass highlight would be invisible.
6. **Fader, error overlay, then the overlay pass** (body outline + port row
   + spillover list per engaged node).

`drawCanvas` runs the whole stack in this order, as one phase of the
canvas frame. The band overlay is the exception: it draws over the
popups, which follow the draw, so `renderCanvas` keeps it.

Wire geometry is built once as a table of **segs** — one per wire, each
carrying its endpoints, the per-end extents that trim the line against a
node body, and the midpoint the arrow sits on. The draw pass and every
hit-test read that one table, so highlight and label placement cannot
drift from the drawn line.

Every wire draws through `drawWire`, fed one seg. A real wire's seg
carries its wireView, which decides the line colour and the port labels
at each end. The draft wire and a buss trunk are **synthetic** segs with
no wireView: they draw untrimmed and unlabelled, and the trunk's port
label is placed separately, on the trunk near the node.

## M / B badges

Fx-backed nodes (`effect`/`generator`) carry two always-visible chips in the
body's top-left corner — **M** (mute) and **B** (bypass) — drawn in the
node pass and tinted when active (`wv:muted` / `wv:bypassed`). They're
hit-tested manually like the body gestures (`badgeHit`), not via an
`InvisibleButton`: a plain click toggles through `wv` and takes precedence over
the body-drag it sits on, while `shiftHeld` (wire mode) suppresses them and a
double-click on a badge is swallowed before the dive. Mute is graph-invisible
(rm preserves the wire underneath, see `docs/routingManager.md § Mute`), so the
toggle fires no `wiringChanged` and the next frame just re-reads the state.

## Buss bars

A buss is a `kind='bus'` node at every degree — a free-floating **bar** that sums
every input tap into every output tap, each crossing scaled by the product of its
two gains. The renderer draws the bar, combs its taps, and owns every buss
gesture; it never sees the realisation (spliced sends below 2×2, an fx-less
summing track at matrix — `docs/wiringManager.md § Busses`, `docs/DAG.md § bus
splice`). To the renderer a buss is just a node whose body is a bar.

`wv:busViews()` yields one `busView {id, pos, orient, ext?, matrix?}` per buss;
`busSegments` turns each into a **rail** (`bar` + per-tap `segs`) shared by the
draw pass and every hit-test, so the bar and its taps can't drift. Membership is
structural — `wv:wireViews()` stamps `bus = {busId, bussedEnd}` on any audio edge
whose endpoint is the bus node (`to` end wins); `busSegments` owns those edges
and the normal wire passes skip them.

Geometry (`ORIENT_VEC` maps `orient` V/H to the bar normal `n` and along-bar axis
`a`):

- **Free bar at the buss's own pos.** Unlike v1's node-anchored rail, the bar
  sits at the busView's `pos`/`orient`; input taps comb one side, output taps the
  other, each an ordinary arrowed `seg` so per-tap fader / RMB-delete / end-hit /
  redraft read the right direction. Every tap shares port 1 (a port index on a
  summing node is meaningless).
- **Span: auto-fit or hand-sized.** With no `ext` the bar spans its taps
  (`tapLo..tapHi`) unioned with a minimum, so add/remove grow and shrink it free.
  A resize drag stamps `ext={lo,hi}` (axial offsets from `pos`) and the bar holds
  that hand-sized span.
- **Taps spread per exit side.** Several taps from one far node spread along the
  bar axis (`farSlot`, keyed by far node + orient + exit side) so they don't all
  leave its body at one point.
- **Committed vs preview.** A committed buss has a live graph node, so its bar
  draws in the **node pass** (`drawBusBar`) as the node's body — selection
  strokes a slab round it. The dedicated `drawBusPass` draws only the live
  creation preview, which has no node and carries a trunk to the node being
  bussed.

### Buss gestures

Creation has three entries, all landing the same `kind='bus'` node:

- **Picker** — a synthetic *Buss* entry in the add-FX picker drops an unwired bar
  at the cursor (`wv:addBusNode`).
- **Node menu, per port** — for each audio port carrying an un-bussed wire
  (`bussablePorts`), a *Buss in/out N (horizontal|vertical)* entry arms the
  `busDraft` gesture (`{nodeId, dir, port, orient}`). The bar is then glued to the cursor and
  a canvas click drops it (`wv:insertBus` — mint the node and re-point that
  port's edges through it, audio-identical under the splice); Esc cancels. While
  armed, a synthetic claim-shaped busView is injected and the wires it would own
  get their `.bus` stamped, so `drawBusPass` draws the real rail and re-routed
  taps — with a trunk to the bussed node — before the click commits.
- **Mid-wire** — `wv:insertBus` is the node-menu commit path above.

A bar is also a **fat rewire target** (`busBarHit`): a redraft whose grabbed end
matches the bar's direction (a matrix bar takes either end) drops onto it as an
ordinary `targetHit {slot={kind='audio', portIdx}}` carrying a `viaBar` marker,
so the existing rewire/`addWire` path handles it unchanged and the highlight
strokes the bar. Shift-hover over a bar (`busBarSource`) starts a drag-out wire
from the grab point.

**Move / resize** is one drag (`makeBusDrag`/`busDragApply`): a middle-third grab
translates the whole bar; a near-end grab resizes that end (floored at its
outermost tap, handing off to the far end if the cursor crosses past it), and
perpendicular motion always slides. Release writes `pos` + `ext` via
`wv:moveBus`. **RMB** on a bar or bus-node body opens the node menu — *Delete
buss* (`wv:deleteBus`: node, incident edges, record, one Undo) and *Rotate buss*
(`wv:rotateBus`: flips V↔H).

## Exercising the page by hand

No spec covers the renderer, so a change to it is checked by walking the
page. This is that walk — every gesture the canvas supports.

- **Wire create** — shift-hover a body, a chip, the keyboard icon and a
  palette row; drag to a body, a chip and the keyboard. A cycle-blocked
  target offers no affordance.
- **Redraft** — move either end. Dropping on empty canvas deletes the
  wire; dropping back on the original target is a no-op, and leaves no
  undo entry. A short click on a wire end does nothing destructive.
- **Palette** — drag a row out to a floating tag and drop it, audio and
  midi both; add and delete a source.
- **Buss** — create from the node menu and from the single-port hover
  path; Esc and a backdrop click cancel either. Move and resize a bar,
  rewire onto it, remove it. A trunk's port label is right for a port
  other than 1.
- **Source tags** — drag a star tag and a bussed tag; default fan
  placement is unchanged.
- **Fader** — click the triangle (the cursor warps to the knob), click
  and drag in the strip, wheel coarse and fine (one undo entry),
  double-click to unity, leave to close.
- **Nodes** — drag one and drag a selection; band-select; a click on
  empty canvas clears it; double-click dives to the sampler or floats
  the FX window.
- **Menus and keys** — RMB the triangle (primary toggle), a node (delete
  and buss items) and empty canvas (FX picker); the N-key picker; Esc at
  every gesture point.
