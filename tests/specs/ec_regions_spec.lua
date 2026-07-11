-- ec group-authoring mode: real cmgr spring-loaded stack, real groupManager (fake tm/cm).
-- ec builds 'region' scope at instantiate; bridge fakes tv surface, not ec's verb bodies.

local t    = require('support')
local util = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {}, assign = {}, del = {} }, 0
  local tm = {}
  function tm:length()           return math.huge end   -- groups here are empty; onTake unused
  function tm:subscribe(sig, fn) hooks[sig] = fn end
  function tm:requestRebuild()   end
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

-- rect spanning two channels (one note lane each) -- the multi-channel
-- dispatch: eventShift channel-moves rather than lane-walks.
local function rectMulti(ppq, dur)
  return { ppq = ppq, dur = dur, chanLo = 1,
           streams = { [0] = { ['note:1'] = true }, [1] = { ['note:1'] = true } } }
end

local LPR = 10

local function mk(opts)
  opts = opts or {}
  local tm = fakeTm()
  local gm = util.instantiate('groupManager', { tm = tm, ds = t.fakeDs() })

  local cols = { { type = 'note', midiChan = 1, lane = 1 },
                 { type = 'note', midiChan = 1, lane = 2 },
                 { type = 'note', midiChan = 2, lane = 1 },
                 { type = 'note', midiChan = 2, lane = 2 } }
  local grid = { cols = cols, numRows = opts.numRows or 20,
                 chanFirstCol = { [1] = 1, [2] = 3 },
                 chanLastCol  = { [1] = 2, [2] = 4 } }

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
    name = 'a nudge previews the move without mutating gm; the caret tracks it',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      armOn(ec, c, g, 1)
      ec:setPos(5, 1, 1)
      c.cmgr:invoke('nudgeForward')
      t.eq(instances(c.gm, g)[1].anchor.ppq, 0, 'gm instance unmoved during preview')
      t.eq(ec:row(), 6, 'caret tracked the preview')
      c.cmgr:invoke('nudgeBack')
      t.eq(ec:row(), 5, 'caret tracked back')
      t.truthy(ec:isInRegionMode())
    end,
  },

  {
    name = 'leaving region mode commits the net drag',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      armOn(ec, c, g, 1)
      ec:setPos(0, 1, 1)
      c.cmgr:invoke('nudgeForward')
      c.cmgr:invoke('nudgeForward')
      t.eq(instances(c.gm, g)[1].anchor.ppq, 0, 'still unmoved before exit')
      c.cmgr:invoke('regionExit')
      t.eq(instances(c.gm, g)[1].anchor.ppq, 2 * LPR, 'committed at +2 rows on exit')
    end,
  },

  {
    name = 'a nudged-then-returned drag commits nothing on exit',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      armOn(ec, c, g, 1)
      ec:setPos(5, 1, 1)
      c.cmgr:invoke('nudgeForward')
      c.cmgr:invoke('nudgeBack')
      local commits = c.bridge.commits
      c.cmgr:invoke('regionExit')
      t.eq(c.bridge.commits, commits, 'net-zero delta: no flush on exit')
      t.eq(instances(c.gm, g)[1].anchor.ppq, 0, 'instance unmoved')
    end,
  },

  {
    name = 'move pins the top at row 0 but lets the bottom hang off, one row left',
    run = function()
      local ec, c = mk()                       -- numRows 20, lpr LPR
      -- top: a group at row 0 cannot preview above it.
      local top = c.gm:mark({}, rect(0, LPR))
      armOn(ec, c, top, 1)
      ec:setPos(0, 1, 1)
      c.cmgr:invoke('nudgeBack')
      t.eq(ec:row(), 0, 'caret pinned: the top cannot preview above row 0')
      c.cmgr:invoke('regionExit')
      t.eq(instances(c.gm, top)[1].anchor.ppq, 0, 'top still at row 0 after commit')

      -- bottom: a 3-row group hangs off the end until one row remains
      -- (top row at numRows - 1 = 19), past the old whole-inside limit (17).
      local bot = c.gm:mark({}, rect(17 * LPR, 3 * LPR))
      armOn(ec, c, bot, 1)
      ec:setPos(17, 1, 1)
      c.cmgr:invoke('nudgeForward')
      c.cmgr:invoke('nudgeForward')
      t.eq(ec:row(), 19, 'caret reaches the last take row')
      c.cmgr:invoke('nudgeForward')
      t.eq(ec:row(), 19, 'clamps there -- one row must remain')
      c.cmgr:invoke('regionExit')
      t.eq(instances(c.gm, bot)[1].anchor.ppq, 19 * LPR, 'committed at the last take row')
    end,
  },

  {
    name = 'eventShift walks a single-lane region across lanes, then spills to the next channel',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))   -- channel 1, lane 1
      armOn(ec, c, g, 1)
      ec:setPos(0, 1, 1)
      c.cmgr:invoke('eventShiftRight')        -- lane 1 -> lane 2, still channel 1
      t.eq(ec:regionCursor().laneDelta, 1, 'lane delta accumulated')
      t.eq(ec:regionCursor().chanDelta or 0, 0, 'no channel change yet')
      t.eq(ec:col(), 2, 'caret on the lane-2 column')
      t.eq(instances(c.gm, g)[1].anchor.laneDelta or 0, 0, 'gm untouched during preview')
      c.cmgr:invoke('eventShiftRight')        -- lane boundary -> spill whole block to channel 2
      t.eq(ec:regionCursor().chanDelta, 1, 'spilled one channel over')
      t.eq(ec:regionCursor().laneDelta, 0, 'landed on the new channel edge lane')
      t.eq(ec:col(), 3, 'caret on channel 2, lane 1')
      c.cmgr:invoke('regionExit')
      local inst = instances(c.gm, g)[1]
      t.eq(inst.anchor.chan, 2, 'committed on channel 2')
      t.eq(inst.anchor.laneDelta or 0, 0, 'at the edge lane')
    end,
  },

  {
    name = 'a single-lane region cannot walk past lane 1 of channel 1',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      armOn(ec, c, g, 1)
      ec:setPos(0, 1, 1)
      c.cmgr:invoke('eventShiftLeft')
      t.eq(ec:regionCursor().laneDelta or 0, 0, 'lane 1 / channel 1 is the corner')
      t.eq(ec:regionCursor().chanDelta or 0, 0)
    end,
  },

  {
    name = 'a multi-channel region channel-moves and clamps at channel 16',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rectMulti(0, LPR))   -- channels 1-2
      armOn(ec, c, g, 1)
      ec:setPos(0, 1, 1)
      c.cmgr:invoke('eventShiftRight')
      t.eq(ec:regionCursor().chanDelta, 1, 'multi-channel region channel-moves')
      t.eq(ec:regionCursor().laneDelta or 0, 0, 'lane untouched')
      c.cmgr:invoke('regionExit')
      t.eq(instances(c.gm, g)[1].anchor.chan, 2, 'committed one channel over')

      local iid = c.gm:newInstance(g, { ppq = 0, chan = 15 })  -- occupies 15-16
      armOn(ec, c, g, iid)
      c.cmgr:invoke('eventShiftRight')
      t.eq(ec:regionCursor().chanDelta or 0, 0, 'channel 16 is the ceiling')
    end,
  },

  {
    name = 'row and lane deltas compose into a diagonal commit',
    run = function()
      local ec, c = mk()
      local g = c.gm:mark({}, rect(0, LPR))
      armOn(ec, c, g, 1)
      ec:setPos(0, 1, 1)
      c.cmgr:invoke('nudgeForward')
      c.cmgr:invoke('eventShiftRight')
      t.eq(instances(c.gm, g)[1].anchor.ppq, 0, 'unmoved during preview')
      c.cmgr:invoke('regionExit')
      local inst = instances(c.gm, g)[1]
      t.eq(inst.anchor.ppq, LPR, 'committed +1 row')
      t.eq(inst.anchor.laneDelta, 1, 'and +1 lane')
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
