# wiringRender refactor — plan

> source: `design/wiring-render-refactor.md` — synthesis compiled from
> there; don't design here.

## Phases

1. **Phase 1 — One wire renderer** (§ Stage 1) — the formal `seg` shape and a
   single `drawWire`, with the draft wire and bus trunk folded into it.  ← in flight
2. **Phase 2 — The machine and the self-contained modes** (§ Stage 2 Data,
   § Relocation map) — the `gesture` variable with its inject/update/cancel
   table, and nodeDrag, band, tagDrag, busDrag, faderDrag moved into it verbatim.
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

- 2026-08-26 wiring: draw the bus trunk through drawWire (§ Stage 1)
- 2026-08-26 wiring: draw the draft wire through drawWire (§ Stage 1)
- 2026-08-26 wiring: give wires one renderer and name the seg shape (§ Stage 1)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

The design doc's line refs have drifted again — they run ~84 high across the
drawing half of the file. Numbers below are against the current tree
(`wiringRender.lua`, 2650 loc).

- **One tooltip helper.** `tooltipAt(sx, sy, text)` for the window-pos, chrome
  push and `BeginTooltip` body duplicated between `drawSlot` (@240–252) and
  `drawWireEndLabel` (@885–896). `nodeAtPoint` and `nodeUnderMouse` stay as
  they are; at one call site each, parameterising the bus-skip buys nothing.
