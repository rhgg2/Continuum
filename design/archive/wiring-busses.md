# wiring busses — explicit rails for high-fan ports

> **Status: superseded & archived.** The v1 node-anchored rail model was replaced
> by the buss-node model in `wiring-busses-v2.md` (also archived); the living
> reference is `docs/wiringPage.md § Buss bars`. Kept for the starburst problem
> statement that motivated busses.
>
> Design note, pre-build. A *bus* renders a port's many edges as a bar with a
> comb of taps and one arrowed trunk, instead of a star of radial wires. It is
> an explicit, user-authored decoration on a node — never auto-detected, never
> part of the routing snapshot. This note fixes the v1 model and the creation
> gesture, and carves both cleanly from the deferred management affordance.

## The problem

A node that sums many sources onto one port — a mix bus, the master — draws as
a starburst: N radial edges crossing the whole canvas to one point. Importing a
non-Continuum mixdown produces exactly this at scale (≈60 nodes, one ≈30-way
sum hub). No viewport trick fixes a starburst; hyperbolic projection only bends
the rays. The mess is structural: too many edges sharing one endpoint, drawn as
independent lines.

A bus is the cheap, contained fix. It is what the user already reached for —
*"I'd take a literal buss over the starburst"* — and it isn't a visual trick: a
≈30-way sum node **is** a bus, and the starburst is the rendering lying about
what the node is. Draw a bus as a bus and the diagram tells the truth.

## Why explicit, not auto

The renderer could sniff high degree and rail it automatically. Rejected:

- **Intent, not guess.** A bus means a thing — drum bus, reverb send, master
  sum. The user declares it; a degree threshold only approximates it.
- **No flicker.** Auto-bus-at-degree-K reorganises the picture the moment you
  wire the Kth cable, and K is arbitrary. Explicit: it's a bus from its first
  edge because you said so.
- **Less code.** You build the rail rendering either way; explicit *deletes*
  the detection heuristic, the threshold, and the flicker handling.

## Why a bus and not a mixer

This thread nearly grew a whole apparatus — fold linear chains, layer the
graph, level-of-detail strips, a console dock with lift-to-edit. Each step was
locally reasonable; their sum was a mixing desk, reimplemented weirdly. That is
the tell to stop: **REAPER already ships a mixer** (the MCP), and it renders
consoles better than this page ever will. The wiring page's differentiated
value is the routing a console *can't* show — cross-track fx, parallel splits,
sidechains, merge/bracket bridges, feedback. That is what must stay excellent.

So the boundary: the page is **great** at non-console routing and merely
**survivable** at the console-shaped import (you'd open the MCP to actually mix
it). The bus is the one feature that buys survivability without building a
console. Everything else — fold, layer, dock, strips — waits until a
*Continuum-native* project actually hurts, and native routing accretes
incrementally and may never throw a 30-way star.

Discipline going forward: the DAG is the model; a bus is a *rendering* of a
port, never a surface you edit instead of the graph.

## The model

A bus is **port-scoped**, not node-scoped. Two independent multiplicities:

- **One bus, many taps** — one port with many edges (the sum hub). One comb.
- **One node, many busses** — many ports, each bussed. These stack on the
  node's sides.

A node carries a list, each entry bound to its port(s):

```
busses = {
  { dir='in',  ports={portRef…}, side='L'|'R'|'T'|'B' },  -- edges where node is `to`
  { dir='out', ports={portRef…}, side=… },                -- edges where node is `from`
  …
}
```

Direction is node-relative, read straight off `edge.from`/`edge.to` — there is
no "input edge" / "output edge" property, only which end *this* node is. An in
bus aggregates the edges where the node is `to`; an out bus, where it is `from`.

**Almost nothing is authored.** Only `dir`, `ports`, `side`. Everything else is
derived at render:

| quantity | derived from |
|---|---|
| orientation | `side` (rail ⟂ the side it sits on) |
| length | the span of its taps — grows/shrinks as edges are added/removed |
| distance from node | stack position among same-side busses |
| trunk lateral offset | stack position (so trunks don't share one entry point) |
| direction cue | the arrowed trunk (into node = in, out of node = out) |
| tap positions | the source heights |

Because length was never stored, add/remove grow and shrink the bar for free.

## Geometry

The rail is a bar on one side of the node. Edges meet it **orthogonally** — a
vertical rail wears horizontal taps like a comb's teeth. The many taps collapse
to **one trunk** from the rail to the node, and that single trunk carries the
arrowhead. The many-to-one collapse at the trunk *is* the decongestion:
N arrowed radial lines become N short taps plus one arrowed trunk.

Multiple busses on one side stack at increasing distance, each trunk entering
the node at a small lateral offset. Per-edge affordances (gain `fader`,
RMB-delete) live on each **tap**, since each tap is still its own edge; the
trunk is shared and carries only the arrow and the (deferred) reposition.

## Creation gesture

One motion unifies port choice and side choice:

1. `Add input bus` / `Add output bus` → a **port-selector overlay** surfaces the
   node's in/out ports as grabbable handles. Ports already bussed are **greyed
   and inert** — the overlay doubles as an "already done" map.
2. Press a port → starts a draft (the rail is now *for* that port).
3. Drag → the side is the **quadrant of the cursor from the node centre**
   (angle, not nearest-edge — forgiving at corners, continuous as you swing
   around). A **live comb preview** shows the real rail and re-routed taps, not
   a stub line — you see what you'll commit before releasing.
4. Release → creates, appended onto that side's stack.
5. Click the overlay backdrop (not a port) → cancels, nothing created.

The overlay is strictly for *adding*. A greyed port is inert, so repositioning
an existing bus is **not** done here — it lives on the trunk-click path
(deferred).

## Decoration & persistence

The `busses` list is pure decoration, orthogonal to routing — the same category
as `pos`. It never enters the routing snapshot; `read` reconstructs the graph
from REAPER and decoration is stamped back afterward. It persists in the central
node-decoration store, keyed exactly as positions are (rm id for source/master
nodes, FX GUID for fx nodes), in project ext state. See
`design/fx-metadata-spike.md` for why that store is the home.

## v1 scope vs deferred

**v1 builds:** the `busses` list in decoration; the `Add input/output bus`
overlay with greyed bussed ports; the draft-drag with quadrant side selection,
live comb preview, and click-away cancel; the render pass that, per bus, gathers
its port's edges and draws the orthogonal-tap comb, the auto-stacked rail, and
the one arrowed trunk. Busses append on create and auto-stack in creation order;
length, distance, and lateral offset are all derived.

**Deferred:** the sophisticated restack/reposition affordance — drag a bus to
re-rank it on its side, move it across sides, hand-tune distance and lateral
spread — and the trunk-click reposition flow. Park these until the auto-layout
has been lived with and its failures are known. v1 is enough to render the thing
and prove it reads better than the star.
