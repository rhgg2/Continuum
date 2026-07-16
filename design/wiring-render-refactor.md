# wiringRender refactor — one wire renderer, explicit gesture machine

Status: approved plan, ready to implement.
Target: `wiringRender.lua` only (2,687 loc). Line refs below were
re-grounded against the current file (sha 217c1f8) on 2026-07-16; if
they drift again, re-locate by the quoted comments.

## Goal

Two structural complaints, one file:

1. **Wires must have exactly one renderer.** Today the line/arrow/label
   trio is emitted from three sites that can drift independently:
   `drawWiresPass` (@1086), `drawDraftWire` (@1211, hand-rolled line +
   arrow, no shared midpoint), and `drawBusPass` (@1506, hand-rolled
   trunk line + arrow + label).
2. **Gesture modes need a real state machine.** Seven nullable
   variables (`drag`, `band`, `wireDraft`, `tagDrag`, `busDraft`,
   `busDrag`, `fader.dragging`) are documented as "at most one live at
   a time" but enforced by five hand-maintained guard chains
   (@1820, @1840, @2067, @2096, @2299), and each mode's
   arm/tick/commit/cancel is smeared across non-adjacent blocks of the
   730-line `renderCanvas`.

## Non-goals / ground rules

- **Behaviour-preserving throughout.** No visual or interaction change,
  however small, unless this doc explicitly calls it out. When the
  faithful port and the "nicer" version differ, port faithfully and
  flag the niceness as a comment in your final report, not in code.
- No spec covers this file (only `gm_wiring_spec` exists, which is
  groupManager's). Verification = full suite green after every stage
  (`mcp__readium_tests__lua_test_run` — catches syntax/load breakage)
  plus Richard manually exercising the page (checklist at the bottom).
  Do not write renderer specs as part of this work.
- Three stages, each independently landable. Stop after each stage,
  run the suite, and nag Richard to commit before starting the next.
- Repo style applies (CLAUDE.md): closures-over-state, `local fn do
  ... end` scoping, `----- Name` banners, comments only for WHY,
  ≤2 lines inline. `.map` files regenerate via the post-edit hook —
  never hand-edit them.
- Existing transient-mutation tricks are load-bearing, not bugs: node
  drag overrides cached `nv.pos` in place (@1748), busDraft appends a
  synthetic `@busDraft` busView to the (already fresh) busViews list
  and stamps `.bus` onto cached wireViews (@1765), tagDrag writes a
  transient `fromOffset` (@1788). All three deliberately feed the
  single geometry pass so preview and committed frames coincide
  (docs/wiringPage.md § Bus creation). Preserve the trick; just
  relocate it.

## Stage 1 — one wire renderer

`segs` already unifies more than it looks: star wires
(`wireSegments`), source stubs (`sourceSegments`), and bus taps
(`busSegments`) all write the same seg shape into one table that
`drawWiresPass` draws. Formalise that shape and give it exactly one
draw function; fold the two outliers (draft wire, bus trunk) into it.

### The seg shape

```lua
--shape: seg = { w?, sx, sy, ex, ey, offX?, offY?, fromHW?, fromHH?, toHW?, toHH?, cx, cy }
--   extents nil → trim at node body (wireExits default); 0 → bare point (bar end,
--   draft ends); w nil → synthetic seg (draft wire, bus trunk) — never labelled.
```

### The renderer

```lua
local function drawWire(p, seg, opts)
  -- opts = { name, labels?, placed?, idStem? }
  -- line (WIRE_THICK) + arrow centred on seg.cx/cy + per-end port labels
end
```

- Line + `drawWireArrow(p, sx, sy, ex, ey, name, seg.cx, seg.cy,
  barTip)`, where `barTip = seg.w ~= nil and seg.toHW == 0 and seg.toHH
  == 0`. **The `seg.w ~= nil` guard is load-bearing.** `drawWiresPass`
  today clamps the arrow onto a bar via `toHW == 0 and toHH == 0`
  (@1100–1101), but the draft wire (@1226) and bus trunk (@1513) draw
  their arrow *unclamped*. Both synthetic segs get extents 0 at both
  ends (below), so an extents-only `barTip` would newly clamp them and
  shift the arrow ~1–2px. Gating on `seg.w` — nil for every synthetic
  seg — keeps the draft and trunk arrows exactly where they are today.
- When `opts.labels`: the per-end decision currently inline in
  `drawWiresPass` (@1102–1119) moves inside — label an end iff
  `w.type == 'audio'`, port ≠ 1, and that end is not the wire's bussed
  end (`w.bus.bussedEnd`). Keep the `exitD` / `segLen - toD` arithmetic
  and the `##wire/...` id stem exactly as-is.

### Call-site conversions

1. **`drawWiresPass`** becomes a thin loop: skip `opts.skipEdgeIdx`
   (the redrafted wire — keep this), derive `name` from `w.type`, call
   `drawWire` with labels on and the shared `placed` set.
2. **Draft wire** — delete `drawDraftWire`. Build a transient seg per
   frame: ends ordered by `draft.cursorEnd` (kept end at `keptAnchor`,
   falling back to the kept node's centre; cursor end at the decayed
   `draftCx/draftCy`), **extents 0 at both ends, cx/cy = geometric
   midpoint of the full segment**. That reproduces today's pixels
   exactly: the current draft draws untrimmed with the arrow at the raw
   midpoint (drawWireArrow with no cx/cy → `(sx+ex)/2`), and the kept
   end is overpainted by the node body anyway (z-order step 4). Labels
   off, `w == nil` so the barTip clamp never fires. Draw it in the same
   z slot (above sleeves, below nodes — @1926).
3. **Bus trunk** — `busSegments` already computes trunk endpoints
   (@1467–1475, stored on the rail @1491–1499); store them as a seg
   (extents 0 both ends, cx/cy = midpoint, matching the explicit
   midpoint the current call passes, and `w == nil` so no clamp).
   `drawBusPass` keeps the bar stroke and the trunk's *label* call —
   the trunk label is genuinely different placement (exitD 0, on the
   trunk near the node, `##bus/...` stem, shared `placed` set) so it
   stays an explicit `drawWireEndLabel` call (@1516–1522) — but its
   line + arrow go through `drawWire`.

### Small dedupes in the same pass

- Extract the verbatim-duplicated tooltip block (`SetNextWindowPos` +
  PopupBg push + `BeginTooltip` … pops) shared by `drawSlot`
  (@324–336) and `drawWireEndLabel` (@969–980) into one helper. Only
  the anchor position and the text differ, so `tooltipAt(sx, sy, text)`
  captures the shared body.
- `nodeAtPoint` (@1676) and `nodeUnderMouse` (@1666) are **not**
  identical any more — `nodeUnderMouse` skips bus-category nodes
  (`nv.category ~= 'bus'`), `nodeAtPoint` does not, and the mousedown
  chain relies on the difference (@2199–2200: "a real node under a bar
  still wins"). Do not merge them. If the duplication still grates,
  parameterise the bus-skip (`nodeAtPoint(nvs, x, y, skipBus)`) rather
  than collapsing the two behaviours into one.

## Stage 2 — explicit gesture state machine

### Data

```lua
-- The one live gesture; nil = idle. Payload fields are today's per-mode
-- table contents, unchanged (shapes documented at the old decls @104–109).
local gesture = nil
-- gesture.mode ∈ 'nodeDrag' | 'band' | 'wireDraft' | 'tagDrag'
--              | 'busDraft' | 'busDrag' | 'faderDrag'

-- modes[mode] = {
--   inject = fn(g, fr),  -- pre-geometry transients (runs before wireSegments)
--   update = fn(g, fr),  -- post-hover tick + mouseup commit; return false to clear
--   cancel = fn(g),      -- Esc, only for modes that bind it
-- }
```

`fr` (frame) carries what the blocks already close over: `p`, `lmx`,
`lmy`, `mx`, `my`, `overCanvas`, `shiftHeld`, `nodeViews`, `nodesById`,
`wireViewsList`, `busViewsList`, `segs`, `busRails`, plus per-frame
hover results where the update hooks need them (`targetHit`,
`draftCx/draftCy`). Build it incrementally — geometry fields get
attached after the geometry pass.

`drag` is renamed `nodeDrag` (the only rename); all other mode names
keep their current variable names to minimise diff noise.

### Relocation map

Move each block verbatim into its mode handler; do not rewrite logic.

| Mode | arm (idle → mode) | inject (pre-geometry) | update (tick + mouseup) |
|---|---|---|---|
| nodeDrag | body-hit in mousedown chain @2205–2214 | pos override @1748–1754 | commit `moveNodes` @2279–2286 |
| band | empty-canvas mousedown @2216 | selection preview @1740–1744 | commit/clear selection @2287–2295 |
| wireDraft | shift-hover source @2109–2147; wire-end redraft @2150–2194; palette row drag (in `renderPalette`) | — | decayed end @1873–1876 (feeds hover), commit ladder @2219–2261 |
| tagDrag | tag mousedown @2195–2197 | transient `fromOffset` @1788–1795 | commit `setSourceTagPos` @2262–2271 |
| busDraft | node-menu `Selectable` @2372 | synthetic busView + wire stamping @1765–1785 | Esc @1974–1975; click-drop `insertBus` @2085–2092 |
| busDrag | bar grab `makeBusDrag` @2202–2204 | live pos/ext @1798–1806 | mouseup commit `moveBus` @2272–2278 |
| faderDrag | arrow LMB @1980–2011; in-strip click @2025–2036 | — | poke-per-frame + release commit @1828–1838 |

Notes per mode:

- **wireDraft**: the palette arm lives in `renderPalette`, outside
  `renderCanvas` — `gesture` is file-scope, so the palette sets it
  directly, exactly as it sets `wireDraft` today. The commit ladder's
  subtleties must survive intact: `fromPalette` counts as moved;
  CLICK_THRESH click-vs-drag split; `sameAsOrigin` no-op (no undo
  burn); empty-canvas delete judged by the *decayed end*
  (`nodeAtPoint`), not the cursor; `hoverFreeze` set only on moved
  drops; click-without-drag on a list row pins the chip + sets
  `sticky`. The draft draw call and the palette floating tag
  (@1926, @1936–1938) stay in the draw phase, gated on
  `gesture.mode == 'wireDraft'`.
- **band**: the band rect overlay (@2416–2423) is one stroke — keep it
  inline in the draw sequence, gated on the mode, rather than adding a
  draw hook to the machine for one user.
- **bus is two modes, not the old `busOverlay`/`armBus` pair** — the
  doc predated a rewrite, and neither `busOverlay` nor `armBus` exists
  in the current file. The two real bus gestures are:
  - **busDraft** (node-menu creation): a menu `Selectable` (@2372)
    arms it; its `inject` glues a synthetic `@busDraft` busView to the
    cursor and stamps `.bus` onto the wires the claimed port owns
    (@1765–1785); it commits on the next left click via `wv:insertBus`
    (@2085–2092) or cancels on Esc (@1974–1975).
  - **busDrag** (bar move/resize): grabbing a bar arms `makeBusDrag`
    (@2202–2204); its `inject` feeds the in-flight pos+ext into the
    geometry pass (@1798–1806, mirroring tagDrag); mouseup commits
    `wv:moveBus` past CLICK_THRESH (@2272–2278).

  They are independent gestures — do not fold either into the other,
  and note that in the mousedown chain the bar grab (@2202) only fires
  when no real node is under the cursor (`nodeUnderMouse` skips busses).
- **faderDrag vs the fader overlay**: split along the real seam. The
  `fader` table (edgeIdx, rect, hitRect, currentLin, valueAtClick,
  wheelPending, wheelIdleFrames) stays a plain file-local *overlay* —
  it coexists with idle hovering, and its open/keep/close logic
  (@1845–1869), wheel debounce (@2039–2062), double-click reset
  (@2013–2021) and draw (@1952) are overlay concerns, untouched. Only
  `fader.dragging` becomes `gesture = { mode = 'faderDrag' }`; the
  fader table drops its `dragging` flag.

### Guard rewrites

Each chain becomes `not gesture` plus its genuinely orthogonal axes:

- @1820 (wire-end + tag hover): `not gesture and not shiftHeld`
- @1840 (arrowMidHit): `not gesture and not shiftHeld` (the old chain's
  `not (fader and fader.dragging)` folds in — faderDrag is a gesture now)
- @2067 (double-click): `not gesture and not shiftHeld and not fader
  and overCanvas` (fader here is the *overlay* — a visible fader
  swallows double-click)
- @2096 (LMB mousedown): `not gesture and not faderConsumed and not
  dblConsumed and overCanvas` — this is the idle→mode transition
  function; the precedence chain inside (badge > shift-hover source >
  wire-end redraft > tag > bar → busDrag / body → nodeDrag > band)
  stays one readable if/elseif.
- @2299 (RMB): `not gesture and overCanvas`

Frame ordering is load-bearing — preserve it: fader open/keep/close and
click handling run before the double-click check, which runs before the
LMB mousedown chain (`faderConsumed` / `dblConsumed` exist precisely to
sequence these). `overCanvas` gates press-*starts* only; mouseup
commits must run even off-canvas, as today.

### Esc and lifecycle

- Esc blocks @1969–1976 become `cancel` hooks. Only two modes bind Esc
  today: wireDraft (@1971–1972) and busDraft (@1974–1975), both a
  simple `cancel = clear`. busDrag has no Esc binding — don't invent
  one. Keep the existing comment about the wiring-scope
  `wiringClearSelection` Esc binding and keep the check at the same
  point in the frame.
- `wr:closeTransients()` (@2525–2528) simplifies to `gesture = nil`
  plus the existing hover/overlay resets (`shiftWas`, `listOpenId`,
  `sticky`, `engagedId`, `hoverFreeze`, `fader`, `wireMenu`). Flag one
  real behaviour change rather than hide it: closeTransients today
  clears `busDrag` but *not* `busDraft` (@2526), so `gesture = nil`
  will now also drop an in-flight busDraft on unbind. That is almost
  certainly correct (a half-placed bus bar shouldn't survive a page
  switch), but it is a change — call it out in the final report.

### Explicitly NOT modes

Hover bookkeeping (`engagedId`, `listOpenId`, `pinned`, `sticky`,
`hoverFreeze`, `shiftWas`) and popup state (`wireMenu`, `nodeMenu`,
`fxPicker`, `paletteSource`) coexist with gestures and are cleared by
their own rules. Leave them as file-locals.

### Docs

Rewrite docs/wiringPage.md § "The gesture state machine" to describe
the explicit machine: the `gesture` variable, the mode list (including
the busDraft/busDrag split), the inject/update/cancel phases, and the
unchanged mousedown precedence. The per-mode semantics prose (forbidden
sets, decayed end, hoverFreeze, pinning) is still accurate — keep it,
re-anchored to the mode names. Update the `--shape:` comment block at
the old state decls (@104–120).

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
   dedup @1896–1906)
6. draw passes in the documented z-order (docs/wiringPage.md § Canvas
   draw order — order is normative)
7. input: fader clicks, double-click, idle mousedown transition,
   `gesture update`, RMB dispatch
8. popups: extract `renderWireMenu` / `renderNodeMenu` — they share the
   anchor + chrome push + close-on-cursor-leave skeleton (@2319–2392),
   so one parameterised popup helper taking a body callback is right
   if it falls out cleanly; two siblings are acceptable if the
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
