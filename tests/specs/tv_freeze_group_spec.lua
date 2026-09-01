-- Track B (fx freeze): the tv verb that converts a host and mints a stock group over its
-- own output. tm_fx_region_spec pins the conversion and the thin; this spec is the wiring --
-- the gate, the mint, the one undo block they share, and what the mint leaves behind: an
-- ordinary group, which instances, mirrors and deletes like any other.
-- see design/archive/fx-freeze.md § Freeze to group
local t    = require('support')
local util = require('util')

local sine30 = { { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } }
local arpUp  = { { kind = 'arp',  period = { 1, 4 }, dir = 'up' } }

-- A mixed chain over a note: the arp promotes derived notes, the sine leaves pb breakpoints,
-- so the one fixture yields both member kinds without registering a stub generator.
local function injectMixed(h, over)
  local region = { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240,
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

-- The fixture frozen: host converted, mint standing over its own output. Returns the
-- harness and the instance the mint seated.
local function frozen(harness)
  local h = harness.mk{ groups = true }
  h.vm:setGridSize(80, 40)
  addNote(h)
  injectMixed(h)
  local _, ci = fxColFor(h, 1)
  h.ec:setPos(0, ci, 1)
  h.cmgr:invoke('freezeFxGroup')
  return h, h.gm:eachInstance()[1]
end

-- The output standing in one region-length window, by offset from its start -- the shape a
-- sibling instance has to reproduce. Says nothing about how many seats the thin left, which
-- is tm_fx_region_spec's subject and free to move.
local function outputAt(h, lo)
  local dump, notes, seats = h.fm:dump(), {}, {}
  for _, n in ipairs(dump.notes) do
    if n.ppq >= lo and n.ppq < lo + 240 then util.add(notes, { off = n.ppq - lo, pitch = n.pitch }) end
  end
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'pb' and c.ppq >= lo and c.ppq < lo + 240 then
      util.add(seats, { off = c.ppq - lo, cents = c.cents })
    end
  end
  table.sort(notes, function(a, b) return a.off < b.off end)
  table.sort(seats, function(a, b) return a.off < b.off end)
  return { notes = notes, seats = seats }
end

-- The take keyed by uuid, so a comparison across an edit reads an event eaten rather than one
-- merely moved -- the closing seat's whole hazard. Deliberately not filtered by gm membership:
-- a seat left outside the rect is precisely the one a tile clears away, and filtering on
-- stateOf would make the check blind to it.
local function takeEvents(h)
  local dump, out = h.fm:dump(), {}
  for _, n in ipairs(dump.notes) do out[n.uuid] = { ppq = n.ppq, pitch = n.pitch } end
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'pb' then out[c.uuid] = { ppq = c.ppq, cents = c.cents } end
  end
  return out
end

local function pbUuidAt(h, ppq)
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.ppq == ppq then return c.uuid end
  end
end

local function noteUuidAt(h, ppq)
  for _, n in ipairs(h.fm:dump().notes) do
    if n.ppq == ppq then return n.uuid end
  end
end

local function pbColIdx(h, chan)
  for i, c in ipairs(h.vm.grid.cols) do
    if c.type == 'pb' and c.midiChan == chan then return i end
  end
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

      t.eq(#(h.ds:get('fxRegions') or {}), 0, 'the host is gone -- the conversion ran')
      local insts = h.gm:eachInstance()
      t.eq(#insts, 1, 'exactly one group, seated at its own origin')
      t.eq(insts[1].anchor.ppq,  0, 'anchored at the host onset')
      t.eq(insts[1].anchor.chan, 1, 'on the host channel')
      t.eq(insts[1].rect.dur,  240, 'over the host span')

      local promoted = 0
      for _, n in ipairs(h.fm:dump().notes) do
        if not n.derived then
          promoted = promoted + 1
          t.truthy(h.gm:stateOf(n.uuid), 'each promoted note is a member of the mint')
        end
      end
      t.truthy(promoted > 0, 'the arp promoted notes')

      local pbCol = h.tm:getChannel(1).onTake.pb
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
    -- it the groups write rides the *next* edit's undo block. see design/archive/fx-freeze.md § Freeze to group
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
    -- already destroyed the host, leaving a freeze with nothing minted over it.
    -- see design/archive/fx-freeze.md § Freeze to group
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
      t.deepEq(h.ds:get('fxRegions'), before, 'the host stands, chain intact')
      t.eq(#h.gm:eachInstance(), 1, 'and nothing was minted')
      t.eq(h.vm:freezeMode('fxr-1'), 'raw', 'the raw freeze is still on offer')
    end,
  },

  {
    name = 'freeze to group: a plain note at the caret is no host',
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

  ----- After the mint the group is ordinary: no frozen-ness survives it

  {
    -- Directly below is the adjacency that bites: the caller's destination clear starts on the tick
    -- a pb window used to seat its closing member. see design/archive/fx-freeze.md § Freeze to group
    name = 'freeze to group: a sibling tiled directly below replays both member kinds',
    run = function(harness)
      local h, inst = frozen(harness)
      local before = takeEvents(h)
      t.truthy(next(before), 'the mint left output to tile past')

      h.vm:clearRegionAt(inst.rect, { ppq = 240, chan = 1 })
      t.truthy(h.gm:newInstance(inst.groupId, { ppq = 240, chan = 1 }),
               'the copy seats immediately below the original')
      h.tm:flush()

      t.deepEq(outputAt(h, 240), outputAt(h, 0), 'the copy replays the notes and the curve alike')
      local after = takeEvents(h)
      for uuid, e in pairs(before) do
        t.deepEq(after[uuid], e, 'and the copy above keeps every event it had')
      end
    end,
  },

  {
    name = 'freeze to group: a mirror edit on either member kind reaches the sibling',
    run = function(harness)
      local h, inst = frozen(harness)
      h.gm:newInstance(inst.groupId, { ppq = 240, chan = 1 })
      h.tm:flush()

      -- pb's group frame is intent, so the assign is in cents; 60 stays inside the bend range,
      -- where a clamp cannot make two different intents read alike.
      h.gm:assignEvent(pbUuidAt(h, 0), { val = 60 })
      h.tm:flush()
      h.gm:assignEvent(noteUuidAt(h, 0), { pitch = 72 })
      h.tm:flush()

      local sibling = outputAt(h, 240)
      t.eq(sibling.seats[1].cents, 60, 'the sibling opens on the edited curve value')
      t.eq(sibling.notes[1].pitch, 72, 'and on the edited pitch')
      t.deepEq(sibling, outputAt(h, 0), 'the two instances read alike after both edits')
    end,
  },

  {
    -- The host is gone, so nothing re-derives what the delete takes away -- the members are
    -- ordinary authored events now.
    name = 'freeze to group: deleting the group takes its output with it',
    run = function(harness)
      local h, inst = frozen(harness)
      h.gm:newInstance(inst.groupId, { ppq = 240, chan = 1 })
      h.tm:flush()

      h.gm:deleteInstance(inst.groupId, inst.instId)
      h.tm:flush()
      t.deepEq(outputAt(h, 0), { notes = {}, seats = {} }, 'the origin instance took its own events')
      t.truthy(#outputAt(h, 240).notes > 0, 'and the sibling stands')

      for _, i in ipairs(h.gm:eachInstance()) do h.gm:deleteInstance(i.groupId, i.instId) end
      h.tm:flush()
      h.tm:rebuild()

      t.deepEq(outputAt(h, 240), { notes = {}, seats = {} }, 'the last instance empties the take')
      t.deepEq(outputAt(h, 0), { notes = {}, seats = {} }, 'and no rebuild brings the frozen output back')
      t.falsy(next((h.ds:get('groups') or {}).groups or {}), 'the group is gone from the store')
    end,
  },

  {
    -- groupDuplicate over the group's own footprint seeds rather than instances, and markGroup
    -- refuses the overlap -- but tv:clearRegionAt has already emptied the destination by then, and
    -- the destination begins on the tick a pb window seats its closing member.
    -- see design/archive/fx-freeze.md § Freeze to group
    name = 'freeze to group: a refused tile below the mint leaves it whole',
    run = function(harness)
      local h = frozen(harness)
      h.ec:setSelection{ row1 = 0, row2 = 3, col1 = pbColIdx(h, 1), col2 = noteColIdx(h, 1),
                         part1 = 'val', part2 = 'pitch' }
      t.eq(h.vm:selectionAsRect().dur, 240, 'the selection spans the frozen footprint')
      local before = takeEvents(h)
      t.truthy(next(before), 'which has output to lose')

      h.cmgr:invoke('groupDuplicate')

      t.eq(#h.gm:eachInstance(), 1, 'the tile mints nothing -- the source footprint is the group itself')
      local after = takeEvents(h)
      for uuid, e in pairs(before) do
        t.deepEq(after[uuid], e, 'and the destination clear reached none of the frozen output')
      end
    end,
  },
}
