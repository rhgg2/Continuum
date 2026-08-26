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
   `closeTransients`, and docs/wiringPage.md. ← in flight
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

- 2026-08-26 wiring: move the tag, bus and fader drags into the machine (§ Stage 2)
- 2026-08-26 wiring: give gestures one state machine, with nodeDrag and band (§ Stage 2)
- 2026-08-26 wiring: extract one tooltip helper (§ Stage 1)
- 2026-08-26 wiring: draw the bus trunk through drawWire (§ Stage 1)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **wireDraft into the machine** (§ Stage 2 Relocation map, § Esc) —
   `modes.wireDraft`, armed by the three sites that set `wireDraft` today:
   shift-hover source @2222, wire-end redraft @2192, palette row drag @2507.
   `update` is the commit ladder @2266–2308 verbatim — `fromPalette` counts as
   moved, CLICK_THRESH click/drag split, `sameAsOrigin` no-op with no undo
   burn, empty-canvas delete judged by `nodeAtPoint` on the decayed end,
   `hoverFreeze` on moved drops only, list-row click pins the chip and sets
   `sticky`. `cancel` is the clear at the Esc block @2019. The decayed end
   @1911, the drop-target hover @1918 and the draft draw with the palette
   floating tag @1970–1985 stay where they are, gated on the mode; `frame`
   carries `draftCx` / `draftCy` / `targetHit`.
2. **busDraft into the machine, and `busy()` retired** (§ Stage 2 Relocation
   map, § Guard rewrites, § Esc and lifecycle) — `modes.busDraft`, armed by the
   node-menu `Selectable` @2387, with the synthetic `@busDraft` busView and
   wire stamping @1808–1826 as `inject`, the click-drop `wv:insertBus` @2132 as
   `update`, and the Esc clear @2022 as `cancel`. With both drafts inside, the
   five guard chains @1860, @1879, @2115, @2143, @2316 become `not gesture`
   plus their orthogonal axes, `busy()` goes, and `closeTransients` @2541
   collapses to `gesture = nil` — which now also drops an in-flight busDraft on
   unbind, so report the change.
3. **Document the machine** (§ Docs) — rewrite docs/wiringPage.md § The gesture
   state machine around the `gesture` variable, the seven modes with the
   busDraft / busDrag split, the inject / update / cancel phases and the
   unchanged mousedown precedence, keeping the per-mode semantics prose
   re-anchored to mode names. Refresh the `--shape:` block at the state decls
   @99–105.
