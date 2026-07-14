-- Phase A of the dirt spine (design/archive/dirty-channels.md § Scheme): the CC walk's timing
-- reconcile is gated per dirty channel. A clean channel is converged (raw agrees with its
-- logical projection), so skipping it stages nothing -- but a swing change must still reseat
-- the channels it resolves to. That dirt is config, not carried by the mm reload payload, so
-- markSwingStale must feed the spine or the gate wrongly skips the reseat. This pins that.

local t = require('support')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }
local classic55 = { factors = { { atom = 'classic', shift = 0.05, period = 1 } } }

local function ccRaw(h)
  for _, c in ipairs(h.fm:dump().ccs) do if c.cc == 7 then return c end end
end

return {
  {
    name = 'swing change reseats a CC through the dirtyChans gate',
    run = function(harness)
      -- Seed a foreign cc at raw=139 (no ppqL); the first rebuild stamps ppqL under c58.
      local h = harness.mk{
        seed = { ccs = {
          { ppq = 139, chan = 1, evType = 'cc', cc = 7, val = 64 },
        } },
        config = { project = { swings = { c58 = classic58, c55 = classic55 } } },
        data   = { swing = { global = 'c58' } },
      }
      local before = ccRaw(h)
      t.eq(before.ppq, 139, 'cc raw at the c58 seat before the swing change')
      local logical = before.ppqL   -- stamped by the first rebuild (toLogical_c58(139))
      t.truthy(logical, 'first rebuild stamped ppqL on the foreign cc')

      -- Switch the global swing: dataChanged -> markSwingStale(nil) -> dirtyChan(nil).
      -- The gate lets chan 1 through, so its raw reseats to the c55 realisation of that logical.
      h.ds:assign('swing', { global = 'c55' })

      local after = ccRaw(h)
      t.eq(after.ppq, h.tm:fromLogical(1, logical), 'cc raw reseated to the c55 realisation')
      t.truthy(after.ppq ~= 139, 'the reseat actually moved the raw off the c58 seat')
    end,
  },
}
