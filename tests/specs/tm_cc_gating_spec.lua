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
  {
    name = 'a cc assign re-clones only its own cell; siblings and other rows carry',
    run = function(harness)
      -- cc 74 shares row 240 with the edited cc 7 cell: the splice must not touch it.
      local h = harness.mk{
        seed = { ccs = {
          { ppq = 0,   chan = 1, evType = 'cc', cc = 7,  val = 10 },
          { ppq = 240, chan = 1, evType = 'cc', cc = 7,  val = 20 },
          { ppq = 480, chan = 1, evType = 'cc', cc = 7,  val = 30 },
          { ppq = 240, chan = 1, evType = 'cc', cc = 74, val = 50 },
        } },
      }
      local col7 = h.tm:getChannel(1).columns.ccs[7].events
      local keep0, edited, keep480 = col7[1], col7[2], col7[3]
      local sibling = h.tm:getChannel(1).columns.ccs[74].events[1]

      h.tm:assignEvent({ uuid = edited.uuid }, { val = 90 }); h.tm:flush()

      local after7 = h.tm:getChannel(1).columns.ccs[7].events
      t.eq(#after7, 3, 'cc 7 column keeps three cells')
      t.truthy(after7[1] == keep0,   'row 0 carries by identity')
      t.truthy(after7[3] == keep480, 'row 480 carries by identity')
      t.eq(after7[2].val, 90, 'the edited cell re-clones with the new value')
      t.truthy(h.tm:getChannel(1).columns.ccs[74].events[1] == sibling,
        'the sibling column cell at the edited row carries by identity')
    end,
  },
  {
    name = 'a cc add and a cc delete splice their own column only',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = {
          { ppq = 0,   chan = 1, evType = 'cc', cc = 7,  val = 10 },
          { ppq = 240, chan = 1, evType = 'cc', cc = 7,  val = 20 },
          { ppq = 240, chan = 1, evType = 'cc', cc = 74, val = 50 },
        } },
      }
      local col7 = h.tm:getChannel(1).columns.ccs[7].events
      local cellA, cellB = col7[1], col7[2]
      local sibling = h.tm:getChannel(1).columns.ccs[74].events[1]

      -- An add's seed has no uuid at snapshot time; the splice must still land it.
      h.tm:addEvent({ evType = 'cc', ppq = 720, chan = 1, cc = 7, val = 40 }); h.tm:flush()

      -- Capture cell references, not the live events array: the carried column mutates in place.
      local after = h.tm:getChannel(1).columns.ccs[7].events
      local keptA, deleted, added = after[1], after[2], after[3]
      t.eq(#after, 3, 'the add landed as a third cell')
      t.eq(added.val, 40, 'the added cell carries its value')
      t.truthy(keptA == cellA and deleted == cellB,
        'existing cells carry by identity across the add')

      h.tm:deleteEvent(deleted.uuid); h.tm:flush()

      local final = h.tm:getChannel(1).columns.ccs[7].events
      t.eq(#final, 2, 'the delete removed exactly its cell')
      t.truthy(final[1] == keptA and final[2] == added,
        'remaining cells carry by identity across the delete')
      t.truthy(h.tm:getChannel(1).columns.ccs[74].events[1] == sibling,
        'the sibling column cell at the deleted row carries by identity')
    end,
  },
}
