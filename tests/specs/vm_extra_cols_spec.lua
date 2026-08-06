-- Pins hideExtraCol's contract: only the topmost empty lane drops, from
-- any lane. See docs/trackerView.md § Extra columns & delay sub-column.

local t = require('support')
local util = require('util')

-- A three-voice chord stamp: over one authored lane-1 note it emits derived lanes 1-3.
local chord3 = { { kind = 'chordStamp', pattern = { kind = 'notes', specs = {
  { lane = 1, ppq = 0, endppq = 240, pitch = 60, vel = 100 },
  { lane = 2, ppq = 0, endppq = 240, pitch = 64, vel = 100 },
  { lane = 3, ppq = 0, endppq = 240, pitch = 67, vel = 100 },
} } } }

-- A one-stage chain aimed at cc 10: dest is a per-entry param, so sine (registry dest pb) claims a cc.
local sineCc = { { kind = 'sine', period = { 1, 2 }, depth = 32, dest = 10 } }

local function noteColsOn(h, chan)
  local out = {}
  for _, c in ipairs(h.vm.grid.cols) do
    if c.type == 'note' and c.midiChan == chan then util.add(out, c) end
  end
  return out
end

return {

  {
    name = 'hideExtraCol on topmost empty note lane shrinks extraColumns',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, lane = 1 },
          },
        },
        data = { extraColumns = { [1] = { notes = 2 } } },
      }
      h.vm:setGridSize(80, 40)

      -- chan 1 lane 1 (has the note) is grid.cols[1]; lane 2 (empty) is [2].
      local laneCol2 = h.vm.grid.cols[2]
      t.eq(laneCol2.lane, 2,            'grid.cols[2] is chan 1 lane 2')
      t.eq(#laneCol2.events, 0,         'lane 2 is empty')

      h.ec:setPos(0, 2, 1)
      h.vm:hideExtraCol()

      local extras = h.ds:get('extraColumns')
      t.eq(extras[1] and extras[1].notes, 1,
           'extraColumns notes count dropped from 2 to 1')

      local laneCols = {}
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'note' and c.midiChan == 1 then
          util.add(laneCols, c)
        end
      end
      t.eq(#laneCols, 1,                'only one note col left on chan 1')
      t.eq(#laneCols[1].events, 1,      'the seeded note survived')
    end,
  },

  {
    name = 'hideExtraCol from a lower lane drops the topmost empty lane',
    run = function(harness)
      -- Note in lane 1, lane 2 empty, cursor on lane 1. Ctrl-Left drops
      -- the top lane regardless of where the cursor sits.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, lane = 1 },
          },
        },
        data = { extraColumns = { [1] = { notes = 2 } } },
      }
      h.vm:setGridSize(80, 40)

      h.ec:setPos(0, 1, 1)
      h.vm:hideExtraCol()

      local extras = h.ds:get('extraColumns')
      t.eq(extras[1] and extras[1].notes, 1,
           'top empty lane dropped from a lower lane')

      local laneCols = {}
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'note' and c.midiChan == 1 then
          util.add(laneCols, c)
        end
      end
      t.eq(#laneCols, 1,                'only one note col left on chan 1')
      t.eq(#laneCols[1].events, 1,      'the seeded note survived')
    end,
  },

  {
    name = 'hideExtraCol with an occupied top lane is a no-op',
    run = function(harness)
      -- Lane 1 empty, lane 2 holds the note. The top lane is occupied,
      -- and lane is rebuild-only, so there is nothing to drop. Refuse.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, lane = 2 },
          },
        },
        data = { extraColumns = { [1] = { notes = 2 } } },
      }
      h.vm:setGridSize(80, 40)

      local laneCol1 = h.vm.grid.cols[1]
      t.eq(laneCol1.lane, 1,            'grid.cols[1] is chan 1 lane 1')
      t.eq(#laneCol1.events, 0,         'lane 1 is empty')

      h.ec:setPos(0, 1, 1)
      h.vm:hideExtraCol()

      local extras = h.ds:get('extraColumns')
      t.eq(extras[1] and extras[1].notes, 2,
           'extraColumns unchanged — interior hide refused')

      local laneCols = {}
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'note' and c.midiChan == 1 then
          util.add(laneCols, c)
        end
      end
      t.eq(#laneCols, 2,                'still two note cols on chan 1')
      local lane2 = laneCols[2]
      t.eq(#lane2.events, 1,            'note still in lane 2')
      t.eq(lane2.events[1].pitch, 60,   'note unchanged')
    end,
  },

  {
    name = 'hideExtraCol drops the top authored lane past a provisional one',
    run = function(harness)
      -- Two authored lanes (the note on lane 1), and a three-voice stamp whose derived
      -- lane 3 shows as a provisional column. Hide counts the authored lanes only.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, lane = 1 },
          },
        },
        data = { extraColumns = { [1] = { notes = 2 } } },
      }
      h.vm:setGridSize(80, 40)
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = chord3 } })
      h.tm:rebuild()

      local before = noteColsOn(h, 1)
      t.eq(#before, 3,                  'fixture check: lanes 1-2 authored, lane 3 provisional')
      t.falsy(before[2].provisional,    'fixture check: lane 2 is the second authored column')
      t.truthy(before[3].provisional,   'fixture check: lane 3 is provisional')

      h.ec:setPos(0, 1, 1)
      h.vm:hideExtraCol()

      local extras = h.ds:get('extraColumns')
      t.eq(extras[1] and extras[1].notes, 1,
           'the top authored lane dropped -- the provisional one is not the user\'s to hide')

      local after = noteColsOn(h, 1)
      t.eq(#after, 3,                   'still three columns: the derived notes still need lanes 2 and 3')
      t.truthy(after[2].provisional,    'lane 2 came straight back as provisional')
      t.truthy(after[3].provisional,    'as did lane 3')
    end,
  },

  {
    name = 'hiding a provisional cc column is a no-op -- it comes straight back',
    run = function(harness)
      -- hideExtraCol's cc arm only clears an extraColumns force, and a chain-claimed column
      -- has none: the write is inert and the column returns from the data.
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                     detune = 0, delay = 0, lane = 1 }
      h.tm:flush()
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = sineCc } })
      h.tm:rebuild()

      local claimed, idx
      for i, c in ipairs(h.vm.grid.cols) do
        if c.type == 'cc' and c.cc == 10 and c.midiChan == 1 then claimed, idx = c, i end
      end
      t.truthy(claimed and claimed.provisional, 'fixture check: cc 10 is provisional')

      h.ec:setPos(0, idx, 1)
      h.vm:hideExtraCol()

      t.eq(h.ds:get('extraColumns'), nil, 'nothing was forced, so nothing is unforced')
      local after
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'cc' and c.cc == 10 and c.midiChan == 1 then after = c end
      end
      t.truthy(after, 'the column is still there')
      t.truthy(after.provisional, 'and still provisional')
    end,
  },

}
