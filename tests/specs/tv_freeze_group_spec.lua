-- Track B (fx freeze): the tv verb that converts a producer and mints a stock group over its
-- own output. tm_fx_region_spec pins the conversion and the thin; this spec is the wiring --
-- the gate, the mint, and the one undo block they share.
-- see design/fx-freeze.md § Freeze to group
local t    = require('support')
local util = require('util')

local sine30 = { { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } }
local arpUp  = { { kind = 'arp',  period = { 1, 4 }, dir = 'up' } }

-- A mixed chain over a note: the arp promotes derived notes, the sine leaves pb breakpoints,
-- so the one fixture yields both member kinds without registering a stub generator.
local function injectMixed(h, over)
  local region = { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                   fx = { arpUp[1], sine30[1] } }
  for k, v in pairs(over or {}) do region[k] = v end
  h.ds:assign('fxRegions', { region })
  h.tm:rebuild()
end

local function addNote(h)
  h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                 vel = 100, detune = 0, delay = 0, lane = 1 }
  h.tm:flush()
end

local function fxColFor(h, chan)
  for i, c in ipairs(h.vm.grid.cols) do
    if c.type == 'fx' and c.midiChan == chan then return c, i end
  end
end

local function noteColIdx(h, chan)
  for i, c in ipairs(h.vm.grid.cols) do
    if c.type == 'note' and c.midiChan == chan and c.lane == 1 then return i end
  end
end

local function authoredUuid(h)
  for _, n in ipairs(h.fm:dump().notes) do if not n.derived then return n.uuid end end
end

local function authoredPitches(h)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do
    if not n.derived then out[#out + 1] = n.pitch end
  end
  table.sort(out)
  return out
end

-- util.atomic reads reaper.Undo_BeginBlock at call time, so a stub installed after the wrap still
-- counts. Outermost blocks only: inner blocks collapse into the verb's.
local function blockCounter(h)
  local depth, blocks = 0, 0
  h.reaper.Undo_BeginBlock = function()
    if depth == 0 then blocks = blocks + 1 end
    depth = depth + 1
  end
  h.reaper.Undo_EndBlock = function() depth = depth - 1 end
  return function() return blocks end
end

return {

  {
    name = 'freeze to group: the conversion mints one group over its own output',
    run = function(harness)
      local h = harness.mk{ groups = true }
      h.vm:setGridSize(80, 40)
      addNote(h)
      injectMixed(h)
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)

      h.cmgr:invoke('freezeFxGroup')

      t.eq(#(h.ds:get('fxRegions') or {}), 0, 'the producer is gone -- the conversion ran')
      local insts = h.gm:eachInstance()
      t.eq(#insts, 1, 'exactly one group, seated at its own origin')
      t.eq(insts[1].anchor.ppq,  0, 'anchored at the producer onset')
      t.eq(insts[1].anchor.chan, 1, 'on the producer channel')
      t.eq(insts[1].rect.dur,  240, 'over the producer span')

      local promoted = 0
      for _, n in ipairs(h.fm:dump().notes) do
        if not n.derived then
          promoted = promoted + 1
          t.truthy(h.gm:stateOf(n.uuid), 'each promoted note is a member of the mint')
        end
      end
      t.truthy(promoted > 0, 'the arp promoted notes')

      local pbCol = h.tm:getChannel(1).columns.pb
      t.truthy(pbCol, 'the frozen sine left a pb column')
      local survivors = 0
      for _, e in ipairs(pbCol.events) do
        if not e.hidden then
          survivors = survivors + 1
          t.truthy(h.gm:stateOf(e.uuid), 'each surviving breakpoint is a member of the mint')
        end
      end
      t.truthy(survivors > 0, 'and breakpoints to be members of')
    end,
  },

  {
    -- gm persists on tm's postflush and flush() returns early with nothing staged, so the mint's
    -- flush carries no mm ops of its own and needs tm:requestRebuild to get past that gate. Without
    -- it the groups write rides the *next* edit's undo block. see design/fx-freeze.md § Freeze to group
    name = 'freeze to group: two rebuilds, one undo block',
    run = function(harness)
      local h = harness.mk{ groups = true }
      h.vm:setGridSize(80, 40)
      addNote(h)
      injectMixed(h)
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)

      local rebuilds = 0
      h.tm:subscribe('rebuild', function() rebuilds = rebuilds + 1 end)
      local blocks = blockCounter(h)

      h.cmgr:invoke('freezeFxGroup')

      t.eq(rebuilds, 2, 'one rebuild for the conversion, one carrying the mint to gm postflush')
      t.eq(blocks(), 1, 'and both inside a single undo block')
      local persisted = (h.ds:get('groups') or {}).groups or {}
      t.truthy(next(persisted), 'the group persisted within it, not left for the next edit')
    end,
  },

  {
    -- The gate runs before any mutation: markGroup's own refusal arrives after the conversion has
    -- already destroyed the producer, leaving a freeze with nothing minted over it.
    -- see design/fx-freeze.md § Freeze to group
    name = 'freeze to group: a colliding footprint declines before anything moves',
    run = function(harness)
      local h = harness.mk{ groups = true }
      h.vm:setGridSize(80, 40)
      addNote(h)
      injectMixed(h)
      t.truthy(h.gm:markGroup({}, h.tm:freezeRect('fxr-1')),
               'an empty group squats on the footprint the mint would claim')
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)

      local before = util.deepClone(h.ds:get('fxRegions'))
      local blocks = blockCounter(h)
      h.cmgr:invoke('freezeFxGroup')

      t.eq(blocks(), 0, 'the decline opens no undo block')
      t.deepEq(h.ds:get('fxRegions'), before, 'the producer stands, chain intact')
      t.eq(#h.gm:eachInstance(), 1, 'and nothing was minted')
      t.eq(h.vm:freezeMode('fxr-1'), 'raw', 'the raw freeze is still on offer')
    end,
  },

  {
    name = 'freeze to group: a plain note at the caret is no producer',
    run = function(harness)
      local h = harness.mk{ groups = true }
      h.vm:setGridSize(80, 40)
      addNote(h)
      h.ec:setPos(0, noteColIdx(h, 1), 1)
      t.falsy(h.vm:freezeMode(authoredUuid(h)), 'a plain note offers no freeze at all')

      local blocks = blockCounter(h)
      h.cmgr:invoke('freezeFxGroup')

      t.eq(blocks(), 0, 'so the verb is never reached')
      t.eq(#h.gm:eachInstance(), 0, 'nothing minted')
      t.deepEq(authoredPitches(h), { 60 }, 'and the note stands')
    end,
  },
}
