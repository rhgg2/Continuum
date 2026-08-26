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
   Landed 2026-08-26, 2 commits.
3. **Phase 3 — The draft modes, guards and docs** (§ Stage 2 Relocation map,
   § Guard rewrites, § Esc and lifecycle, § Docs) — wireDraft and busDraft with
   their commit ladders, the five guard chains rewritten to `not gesture`,
   `closeTransients`, and docs/wiringPage.md. Landed 2026-08-26, 3 commits.
4. **Phase 4 — Decompose renderCanvas** (§ Stage 3) — the eight named phases
   under ~150 lines of sequencing, plus `renderWireMenu` / `renderNodeMenu`.
   ← in flight

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

- 2026-08-26 wiring: extract the canvas draw pass (§ Stage 3 (6))
- 2026-08-26 wiring: extract the hover resolution phase (§ Stage 3 ⑤)
- 2026-08-26 wiring: extract the frame carrier and the head phases (§ Stage 3 (1)-(4))
- 2026-08-26 wiring: document the gesture state machine (§ Docs)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)
4. **Fader input** (§ Stage 3 ⑦) — `faderInput(frame)` @2085–2169: the
   triangle LMB open with the OS cursor warp, the double-click unity reset,
   the in-strip click, and the wheel debounce; it returns `faderConsumed` for
   the mousedown gate. The Esc dispatch @2078–2083 stays in the sequencing.
5. **The gesture transition and RMB** (§ Stage 3 ⑦) — `beginGesture(frame)`
   @2189–2319: the idle→mode precedence chain (badge > shift-hover >
   wire-end > tag > bar > body > band) with the `gesture update` dispatch on
   its else arm, plus the double-click dive @2171–2187 and
   `rmbDispatch(frame)` @2321–2339.
6. **The popups** (§ Stage 3 ⑧) — `renderWireMenu(frame)` and
   `renderNodeMenu(frame)` @2341–2415, and the fx-picker shell @2417–2437 if
   the shared skeleton covers it: one helper taking a body callback if the
   anchor + chrome push + close-on-cursor-leave parameterises cleanly, two
   siblings if not. This is the item that lands renderCanvas at its ~150-line
   sequencing target.
