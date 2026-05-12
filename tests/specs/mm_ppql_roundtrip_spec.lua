-- Phase 1 (two-frame timing): ppqL/endppqL ride the per-event metadata
-- channel through mm's save/load loop without explicit whitelist entries.
-- Author notes/ccs through the real mm under modify(), then bring up a
-- second mm against the same take and confirm ppqL/endppqL come back.

local t = require('support')

require('util')
local realMM = require('realMidiManager')()

local function freshTake()
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-ppql-roundtrip'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')
  return take, fakeReaper
end

return {
  {
    name = 'note ppqL/endppqL survive a save/load round-trip',
    run = function()
      local take = freshTake()
      local mm = realMM(take)
      mm:modify(function()
        mm:addNote{ ppq = 120, endppq = 240, chan = 1, pitch = 60, vel = 100,
                    ppqL = 119, endppqL = 239 }
      end)

      local mm2 = realMM(take)
      local _, n = mm2:notes()()
      t.truthy(n, 'note round-tripped')
      t.eq(n.ppq,     120)
      t.eq(n.endppq,  240)
      t.eq(n.ppqL,    119, 'ppqL restored from P_EXT')
      t.eq(n.endppqL, 239, 'endppqL restored from P_EXT')
    end,
  },

  {
    name = 'cc ppqL survives a save/load round-trip (lazy-sidecar allocates uuid)',
    run = function()
      local take = freshTake()
      local mm = realMM(take)
      mm:modify(function()
        mm:addCC{ ppq = 60, msgType = 'cc', chan = 1, cc = 7, val = 64,
                  ppqL = 59 }
      end)

      local mm2 = realMM(take)
      local _, c = mm2:ccs()()
      t.truthy(c, 'cc round-tripped')
      t.truthy(c.uuid, 'metadata stamp allocated a uuid (sidecar)')
      t.eq(c.ppq,  60)
      t.eq(c.ppqL, 59, 'ppqL restored from P_EXT')
    end,
  },

  {
    name = 'pb ppqL survives a save/load round-trip',
    run = function()
      local take = freshTake()
      local mm = realMM(take)
      mm:modify(function()
        mm:addCC{ ppq = 80, msgType = 'pb', chan = 2, val = 1024,
                  ppqL = 79 }
      end)

      local mm2 = realMM(take)
      local _, c = mm2:ccs()()
      t.truthy(c, 'pb round-tripped')
      t.eq(c.msgType, 'pb')
      t.eq(c.ppq,  80)
      t.eq(c.ppqL, 79, 'ppqL restored from P_EXT')
    end,
  },

  {
    name = 'plain cc with no ppqL stays plain (no uuid; no P_EXT entry)',
    run = function()
      local take = freshTake()
      local mm = realMM(take)
      mm:modify(function()
        mm:addCC{ ppq = 30, msgType = 'cc', chan = 1, cc = 11, val = 32 }
      end)

      local mm2 = realMM(take)
      local _, c = mm2:ccs()()
      t.truthy(c)
      t.eq(c.uuid, nil, 'no metadata, no uuid (lazy-sidecar)')
      t.eq(c.ppqL, nil)
    end,
  },

  {
    name = 'mixed take: many events, all ppqL stamps survive concurrently',
    run = function()
      local take = freshTake()
      local mm = realMM(take)
      mm:modify(function()
        mm:addNote{ ppq = 100, endppq = 200, chan = 1, pitch = 60, vel = 100, ppqL = 99,  endppqL = 199 }
        mm:addNote{ ppq = 300, endppq = 400, chan = 2, pitch = 64, vel = 110, ppqL = 301, endppqL = 401 }
        mm:addCC  { ppq = 50,  msgType = 'cc', chan = 1, cc = 7,  val = 64,   ppqL = 49 }
        mm:addCC  { ppq = 150, msgType = 'cc', chan = 1, cc = 7,  val = 80,   ppqL = 151 }
      end)

      local mm2 = realMM(take)

      local notes = {}
      for _, n in mm2:notes() do notes[#notes+1] = n end
      table.sort(notes, function(a, b) return a.ppq < b.ppq end)
      t.eq(#notes, 2)
      t.eq(notes[1].ppqL,    99)
      t.eq(notes[1].endppqL, 199)
      t.eq(notes[2].ppqL,    301)
      t.eq(notes[2].endppqL, 401)

      local ccs = {}
      for _, c in mm2:ccs() do ccs[#ccs+1] = c end
      table.sort(ccs, function(a, b) return a.ppq < b.ppq end)
      t.eq(#ccs, 2)
      t.eq(ccs[1].ppqL, 49)
      t.eq(ccs[2].ppqL, 151)
    end,
  },
}
