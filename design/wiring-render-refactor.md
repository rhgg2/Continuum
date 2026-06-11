# wiringRender refactor — one wire renderer, explicit gesture machine

Status: approved plan, ready to implement.
Target: `wiringRender.lua` only (2,528 loc). Line refs below are against
that file as of this writing; re-locate by the quoted comments if they
have drifted.

## Goal

Two structural complaints, one file:

1. **Wires must have exactly one renderer.** Today the line/arrow/label
   trio is emitted from three sites that can drift independently:
   `drawWiresPass` (@1036), `drawDraftWire` (@1158, hand-rolled line +
   arrow, no shared midpoint), and `drawBusPass` (@1418, hand-rolled
   trunk line + arrow + label).
2. **Gesture modes need a real state machine.** Seven nullable
   variables (`drag`, `band`, `wireDraft`, `tagDrag`, `busOverlay`,
   `busDraft`, `fader.dragging`) are documented as "at most one live at
   a time" but enforced by five hand-maintained guard chains
   (@1683, @1703, @1917, @1960, @2142), and each mode's
   arm/tick/commit/cancel is smeared across non-adjacent blocks of the
   700-line `renderCanvas`.

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
  drag overrides cached `nv.pos` in place (@1616), busDraft appends a
  synthetic bus to a *copy* of `nv.busses` and stamps `.bus` onto
  cached wireViews (@1633), tagDrag writes a transient `fromOffset`
  (@1664). All three deliberately feed the single geometry pass so
  preview and committed frames coincide (docs/wiringPage.md § Bus
  creation). Preserve the trick; just relocate it.

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

- Line + `drawWireArrow(p, sx, sy, ex, ey, name, seg.cx, seg.cy)`.
- When `opts.labels`: the per-end decision currently inline in
  `drawWiresPass` (@1049–1066) moves inside — label an end iff
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
   midpoint, and the kept end is overpainted by the node body anyway
   (z-order step 4). Labels off. Draw it in the same z slot (above
   sleeves, below nodes — @1782).
3. **Bus trunk** — `busSegments` already computes trunk endpoints
   (@1394–1399); store them as a seg (extents 0 both ends, cx/cy =
   midpoint, matching the explicit midpoint the current call passes).
   `drawBusPass` keeps the bar stroke and the trunk's *label* call —
   the trunk label is genuinely different placement (exitD 0, on the
   trunk near the node, `##bus/...` stem, shared `placed` set) so it
   stays an explicit `drawWireEndLabel` call — but its line + arrow go
   through `drawWire`.

### Small dedupes in the same pass

- Extract the verbatim-duplicated tooltip block (`SetNextWindowPos` +
  PopupBg push + `BeginTooltip` … pops) shared by `drawSlot`
  (@327–339) and `drawWireEndLabel` (@920–931) into one helper.
- `nodeAtPoint` (@1544) is character-identical to `nodeUnderMouse`
  (@1534) — delete one, keep the better name (`nodeAtPoint`, since the
  draft path probes an arbitrary point), update both call sites.

## Stage 2 — explicit gesture state machine

### Data

```lua
-- The one live gesture; nil = idle. Payload fields are today's per-mode
-- table contents, unchanged (shapes documented at the old decls @107–123).
local gesture = nil
-- gesture.mode ∈ 'nodeDrag' | 'band' | 'wireDraft' | 'tagDrag'
--              | 'busOverlay' | 'busDraft' | 'faderDrag'

-- modes[mode] = {
--   inject = fn(g, fr),  -- pre-geometry transients (runs before wireSegments)
--   update = fn(g, fr),  -- post-hover tick + mouseup commit; return false to clear
--   cancel = fn(g),      -- Esc, only for modes that bind it
-- }
```

`fr` (frame) carries what the blocks already close over: `p`, `lmx`,
`lmy`, `mx`, `my`, `overCanvas`, `shiftHeld`, `nodeViews`, `nodesById`,
`wireViewsList`, `segs`, `busRails`, plus per-frame hover results where
the update hooks need them (`targetHit`, `draftCx/draftCy`). Build it
incrementally — geometry fields get attached after the geometry pass.

`drag` is renamed `nodeDrag` (the only rename); all other mode names
keep their current variable names to minimise diff noise.

### Relocation map

Move each block verbatim into its mode handler; do not rewrite logic.

| Mode | arm (idle → mode) | inject (pre-geometry) | update (tick + mouseup) |
|---|---|---|---|
| nodeDrag | body-hit in mousedown chain @2054–2064 | pos override @1616–1622 | commit `moveNodes` @2122–2129 |
| band | empty-canvas mousedown @2066 | selection preview @1607–1612 | commit/clear selection @2130–2138 |
| wireDraft | shift-hover port @1966–2002; wire-end redraft @2005–2049; palette row drag @2333–2342 | — | decayed end @1736–1739 (feeds hover), commit ladder @2069–2111 |
| tagDrag | tag mousedown @2050–2052 | transient `fromOffset` @1664–1671 | commit `setSourceTagPos` @2112–2121 |
| busOverlay | `armBus` @1493–1504 (node menu) | layout + auto-clear @1657–1661 | click → busDraft / cancel @1947–1956 |
| busDraft | `armBus` single-port path; busOverlay handle click | synthetic bus + wire stamping @1633–1656 | commit/cancel @1934–1946 |
| faderDrag | arrow LMB @1830–1861; in-strip click @1875–1886 | — | poke-per-frame + release commit @1691–1701 |

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
  (@1782, @1790–1792) stay in the draw phase, gated on
  `gesture.mode == 'wireDraft'`.
- **band**: the band rect overlay (@2253–2258) is one stroke — keep it
  inline in the draw sequence, gated on the mode, rather than adding a
  draw hook to the machine for one user.
- **faderDrag vs the fader overlay**: split along the real seam. The
  `fader` table (edgeIdx, rect, hitRect, currentLin, valueAtClick,
  wheelPending, wheelIdleFrames) stays a plain file-local *overlay* —
  it coexists with idle hovering, and its open/keep/close logic
  (@1702–1732), wheel debounce (@1891–1912), double-click reset
  (@1865–1871) and draw (@1802) are overlay concerns, untouched. Only
  `fader.dragging` becomes `gesture = { mode = 'faderDrag' }`; the
  fader table drops its `dragging` flag.

### Guard rewrites

Each chain becomes `not gesture` plus its genuinely orthogonal axes:

- @1683 (wire-end + tag hover): `not gesture and not shiftHeld`
- @1703 (arrowMidHit): `not gesture and not shiftHeld`
- @1917 (double-click): `not gesture and not shiftHeld and not fader`
  (fader here is the *overlay* — visible fader swallows double-click)
- @1960 (LMB mousedown): `not gesture and not faderConsumed and not
  dblConsumed and overCanvas` — this is the idle→mode transition
  function; the precedence chain inside (shift-hover > wire-end > tag >
  body > band) stays one readable if/elseif.
- @2142 (RMB): `not gesture and overCanvas`

Frame ordering is load-bearing — preserve it: fader open/keep/close and
click handling run before the double-click check, which runs before the
LMB mousedown chain (`faderConsumed` / `dblConsumed` exist precisely to
sequence these). `overCanvas` gates press-*starts* only; mouseup
commits must run even off-canvas, as today.

### Esc and lifecycle

- Esc blocks @1821–1826 become `cancel` hooks for wireDraft,
  busOverlay, busDraft (busOverlay and busDraft both clear → simple
  `cancel = clear`). Keep the existing comment about the wiring-scope
  `wiringClearSelection` Esc binding and keep the check at the same
  point in the frame.
- `wr:closeTransients()` (@2371) simplifies: `gesture = nil` plus the
  existing hover/overlay resets (`shiftWas`, `listOpenId`, `sticky`,
  `engagedId`, `hoverFreeze`, `fader`, `wireMenu`).

### Explicitly NOT modes

Hover bookkeeping (`engagedId`, `listOpenId`, `pinned`, `sticky`,
`hoverFreeze`, `shiftWas`) and popup state (`wireMenu`, `nodeMenu`,
`fxPicker`, `paletteSource`) coexist with gestures and are cleared by
their own rules. Leave them as file-locals.

### Docs

Rewrite docs/wiringPage.md § "The gesture state machine" to describe
the explicit machine: the `gesture` variable, the mode list, the
inject/update/cancel phases, and the unchanged mousedown precedence.
The per-mode semantics prose (forbidden sets, decayed end, hoverFreeze,
pinning) is still accurate — keep it, re-anchored to the mode names.
Update the `--shape:` comment block at the old state decls.

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
   dedup @1758–1768)
6. draw passes in the documented z-order (docs/wiringPage.md § Canvas
   draw order — order is normative)
7. input: fader clicks, double-click, idle mousedown transition,
   `gesture update`, RMB dispatch
8. popups: extract `renderWireMenu` / `renderNodeMenu` — they share the
   anchor + chrome push + close-on-cursor-leave skeleton (@2160–2228),
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
- Bus: create via menu overlay and via single-port hover path; Esc and
  backdrop-click cancel both; rewire onto bar; remove bus; trunk port
  label correct for port ≠ 1.
- Source tags: drag star tag and bussed tag; default fan placement
  unchanged.
- Fader: triangle click (cursor warps to knob), in-strip click + drag,
  wheel coarse/fine + single undo entry, double-click to unity,
  close-on-leave.
- Node drag (single + selection), band select, empty-canvas click
  clears, double-click dives sampler / floats FX.
- RMB: triangle menu (primary toggle), node menu (delete/bus items),
  empty canvas FX picker; N-key picker; Esc at every gesture point.
