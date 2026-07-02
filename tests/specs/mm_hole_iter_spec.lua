-- Phase B pin - design/deferred-reindex.md item 2. mm's four iterators skip
-- the holes a delete leaves in the sparse note/cc arrays and keep yielding
-- survivors past the hole, up to the noteCount/ccCount high-water mark.
--
-- The holes only exist mid-modify today (mm:modify compacts at unwind), so
-- the spec observes them from inside the modify closure - the exact state
-- the deferred-reindex flip (Phase D) makes the whole pipeline run against.

local t = require('support')

local function ppqsOf(iter)
  local out = {}
  for _, e in iter do out[#out + 1] = e.ppq end
  table.sort(out)
  return out
end

return {
  {
    name = 'notes() skips a mid-array delete hole and yields the survivor past it',
    run = function(harness)
      local mm = harness.bareMM{ notes = {
        { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
        { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100 },
        { ppq = 480, endppq = 720, chan = 1, pitch = 64, vel = 100 },
      } }
      local midTok
      for _, n in mm:notes() do if n.ppq == 240 then midTok = mm:tokenOf(n) end end

      local seen
      mm:modify(function()
        mm:delete(midTok)
        seen = ppqsOf(mm:notes())
      end)

      t.eq(#seen, 2, 'both survivors yielded despite the mid-array hole')
      t.eq(seen[1], 0)
      t.eq(seen[2], 480, 'the note past the hole is not truncated')
    end,
  },

  {
    name = 'ccs() and ccsRaw() skip a mid-array delete hole',
    run = function(harness)
      local mm = harness.bareMM{ ccs = {
        { ppq =   0, evType = 'cc', chan = 1, cc = 7, val = 10 },
        { ppq = 120, evType = 'cc', chan = 1, cc = 7, val = 20 },
        { ppq = 240, evType = 'cc', chan = 1, cc = 7, val = 30 },
      } }
      local midTok
      for _, c in mm:ccs() do if c.ppq == 120 then midTok = mm:tokenOf(c) end end

      local cloned, raw
      mm:modify(function()
        mm:delete(midTok)
        cloned = ppqsOf(mm:ccs())
        raw    = ppqsOf(mm:ccsRaw())
      end)

      t.eq(#cloned, 2, 'ccs() yields both survivors')
      t.eq(cloned[1], 0); t.eq(cloned[2], 240)
      t.eq(#raw, 2, 'ccsRaw() yields both survivors')
      t.eq(raw[1], 0); t.eq(raw[2], 240)
    end,
  },

  {
    name = 'events() skips holes in both the note and the cc array',
    run = function(harness)
      local mm = harness.bareMM{
        notes = {
          { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
          { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100 },
          { ppq = 480, endppq = 720, chan = 1, pitch = 64, vel = 100 },
        },
        ccs = {
          { ppq =  30, evType = 'cc', chan = 2, cc = 7, val = 10 },
          { ppq = 270, evType = 'cc', chan = 2, cc = 7, val = 20 },
          { ppq = 510, evType = 'cc', chan = 2, cc = 7, val = 30 },
        },
      }
      local noteMid, ccMid
      for _, n in mm:notes() do if n.ppq == 240 then noteMid = mm:tokenOf(n) end end
      for _, c in mm:ccs()   do if c.ppq == 270 then ccMid  = mm:tokenOf(c) end end

      local ppqs
      mm:modify(function()
        mm:delete(noteMid)
        mm:delete(ccMid)
        ppqs = ppqsOf(mm:events())
      end)

      t.eq(#ppqs, 4, 'all four survivors across both arrays')
      t.eq(ppqs[1], 0);   t.eq(ppqs[2], 30)
      t.eq(ppqs[3], 480); t.eq(ppqs[4], 510)
    end,
  },
}
