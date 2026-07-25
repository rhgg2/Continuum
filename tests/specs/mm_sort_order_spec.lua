-- Pins rebuild's ordering contract: after a modify, notes/ccs come back
-- ppq-sorted, and a newly added event sits behind everything already at its
-- ppq. Exercises both sort paths: the near-sorted insertion pass and the
-- shift-budget fallback that a bulk reverse-order add trips.
-- A ppq move lands among its new equals by the same rule as an add: one splice
-- serves both, so the mechanism settles what design/stable-slots.md § Equal-ppq
-- order left open for phase 1.

local t = require('support')
local midiBlob = require('midiBlob')

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

-- One field of everything sitting at one ppq, in walk order: exactly what the
-- equal-ppq rule constrains, and nothing else.
local function fieldAt(iter, ppq, field)
  local out = {}
  for _, e in iter do if e.ppq == ppq then out[#out + 1] = e[field] end end
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
      t.deepEq(fieldAt(mm:ccsRaw(), 100, 'cc'), { 7, 1 }, 'coincident ccs stay in insertion order')
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
      t.deepEq(fieldAt(mm:notesRaw(), 5, 'pitch'), { 60, 61 },
        'equal-ppq pair keeps insertion order through the fallback')
    end,
  },

  {
    -- The rule Phase 1's binary search has to target: an added event inserts
    -- after everything already at that ppq. see design/stable-slots.md
    name = 'a note added at an occupied ppq lands behind the note already there',
    run = function(harness)
      local mm = harness.bareMM{ notes = {
        { ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 100 },
      } }
      mm:modify(function()
        mm:add{ evType = 'note', ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100 }
      end)
      t.deepEq(fieldAt(mm:notesRaw(), 240, 'pitch'), { 60, 62 },
        'the added note sits behind its equal')
    end,
  },

  {
    -- The consequence of one splice serving both verbs: the add rule decides the
    -- move as well. Under the dense-loc reindex the moved note stayed put instead.
    name = 'a note moved onto an occupied ppq lands behind the note already there',
    run = function(harness)
      local mm = harness.bareMM{ notes = {
        { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
        { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100 },
      } }
      local moved
      for _, n in mm:notesRaw() do if n.ppq == 0 then moved = n.uuid end end
      mm:modify(function() mm:assign(moved, { ppq = 240, endppq = 480 }) end)

      t.deepEq(fieldAt(mm:notesRaw(), 240, 'pitch'), { 62, 60 },
        'the moved note sits behind the note already at 240')
    end,
  },

  {
    name = 'a backwards ppq move lands behind its new equals too',
    run = function(harness)
      local mm = harness.bareMM{ notes = {
        { ppq =   0, endppq = 120, chan = 1, pitch = 60, vel = 100 },
        { ppq = 120, endppq = 240, chan = 1, pitch = 62, vel = 100 },
        { ppq = 240, endppq = 480, chan = 1, pitch = 64, vel = 100 },
      } }
      local moved
      for _, n in mm:notesRaw() do if n.ppq == 240 then moved = n.uuid end end
      mm:modify(function() mm:assign(moved, { ppq = 0, endppq = 120 }) end)

      t.deepEq(orderedPpqs(mm:notesRaw()), { 0, 0, 120 }, 'the move re-sorted downwards')
      t.deepEq(fieldAt(mm:notesRaw(), 0, 'pitch'), { 60, 64 },
        'and it landed behind the note already at 0')
    end,
  },

  {
    -- serialise keys on (ppq, rank, slot), so among equal-ppq siblings the wire follows
    -- slot order -- and free-list reuse can hand a new event a slot below one already
    -- there. Model and wire diverge here on purpose. see plan/stable-slots.md
    name = 'equal-ppq wire order follows slot, not model order',
    run = function(harness)
      local mm = harness.bareMM{ notes = {
        { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100 },   -- slot 1
        { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100 },   -- slot 2
      } }
      local doomed
      for _, n in mm:notesRaw() do if n.ppq == 0 then doomed = n.uuid end end

      local blob
      local realSetAllEvts = reaper.MIDI_SetAllEvts
      reaper.MIDI_SetAllEvts = function(take, evts) blob = evts; return realSetAllEvts(take, evts) end
      mm:modify(function()
        mm:delete(doomed)   -- slot 1 onto the LIFO free list; the add takes it straight back
        mm:add{ evType = 'note', ppq = 240, endppq = 480, chan = 1, pitch = 64, vel = 100 }
      end)
      reaper.MIDI_SetAllEvts = realSetAllEvts

      local wirePitches = {}
      for _, n in ipairs(midiBlob.parse(blob)) do
        if n.ppq == 240 then wirePitches[#wirePitches + 1] = n.pitch end
      end
      t.deepEq(wirePitches, { 64, 62 }, 'the reused low slot puts the new note first on the wire')
      t.deepEq(fieldAt(mm:notesRaw(), 240, 'pitch'), { 62, 64 },
        'while the model still obeys the add-after-equals rule')
    end,
  },
}
