-- diffGroup emits {delay=util.REMOVE} on revive when original delay=0; that sentinel crashed
-- realiseNoteUpdate (delayToPPQ on a table). Real tm+gm: fake-tm never realises the assign.

local t       = require('support')
local harness = require('harness')

local function seededHarness()
  return harness.mk{
    groups = true,
    seed   = { length = 7680, resolution = 240, notes = {
      { ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
        chan = 1, lane = 1, pitch = 60, vel = 100, uuid = 1 },
    } },
  }
end

local RECT = { ppq = 0, dur = 960, chanLo = 1,
               streams = { [0] = { ['note:1'] = true } } }

local function noteAtPpq(h, ppq)
  for _, n in ipairs(h.fm:dump().notes) do
    if n.ppq == ppq then return n end
  end
end

return {
  {
    name = 'global type-over a locally-deleted slot revives without choking on delay=REMOVE',
    run = function()
      local h   = seededHarness()
      local gm  = h.gm
      local gid = gm:markGroup(h.vm:eventsInRect(RECT), RECT)
      gm:newInstance(gid, { ppq = 960, chan = 1 })   -- instance copy lands at ppq 960
      h.tm:flush()

      local copy = noteAtPpq(h, 960)
      t.truthy(copy, 'instance copy projected at the anchor slot')

      gm:setLocalMode(true)
      gm:deleteEvent(copy.uuid); h.tm:flush()
      gm:setLocalMode(false)

      -- Typed create over the now-empty slot. No delay field, mirroring tv's
      -- create path (tm defaults delay only on add, after toGroup runs).
      gm:addEvent{ evType = 'note', chan = 1, lane = 1, ppq = 960,
                   endppq = 1200, pitch = 99, vel = 100 }
      h.tm:flush()

      local revived = noteAtPpq(h, 960)
      t.truthy(revived, 'slot revived with the typed note')
      t.eq(revived.pitch, 99, 'carries the typed pitch, not the old member value')
    end,
  },
}
