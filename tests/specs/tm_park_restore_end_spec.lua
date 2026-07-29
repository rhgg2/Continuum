-- Park-restore in a swung channel: the one place the restored end's frame shows.
-- Every other park-restore fixture runs under identity swing, where logical and raw
-- are the same number, so an end taken from the wrong frame reads as correct. Here
-- logical 360 restores as raw 379 while the cell's ceiling stays logical, so a frame
-- confusion in either direction fails, and a dropped cell ceiling cannot pass.
-- see design/rebuild-commit-cadence.md § The suite does not discriminate any of this

local t    = require('support')
local util = require('util')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }
local arpUp     = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }

return {

  {
    name = 'restore under swing: the mm end is raw, the cell ceiling stays logical',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58 } } },
        data   = { swing = { global = 'c58' } },
      }
      -- Onset and ceiling are both mid-period, so c58 bows both off their logical
      -- values -- which is what identity-swing fixtures cannot do.
      h.tm:addEvent({ evType = 'note', ppq = 120, endppq = 360, chan = 1,
                      pitch = 60, vel = 100, detune = 0, delay = 0, lane = 1 })
      h.tm:flush()

      local authored = h.fm:dump().notes[1]
      t.eq(authored.ppq,    139, 'c58 maps logical onset 120 to raw 139')
      t.eq(authored.endppq, 379, 'and logical ceiling 360 to raw 379')
      local uuid = authored.uuid

      h.ds:assign('fxRegions',
        { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = arpUp } })
      h.tm:rebuild()
      t.eq(#h.tm:getChannel(1).parked, 1, 'the covered note parks off the take')

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()

      local restored
      for _, n in ipairs(h.fm:dump().notes) do if n.uuid == uuid then restored = n end end
      t.truthy(restored, 'the parked note is back on the take under its own uuid')
      t.eq(restored.ppq,     139, 'restored onset lands in the raw frame')
      t.eq(restored.endppq,  379, 'restored end lands in the raw frame, not at the logical 360')
      t.eq(restored.endppqL, 360, 'and carries the logical ceiling alongside it')

      local cell = h.tm:getChannel(1).columns.notes[1].events[1]
      t.eq(cell.uuid, uuid, 'the restored cell is back in its lane')
      t.truthy(cell.endppqC, 'the tail walk reached the restored cell and wrote its ceiling')
      -- Rounded: endppqC is toLogical of the *rounded* raw end, so it lands a fifth of
      -- a tick short of 360. The frame is the assertion, not the last decimal.
      t.eq(util.round(cell.endppqC), 360,
        'the cell ceiling is the logical 360, never the raw 379')
    end,
  },

}
