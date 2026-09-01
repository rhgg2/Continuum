-- Park-restore in a swung channel: the one place the restored end's frame shows.
-- Every other park-restore fixture runs under identity swing, where logical and raw
-- are the same number, so an end taken from the wrong frame reads as correct. Here
-- logical 360 restores as raw 379 while the cell's ceiling stays logical, so a frame
-- confusion in either direction fails, and a dropped cell ceiling cannot pass.
--
-- Case 1 holds the restore's authored ceiling and its actual bound at the same number,
-- so it cannot see an end that is written once and never corrected. Case 2 separates
-- them with a clipping lane neighbour: ceiling raw 619, bound raw 379.
-- see design/archive/rebuild-commit-cadence.md § The suite does not discriminate any of this

local t    = require('support')
local util = require('util')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }
local arpUp     = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }

local function findBy(list, key, value)
  for _, item in ipairs(list) do if item[key] == value then return item end end
end

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
        { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240, fx = arpUp } })
      h.tm:rebuild()
      t.eq(#h.tm:getChannel(1).parked, 1, 'the covered note parks off the take')

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()

      local restored = findBy(h.fm:dump().notes, 'uuid', uuid)
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

  {
    name = 'restore clipped by a lane neighbour: the end is the clip, not the ceiling',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58 } } },
        data   = { swing = { global = 'c58' } },
      }
      -- The note that parks: authored ceiling logical 600, raw 619.
      h.tm:addEvent({ evType = 'note', ppq = 120, endppq = 600, chan = 1,
                      pitch = 60, vel = 100, detune = 0, delay = 0, lane = 1 })
      -- The clipper, which stays on take. Same lane, because that is what moves
      -- endppqC; different pitch, so the lane bound alone clips and pitchClip stays
      -- math.huge -- laneBound and rawBound then agree on the clip at raw 379.
      h.tm:addEvent({ evType = 'note', ppq = 360, endppq = 480, chan = 1,
                      pitch = 62, vel = 100, detune = 0, delay = 0, lane = 1 })
      h.tm:flush()

      local authored = findBy(h.fm:dump().notes, 'pitch', 60)
      t.eq(authored.endppq,  379, 'the clip is already in force on take, before any park')
      t.eq(authored.endppqL, 600, 'and the authored ceiling survives it')
      local uuid = authored.uuid

      h.ds:assign('fxRegions',
        { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240, fx = arpUp } })
      h.tm:rebuild()
      t.eq(#h.tm:getChannel(1).parked, 1, 'only the covered note parks; the clipper sits outside')

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()

      local restored = findBy(h.fm:dump().notes, 'uuid', uuid)
      t.truthy(restored, 'the parked note is back on the take under its own uuid')
      t.eq(restored.ppq,     139, 'restored onset lands in the raw frame')
      t.eq(restored.endppq,  379, 'the restored end is the lane clip, not the ceiling 619')
      t.eq(restored.endppqL, 600, 'and the authored logical ceiling rides alongside')

      local cell = findBy(h.tm:getChannel(1).columns.notes[1].events, 'uuid', uuid)
      t.truthy(cell, 'the restored cell is back in its lane, alongside the clipper')
      t.eq(util.round(cell.endppqC), 360,
        'the walk reached the cell and wrote the clipped ceiling, logical')
      t.eq(cell.endppq, 600, 'while the authored ceiling still shows in the column')
    end,
  },

}
