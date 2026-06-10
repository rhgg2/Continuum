-- Binding mutations through the real tv path. automateParam binds the
-- palette param at the cursor channel and requests its cc column;
-- unautomateParam empties the lane, then column + binding go via
-- hideExtraCol; hideExtraCol alone also drops the binding of an empty
-- bound column. Real trackerView + real paramAutomation via harness.mk.

local t = require('support')

local NOTE = { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
               detune = 0, delay = 0, lane = 1 }

local BINDING = { busCode = 0, trackGuid = '{DST}', fxGuid = '{FX-1}',
                  param = 3, scale = 1, offset = 0, label = 'Cutoff' }

local function ccColIndex(h, cc)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'cc' and col.cc == cc then return i end
  end
end

return {

  {
    name = 'automateParam binds the palette param and requests its cc column',
    run = function(harness)
      local h = harness.mk{ seed = { notes = { NOTE } } }
      h.reaper._state.projectItems = { { takes = { 'take1' } } }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.vm:setPaletteParam{ trackGuid = '{DST}', fxGuid = '{FX-1}', param = 3, label = 'Cutoff' }
      h.vm:automateParam()

      local b = h.vm:paramBinding(1, 119)
      t.truthy(b, 'bound at the top lane')
      t.eq(b.label, 'Cutoff')
      t.eq(b.param, 3)
      t.eq(b.busCode, 0)
      t.truthy(h.cm:get('extraColumns')[1].ccs[119], 'cc column requested')
      h.vm:rebuild()
      t.truthy(ccColIndex(h, 119), 'cc column materialised')

      -- second bind on the same channel walks down a lane, fresh bus code
      h.vm:setPaletteParam{ trackGuid = '{DST}', fxGuid = '{FX-1}', param = 4, label = 'Res' }
      h.vm:automateParam()
      local b2 = h.vm:paramBinding(1, 118)
      t.truthy(b2, 'next lane down')
      t.eq(b2.busCode, 1, 'fresh bus code')
    end,
  },

  {
    name = 'allocation skips authored cc columns and event-bearing ccs',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { NOTE } },
        config = { take = { extraColumns = { [1] = { notes = 1, ccs = { [118] = true } } } } },
      }
      local r = h.reaper
      r._state.projectItems = { { takes = { 'take1' } } }
      r._state.takeIsMidi['take1'] = true
      -- A raw cc 119 on chan 1 lives in reaper but not in the fake mm —
      -- usedLanes scans reaper directly, project-wide.
      r:seedMidi('take1', { ccs = { { ppq = 0, chanmsg = 0xB0, chan = 0, msg2 = 119, msg3 = 64 } } })
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.vm:setPaletteParam{ trackGuid = '{DST}', fxGuid = '{FX-1}', param = 3, label = 'Cutoff' }
      h.vm:automateParam()

      t.truthy(h.vm:paramBinding(1, 117),
        'skipped the user column at 118 and the event-bearing cc at 119')
    end,
  },

  {
    name = 'unautomateParam deletes lane events then removes column and binding',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { NOTE },
          ccs = { { ppq = 0,   chan = 1, evType = 'cc', cc = 110, val = 64 },
                  { ppq = 240, chan = 1, evType = 'cc', cc = 110, val = 80 } },
        },
        config = { take = {
          extraColumns    = { [1] = { notes = 1, ccs = { [110] = true } } },
          paramAutomation = { [1] = { [110] = BINDING } },
        } },
      }
      h.vm:setGridSize(80, 40)
      local idx = ccColIndex(h, 110)
      t.truthy(idx, 'bound cc column present')
      t.eq(#h.vm.grid.cols[idx].events, 2, 'lane holds events')
      h.ec:setPos(0, idx, 1)
      h.vm:unautomateParam()

      t.falsy(h.vm:paramBinding(1, 110), 'binding gone')
      t.falsy(ccColIndex(h, 110), 'column gone')
      t.falsy((h.cm:get('extraColumns')[1] or {}).ccs, 'extraColumns entry cleaned')
    end,
  },

  {
    name = 'hideExtraCol on an empty bound cc column drops the binding',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { NOTE } },
        config = { take = {
          extraColumns    = { [1] = { notes = 1, ccs = { [110] = true } } },
          paramAutomation = { [1] = { [110] = BINDING } },
        } },
      }
      h.vm:setGridSize(80, 40)
      local idx = ccColIndex(h, 110)
      t.truthy(idx, 'bound cc column present')
      h.ec:setPos(0, idx, 1)
      h.vm:hideExtraCol()

      t.falsy(h.vm:paramBinding(1, 110), 'binding gone')
      t.falsy(ccColIndex(h, 110), 'column gone')
    end,
  },

}
