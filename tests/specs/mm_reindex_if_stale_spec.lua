-- Phase C pin - design/deferred-reindex.md item 5. mm:reindexIfStale() is the
-- scaffold Phase D flips onto: it runs a reindex only when a deferred modify
-- left the arrays stale. Nothing sets the stale flag yet, so today the call
-- verifiably reindexes nothing - loadIndex gained it at its head as a no-op.

local t = require('support')

local function tokPpqs(mm)
  local out = {}
  for tok, e in mm:events() do out[#out + 1] = tok .. '@' .. e.ppq end
  return out
end

return {
  {
    name = 'reindexIfStale() is a no-op on already-compact state',
    run = function(harness)
      local mm = harness.bareMM{
        notes = {
          { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
          { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100 },
        },
        ccs = {
          { ppq = 120, evType = 'cc', chan = 1, cc = 7, val = 10 },
        },
      }
      local before = tokPpqs(mm)
      mm:reindexIfStale()
      t.deepEq(tokPpqs(mm), before, 'events unchanged - no reindex fired')
    end,
  },

  {
    name = 'reindexIfStale() stays inert after a compacting modify',
    run = function(harness)
      local mm = harness.bareMM{ notes = {
        { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
        { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100 },
        { ppq = 480, endppq = 720, chan = 1, pitch = 64, vel = 100 },
      } }
      local midTok
      for _, n in mm:notes() do if n.ppq == 240 then midTok = mm:tokenOf(n) end end
      mm:modify(function() mm:delete(midTok) end)   -- rebuild at unwind clears staleness

      local after = tokPpqs(mm)
      mm:reindexIfStale()
      t.deepEq(tokPpqs(mm), after, 'compacted survivors untouched - flag already clear')
    end,
  },
}
