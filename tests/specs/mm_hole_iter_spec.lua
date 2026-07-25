-- mm's four iterators must keep yielding every survivor of a delete taken mid-modify:
-- the ones ahead of it and - the original bug - the ones behind it.
--
-- Stable slots retired the hole this was first written against: mm:delete now splices the
-- slot out of the order array, so a walk started after the delete never sees it at all.
-- Each case takes a fresh iterator after the delete for that reason - splicing under a
-- live one raises (docs/midiManager.md § Mutation contract).

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
      for _, n in mm:notes() do if n.ppq == 240 then midTok = n.uuid end end

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
      for _, c in mm:ccs() do if c.ppq == 120 then midTok = c.uuid end end

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
      for _, n in mm:notes() do if n.ppq == 240 then noteMid = n.uuid end end
      for _, c in mm:ccs()   do if c.ppq == 270 then ccMid  = c.uuid end end

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
