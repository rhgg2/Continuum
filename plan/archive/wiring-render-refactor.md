# wiringRender refactor — plan

> closed 2026-08-27. The model landed in `docs/wiringPage.md` and in the
> `--shape:` annotations of `wiringRender.lua`; this is the record of the
> work, not a live plan.

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
   Landed 2026-08-27, 7 commits.

## Standing constraints

- Behaviour-preserving throughout; when the faithful port and the nicer
  version differ, port faithfully and flag the niceness in the report.
- No renderer specs. Verification is the full suite green (load/syntax
  breakage) plus Richard walking the checklist after every phase (now
  `docs/wiringPage.md`).
- Phases 2 and 3 are the design doc's single stage 2, split for context.
  Between them the guard chains read through one transitional helper
  (`local function busy() return gesture or wireDraft or busDraft end`),
  which phase 3 deletes. Nothing else straddles the seam.

## Landed  (newest first; prune below ~4)

- 2026-08-27 wiring: extract the canvas popups and fix the N-key picker (§ Stage 3 ⑧)
- 2026-08-27 wiring: extract the gesture transition and RMB dispatch (§ Stage 3 ⑦)
- 2026-08-26 wiring: extract the fader input phase (§ Stage 3 ⑦)
- 2026-08-26 wiring: extract the canvas draw pass (§ Stage 3 (6))

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty)
