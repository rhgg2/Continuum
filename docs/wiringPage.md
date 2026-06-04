# wiringPage

The coordinator citizen for the node graph: renders the canvas, reads
keyboard / mouse, and talks only to `wiringView` for graph state. Three
source `--invariant:` lines fix its boundaries — render+input only (no
`wm` reference), project-wide (`bind()` takes no take), the page owns
every pixel. This doc carries the *why* those don't: the gesture state
machine and the canvas draw order.

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
