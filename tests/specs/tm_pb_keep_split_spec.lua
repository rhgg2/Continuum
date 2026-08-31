-- The keep/live split of a clipped pb window. Under seed dirt a pb replace window is clipped
-- against the emit scope of the producers that re-ran (docs/trackerManager.md § The producer gate).
-- The live part refolds from the chain curve; the kept part's seats stand on the wire and its
-- column cells carry verbatim from the prior pass. Where the two parts touch, the tick belongs to
-- whichever side opens on it -- two pb events at one (chan, ppq) are a contradiction on the wire
-- (docs/tuning.md § Authoring onto a hidden seat).
--
-- The fixture is three abutting sine windows on chan 1 -- [0,240), [240,480), [480,720) -- which
-- merge into one replace span, so any narrower pb scope clips it. The hosts sit on lane 2: pb is
-- channel-wide, so a host's lane is free, while an edit to a lane-1 note would set the detune hold
-- and force every window right of it live (docs/tuning.md § Seat-span-scoped onset walk 5), leaving
-- nothing kept to watch. One authored pb past all three windows surfaces the pb column, since a
-- channel of nothing but hidden seats projects none.
--
-- Two edits then put the same tick, 480, in both roles. Seeding the third window makes [480,720)
-- live, so 480 opens the live side; deepening the middle host makes [0,480) live, so 480 opens the
-- kept side -- and is then the fenced seat, kept-owned yet inside the live window's seat span,
-- carried instead of swept as an absorber with no seat to fill.

local t    = require('support')
local util = require('util')

local WIN        = 240   -- host window length at the harness resolution; the windows abut at 240 and 480
local EDGE       = 2 * WIN
local BASE_CENTS = 25    -- the authored pb past every window; every seat folds onto it

-- Independent of the module: cents to raw over the default 2-semitone pb range.
local function centsToRaw(cents) return util.round(cents * 8192 / 200) end

local function sine(depth)
  return { { kind = 'sine', period = { 1, 4 }, depth = depth, onset = 0 } }
end

local function host(ppq, depth)
  return { evType = 'note', ppq = ppq, endppq = ppq + WIN, chan = 1, pitch = 60 + ppq // WIN,
           vel = 100, detune = 0, delay = 0, lane = 2, fx = sine(depth) }
end

-- Three abutting pb producers, added one at a time so every pass is an ordinary edit rebuild.
local function threeWindows(harness)
  local h = harness.mk{ seed = { ccs = {
    { ppq = 1000, chan = 1, evType = 'pb',
      val = centsToRaw(BASE_CENTS), cents = BASE_CENTS, shape = 'step' } } } }
  for i = 0, 2 do h.tm:addEvent(host(i * WIN, 30)); h.tm:flush() end
  return h
end

-- The channel's pb wire: raw val by ppq.
local function wire(h)
  local out = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == 1 then out[c.ppq] = c.val end
  end
  return out
end

-- The projected pb column by ppq (no swing here, so a cell's logical ppq is its raw one), and the
-- ppqs holding a second event. A carried cell is the prior column's own table and a reprojected one
-- a fresh clone, so table identity reads which side of the split claimed a tick.
local function column(h)
  local col = h.tm:getChannel(1).columns.pb
  t.truthy(col, 'fixture check: the authored pb surfaces a pb column')
  local byPpq, doubled = {}, {}
  for _, e in ipairs(col.events) do
    if byPpq[e.ppq] then util.add(doubled, e.ppq) else byPpq[e.ppq] = e end
  end
  return byPpq, doubled
end

-- The pb ppqs mm is written at while `edit` runs. tm holds the harness's own mm table, so wrapping
-- the three write doors intercepts the pipeline's whole output (tm_zero_write_spec's instrument).
local function pbWritesDuring(h, edit)
  local ppqOf, hit = {}, {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' then ppqOf[c.uuid] = c.ppq end
  end
  local mm = h.fm
  local add, assign, delete = mm.add, mm.assign, mm.delete
  local function seen(ppq) if ppq then util.add(hit, ppq) end end
  mm.add    = function(...) local evt = select(2, ...)
                            if evt.evType == 'pb' then seen(evt.ppq) end; return add(...) end
  mm.assign = function(...) seen(ppqOf[select(2, ...)]); return assign(...) end
  mm.delete = function(...) seen(ppqOf[select(2, ...)]); return delete(...) end
  edit()
  mm.add, mm.assign, mm.delete = add, assign, delete
  return hit
end

-- Dirt inside the third window alone, on a lane no producer hosts: [480,720) runs, the rest keeps.
local function seedThirdWindow(h)
  h.tm:addEvent({ evType = 'note', ppq = 600, endppq = 660, chan = 1, pitch = 70,
                  vel = 100, detune = 0, delay = 0, lane = 3 })
  h.tm:flush()
end

-- Dirt on the middle host itself: its chain re-runs at twice the depth, and [0,480) is live.
local function deepenMiddleHost(h)
  local mid
  for _, e in ipairs(h.tm:getChannel(1).columns.notes[2].events) do
    if e.ppq == WIN then mid = e end
  end
  t.truthy(mid, 'fixture check: the middle host stands on lane 2')
  h.tm:assignEvent(mid, { fx = sine(60) })
  h.tm:flush()
end

return {

  {
    name = 'a kept sub-span stands: its seats hold their values and mm is never written there',
    run = function(harness)
      local h = threeWindows(harness)
      local before = wire(h)
      t.truthy(before[495] and before[525], 'fixture check: the third window seats a sine stream')

      local hit  = pbWritesDuring(h, function() deepenMiddleHost(h) end)
      local after = wire(h)
      for ppq, val in pairs(before) do
        if ppq >= EDGE then t.eq(after[ppq], val, 'kept seat at ' .. ppq .. ' stands unchanged') end
      end
      t.truthy(#hit > 0, 'fixture check: the live half of the split did write')
      for _, ppq in ipairs(hit) do
        t.truthy(ppq < EDGE, 'no mm write lands in the kept range (one did, at ' .. ppq .. ')')
      end
    end,
  },

  {
    name = 'the live sub-span refolds from the chain curve, at the depth the edit gave it',
    run = function(harness)
      local h = threeWindows(harness)
      local before = wire(h)
      t.eq(before[255], centsToRaw(BASE_CENTS + 30), 'the middle window crests a depth above the base')
      t.eq(before[285], centsToRaw(BASE_CENTS - 30), 'and troughs the same distance below it')

      deepenMiddleHost(h)

      local after = wire(h)
      t.eq(after[255], centsToRaw(BASE_CENTS + 60), 'the live sub-span refolds at the doubled depth')
      t.eq(after[285], centsToRaw(BASE_CENTS - 60), 'trough and crest alike')
      t.eq(after[495], before[495], 'the kept third window keeps the depth it was folded at')
    end,
  },

  {
    name = 'the shared edge is claimed once, by whichever side opens on it',
    run = function(harness)
      local h = threeWindows(harness)
      local col0, doubled0 = column(h)
      t.eq(#doubled0, 0, 'the built column holds one pb per tick')
      t.truthy(col0[EDGE] and col0[EDGE - 1], 'fixture check: a cell on each side of the edge')

      seedThirdWindow(h)   -- live [480,720): the edge is the live side's opening tick
      local colA, doubledA = column(h)
      t.eq(#doubledA, 0, 'the edge is claimed once, not by both sides at once')
      t.truthy(colA[EDGE] ~= col0[EDGE], 'the live side reprojects the tick it opens on')
      t.eq(colA[EDGE - 1], col0[EDGE - 1], 'the kept side carries the tick below it verbatim')

      deepenMiddleHost(h)  -- live [0,480): the same edge now opens the kept side
      local colB, doubledB = column(h)
      t.eq(#doubledB, 0, 'and once more with the sides reversed')
      t.eq(colB[EDGE], colA[EDGE], 'the edge, kept-owned this pass, carries')
      t.truthy(colB[EDGE - 1] ~= colA[EDGE - 1], 'while the live side reprojects the tick below it')
    end,
  },

  {
    name = 'the fence: a kept boundary seat inside a live seat span is carried, not swept',
    run = function(harness)
      local h = threeWindows(harness)
      local before = wire(h)
      t.truthy(before[EDGE] and before[EDGE - 1], 'fixture check: a seat on each side of the edge')

      -- A live window's seat span reaches one tick back for dual points, so the kept re-centre seat
      -- below its start lies in scope while owning no seat of its own.
      seedThirdWindow(h)
      t.eq(wire(h)[EDGE - 1], before[EDGE - 1], 'the kept re-centre seat under a live start stands')

      -- And the span closes on the live window's end, which the kept window to its right opens on.
      deepenMiddleHost(h)
      t.eq(wire(h)[EDGE], before[EDGE], 'the kept window-start seat at a live end stands')
    end,
  },
}
