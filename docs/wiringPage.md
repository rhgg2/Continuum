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

Editing flows through a handful of page-local, ephemeral state tables
(never persisted). At most one is live at a time, and mousedown resolves
them in a fixed precedence:

> **shift-hover (new wire) > wire-end-hover (redraft) > body-hit (drag)
> > empty canvas (band).**

- **`drag`** — mousedown on a node body. Maps every node under the drag
  (the grabbed one alone if unselected, else the whole selection) to its
  origin pos; each redraws at `start + (mouse − mouseStart)` while the
  button is held. Mouseup commits the set in one `moveNodes` — one
  mutate, one signal.
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

Two non-drag gestures sit outside the precedence chain:

- **Double-click a node body** dives: a Continuum Sampler node opens the
  sample page bound to its track (via `diveToSampler`); any other fx node
  floats its REAPER FX window. The first click's no-op body-drag has
  already committed, so a `dblConsumed` flag stops the second press from
  re-arming a drag.
- **Right-click** resolves triangle → wire menu, node body → node menu
  (Delete node), empty canvas → FX picker.

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

1. **Existing wires** (bottom), overpainted at the node edge by step 4 so
   they read as emerging from behind the body.
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

Wire geometry (`segs`) is built once and shared by the draw pass and every
hit-test, so highlight and label placement can never drift from the drawn
line.

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
splice`). To the renderer a buss is just a node whose body is a bar. The model's
rationale and rejected alternatives are archived in
`design/archive/wiring-busses-v2.md`.

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
  (`bussablePorts`), a *Buss in/out N (horizontal|vertical)* entry arms
  `busDraft {nodeId, dir, port, orient}`. The bar is then glued to the cursor and
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
