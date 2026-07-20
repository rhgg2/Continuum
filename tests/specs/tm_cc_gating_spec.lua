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

local function note(chan, ppq, pitch)
  return { evType = 'note', ppq = ppq, endppq = ppq + 240, chan = chan, pitch = pitch,
           vel = 100, detune = 0, delay = 0, lane = 1 }
end

-- cc/at/pc mm records minus the volatile per-rebuild loc: a reseat assign churns this bag.
local function ccMmBag(h)
  local bag = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'cc' or c.evType == 'at' or c.evType == 'pc' then
      local rec = {}
      for k, v in pairs(c) do if k ~= 'loc' then rec[k] = v end end
      bag[#bag + 1] = rec
    end
  end
  return bag
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
  {
    name = 'a note edit carries the cc columns untouched and stages no cc mm write',
    run = function(harness)
      -- chan 1 holds a plain cc lane; no swing, so every cell is converged after the first build.
      -- Commit B carries the cc/at/pc columns across an interval-dirty note edit rather than
      -- re-deriving them, so the note add below must neither re-clone a cc cell nor reseat one.
      local h = harness.mk{
        seed = { ccs = {
          { ppq = 0,   chan = 1, evType = 'cc', cc = 7, val = 10 },
          { ppq = 240, chan = 1, evType = 'cc', cc = 7, val = 20 },
          { ppq = 480, chan = 1, evType = 'cc', cc = 7, val = 30 },
        } },
      }
      h.tm:addEvent(note(1, 0, 60)); h.tm:flush()

      -- Capture the carried cells by object identity: a splice that re-clones swaps these out.
      local col = h.tm:getChannel(1).columns.ccs[7].events
      local carried = {}
      for i, e in ipairs(col) do carried[i] = e end
      t.eq(#carried, 3, 'cc 7 column materialised its three cells')
      local mmBefore = ccMmBag(h)

      -- A pure note add on chan 1: interval dirt with no cc-family seed.
      h.tm:addEvent(note(1, 720, 64)); h.tm:flush()

      local after = h.tm:getChannel(1).columns.ccs[7].events
      t.eq(#after, #carried, 'cc 7 column keeps its three cells')
      for i = 1, #carried do
        t.truthy(after[i] == carried[i], 'cc cell ' .. i .. ' is the carried object, not a re-clone')
      end
      t.bagEq(ccMmBag(h), mmBefore, 'the note edit staged no cc mm write')
    end,
  },
}
