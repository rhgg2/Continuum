-- Phase D pins - design/archive/deferred-reindex.md item 1. With the reindex deferred to
-- one rebuild at the outermost unwind, the whole tm:rebuild pipeline runs against
-- the sparse (holed) cc array a mid-pipeline delete leaves behind. Three pipeline
-- stages read mm:ccsRaw() downstream of such a delete; each must see the survivors
-- past the hole, not truncate at it. Green today rests on Phase B's hole-tolerant
-- iterators AND Phase D's deferral - revert either and a survivor vanishes.

local t = require('support')

local function tokenOfNote(mm, chan, pitch)
  for _, n in mm:notes() do
    if n.chan == chan and n.pitch == pitch then return mm:tokenOf(n) end
  end
end

local function ccTokenAt(mm, chan, evType, ppq)
  for _, c in mm:ccsRaw() do
    if c.chan == chan and c.evType == evType and c.ppq == ppq then return mm:tokenOf(c) end
  end
end

local function pcCol(h, chan)
  local out = {}
  for _, e in ipairs(h.tm:getChannel(chan).columns.pc.events) do
    out[#out + 1] = { ppq = e.ppq, val = e.val }
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

local function pasInCol(h, chan)
  local out = {}
  for _, col in ipairs(h.tm:getChannel(chan).columns.notes) do
    for _, e in ipairs(col.events) do
      if e.evType == 'pa' then out[#out + 1] = e.ppq end
    end
  end
  table.sort(out)
  return out
end

-- Authored (visible) pbs projected into the pb column, as { ppq, cents }.
local function authoredPbCol(h, chan)
  local out = {}
  local col = h.tm:getChannel(chan).columns.pb
  for _, e in ipairs((col and col.events) or {}) do
    if not e.hidden then out[#out + 1] = { ppq = e.ppq, cents = e.val } end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

return {

  {
    name = 'PC re-projection reads past a mid-pipeline PC-delete hole (:2362)',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 1 },
          { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0, sample = 2 },
          { ppq = 480, endppq = 720, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0, sample = 3 },
        } },
        config = { transient = { trackerMode = true } },
      }
      -- Delete the lowest-ppq note: reconcile deletes its PC (hole at the first cc
      -- loc), then :2362 rebuilds the pc column from ccsRaw() past that hole.
      h.tm:deleteEvent(tokenOfNote(h.fm, 1, 60))
      h.tm:flush()
      t.deepEq(pcCol(h, 1), { { ppq = 240, val = 2 }, { ppq = 480, val = 3 } })
    end,
  },

  {
    name = 'PA dispatch reads past a mid-pipeline cc-delete hole (:1598)',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 } },
          ccs = {
            { ppq =  10, chan = 1, evType = 'cc', cc = 7, val = 40 },        -- lowest loc; deleted below
            { ppq = 240, chan = 1, evType = 'pa', pitch = 60, vel = 0x50 },  -- higher loc; must still project
          },
        },
      }
      h.tm:deleteEvent(ccTokenAt(h.fm, 1, 'cc', 10))
      h.tm:flush()
      t.deepEq(pasInCol(h, 1), { 240 }, 'pa projected into pitch 60 column despite the low-loc hole')
    end,
  },

  {
    name = 'absorber snapshot reads past a mid-pipeline cc-delete hole (:2063)',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 } },
          ccs = {
            { ppq =  10, chan = 1, evType = 'cc', cc = 7, val = 40 },     -- lowest loc; deleted below
            { ppq = 240, chan = 1, evType = 'pb', cents = 25, val = 0 },  -- both must survive into pbsByChan
            { ppq = 480, chan = 1, evType = 'pb', cents = 50, val = 0 },
          },
        },
      }
      -- The initial load seats a hidden absorber pb at ppq 0, so deleting cc7@10 holes
      -- mid-array with both authored pbs past it. rebuildPbs snapshots every pb from
      -- ccsRaw() (:2063) to build the pb column; a truncation at the hole drops them.
      h.tm:deleteEvent(ccTokenAt(h.fm, 1, 'cc', 10))
      h.tm:flush()
      t.deepEq(authoredPbCol(h, 1), { { ppq = 240, cents = 25 }, { ppq = 480, cents = 50 } },
        'both authored pbs survive the snapshot despite the hole before them')
    end,
  },
}
