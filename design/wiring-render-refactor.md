# wiringRender refactor — one wire renderer, explicit gesture machine

> opened: 2026-06-12 · status: in flight — plan/wiring-render-refactor.md,
> phase 4 (decompose renderCanvas)

Target: `wiringRender.lua` only (2,715 loc). The line refs below have
drifted; the live numbers for the phase in flight are in
plan/wiring-render-refactor.md § Queued, and anything else re-locates by
the quoted comments.

## Goal

Two structural complaints, one file:

1. **Wires must have exactly one renderer.** The line/arrow/label trio was
   emitted from three sites that could drift independently: the wire pass,
   the draft wire, and the buss trunk.
2. **Gesture modes need a real state machine.** Seven nullable variables
   (`drag`, `band`, `wireDraft`, `tagDrag`, `busDraft`, `busDrag`,
   `fader.dragging`) were documented as "at most one live at a time" but
   enforced by five hand-maintained guard chains, and each mode's
   arm/tick/commit/cancel was smeared across non-adjacent blocks of the
   730-line `renderCanvas`.

## Non-goals / ground rules

- **Behaviour-preserving throughout.** No visual or interaction change,
  however small, unless this doc explicitly calls it out. When the
  faithful port and the "nicer" version differ, port faithfully and
  flag the niceness as a comment in your final report, not in code.
- No spec covers this file (only `gm_wiring_spec` exists, which is
  groupManager's). Verification = full suite green after every stage
  (`mcp__continuum_tests__lua_test_run` — catches syntax/load breakage)
  plus Richard manually exercising the page (checklist at the bottom).
  Do not write renderer specs as part of this work.
- Three stages, each independently landable. Stop after each stage,
  run the suite, and nag Richard to commit before starting the next.
- Repo style applies (CLAUDE.md): closures-over-state, `local fn do
  ... end` scoping, `----- Name` banners, comments only for WHY,
  ≤2 lines inline. `.map` files regenerate via the post-edit hook —
  never hand-edit them.
- Existing transient-mutation tricks are load-bearing, not bugs: node
  drag overrides cached `nv.pos` in place, busDraft appends a synthetic
  `@busDraft` busView and stamps `.bus` onto cached wireViews, tagDrag
  writes a transient `fromOffset` — the three `inject` hooks. All three
  deliberately feed the single geometry pass so preview and committed
  frames coincide (docs/wiringPage.md § Buss gestures). Preserve the
  trick; just relocate it.

## Stage 1 — one wire renderer

Landed 2026-08-26 in four commits; the model is now
docs/wiringPage.md § Canvas draw order, and the seg shape is the
`--shape:` annotation above `wireSegments`.

## Stage 2 — explicit gesture state machine

Landed 2026-08-26 in five commits; the model is now docs/wiringPage.md
§ The gesture state machine, and each mode's payload shape sits at its
entry in the `modes` table.

## Stage 3 — decompose renderCanvas

Falls out of stage 2. Target: `renderCanvas` under ~150 lines of
sequencing, phases named in order:

1. frame state (origin, painter, mouse, shift edge, hoverFreeze decay)
2. view gather (nodeViews sans sources, selection, nodesById)
3. `gesture inject` (machine hook)
4. geometry: `wireSegments` / `sourceSegments` / `busSegments` +
   midpoint stamp
5. hover resolution (wireEndHover, tagHover, arrowHitIdx, fader
   keep/close, sourceHit/targetHit/stickyHit/draftSourceHit, overlay
   dedup)
6. draw passes in the documented z-order (docs/wiringPage.md § Canvas
   draw order — order is normative)
7. input: fader clicks, double-click, idle mousedown transition,
   `gesture update`, RMB dispatch
8. popups: extract `renderWireMenu` / `renderNodeMenu` — they share the
   anchor + chrome push + close-on-cursor-leave skeleton, so one
   parameterised popup helper taking a body callback is right if it
   falls out cleanly; two siblings are acceptable if the
   parameterisation gets awkward.

## Manual verification checklist (Richard, per stage)

- Wire create: shift-hover body/chip/keyboard/list-row, drag to
  body/chip/keyboard, cycle-blocked target gives no affordance.
- Redraft both ends; drop on empty canvas deletes; drop on original
  target is a no-op (no undo entry); short-click on wire end does
  nothing destructive.
- Palette: row drag → floating tag → drop (audio + midi); add/del
  source.
- Bus: create via node menu (busDraft) and via single-port hover path;
  Esc and backdrop-click cancel both; move/resize a bar (busDrag);
  rewire onto bar; remove bus; trunk port label correct for port ≠ 1.
- Source tags: drag star tag and bussed tag; default fan placement
  unchanged.
- Fader: triangle click (cursor warps to knob), in-strip click + drag,
  wheel coarse/fine + single undo entry, double-click to unity,
  close-on-leave.
- Node drag (single + selection), band select, empty-canvas click
  clears, double-click dives sampler / floats FX.
- RMB: triangle menu (primary toggle), node menu (delete/bus items),
  empty canvas FX picker; N-key picker; Esc at every gesture point.
