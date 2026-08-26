# wiringRender refactor — plan

> source: `design/wiring-render-refactor.md` — synthesis compiled from
> there; don't design here.

## Phases

1. **Phase 1 — One wire renderer** (§ Stage 1) — the formal `seg` shape and a
   single `drawWire`, with the draft wire and bus trunk folded into it.
   Landed 2026-08-26, 4 commits.
2. **Phase 2 — The machine and the self-contained modes** (§ Stage 2 Data,
   § Relocation map) — the `gesture` variable with its inject/update/cancel
   table, and nodeDrag, band, tagDrag, busDrag, faderDrag moved into it verbatim.
   ← in flight
3. **Phase 3 — The draft modes, guards and docs** (§ Stage 2 Relocation map,
   § Guard rewrites, § Esc and lifecycle, § Docs) — wireDraft and busDraft with
   their commit ladders, the five guard chains rewritten to `not gesture`,
   `closeTransients`, and docs/wiringPage.md.
4. **Phase 4 — Decompose renderCanvas** (§ Stage 3) — the eight named phases
   under ~150 lines of sequencing, plus `renderWireMenu` / `renderNodeMenu`.

## Standing constraints

- Behaviour-preserving throughout; when the faithful port and the nicer
  version differ, port faithfully and flag the niceness in the report.
- No renderer specs. Verification is the full suite green (load/syntax
  breakage) plus Richard walking the checklist at the foot of the design
  doc after every phase.
- Phases 2 and 3 are the design doc's single stage 2, split for context.
  Between them the guard chains read through one transitional helper
  (`local function busy() return gesture or wireDraft or busDraft end`),
  which phase 3 deletes. Nothing else straddles the seam.

## Landed  (newest first; prune below ~4)

- 2026-08-26 wiring: extract one tooltip helper (§ Stage 1)
- 2026-08-26 wiring: draw the bus trunk through drawWire (§ Stage 1)
- 2026-08-26 wiring: draw the draft wire through drawWire (§ Stage 1)
- 2026-08-26 wiring: give wires one renderer and name the seg shape (§ Stage 1)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

The design doc's stage-2 line refs are stale — they run 30–55 high. Numbers
below are against the current tree (`wiringRender.lua`, 2661 loc, with
`renderCanvas` at 1647).

1. **The `gesture` variable, its mode table, and nodeDrag + band inside it.**
   Add `local gesture = nil` beside the mode locals (@99–128) and a
   `modes[mode] = { inject, update, cancel }` table; `inject(g, fr)` runs
   before the geometry pass (where today's transient blocks sit, @1685–1755),
   `update(g, fr)` runs in the input if/elseif chain (@2186–2265) and returns
   false to clear the gesture. `fr` carries what those blocks close over —
   `p`, `lmx/lmy`, `nodeViews`, `nodesById`, `wireViewsList`, `busViewsList`,
   `segs`, `busRails`, plus the geometry-derived fields attached after the
   pass. A transitional `local function busy() return gesture or wireDraft or
   busDraft end` replaces the variable lists in the five guard chains (@1776,
   @1796, @2034, @2063, @2269); @1796 keeps its separate
   `not (fader and fader.dragging)` clause for now. `drag` becomes mode
   `nodeDrag` (arm @2176–2182, pos override @1694–1706, splice read
   @1768–1771, `moveNodes` commit @2246–2256); `band` becomes mode `band`
   (arm @2183, selection preview @1685–1692, commit @2257–2264), with the
   band rect overlay (@2387–2393) left inline, gated on the mode.
2. **tagDrag, busDrag and faderDrag into the machine.** tagDrag: transient
   `fromOffset` @1734–1743, arm @2164, `setSourceTagPos` commit @2229–2238.
   busDrag: live pos/ext @1745–1755, arm @2166–2171, `moveBus` commit
   @2239–2245. faderDrag carries no hooks — `fader.dragging` becomes
   `gesture = { mode = 'faderDrag' }` (armed @1990–2002 and at the arrow-LMB
   click), the fader table drops the flag, and the per-frame poke and release
   commit stay inline at @1782–1794 gated on the mode, since that block runs
   between the two hover passes and its result feeds both. @1796 then drops
   its fader clause into `busy()`. One behaviour change to flag: @1776 now
   suppresses wire-end and tag hover during a fader drag, where today it does
   not — @1823 already drops the fader's own wire end, so the difference is a
   neighbouring wire end highlighting under the strip.
