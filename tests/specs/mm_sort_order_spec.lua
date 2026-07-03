-- Pins rebuild's ordering contract: after a modify, notes/ccs come back
-- ppq-sorted with equal-ppq events in insertion order. Exercises both sort
-- paths: the near-sorted insertion pass and the shift-budget fallback that a
-- bulk reverse-order add trips.

local t = require('support')

local function orderedPpqs(iter)
  local out = {}
  for _, e in iter do out[#out + 1] = e.ppq end
  return out
end

local function sortedCopy(list)
  local out = {}
  for i, v in ipairs(list) do out[i] = v end
  table.sort(out)
  return out
end

return {
  {
    name = 'a scattered add lands in ppq order (near-sorted fast path)',
    run = function(harness)
      local mm = harness.bareMM{ notes = {
        { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
        { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100 },
        { ppq = 480, endppq = 720, chan = 1, pitch = 64, vel = 100 },
      } }
      mm:modify(function()
        mm:add{ evType = 'note', ppq = 120, endppq = 200, chan = 1, pitch = 61, vel = 100 }
      end)
      t.deepEq(orderedPpqs(mm:notesRaw()), { 0, 120, 240, 480 },
        'appended note settles into ppq position')
    end,
  },

  {
    name = 'equal-ppq ccs keep insertion order across rebuilds',
    run = function(harness)
      local mm = harness.bareMM()
      mm:modify(function()
        mm:add{ evType = 'cc', ppq = 100, chan = 1, cc = 7, val = 1 }
        mm:add{ evType = 'cc', ppq = 100, chan = 1, cc = 1, val = 2 }
        mm:add{ evType = 'cc', ppq =  50, chan = 1, cc = 4, val = 3 }
      end)
      -- second structural modify forces another rebuild over the settled array
      mm:modify(function()
        mm:add{ evType = 'cc', ppq = 200, chan = 1, cc = 9, val = 4 }
      end)
      local ccNums = {}
      for _, c in mm:ccsRaw() do if c.ppq == 100 then ccNums[#ccNums + 1] = c.cc end end
      t.deepEq(ccNums, { 7, 1 }, 'coincident ccs stay in insertion order')
    end,
  },

  {
    name = 'bulk reverse-order add trips the shift budget and still lands sorted, stably',
    run = function(harness)
      local mm = harness.bareMM()
      mm:modify(function()
        -- 64 notes appended in strictly decreasing ppq: ~2016 inversions >> budget (8n)
        for i = 64, 1, -1 do
          mm:add{ evType = 'note', ppq = i * 10, endppq = i * 10 + 5, chan = 1, pitch = 60, vel = 100 }
        end
        -- equal-ppq pair appended last; must come out in insertion order
        mm:add{ evType = 'note', ppq = 5, endppq = 8, chan = 1, pitch = 60, vel = 100 }
        mm:add{ evType = 'note', ppq = 5, endppq = 8, chan = 1, pitch = 61, vel = 100 }
      end)
      local ppqs = orderedPpqs(mm:notesRaw())
      t.eq(#ppqs, 66, 'all notes survive the fallback sort')
      t.deepEq(ppqs, sortedCopy(ppqs), 'fallback leaves the array ppq-sorted')
      local pitchesAt5 = {}
      for _, n in mm:notesRaw() do if n.ppq == 5 then pitchesAt5[#pitchesAt5 + 1] = n.pitch end end
      t.deepEq(pitchesAt5, { 60, 61 }, 'equal-ppq pair keeps insertion order through the fallback')
    end,
  },
}
