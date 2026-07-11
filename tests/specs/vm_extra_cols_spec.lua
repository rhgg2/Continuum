-- Pins hideExtraCol's contract: only the topmost empty lane drops, from
-- any lane. See docs/trackerView.md § Extra columns & delay sub-column.

local t = require('support')
local util = require('util')

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

}
