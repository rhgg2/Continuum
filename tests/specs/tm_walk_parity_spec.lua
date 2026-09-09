-- The tail walk has two implementations of one rule. `frontierTails` seeks to each dirt seed and
-- probes a bounded few rows either side for the neighbours that bound it; `linearTails` sweeps the
-- channel. `rebuildTails` routes on seed count: at most FRONTIER_SEED_CAP seeds, on a channel that
-- is not wholesale, take the frontier. The two must derive the same frame, and design/lane-bound.md
-- lifts the lane bound out of both of them, so this is the net under that move.
--
-- Holding the end state fixed while changing the route means varying the granularity of one edit.
-- Two harnesses build the same channel and delete the same twenty notes: one in a single flush,
-- which seeds twenty and routes linear, the other in four flushes of five, which routes the frontier
-- each time. The two frames are compared before the deletions as well as after, so a divergence
-- belongs to the deletions and not to the build.
--
-- Two surfaces carry the answer, and they are the two bounds design/lane-bound.md separates. The
-- column's `endppqC` is the lane bound and lives in the frame; the raw bound adds the same-pitch
-- clip and reaches only mm. A walk that missed a lane neighbour moves the first, one that missed a
-- pitch neighbour moves the second alone.
--
-- Every note's ceiling overruns its lane successor, so every bound in the fixture is a clip and
-- removing any onset moves the bound before it. Each bar's lane-2 blocker recycles its lane-1
-- host's pitch, so the host's raw tail is cut far short of its lane bound. Deleting every other
-- blocker leaves two neighbours of each -- the filler before it on its lane, its host on the pitch --
-- to re-bound, and no seed names either.
--
-- FRONTIER_SEED_CAP is a local of src/tracker/trackerRebuild.lua, so the twenty and the five here are
-- arithmetic against the sixteen it holds, not an assertion. Raising it past twenty would leave both
-- runs on the frontier and this spec comparing one walk with itself.
--
-- The channel holds authored notes alone. Fresh fx output counts toward the same cap and reaches
-- both walks as a second probe source, so nothing here exercises that term; tm_lane_bound_spec has
-- the authored population's independence from it.

local t    = require('support')
local util = require('util')

-- classic-55: the principal at x=0.5 maps to 0.55 of the period, so a row and its raw image differ.
local c55 = {
  config = { project = { swings = { c55 = {
    factors = { { atom = 'classic', shift = 0.05, period = 1 } } } } } },
  data   = { swing = { global = 'c55' } },
}

local BARS, BAR = 40, 480
local TAKE_LEN  = 24000   -- past the last bar's ceiling, so the take edge clips nothing

local function note(ppq, endppq, pitch, lane)
  return { evType = 'note', ppq = ppq, endppq = endppq, chan = 1, pitch = pitch,
           vel = 100, detune = 0, delay = 0, lane = lane }
end

-- Three notes a bar: a lane-1 host whose ceiling overruns two lane successors, a lane-2 blocker a
-- sixth of a bar in on the host's own pitch, and a lane-2 filler on a pitch of its own. Both lane-2
-- ceilings overrun the next bar's blocker.
local function build(h)
  for i = 0, BARS - 1 do
    local base, pitch = i * BAR, 60 + (i % 3)
    h.tm:addEvent(note(base,       base + 900,  pitch,        1))
    h.tm:addEvent(note(base + 120, base + 1000, pitch,        2))
    h.tm:addEvent(note(base + 300, base + 1000, 72 + (i % 2), 2))
  end
  h.tm:flush()
end

-- Per-rebuild identity that nothing renders, excluded as tm_gate_parity_spec excludes it.
local VOLATILE = { loc = true, origShape = true, key = true }

local function project(e)
  local out = {}
  for k, v in pairs(e) do if not VOLATILE[k] then out[k] = v end end
  return out
end

-- The channel's note columns, each canonically ordered so a same-ppq tie cannot decide equality.
local function frameNotes(h)
  local out = {}
  for lane, col in ipairs(h.tm:getChannel(1).onTake.notes) do
    local evs = {}
    for _, e in ipairs(col.events) do util.add(evs, project(e)) end
    table.sort(evs, function(a, b) return t.repr(a) < t.repr(b) end)
    out[lane] = evs
  end
  return out
end

-- The wire side, where the raw bound alone reaches.
local function wireNotes(h)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do util.add(out, project(n)) end
  return out
end

local function noteAt(h, lane, ppq)
  for _, e in ipairs(h.tm:getChannel(1).onTake.notes[lane].events) do
    if e.ppq == ppq then return e end
  end
end

local function wireOf(h, evt)
  for _, n in ipairs(h.fm:dump().notes) do if n.uuid == evt.uuid then return n end end
end

-- Every other bar's blocker: the lane-2 stream runs blocker, filler, blocker, filler, so its first
-- entry of each four is one.
local function blockers(h)
  local lane2 = {}
  for _, e in ipairs(h.tm:getChannel(1).onTake.notes[2].events) do util.add(lane2, e) end
  table.sort(lane2, function(a, b) return a.ppq < b.ppq end)
  local out = {}
  for i = 1, #lane2, 4 do util.add(out, lane2[i]) end
  return out
end

local function deleteBlockers(h, batch)
  local doomed = blockers(h)
  for i = 1, #doomed, batch do
    for j = i, math.min(i + batch - 1, #doomed) do h.tm:deleteEvent(doomed[j]) end
    h.tm:flush()
  end
  return #doomed
end

-- The bar-1 filler and the bar-2 host: the two survivors bordering the bar-2 blocker, one on its
-- lane and one on its pitch. Their bounds are what the deletion moves and what no seed names.
local FILLER_PPQ, HOST_PPQ = BAR + 300, 2 * BAR

local function walksAgree(harness, opts)
  local linear, frontier = harness.mk(opts), harness.mk(opts)
  build(linear)
  build(frontier)
  t.deepEq(frameNotes(frontier), frameNotes(linear), 'fixture check: the two builds start equal')

  local host, filler = noteAt(linear, 1, HOST_PPQ), noteAt(linear, 2, FILLER_PPQ)
  t.truthy(filler.endppqC < filler.endppq,
    'fixture check: the filler is clipped by its lane successor, short of its own ceiling')
  t.eq(wireOf(linear, host).endppq, wireOf(linear, noteAt(linear, 2, HOST_PPQ + 120)).ppq,
    "fixture check: the blocker on the host's pitch clips the host's raw tail")
  local laneBefore, rawBefore = filler.endppqC, wireOf(linear, host).endppq

  t.eq(deleteBlockers(linear, 20), 20, 'fixture check: twenty seeds in one flush, past the cap')
  t.eq(deleteBlockers(frontier, 5), 20, 'fixture check: and five at a time, under it, four times')

  t.truthy(noteAt(linear, 2, FILLER_PPQ).endppqC > laneBefore,
    'precondition: the deletions moved a lane bound no seed named')
  t.truthy(wireOf(linear, host).endppq > rawBefore, 'precondition: and a raw bound likewise')

  t.deepEq(frameNotes(frontier), frameNotes(linear),
    'the two walks leave the same lane bounds on the columns')
  t.bagEq(wireNotes(frontier), wireNotes(linear),
    'and the same raw bounds on the wire')
end

return {

  {
    name = 'the frontier and the linear walk derive the same frame from the same deletions',
    run = function(harness) walksAgree(harness, { seed = { length = TAKE_LEN } }) end,
  },

  {
    -- Swing puts a row and its raw image at different numbers, so a term read in the wrong frame
    -- lands somewhere else. The two walks convert at different points and must still agree.
    name = 'and on a swung channel, where a lane bound and its raw image are different numbers',
    run = function(harness)
      walksAgree(harness, { seed = { length = TAKE_LEN }, config = c55.config, data = c55.data })
    end,
  },

}
