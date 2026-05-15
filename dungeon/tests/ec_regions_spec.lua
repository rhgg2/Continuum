-- ec regions: driven through the public command surface. ec builds the
-- 'region' overlay scope at instantiate (modal + verbs); we exercise it
-- by pushing a tracker scope underneath, entering region mode via
-- ec:enterRegionMode(), and dispatching through cmgr:invoke. The modal
-- stack — not a flag — gates the verbs; tests assert through it.

local t       = require('support')
local util    = require('util')
local regions = require('regions')

local DEFAULT_ORIGINALS = {
  'deleteSel', 'nudgeBack', 'nudgeForward',
  'growNote', 'shrinkNote', 'noteOff',
  'inputSampleUp', 'inputSampleDown',
  'someOther',
}

-- ec construction. Real cmgr + tracker scope underneath; the region
-- overlay is built by ec on its `cmgr` dep. Originals registered on
-- tracker are pure side-effect markers so we can observe pass-through
-- vs shadow vs modal-block.
local function mkEc(opts)
  opts = opts or {}
  local cols = opts.cols or {
    { type='note', midiChan=1, lane=1 },
    { type='note', midiChan=1, lane=2 },
  }
  local events  = {}
  local origLog = {}
  local grid = { cols = cols, numRows = opts.numRows or 8,
                 chanFirstCol = { [1] = 1 },
                 chanLastCol  = { [1] = #cols } }
  local cmgr = util.instantiate('commandManager', { cm = { get = function() return 'qwerty' end } })
  local ec = util.instantiate('editCursor', {
    grid        = grid,
    cm          = { get = function() return 0 end },
    cmgr        = cmgr,
    rowPerBar   = function() return 4 end,
    logPerRow   = function() return opts.logPerRow or 10 end,
    regionsHook = function(verb, id) util.add(events, { verb=verb, id=id }) end,
  })
  for _, col in ipairs(cols) do ec:decorateCol(col) end

  local tracker = cmgr:scope('tracker')
  for _, name in ipairs(opts.originals or DEFAULT_ORIGINALS) do
    tracker:register(name, function() util.add(origLog, name); return 'orig:' .. name end)
  end
  cmgr:push('tracker')

  return ec, { grid = grid, cols = cols, cmgr = cmgr,
               events = events, origLog = origLog }
end

local function hasVerb(events, verb)
  for _, e in ipairs(events) do if e.verb == verb then return true end end
  return false
end

return {

  ----- lifecycle: enter / bail / commit / mode flag

  {
    name = 'enterRegionMode sets mode; regionBail clears it',
    run = function()
      local ec, c = mkEc()
      t.falsy(ec:isInRegionMode())
      ec:enterRegionMode()
      t.truthy(ec:isInRegionMode())
      c.cmgr:invoke('regionBail')
      t.falsy(ec:isInRegionMode())
    end,
  },

  {
    name = 'region verbs are unreachable outside mode',
    run = function()
      local ec, c = mkEc()
      -- Outside mode, the region scope isn't on the stack; its verbs
      -- don't resolve.
      t.eq(c.cmgr:invoke('regionBail'),    nil)
      t.eq(c.cmgr:invoke('regionCommit'),  nil)
      t.eq(c.cmgr:invoke('regionDrop'),    nil)
      t.eq(c.cmgr:invoke('regionNew'),     nil)
      t.eq(c.cmgr:invoke('regionNext'),    nil)
      t.eq(c.cmgr:invoke('regionPrev'),    nil)
      t.eq(c.cmgr:invoke('regionExtendParts'),  nil)
      t.eq(c.cmgr:invoke('regionShrinkParts'),  nil)
      t.falsy(ec:isInRegionMode())
    end,
  },

  {
    name = 'enterRegionMode picks up cursor-implicit active region (half-open)',
    run = function()
      local ec, c = mkEc{ logPerRow = 10, numRows = 20 }
      ec:enterRegionMode()
      ec:setSelection{ row1=0, row2=4, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionNew')  -- A: ppq [0, 50)
      local a = ec:activeRegionId()
      ec:setSelection{ row1=5, row2=9, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionNew')  -- B: ppq [50, 100)
      local b = ec:activeRegionId()
      c.cmgr:invoke('regionBail')

      ec:setPos(4, 1, 1); ec:enterRegionMode()
      t.eq(ec:activeRegionId(), a, 'ppq 40 inside [0,50)')
      c.cmgr:invoke('regionBail')
      ec:setPos(5, 1, 1); ec:enterRegionMode()
      t.eq(ec:activeRegionId(), b, 'ppq 50 lives in [50,100), not [0,50)')
    end,
  },

  ----- regionNew / extend / shrink (selection-driven)

  {
    name = 'regionNew creates region from selection; bumps id; cycles colour; clears selection; fires create',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      ec:enterRegionMode()
      ec:setSelection{ row1=0, row2=1, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionNew')
      t.falsy(ec:hasSelection(), 'selection cleared after new')

      local r = ec:listRegions()[1]
      t.eq(r.id, 1); t.eq(r.colour, 1)
      t.eq(r.ppqLo, 0); t.eq(r.ppqHi, 20)
      t.truthy(r.parts[regions.colKey(c.cols[1], 'pitch')])
      t.truthy(hasVerb(c.events, 'create'))

      ec:setSelection{ row1=3, row2=3, col1=2, col2=2, part1='vel', part2='vel' }
      c.cmgr:invoke('regionNew')
      local list = ec:listRegions()
      t.eq(#list, 2)
      t.eq(list[2].id, 2); t.eq(list[2].colour, 2)
    end,
  },

  {
    name = 'regionExtendParts unions parts onto active region',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      ec:enterRegionMode()
      ec:setSelection{ row1=0, row2=1, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionNew')
      local id = ec:activeRegionId()

      ec:setSelection{ row1=0, row2=1, col1=2, col2=2, part1='vel', part2='vel' }
      c.cmgr:invoke('regionExtendParts')
      local r = ec:getRegion(id)
      t.truthy(r.parts[regions.colKey(c.cols[1], 'pitch')])
      t.truthy(r.parts[regions.colKey(c.cols[2], 'vel')])
    end,
  },

  {
    name = 'regionExtendParts with no active region falls through to new',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      ec:enterRegionMode()
      t.eq(ec:activeRegionId(), nil)
      ec:setSelection{ row1=2, row2=2, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionExtendParts')
      t.truthy(ec:activeRegionId(), 'extend with no active created a region')
      t.eq(#ec:listRegions(), 1)
    end,
  },

  {
    name = 'regionShrinkParts removes parts; keeps region when parts go empty; no-op without active',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      ec:enterRegionMode()
      ec:setSelection{ row1=0, row2=0, col1=1, col2=2, part1='pitch', part2='vel' }
      c.cmgr:invoke('regionNew')
      local id = ec:activeRegionId()

      ec:setSelection{ row1=0, row2=0, col1=2, col2=2, part1='vel', part2='vel' }
      c.cmgr:invoke('regionShrinkParts')
      local r = ec:getRegion(id)
      t.truthy(r.parts[regions.colKey(c.cols[1], 'pitch')])
      t.falsy (r.parts[regions.colKey(c.cols[2], 'vel')])

      c.cmgr:invoke('regionDrop')
      t.eq(ec:activeRegionId(), nil)
      ec:setSelection{ row1=0, row2=0, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionShrinkParts')  -- no active → no-op
      t.eq(#ec:listRegions(), 0, 'shrink without active does nothing')
    end,
  },

  ----- next / prev cycling

  {
    name = 'regionNext / regionPrev clamp at the ends',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      ec:enterRegionMode()
      for r = 0, 4, 2 do
        ec:setSelection{ row1=r, row2=r, col1=1, col2=1, part1='pitch', part2='pitch' }
        c.cmgr:invoke('regionNew')
      end
      local list = ec:listRegions()
      local a, b, _ = list[1].id, list[2].id, list[3].id
      t.eq(ec:activeRegionId(), list[3].id, 'newest is active')

      c.cmgr:invoke('regionNext'); t.eq(ec:activeRegionId(), list[3].id, 'next at end clamps')
      c.cmgr:invoke('regionPrev'); t.eq(ec:activeRegionId(), b)
      c.cmgr:invoke('regionPrev'); t.eq(ec:activeRegionId(), a)
      c.cmgr:invoke('regionPrev'); t.eq(ec:activeRegionId(), a, 'prev at start clamps')
    end,
  },

  {
    name = 'regionNext/regionPrev snap cursor to active region top-left',
    run = function()
      local ec, c = mkEc{ logPerRow = 10, numRows = 20 }
      ec:enterRegionMode()
      ec:setSelection{ row1=0, row2=1, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionNew')   -- A at row 0, col 1, pitch
      ec:setSelection{ row1=5, row2=6, col1=2, col2=2, part1='vel',   part2='vel'   }
      c.cmgr:invoke('regionNew')   -- B at row 5, col 2, vel

      -- B is active (newest). Park cursor away, then Prev → A's top-left.
      ec:setPos(12, 1, 1)
      c.cmgr:invoke('regionPrev')
      t.eq(ec:row(), 0); t.eq(ec:col(), 1)
      t.eq(ec:cursorPart(), 'pitch')

      ec:setPos(12, 1, 1)
      c.cmgr:invoke('regionNext')
      t.eq(ec:row(), 5); t.eq(ec:col(), 2)
      t.eq(ec:cursorPart(), 'vel')

      t.falsy(ec:hasSelection(), 'cycle clears selection')
    end,
  },

  {
    name = 'regionNudgeForward/Back shift cursor by the same row delta',
    run = function()
      local ec, c = mkEc{ logPerRow = 10, numRows = 20 }
      ec:enterRegionMode()
      ec:setSelection{ row1=2, row2=3, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionNew')

      ec:setPos(5, 1, 1)
      c.cmgr:invoke('regionNudgeForward')
      t.eq(ec:row(), 6, 'cursor follows +1 row')
      c.cmgr:invoke('regionNudgeBack')
      c.cmgr:invoke('regionNudgeBack')
      t.eq(ec:row(), 4, 'cursor follows -2 rows')
    end,
  },

  {
    name = 'regionNudge cursor delta matches clamped translation, not raw input',
    run = function()
      local ec, c = mkEc{ logPerRow = 10, numRows = 20 }
      ec:enterRegionMode()
      ec:setSelection{ row1=0, row2=1, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionNew')   -- region at the top; back is fully clamped

      ec:setPos(10, 1, 1)
      c.cmgr:invoke('regionNudgeBack')
      t.eq(ec:row(), 10, 'clamped translation: cursor does not move')
    end,
  },

  ----- drop

  {
    name = 'regionDrop deletes active region; clears activeRegionId; fires delete',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      ec:enterRegionMode()
      ec:setSelection{ row1=0, row2=0, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionNew')
      local id = ec:activeRegionId()

      local pre = #c.events
      c.cmgr:invoke('regionDrop')
      t.eq(ec:getRegion(id), nil)
      t.eq(ec:activeRegionId(), nil)
      t.truthy(hasVerb({table.unpack(c.events, pre + 1)}, 'delete'))
    end,
  },

  {
    name = 'tracker deleteSel still runs outside mode (no name collision with regionDrop)',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      t.eq(c.cmgr:invoke('deleteSel'), 'orig:deleteSel', 'outside mode runs tracker original')
      ec:enterRegionMode()
      t.eq(c.cmgr:invoke('deleteSel'), nil, 'in mode the tracker original is gated out (deleteSel not in passthrough)')
    end,
  },

  ----- time-axis: translate, grow/shrink, snapHi toggle

  {
    name = 'regionNudgeForward / regionNudgeBack translate active region by logPerRow',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      ec:enterRegionMode()
      ec:setSelection{ row1=2, row2=3, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionNew')
      local id = ec:activeRegionId()
      local lo, hi = ec:getRegion(id).ppqLo, ec:getRegion(id).ppqHi

      c.cmgr:invoke('regionNudgeForward')
      local r1 = ec:getRegion(id)
      t.eq(r1.ppqLo, lo + 10); t.eq(r1.ppqHi, hi + 10)

      c.cmgr:invoke('regionNudgeBack'); c.cmgr:invoke('regionNudgeBack')
      local r2 = ec:getRegion(id)
      t.eq(r2.ppqLo, lo - 10); t.eq(r2.ppqHi, hi - 10)
    end,
  },

  {
    name = 'regionGrow / regionShrink adjust ppqHi; clamps ppqHi >= ppqLo',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      ec:enterRegionMode()
      ec:setSelection{ row1=0, row2=0, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionNew')
      local id = ec:activeRegionId()
      local lo = ec:getRegion(id).ppqLo
      local hi = ec:getRegion(id).ppqHi  -- = lo + 10

      c.cmgr:invoke('regionGrow')
      t.eq(ec:getRegion(id).ppqHi, hi + 10)
      c.cmgr:invoke('regionShrink'); c.cmgr:invoke('regionShrink')
      t.eq(ec:getRegion(id).ppqHi, hi - 10, 'two shrinks return to lo')
      t.eq(ec:getRegion(id).ppqHi, lo)
      c.cmgr:invoke('regionShrink')
      t.eq(ec:getRegion(id).ppqHi, lo, 'ppqHi clamped at ppqLo')
    end,
  },

  {
    name = 'regionSnapHi toggles ppqHi between cursor-row*lpr and take-length*lpr',
    run = function()
      local ec, c = mkEc{ logPerRow = 10, numRows = 8 }
      ec:enterRegionMode()
      ec:setSelection{ row1=0, row2=3, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionNew')
      local id = ec:activeRegionId()

      ec:setPos(5, 1, 1)
      c.cmgr:invoke('regionSnapHi')
      t.eq(ec:getRegion(id).ppqHi, 50, 'first press snaps to cursor·lpr')
      c.cmgr:invoke('regionSnapHi')
      t.eq(ec:getRegion(id).ppqHi, 80, 'second press extends to numRows·lpr')
    end,
  },

  ----- commit installs bbox selection + exits

  {
    name = 'regionCommit installs bbox selection from active region; exits mode',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      ec:enterRegionMode()
      ec:setSelection{ row1=1, row2=4, col1=1, col2=2, part1='pitch', part2='vel' }
      c.cmgr:invoke('regionNew')
      ec:selClear()
      t.falsy(ec:hasSelection())

      c.cmgr:invoke('regionCommit')
      t.falsy(ec:isInRegionMode())
      t.truthy(ec:hasSelection())
      local r1, r2, c1, c2, p1, p2 = ec:region()
      t.eq(r1, 1); t.eq(r2, 4); t.eq(c1, 1); t.eq(c2, 2)
      t.eq(p1, 'pitch'); t.eq(p2, 'vel')
    end,
  },

  {
    name = 'regionCommit on region whose parts are not on the grid is a silent no-op (no selection installed)',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      ec.regionData.regions = {{ id=1, colour=1, ppqLo=0, ppqHi=20,
                                  parts = { ['note:9:9:pitch'] = true } }}
      ec.regionData.idCtr = 1
      ec:enterRegionMode()
      c.cmgr:invoke('regionNext')
      t.eq(ec:activeRegionId(), 1)
      c.cmgr:invoke('regionCommit')
      t.falsy(ec:hasSelection(), 'stale parts → commit installs nothing')
      t.falsy(ec:isInRegionMode())
    end,
  },

  ----- empty-parts sweep on exit

  {
    name = 'bail sweeps empty-parts regions; commit sweeps them too',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }

      ec:enterRegionMode()
      ec:setSelection{ row1=0, row2=0, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionNew')
      local id = ec:activeRegionId()

      ec:setSelection{ row1=0, row2=0, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionShrinkParts')
      t.eq(next(ec:getRegion(id).parts), nil, 'parts went empty')

      c.cmgr:invoke('regionBail')
      t.eq(ec:getRegion(id), nil, 'bail swept the empty region')

      -- Same on commit.
      ec:enterRegionMode()
      ec:setSelection{ row1=0, row2=0, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionNew')
      local id2 = ec:activeRegionId()
      ec:setSelection{ row1=0, row2=0, col1=1, col2=1, part1='pitch', part2='pitch' }
      c.cmgr:invoke('regionShrinkParts')
      c.cmgr:invoke('regionCommit')
      t.eq(ec:getRegion(id2), nil, 'commit swept the empty region')
    end,
  },

  ----- modal gate via stack: non-passthrough commands blocked in mode

  {
    name = 'non-passthrough tracker commands are blocked in mode; pass through outside',
    run = function()
      local ec, c = mkEc()
      t.eq(c.cmgr:invoke('someOther'), 'orig:someOther', 'outside mode: tracker original runs')
      ec:enterRegionMode()
      t.eq(c.cmgr:invoke('someOther'), nil, 'in mode: modal blocks (not in passthrough)')
      c.cmgr:invoke('regionBail')
      t.eq(c.cmgr:invoke('someOther'), 'orig:someOther', 'pass-through restored after bail')
    end,
  },

  ----- mouse paint primitive

  {
    name = 'paintRegionCell extend auto-seeds a one-row region; grows ppq span on subsequent cells',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      local key = regions.colKey(c.cols[1], 'pitch')

      ec:paintRegionCell(3, key, 'extend')
      local id = ec:activeRegionId()
      t.truthy(id, 'auto-seeded')
      local r = ec:getRegion(id)
      t.eq(r.ppqLo, 30); t.eq(r.ppqHi, 40, 'one-row slab at painted row')
      t.truthy(r.parts[key])

      ec:paintRegionCell(5, key, 'extend')
      r = ec:getRegion(id)
      t.eq(r.ppqLo, 30); t.eq(r.ppqHi, 60, 'ppqHi grew to cover row 5')

      ec:paintRegionCell(1, key, 'extend')
      r = ec:getRegion(id)
      t.eq(r.ppqLo, 10); t.eq(r.ppqHi, 60, 'ppqLo shrank to cover row 1')
    end,
  },

  {
    name = 'paintRegionCell shrink with no active region is a no-op',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      ec:paintRegionCell(0, regions.colKey(c.cols[1], 'pitch'), 'shrink')
      t.eq(ec:activeRegionId(), nil)
      t.eq(#ec:listRegions(), 0)
    end,
  },

  {
    name = 'paintRegionCell shrink removes the painted colKey only',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      local k1 = regions.colKey(c.cols[1], 'pitch')
      local k2 = regions.colKey(c.cols[2], 'pitch')
      ec:paintRegionCell(0, k1, 'extend')
      ec:paintRegionCell(0, k2, 'extend')
      local id = ec:activeRegionId()
      ec:paintRegionCell(0, k1, 'shrink')
      local r = ec:getRegion(id)
      t.falsy (r.parts[k1])
      t.truthy(r.parts[k2])
    end,
  },

  ----- read-side: listRegions

  {
    name = 'listRegions returns regions in insertion order; getRegion(unknown) is nil',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      ec:enterRegionMode()
      for r = 0, 2 do
        ec:setSelection{ row1=r, row2=r, col1=1, col2=1, part1='pitch', part2='pitch' }
        c.cmgr:invoke('regionNew')
      end
      local list = ec:listRegions()
      t.eq(#list, 3)
      t.eq(list[1].id, 1); t.eq(list[2].id, 2); t.eq(list[3].id, 3)
      t.eq(ec:getRegion(42), nil, 'unknown id is nil')
    end,
  },

  ----- shape round-trip via new → commit

  {
    name = 'selection → regionNew → regionCommit is idempotent',
    run = function()
      local ec, c = mkEc{ logPerRow = 10 }
      ec:enterRegionMode()
      ec:setSelection{ row1=1, row2=4, col1=1, col2=2, part1='pitch', part2='vel' }
      c.cmgr:invoke('regionNew')
      -- selection is cleared by new; commit should restore it
      t.falsy(ec:hasSelection())
      c.cmgr:invoke('regionCommit')
      local r1, r2, c1, c2, p1, p2 = ec:region()
      t.eq(r1, 1); t.eq(r2, 4); t.eq(c1, 1); t.eq(c2, 2)
      t.eq(p1, 'pitch'); t.eq(p2, 'vel')
    end,
  },

}
