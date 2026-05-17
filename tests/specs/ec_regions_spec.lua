-- ec region mode, driven through the real cmgr modal stack against a
-- real groupManager (fake tm/cm, as the gm_* specs do). ec builds the
-- 'region' overlay scope at instantiate; we push a tracker scope under
-- it, enter via ec:enterRegionMode(), and dispatch through cmgr:invoke.
-- The bridge stands in for trackerView's grid<->logical surface --
-- faking the bridge fakes tv, never ec's verb bodies, which run real.

local t    = require('support')
local util = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {}, assign = {}, del = {} }, 0
  local tm = {}
  function tm:subscribe(sig, fn) hooks[sig] = fn end
  function tm:addEvent(evt)      staged.add[#staged.add + 1] = evt end
  function tm:assignEvent(e, u)  staged.assign[#staged.assign + 1] = { evt = e, update = u } end
  function tm:deleteEvent(evt)   staged.del[#staged.del + 1] = evt end
  function tm:flush()
    if hooks.preflush then hooks.preflush({}, {}, {}) end
    for _, e in ipairs(staged.add) do
      if e.uuid == nil then seq = seq + 1; e.uuid = 1000 + seq end
    end
    if hooks.postflush then hooks.postflush() end
  end
  return tm, staged
end

local function fakeCm()
  local store = {}
  return { get = function(_, k) return store[k] end,
           set = function(_, _l, k, v) store[k] = v end }
end

-- rect over a single note stream at chan offset 0; dur a multiple of lpr.
local function rect(ppq, dur)
  return { ppq = ppq, dur = dur, chanLo = 1,
           streams = { [0] = { ['note:1'] = true } } }
end

local LPR = 10

local function mk(opts)
  opts = opts or {}
  local tm = fakeTm()
  local gm = util.instantiate('groupManager', { tm = tm, cm = fakeCm() })

  local cols = { { type = 'note', midiChan = 1, lane = 1 },
                 { type = 'note', midiChan = 1, lane = 2 } }
  local grid = { cols = cols, numRows = opts.numRows or 20,
                 chanFirstCol = { [1] = 1 }, chanLastCol = { [1] = 2 } }

  local cmgr = util.instantiate('commandManager',
                                { cm = { get = function() return 'qwerty' end } })

  local bridge = { gm = gm, selCalls = {}, paintCalls = {},
                   rect = nil, anchor = nil, commits = 0 }
  function bridge.eventsInRect()       return {} end
  function bridge.selectionAsRect()    return bridge.rect end
  function bridge.cursorAnchor()       return bridge.anchor end
  function bridge.instanceAt()         return bridge.instAt end
  function bridge.commit()             bridge.commits = bridge.commits + 1
                                       return tm:flush() end
  function bridge.paintStream(g, i, col, on)
    bridge.paintCalls[#bridge.paintCalls + 1] = { g, i, col, on }
  end

  local ec = util.instantiate('editCursor', {
    grid        = grid,
    cm          = { get = function() return 0 end },
    cmgr        = cmgr,
    rowPerBar   = function() return 4 end,
    logPerRow   = function() return LPR end,
    groupBridge = bridge,
  })
  for _, col in ipairs(cols) do ec:decorateCol(col) end

  -- tv install emulation: flip a real selection so ec:hasSelection() and
  -- the caret land where a real instanceSelection would put them.
  function bridge.instanceSelection(g, i)
    bridge.selCalls[#bridge.selCalls + 1] = { g, i }
    ec:setSelection{ row1 = 0, row2 = 0, col1 = 1, col2 = 1,
                     part1 = 'pitch', part2 = 'pitch' }
  end

  local origLog = {}
  local tracker = cmgr:scope('tracker')
  for _, name in ipairs{ 'someOther', 'cursorDown' } do
    tracker:register(name, function() origLog[#origLog + 1] = name
                                      return 'orig:' .. name end)
  end
  cmgr:push('tracker')

  return ec, { gm = gm, cmgr = cmgr, bridge = bridge,
               grid = grid, origLog = origLog }
end

local function instances(gm, groupId)
  local out = {}
  for _, e in ipairs(gm:eachInstance()) do
    if groupId == nil or e.groupId == groupId then out[#out + 1] = e end
  end
  return out
end

return {

  ----- lifecycle / modal gate

  {
    name = 'enterRegionMode sets mode; regionBail clears it',
    run = function()
      local ec, c = mk()
      t.falsy(ec:isInRegionMode())
      ec:enterRegionMode()
      t.truthy(ec:isInRegionMode())
      c.cmgr:invoke('regionBail')
      t.falsy(ec:isInRegionMode())
      t.eq(ec:regionCursor(), nil, 'bail clears the region cursor')
    end,
  },

  {
    name = 'region verbs unreachable outside mode',
    run = function()
      local ec, c = mk()
      for _, v in ipairs{ 'regionBail', 'regionCommit', 'regionNew',
                          'regionInstance', 'regionDrop', 'regionNext',
                          'regionPrev', 'regionGrow', 'regionShrink' } do
        t.eq(c.cmgr:invoke(v), nil, v .. ' does not resolve outside mode')
      end
      t.falsy(ec:isInRegionMode())
    end,
  },

  {
    name = 'non-passthrough tracker command blocked in mode, runs outside',
    run = function()
      local ec, c = mk()
      t.eq(c.cmgr:invoke('someOther'), 'orig:someOther', 'runs outside mode')
      ec:enterRegionMode()
      t.eq(c.cmgr:invoke('someOther'), nil, 'modal blocks (not passthrough)')
      c.cmgr:invoke('regionBail')
      t.eq(c.cmgr:invoke('someOther'), 'orig:someOther', 'restored after bail')
    end,
  },

  {
    name = 'enterRegionMode seeds the region cursor from the caret instance',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      c.bridge.instAt = { groupId = g, instId = instances(c.gm, g)[1].instId }
      ec:enterRegionMode()
      t.eq(ec:regionCursor().groupId, g, 'seeded from the caret instance')
      t.eq(ec:regionCursor().instId, instances(c.gm, g)[1].instId)
    end,
  },

  {
    name = 'enterRegionMode falls back to the active group when caret over none',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))   -- mark sets it active
      c.bridge.instAt = nil
      ec:enterRegionMode()
      t.eq(ec:regionCursor().groupId, g, 'fell back to the active group')
      t.eq(ec:regionCursor().instId, instances(c.gm, g)[1].instId)
    end,
  },

  ----- regionNew / regionInstance

  {
    name = 'regionNew seeds a group from the selection rect; cursor + clear',
    run = function()
      local ec, c = mk()
      ec:enterRegionMode()
      ec:setSelection{ row1 = 0, row2 = 0, col1 = 1, col2 = 1,
                       part1 = 'pitch', part2 = 'pitch' }
      c.bridge.rect = rect(0, LPR)
      c.cmgr:invoke('regionNew')
      t.eq(#instances(c.gm), 1, 'a group was created')
      local rc = ec:regionCursor()
      t.eq(rc.instId, 1)
      t.eq(rc.groupId, instances(c.gm)[1].groupId)
      t.falsy(ec:hasSelection(), 'selection cleared after new')
    end,
  },

  {
    name = 'regionNew with no selection rect is a silent no-op',
    run = function()
      local ec, c = mk()
      ec:enterRegionMode()
      c.bridge.rect = nil
      c.cmgr:invoke('regionNew')
      t.eq(#instances(c.gm), 0, 'no group created')
      t.eq(ec:regionCursor(), nil)
    end,
  },

  {
    name = 'regionInstance drops another copy of the cursor group',
    run = function()
      local ec, c = mk()
      ec:enterRegionMode()
      c.bridge.rect = rect(0, LPR)
      c.cmgr:invoke('regionNew')
      local g = ec:regionCursor().groupId
      c.bridge.anchor = { ppq = 100, chan = 1 }
      c.cmgr:invoke('regionInstance')
      t.eq(#instances(c.gm, g), 2, 'second instance added')
      t.eq(ec:regionCursor().instId, instances(c.gm, g)[2].instId)
    end,
  },

  {
    name = 'creation verbs flush so a new region materialises immediately',
    run = function()
      local ec, c = mk()
      ec:enterRegionMode()
      c.bridge.rect = rect(0, LPR)
      c.cmgr:invoke('regionNew')
      t.eq(c.bridge.commits, 1, 'regionNew flushed staged group ops')
      c.bridge.anchor = { ppq = LPR, chan = 1 }
      c.cmgr:invoke('regionInstance')
      t.eq(c.bridge.commits, 2, 'regionInstance flushed the new copy')
    end,
  },

  ----- next / prev cycling

  {
    name = 'regionNext / regionPrev cycle deterministically and clamp',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      c.gm:newInstance(g, { ppq = 100, chan = 1 })
      c.gm:newInstance(g, { ppq = 200, chan = 1 })
      local list = {}
      for _, e in ipairs(c.gm:eachInstance()) do list[#list + 1] = e.instId end
      table.sort(list)

      ec:enterRegionMode()                    -- seeded at active group's first
      t.eq(ec:regionCursor().instId, list[1])
      c.cmgr:invoke('regionPrev')
      t.eq(ec:regionCursor().instId, list[1], 'prev at start clamps')
      c.cmgr:invoke('regionNext')
      t.eq(ec:regionCursor().instId, list[2])
      c.cmgr:invoke('regionNext')
      c.cmgr:invoke('regionNext')
      t.eq(ec:regionCursor().instId, list[3], 'next at end clamps')
      t.falsy(ec:hasSelection(), 'nav is border-only -- no grid selection')
      t.eq(#c.bridge.selCalls, 0, 'cycle never calls instanceSelection')
    end,
  },

  ----- nudge (move instance)

  {
    name = 'regionNudgeForward moves the instance and the caret follows',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      ec:enterRegionMode()
      ec:setPos(5, 1, 1)
      c.cmgr:invoke('regionNudgeForward')
      t.eq(instances(c.gm, g)[1].anchor.ppq, LPR, 'instance moved +1 row')
      t.eq(ec:row(), 6, 'caret followed +1')
      c.cmgr:invoke('regionNudgeBack')
      t.eq(instances(c.gm, g)[1].anchor.ppq, 0)
      t.eq(ec:row(), 5)
    end,
  },

  {
    name = 'regionNudge rejected by collision: instance and caret unchanged',
    run = function()
      local ec, c = mk()
      c.gm:mark({}, rect(20, LPR))                    -- b: [20,30)
      local a = c.gm:mark({}, rect(0, LPR))           -- a: [0,10), active
      ec:enterRegionMode()                            -- seeds cursor to a
      ec:setPos(5, 1, 1)
      c.cmgr:invoke('regionNudgeForward')             -- a -> [10,20) ok
      t.eq(instances(c.gm, a)[1].anchor.ppq, LPR)
      t.eq(ec:row(), 6)
      c.cmgr:invoke('regionNudgeForward')             -- a -> [20,30) hits b
      t.eq(instances(c.gm, a)[1].anchor.ppq, LPR, 'rejected: instance held')
      t.eq(ec:row(), 6, 'rejected: caret held')
    end,
  },

  ----- drop

  {
    name = 'regionDrop deletes the cursor instance; advances; last drops group',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      c.gm:newInstance(g, { ppq = 100, chan = 1 })
      ec:enterRegionMode()
      t.eq(#instances(c.gm, g), 2)
      c.cmgr:invoke('regionDrop')
      t.eq(#instances(c.gm, g), 1, 'one instance dropped')
      t.truthy(ec:regionCursor(), 'cursor advanced to the survivor')
      c.cmgr:invoke('regionDrop')
      t.eq(#instances(c.gm, g), 0, 'group emptied')
      t.eq(ec:regionCursor(), nil, 'cursor cleared with the group')
    end,
  },

  ----- resize (end + start edges)

  {
    name = 'regionGrow / regionShrink move the end edge by logPerRow',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, 2 * LPR))
      ec:enterRegionMode()
      c.cmgr:invoke('regionGrow')
      t.eq(instances(c.gm, g)[1].rect.dur, 3 * LPR, 'end edge out +lpr')
      c.cmgr:invoke('regionShrink')
      c.cmgr:invoke('regionShrink')
      t.eq(instances(c.gm, g)[1].rect.dur, LPR, 'end edge in -2 lpr')
    end,
  },

  {
    name = 'regionGrowStart / regionShrinkStart move the start edge (Model A)',
    run = function()
      local ec, c = mk()
      local g  = c.gm:mark({}, rect(LPR, 2 * LPR))    -- [10,30)
      ec:enterRegionMode()
      c.cmgr:invoke('regionShrinkStart')              -- start in: +lpr
      local r = instances(c.gm, g)[1].rect
      t.eq(r.ppq, 2 * LPR, 'start edge moved in')
      t.eq(r.dur, LPR,     'span shorter by lpr')
      c.cmgr:invoke('regionGrowStart')                -- start out: -lpr
      r = instances(c.gm, g)[1].rect
      t.eq(r.ppq, LPR)
      t.eq(r.dur, 2 * LPR)
    end,
  },

  ----- paint (stream-set sculpt via the bridge)

  {
    name = 'regionPaintExtend/Shrink forward (groupId, instId, cursorCol, on) to the bridge',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      ec:enterRegionMode()
      local iid = ec:regionCursor().instId
      ec:setPos(0, 2, 1)                       -- caret on col 2
      c.cmgr:invoke('regionPaintExtend')
      c.cmgr:invoke('regionPaintShrink')
      t.eq(#c.bridge.paintCalls, 2)
      t.deepEq(c.bridge.paintCalls[1], { g, iid, 2, true })
      t.deepEq(c.bridge.paintCalls[2], { g, iid, 2, false })
    end,
  },

  ----- commit

  {
    name = 'regionCommit installs the instance selection and exits mode',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      ec:enterRegionMode()
      ec:selClear()
      t.falsy(ec:hasSelection())
      c.cmgr:invoke('regionCommit')
      t.falsy(ec:isInRegionMode(), 'commit exited mode')
      t.truthy(ec:hasSelection(), 'commit installed the instance selection')
      local last = c.bridge.selCalls[#c.bridge.selCalls]
      t.eq(last[1], g)
    end,
  },

}
