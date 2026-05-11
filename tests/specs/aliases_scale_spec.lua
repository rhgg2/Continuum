-- Phase 7: scale routes { ppqL = [mul k, add a*(1-k)], durL = [mul k] }
-- onto an aliased child's spec node so the child stays attached. Anchor
-- = selection anchor row (falls back to cursor row when no selection).
-- The add term is suppressed when zero, so anchor-at-row-0 leaves only
-- the mul. Selection is filtered through aliases.localRoots: a child
-- whose parent is also in the selection drops out, so the parent's
-- mutation re-derives it through the spec tree. See design/aliases.md.
--
-- Setup: rowPerBeat=4, resolution=240 → logPerRow=60. Anchor row r →
-- aLogical = r * 60.

local t = require('support')

local function rootByUuid(notes, uuid)
  for _, n in ipairs(notes) do if n.uuid == uuid then return n end end
end

local function byParent(list, uuid)
  local out = {}
  for _, e in ipairs(list) do
    if e.parentUuid == uuid then out[#out + 1] = e end
  end
  return out
end

local function noteCol(h, chan)
  for ci, c in ipairs(h.vm.grid.cols) do
    if c.type == 'note' and c.midiChan == chan then return ci end
  end
end

local function shortNote(extras)
  local n = { ppq = 0, endppq = 60, ppqL = 0, endppqL = 60,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
              lane = 1, rpb = 4, uuid = 1 }
  for k, v in pairs(extras or {}) do n[k] = v end
  return n
end

local CFG = { config = { take = { rowPerBeat = 4 } } }

return {
  --------------------------------------------------------------------
  -- Plain (non-aliased) root scaled by 2 around row 0: ppq and endppq
  -- doubled, no aliases metadata.
  --------------------------------------------------------------------
  {
    name = 'plain root, scale x2 at anchor=0: ppq and endppq doubled; no spec emitted',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{ ppq = 60, endppq = 120,
                                       ppqL = 60, endppqL = 120 } } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0)

      h.vm:scaleAll(2)

      local notes = h.fm:dump().notes
      t.eq(#notes, 1)
      t.eq(notes[1].ppq,    120)
      t.eq(notes[1].endppq, 240)
      t.eq(notes[1].aliases, nil, 'no spec on plain event')
    end,
  },

  --------------------------------------------------------------------
  -- Aliased child scaled at its own row: routing fires, both mul and
  -- add appended to ppqL, kid stays put (identity at anchor) but durL
  -- doubles. Selection is just the kid's row, so the root (row 0) is
  -- excluded from the scope and localRoots is a no-op here.
  --------------------------------------------------------------------
  {
    name = 'aliased child, anchor=own row: spec routing appends mul+add to ppqL, mul to durL; ppq unchanged, dur doubles',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 120}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      local nc = noteCol(h, 1)
      h.ec:setSelection{ row1 = 2, row2 = 2, col1 = nc, col2 = nc,
                         part1 = 'pitch', part2 = 'pitch' }

      h.vm:scaleSelection(2)

      local notes = h.fm:dump().notes
      local root  = rootByUuid(notes, 1)
      local spec  = root.aliases[1]
      t.deepEq(spec.xform.ppqL, {{'add', 120}, {'mul', 2}, {'add', -120}},
        'mul and add both appended (anchor=row 2, k=2 → addTerm=-120)')
      t.deepEq(spec.xform.durL, {{'mul', 2}}, 'durL has mul only — no translation')

      local kid = byParent(notes, 1)[1]
      t.eq(kid.ppq,    120, 'on-anchor child stays at row 2')
      t.eq(kid.endppq, 240, 'duration doubled: 120 + 60×2')
    end,
  },

  --------------------------------------------------------------------
  -- Two aliased kids, anchor at row 2; one ON anchor (stays put), one
  -- OFF anchor (scales toward). Both spec nodes get the same op list.
  --------------------------------------------------------------------
  {
    name = 'two aliased kids, anchor=2, k=0.5: on-anchor kid stays, off-anchor kid scales toward',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{
          aliasCtr = 3,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 120}}, pitch = {{'add', 1}} }, children = {} },
            { id = '2', xform = { ppqL = {{'add', 240}}, pitch = {{'add', 2}} }, children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      local nc = noteCol(h, 1)
      h.ec:setSelection{ row1 = 2, row2 = 4, col1 = nc, col2 = nc,
                         part1 = 'pitch', part2 = 'pitch' }

      h.vm:scaleSelection(1, 2)

      local notes = h.fm:dump().notes
      local root  = rootByUuid(notes, 1)
      t.deepEq(root.aliases[1].xform.ppqL,
        {{'add', 120}, {'mul', 0.5}, {'add', 60}},
        'on-anchor: aLogical*(1-0.5) = 60')
      t.deepEq(root.aliases[2].xform.ppqL,
        {{'add', 240}, {'mul', 0.5}, {'add', 60}})

      local kids = byParent(notes, 1)
      table.sort(kids, function(a, b) return a.ppq < b.ppq end)
      t.eq(kids[1].ppq, 120, 'on-anchor kid stays put')
      t.eq(kids[2].ppq, 180, 'off-anchor kid scaled toward (240 → 0.5*240 + 60)')
    end,
  },

  --------------------------------------------------------------------
  -- Coalescence: durL is a pure mul list (anchor-independent), so
  -- repeated scaling collapses mul·mul. ppqL keeps the add terms
  -- intact between muls (so it doesn't coalesce except at anchor=0,
  -- which isn't reachable here without the root in scope).
  --------------------------------------------------------------------
  {
    name = 'scale x2 twice with same anchor coalesces durL muls to mul 4',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 120}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      local nc = noteCol(h, 1)
      h.ec:setSelection{ row1 = 2, row2 = 2, col1 = nc, col2 = nc,
                         part1 = 'pitch', part2 = 'pitch' }

      h.vm:scaleSelection(2)
      h.vm:scaleSelection(2)

      local spec = rootByUuid(h.fm:dump().notes, 1).aliases[1]
      t.deepEq(spec.xform.durL, {{'mul', 4}},
        'durL muls collapse via coalescence (anchor-independent)')
    end,
  },

  --------------------------------------------------------------------
  -- Selection follow-up: span×k integer at the current rpb — selection
  -- reshapes around the anchor row, rpb unchanged.
  --------------------------------------------------------------------
  {
    name = 'span×k integer: selection reshapes around anchor; rpb unchanged',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{} } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      local nc = noteCol(h, 1)
      -- Anchor at row 2, cursor at row 6 — span = 4. k = 1/2 → new span = 2.
      h.ec:setSelection{ row1 = 2, row2 = 6, col1 = nc, col2 = nc,
                         part1 = 'pitch', part2 = 'pitch' }

      h.vm:scaleSelection(1, 2)

      local r1, r2 = h.ec:region()
      t.eq(r1, 2, 'anchor row preserved')
      t.eq(r2, 4, 'cursor row scaled to anchor + span/2')
      t.eq(h.cm:get('rowPerBeat'), 4, 'rpb unchanged')
    end,
  },

  --------------------------------------------------------------------
  -- Selection follow-up: span×k non-integer — rpb is multiplied by the
  -- reduced denominator so the new geometry lands on integer rows.
  --------------------------------------------------------------------
  {
    name = 'span×k non-integer: rpb refined by reduced denom; selection lands on integer rows',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{} } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      local nc = noteCol(h, 1)
      -- Anchor row 2, cursor row 6: span = 4. k = 1/3 → newSpan = 4/3 (non-int).
      -- Bump rpb 4 → 12. anchor: 2*3 = 6. cursor: 6 + 1*4 = 10.
      h.ec:setSelection{ row1 = 2, row2 = 6, col1 = nc, col2 = nc,
                         part1 = 'pitch', part2 = 'pitch' }

      h.vm:scaleSelection(1, 3)

      t.eq(h.cm:get('rowPerBeat'), 12, 'rpb multiplied by reduced denom 3')
      local r1, r2 = h.ec:region()
      t.eq(r1, 6,  'anchor row scaled: 2 × 3')
      t.eq(r2, 10, 'cursor row: anchor + p×span = 6 + 1×4')
    end,
  },

  --------------------------------------------------------------------
  -- Reduction in lowest terms: scale by 2/4 means q=2, not q=4. With
  -- span = 2, span%q = 0, so no rpb bump and selection reshapes in place.
  --------------------------------------------------------------------
  {
    name = 'kNum/kDen reduced before rpb math: 2/4 acts like 1/2',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{} } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      local nc = noteCol(h, 1)
      h.ec:setSelection{ row1 = 0, row2 = 4, col1 = nc, col2 = nc,
                         part1 = 'pitch', part2 = 'pitch' }

      h.vm:scaleSelection(2, 4)

      t.eq(h.cm:get('rowPerBeat'), 4, 'rpb unchanged — 2/4 reduces to 1/2 (q=2 divides span=4)')
      local r1, r2 = h.ec:region()
      t.eq(r1, 0); t.eq(r2, 2)
    end,
  },

  --------------------------------------------------------------------
  -- Refusal: rpb*q would exceed the cap (32) — selection unchanged,
  -- rpb unchanged, geometry silently slips. The ops still apply.
  --------------------------------------------------------------------
  {
    name = 'rpb cap exceeded: refinement refused; selection and rpb unchanged',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{} } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      h.cm:set('take', 'rowPerBeat', 16)   -- pre-bump so 16 × 3 = 48 > 32 cap
      local nc = noteCol(h, 1)
      h.ec:setSelection{ row1 = 4, row2 = 12, col1 = nc, col2 = nc,
                         part1 = 'pitch', part2 = 'pitch' }

      h.vm:scaleSelection(1, 3)   -- q=3, span=8, span%3 ≠ 0; 16×3 = 48 > 32

      t.eq(h.cm:get('rowPerBeat'), 16, 'rpb unchanged — refinement refused')
      local r1, r2 = h.ec:region()
      t.eq(r1, 4);  t.eq(r2, 12, 'selection unchanged on refusal')
    end,
  },

  --------------------------------------------------------------------
  -- localRoots invariant: when the selection contains both a root and
  -- its aliased child, only the root is scaled. The child is filtered
  -- out — the root's mutation re-derives it via the spec tree, so
  -- touching both would double-mutate. The spec node is left alone.
  --------------------------------------------------------------------
  {
    name = 'selection contains root and child: child filtered, spec untouched, root scales as plain',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 120}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      local nc = noteCol(h, 1)
      h.ec:setSelection{ row1 = 0, row2 = 2, col1 = nc, col2 = nc,
                         part1 = 'pitch', part2 = 'pitch' }

      h.vm:scaleSelection(2)

      local notes = h.fm:dump().notes
      local root  = rootByUuid(notes, 1)
      t.deepEq(root.aliases[1].xform.ppqL, {{'add', 120}},
        'spec ppqL unchanged — child filtered before routing')
      t.eq(root.aliases[1].xform.durL, nil,
        'spec durL untouched — child filtered before routing')
      t.eq(root.endppqL, 120, 'root scaled via plain path (60 → 120)')
    end,
  },
}
