-- ec group-authoring mode: real cmgr spring-loaded stack, real groupManager (fake tm/cm).
-- ec builds 'region' scope at instantiate; bridge fakes tv surface, not ec's verb bodies.

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

-- rect over a single note stream at chan offset 0; dur a multiple of lpr.
local function rect(ppq, dur)
  return { ppq = ppq, dur = dur, chanLo = 1,
           streams = { [0] = { ['note:1'] = true } } }
end

local LPR = 10

local function mk(opts)
  opts = opts or {}
  local tm = fakeTm()
  local gm = util.instantiate('groupManager', { tm = tm, ds = t.fakeDs() })

  local cols = { { type = 'note', midiChan = 1, lane = 1 },
                 { type = 'note', midiChan = 1, lane = 2 } }
  local grid = { cols = cols, numRows = opts.numRows or 20,
                 chanFirstCol = { [1] = 1 }, chanLastCol = { [1] = 2 } }

  local cmgr = util.instantiate('commandManager',
                                { cm = { get = function() return 'qwerty' end } })

  local bridge = { gm = gm, paintCalls = {},
                   rect = nil, anchor = nil, instAt = nil, commits = 0 }
  function bridge.eventsInRect()    return {} end
  function bridge.selectionAsRect() return bridge.rect end
  function bridge.cursorAnchor()    return bridge.anchor end
  function bridge.instanceAt()      return bridge.instAt end
  function bridge.commit()          bridge.commits = bridge.commits + 1
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

  -- Stub tracker: cursorDown is REGION_KEEPALIVE (stays armed); someOther is foreign (bails).
  -- Redirect targets need no tracker registration — redirect fires regardless.
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

local function anchorPpqs(gm, groupId)
  local out = {}
  for _, e in ipairs(instances(gm, groupId)) do out[#out + 1] = e.anchor.ppq end
  table.sort(out)
  return out
end

local function armOn(ec, c, groupId, instId)
  c.bridge.instAt = { groupId = groupId, instId = instId or instances(c.gm, groupId)[1].instId }
  ec:regionArm()
end

return {

  ----- arm / bail lifecycle

  {
    name = 'regionArm with a selection seeds a group, arms, clears selection',
    run = function()
      local ec, c = mk()
      ec:setSelection{ row1 = 0, row2 = 0, col1 = 1, col2 = 1,
                       part1 = 'pitch', part2 = 'pitch' }
      c.bridge.rect = rect(0, LPR)
      ec:regionArm()
      t.truthy(ec:isInRegionMode(), 'armed')
      t.eq(#instances(c.gm), 1, 'a group was created')
      local rc = ec:regionCursor()
      t.eq(rc.instId, 1)
      t.eq(rc.groupId, instances(c.gm)[1].groupId)
      t.falsy(ec:hasSelection(), 'selection cleared')
    end,
  },

  {
    name = 'regionArm with no selection arms on the caret instance',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      armOn(ec, c, g)
      t.truthy(ec:isInRegionMode())
      t.eq(ec:regionCursor().groupId, g)
      t.eq(ec:regionCursor().instId, instances(c.gm, g)[1].instId)
    end,
  },

  {
    name = 'regionArm with no selection and no caret instance is a no-op',
    run = function()
      local ec, c = mk()
      c.bridge.instAt = nil
      ec:regionArm()
      t.falsy(ec:isInRegionMode(), 'not armed')
      t.eq(ec:regionCursor(), nil)
    end,
  },

  {
    name = 'regionBail exits and clears any selection',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      armOn(ec, c, g, 1)
      ec:setSelection{ row1 = 0, row2 = 1, col1 = 1, col2 = 1,
                       part1 = 'pitch', part2 = 'pitch' }
      c.cmgr:invoke('regionBail')
      t.falsy(ec:isInRegionMode(), 'bailed')
      t.eq(ec:regionCursor(), nil, 'cursor cleared')
      t.falsy(ec:hasSelection(), 'selection cleared')
    end,
  },

  {
    name = 'regionExit exits but leaves the selection intact',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      armOn(ec, c, g, 1)
      ec:setSelection{ row1 = 0, row2 = 1, col1 = 1, col2 = 1,
                       part1 = 'pitch', part2 = 'pitch' }
      c.cmgr:invoke('regionExit')
      t.falsy(ec:isInRegionMode(), 'exited')
      t.eq(ec:regionCursor(), nil, 'cursor cleared')
      t.truthy(ec:hasSelection(), 'selection preserved (unlike regionBail)')
    end,
  },

  {
    name = 'region-owned verbs unreachable outside mode',
    run = function()
      local ec, c = mk()
      for _, v in ipairs{ 'regionExit', 'regionBail', 'regionPaintExtend', 'regionPaintShrink' } do
        t.eq(c.cmgr:invoke(v), nil, v .. ' does not resolve outside mode')
      end
      t.falsy(ec:isInRegionMode())
    end,
  },

  ----- redirect verbs (reinterpret tracker commands onto the armed instance)

  {
    name = 'paste / groupPaste drop a new instance at the caret, stay armed',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      armOn(ec, c, g, 1)
      c.bridge.anchor = { ppq = 100, chan = 1 }
      c.cmgr:invoke('paste')
      t.eq(#instances(c.gm, g), 2, 'paste added an instance')
      c.bridge.anchor = { ppq = 200, chan = 1 }
      c.cmgr:invoke('groupPaste')
      t.eq(#instances(c.gm, g), 3, 'groupPaste added another')
      t.truthy(ec:isInRegionMode(), 'still armed')
    end,
  },

  {
    name = 'delete / deleteSel drop the armed instance, stay armed',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      c.gm:newInstance(g, { ppq = 100, chan = 1 })
      armOn(ec, c, g, 1)
      c.cmgr:invoke('deleteSel')
      t.eq(#instances(c.gm, g), 1, 'deleteSel dropped one')
      c.cmgr:invoke('delete')
      t.eq(#instances(c.gm, g), 0, 'delete dropped the last')
      t.truthy(ec:isInRegionMode(), 'still armed')
    end,
  },

  {
    name = 'nudgeForward / nudgeBack move the instance, caret follows',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      armOn(ec, c, g, 1)
      ec:setPos(5, 1, 1)
      c.cmgr:invoke('nudgeForward')
      t.eq(instances(c.gm, g)[1].anchor.ppq, LPR, 'instance +1 row')
      t.eq(ec:row(), 6, 'caret followed')
      c.cmgr:invoke('nudgeBack')
      t.eq(instances(c.gm, g)[1].anchor.ppq, 0)
      t.eq(ec:row(), 5)
      t.truthy(ec:isInRegionMode())
    end,
  },

  {
    name = 'growNote / shrinkNote resize the instance end edge',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, 2 * LPR))
      armOn(ec, c, g, 1)
      c.cmgr:invoke('growNote')
      t.eq(instances(c.gm, g)[1].rect.dur, 3 * LPR, 'end out +lpr')
      c.cmgr:invoke('shrinkNote')
      c.cmgr:invoke('shrinkNote')
      t.eq(instances(c.gm, g)[1].rect.dur, LPR, 'end in -2 lpr')
    end,
  },

  {
    name = 'duplicate (duplicateDown / groupDuplicate) cascades one group-length on',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))   -- inst 1 @ ppq 0, dur LPR
      armOn(ec, c, g, 1)
      c.cmgr:invoke('groupDuplicate')
      t.deepEq(anchorPpqs(c.gm, g), { 0, LPR }, 'first copy one group-length on')
      c.cmgr:invoke('duplicateDown')
      t.deepEq(anchorPpqs(c.gm, g), { 0, LPR, 2 * LPR }, 'and one more on')
      t.truthy(ec:isInRegionMode(), 'still armed')
    end,
  },

  {
    name = 'paint forwards (groupId, instId, cursorCol, on) to the bridge',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      armOn(ec, c, g, 1)
      local iid = ec:regionCursor().instId
      ec:setPos(0, 2, 1)                       -- caret on col 2
      c.cmgr:invoke('regionPaintExtend')
      c.cmgr:invoke('regionPaintShrink')
      t.eq(#c.bridge.paintCalls, 2)
      t.deepEq(c.bridge.paintCalls[1], { g, iid, 2, true })
      t.deepEq(c.bridge.paintCalls[2], { g, iid, 2, false })
    end,
  },

  ----- spring auto-exit

  {
    name = 'keepAlive nav command runs and keeps the mode armed',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      armOn(ec, c, g, 1)
      t.eq(c.cmgr:invoke('cursorDown'), 'orig:cursorDown', 'nav ran')
      t.truthy(ec:isInRegionMode(), 'still armed')
    end,
  },

  {
    name = 'any other command bails then runs (execute-through)',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      armOn(ec, c, g, 1)
      t.eq(c.cmgr:invoke('someOther'), 'orig:someOther', 'foreign command ran')
      t.falsy(ec:isInRegionMode(), 'and disarmed')
      t.eq(ec:regionCursor(), nil)
    end,
  },
}
