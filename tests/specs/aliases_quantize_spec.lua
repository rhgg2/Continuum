-- Phase 7: quantize routes a relative {'snap', step} op onto an aliased
-- child's spec node so the child stays attached; quantizeKeepRealised
-- still severs (delay-absorption is per-emit, not in the spec). See
-- design/aliases.md §Mutation.
--
-- Setup: rowPerBeat=4, resolution=240 → logPerRow=60. shortNote keeps
-- successive children's tails out of each other's onsets so the lane
-- allocator doesn't drag a planned successor forward via conformOverlaps'
-- residual logical overlap (see prior incident note in git history).

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

local function rootNote(extras)
  local n = { ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
              lane = 1, rpb = 4, uuid = 1 }
  for k, v in pairs(extras or {}) do n[k] = v end
  return n
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
  -- Aliased child off-grid: quantize appends {'snap', 60} to ppqL
  -- (and durL on a note) and the child stays attached. Spec keeps the
  -- node; resolved ppq lands on the snapped grid.
  --------------------------------------------------------------------
  {
    name = 'quantize on an off-grid aliased child appends snap and keeps it attached',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 250}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)

      local kid = byParent(h.fm:dump().notes, 1)[1]
      t.truthy(kid); t.eq(kid.ppq, 250); t.eq(kid.pitch, 61)

      h.vm:quantizeAll()

      local notes   = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.eq(#oldRoot.aliases, 1, 'spec node stays in tree')
      local spec = oldRoot.aliases[1]
      t.deepEq(spec.xform.ppqL, {{'add', 250}, {'snap', 60}})
      t.deepEq(spec.xform.durL, {{'snap', 60}})

      local kid2 = byParent(notes, 1)[1]
      t.truthy(kid2, 'child still aliased')
      t.eq(kid2.ppq,    240, 'resolves to snapped row 4')
      t.eq(kid2.pitch,   61, 'pitch preserved')
      t.deepEq(h.tm:specPathOf(kid2), {1})
    end,
  },

  --------------------------------------------------------------------
  -- Two aliased children of one root: both append snap, both stay
  -- attached, both resolve to their snapped grid positions.
  --------------------------------------------------------------------
  {
    name = 'quantize on two aliased children: both append snap, both stay attached',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{
          aliasCtr = 3,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 250}}, pitch = {{'add', 1}} }, children = {} },
            { id = '2', xform = { ppqL = {{'add', 290}}, pitch = {{'add', 2}} }, children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      t.eq(#byParent(h.fm:dump().notes, 1), 2)

      h.vm:quantizeAll()

      local notes   = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.eq(#oldRoot.aliases, 2, 'both spec nodes still present')
      t.deepEq(oldRoot.aliases[1].xform.ppqL, {{'add', 250}, {'snap', 60}})
      t.deepEq(oldRoot.aliases[2].xform.ppqL, {{'add', 290}, {'snap', 60}})

      local kids = byParent(notes, 1)
      table.sort(kids, function(a, b) return a.ppq < b.ppq end)
      t.eq(#kids, 2)
      t.eq(kids[1].ppq, 240); t.eq(kids[1].pitch, 61)
      t.eq(kids[2].ppq, 300); t.eq(kids[2].pitch, 62)
    end,
  },

  --------------------------------------------------------------------
  -- On-grid aliased child gets no snap appended (no plan); off-grid
  -- sibling does. Proves the "changed" gate on plan emission.
  --------------------------------------------------------------------
  {
    name = 'on-grid aliased child: no snap appended; off-grid sibling: snap appended',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{
          aliasCtr = 3,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} }, children = {} },
            { id = '2', xform = { ppqL = {{'add', 290}}, pitch = {{'add', 2}} }, children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      h.vm:quantizeAll()

      local notes   = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.eq(#oldRoot.aliases, 2, 'both still in tree')
      t.deepEq(oldRoot.aliases[1].xform.ppqL, {{'add', 240}},
        'on-grid id=1 untouched')
      t.deepEq(oldRoot.aliases[2].xform.ppqL, {{'add', 290}, {'snap', 60}},
        'off-grid id=2 snap appended')

      local kids = byParent(notes, 1)
      table.sort(kids, function(a, b) return a.ppq < b.ppq end)
      t.eq(kids[1].ppq, 240); t.eq(kids[1].pitch, 61)
      t.eq(kids[2].ppq, 300); t.eq(kids[2].pitch, 62)
    end,
  },

  --------------------------------------------------------------------
  -- Aliasing root with on-grid child: no plans anywhere; root and
  -- spec preserved intact.
  --------------------------------------------------------------------
  {
    name = 'aliasing root with on-grid child: no plans, root preserved intact',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      h.vm:quantizeAll()

      local notes   = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.truthy(oldRoot)
      t.eq(#oldRoot.aliases, 1)
      t.deepEq(oldRoot.aliases[1].xform.ppqL, {{'add', 240}},
        'no snap appended — was already on-grid')

      local kids = byParent(notes, 1)
      t.eq(#kids, 1); t.deepEq(h.tm:specPathOf(kids[1]), {1}, 'still aliased')
    end,
  },

  --------------------------------------------------------------------
  -- Aliased mid stays attached; its grandchild is on-grid pre-quantize
  -- (no plan, no snap appended) but after the mid's snap it composes
  -- against the snapped mid position. Demonstrates accepted alias
  -- drift: grandchild moves off-grid as the mid moves on-grid.
  --------------------------------------------------------------------
  {
    name = 'aliased mid: snap appended; grandchild composes against the snapped mid',
    run = function(harness)
      -- Mid resolved ppq = 250 (off-grid → planned, snap appended).
      -- Grandchild resolved ppq = 250 + 50 = 300 (on-grid → no plan).
      -- Post-quantize: mid xform = {add 250, snap 60} → resolved 240.
      -- Grandchild composes: 240 + 50 = 290 (alias drift, accepted).
      local h = harness.mk(util.assign({
        seed = { notes = { shortNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 250}}, pitch = {{'add', 1}} },
              children = {
                { id = '1',
                  xform = { ppqL = {{'add', 50}}, pitch = {{'add', 1}},
                            vel = {{'add', 5}} },
                  children = {} },
              }},
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)
      h.vm:quantizeAll()

      local notes   = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.eq(#oldRoot.aliases, 1, 'mid spec stays in tree')
      local mid = oldRoot.aliases[1]
      t.deepEq(mid.xform.ppqL, {{'add', 250}, {'snap', 60}})
      t.eq(#mid.children, 1, 'grandchild spec preserved')

      local kids = byParent(notes, 1)
      local emitMid, emitGrand
      for _, e in ipairs(kids) do
        local idx = h.tm:specPathOf(e)
        local key = idx and table.concat(idx, '.') or nil
        if     key == '1'   then emitMid = e
        elseif key == '1.1' then emitGrand = e end
      end

      t.truthy(emitMid)
      t.eq(emitMid.ppq, 240, 'mid resolves to snapped row 4')
      t.eq(emitMid.pitch, 61)

      t.truthy(emitGrand)
      t.eq(emitGrand.ppq,   290, 'grandchild = snapped-mid(240) + 50')
      t.eq(emitGrand.pitch, 62)
      t.eq(emitGrand.vel,   105)
    end,
  },

  --------------------------------------------------------------------
  -- quantizeKeepRealised on aliased child: severs and absorbs into
  -- delay. This path does NOT route relative — delay is per-emit,
  -- not in the spec — so the keepRealised promise (preserve realised
  -- onset) requires severance.
  --------------------------------------------------------------------
  {
    name = 'quantizeKeepRealised on aliased child: severs; delay preserves realised onset',
    run = function(harness)
      -- Resolved ppq = 250, delay = 0 → realised = 250. Snap ppqL to
      -- row 4 → 240; delay must absorb +10 ppq so realised stays 250.
      local h = harness.mk(util.assign({
        seed = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1',
              xform = { ppqL = {{'add', 250}}, pitch = {{'add', 1}} },
              children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)

      h.vm:quantizeKeepRealisedAll()

      local notes   = h.fm:dump().notes
      local oldRoot = rootByUuid(notes, 1)
      t.deepEq(oldRoot.aliases, {}, 'severed')

      local promoted
      for _, n in ipairs(notes) do
        if not n.parentUuid and n.uuid ~= 1 then promoted = n end
      end
      t.truthy(promoted)
      t.eq(promoted.ppqL, 240, 'intent ppq snapped to row 4')
      t.eq(promoted.ppq,  250, 'realised onset preserved (delay absorbed +10)')
    end,
  },
}
