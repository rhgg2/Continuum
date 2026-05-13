-- mm:loadRegions / mm:saveRegions: persistence of the take-level region
-- blob via P_EXT:ctm_regions. Run against the real midiManager so the
-- serialise / unserialise round-trip is on the wire, with the fakeReaper
-- backing the P_EXT store.

local t = require('support')

local function withMm(harness, body)
  local h = harness.mk{ seed = { notes = {} } }
  body(h.fm)   -- fm is the real mm in this harness build; takeExt is fakeReaper
end

return {

  {
    name = 'loadRegions on a fresh take returns an empty well-formed blob',
    run = function(harness)
      withMm(harness, function(mm)
        local b = mm:loadRegions()
        t.deepEq(b, { regions = {}, idCtr = 0 })
      end)
    end,
  },

  {
    name = 'saveRegions then loadRegions round-trips the blob',
    run = function(harness)
      withMm(harness, function(mm)
        local blob = {
          regions = {
            { id = 1, colour = 1, ppqLo =   0, ppqHi = 240,
              parts = { ['note:1:1:pitch'] = true, ['note:1:1:vel'] = true } },
            { id = 2, colour = 2, ppqLo = 480, ppqHi = 720,
              parts = { ['cc:1:7'] = true } },
          },
          idCtr = 2,
        }
        mm:saveRegions(blob)
        local got = mm:loadRegions()
        t.deepEq(got, blob)
      end)
    end,
  },

  {
    name = 'saveRegions(nil) writes an empty blob, not garbage',
    run = function(harness)
      withMm(harness, function(mm)
        mm:saveRegions(nil)
        t.deepEq(mm:loadRegions(), { regions = {}, idCtr = 0 })
      end)
    end,
  },

  {
    name = 'idCtr survives across save / load even with empty regions',
    run = function(harness)
      withMm(harness, function(mm)
        mm:saveRegions{ regions = {}, idCtr = 17 }
        t.eq(mm:loadRegions().idCtr, 17)
      end)
    end,
  },

}
