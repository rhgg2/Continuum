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

## Bus rail geometry

A bus is an explicit, user-authored decoration on a node (`node.busses`,
port-scoped) that renders one port's many edges as a **rail** instead of a
star: a bar on one side of the node, the edges meeting it as orthogonal comb
taps, and the many taps collapsing to **one arrowed trunk** into the node. The
many-to-one collapse at the trunk is the decongestion — N radial arrowed lines
become N short taps plus one arrowed trunk. The design rationale (why explicit,
why a bus and not a mixer) lives in `design/wiring-busses.md`.

`wv:wireViews()` stamps each claimed edge with `bus = { nodeId, busIdx,
bussedEnd }`; `busSegments` owns those edges (the normal `wireSegments` /
`sourceSegments` passes skip them) and `drawBusPass` strokes the bar + trunk.

Geometry, per bus (`SIDE_VEC` maps `side` to the outward normal `n` and the
along-bar axis `a`; the bar is ⟂ the normal):

- **Bar distance** from the body is `half + BUS_BASE + rank·BUS_STACK_GAP`,
  where `rank` is the bus's position among same-side busses — so stacked rails
  don't overlap. The bar's centre sits on the node's centre line projected out
  along the normal.
- **Each tap lands orthogonally.** A real far-end node lands at its *projection*
  onto the bar (the wire from its position to the projection is purely along the
  normal, hence ⟂ the bar). A **source** far-end has no body — each of its edges
  is a positioned copy, so it stands off the bar by `BUS_TAP_LEN` (plus its tag
  patch extent) at an evenly-spaced slot, and the existing source-tag pass draws
  its label at that outer end. Tap segs are normal `segs` (so the per-tap fader,
  RMB-delete, end-hit, and highlight all work unchanged) but flagged `tap` so
  `drawWiresPass` suppresses their radial arrow — the trunk carries the one arrow.
- **The bar spans its taps** (`min..max` of their along-axis coordinate, plus
  `BUS_BAR_PAD`). Length was never stored, so add/remove grow and shrink it free.
- **The trunk** runs from the bar centre to the node edge along the normal; its
  arrow follows `dir` (into the node for an in-bus, out for an out-bus).

v1 warts: dragging a bussed source tag is inert (the copy's slot is derived, not
`fromOffset`); a node pair carrying both a bussed and a non-bussed wire gets a
small slot-offset gap. Both are noted for the deferred reposition work.

### Bus creation

The *Add input/output bus* node-menu items arm `busOverlay = {nodeId, dir}` — a
modal port-selector that, while live, owns the mouse (the normal mousedown
precedence chain is gated off). It draws the node's audio ports for that
direction as grab handles on a fixed face (in→top, out→bottom — the grab spot,
*not* the eventual side); ports already on a same-direction bus render
stroke-only and inert. Pressing a free handle arms `busDraft`; the side is then
the **quadrant of the cursor from the node centre**, recomputed each frame, so
swinging around the node continuously re-sides the rail.

The live comb preview reuses the Phase-2 render untouched: each frame a
synthetic bus is appended to the transient `nodeView.busses` (a copy — the alias
points at the cached clone) and the wires it would claim get their `.bus` stamped,
so `busSegments`/`drawBusPass` draw the real rail before commit. Release calls
`wv:addBus` and the next frame renders it from the graph; the preview and
committed frames are geometrically identical, so there's no flicker. Esc or a
backdrop click (overlay only) cancels.
