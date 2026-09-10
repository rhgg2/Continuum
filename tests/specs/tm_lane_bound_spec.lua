-- An authored note's lane bound is a function of the authored population alone -- the column's own
-- events together with the parked ones that have left the take. Fx expansion adds derived notes to
-- the channel and the tail walk meets them in the same pass, yet none of them moves an authored
-- note's `endppqC`. See docs/trackerManager.md § Lane occupancy.
--
-- What holds it is the region lane allocator: it seeds each lane's occupancy from the spans already
-- sounding there before placing a derived note, so a derived note lands only where its lane has
-- finished. The two cases are the two ways that can go. In the first the allocator does the work --
-- the authored tail reaches into the region's window, so the tiles are pushed off its lane. In the
-- second the tiles do take the authored note's lane, past its ceiling, and the bound stands for the
-- simpler reason that the tail had already ended.
--
-- Each case snapshots every authored note's `endppqC` before the region is assigned and compares
-- after the rebuild, over both halves of the population. The region parks its input note, so the
-- comparison spans the park: parking moves a note between the halves and moves no bound.
--
-- The third case turns it around, with the parked half doing the bounding. Its two notes share a
-- lane, so the region's input is the tail's lane successor and parking it must not release the
-- clip. That channel is swung, which puts the successor's row and its raw position at different
-- numbers -- a bound read in the wrong frame lands somewhere else entirely.
--
-- The next two cases pin the frame the bound is stated in. Every term of a lane bound is logical --
-- the ceiling, the successor's onset, the take length and the floor -- so the number a note is drawn
-- to is a row, and the wire bound is that row converted once. Swing separates a row from its raw
-- position and delay moves a raw onset off its row, so between them the two readings come apart.
-- See docs/trackerManager.md § Tail walk.
--
-- The next case pins how far the one expression reaches. `overlap` is a term of the lane bound, so a
-- note carrying one is drawn past its lane successor -- and the fx window its chain runs in closes on
-- that same number. The tail walk and the window census are two readers of one statement.
--
-- The next case takes the other half of that expression. A derived note lies outside the authored
-- population, so it bounds over the one it belongs to: its lane's on-take events together with the
-- pass's own output, which is what sounds there. The successor is the next onset in column order
-- here too, so a neighbour whose delay carries its raw onset past the note behind it is still the
-- note that follows.
--
-- The last case is the same expression asked of a tile nothing re-derived. A stage emitting past its
-- own window leaves a tile whose lane successor sits outside that window, so an edit to the
-- successor leaves the host kept and the tile comes back holding the ceiling it was emitted with.
-- The walk states a derived note's lane bound, and it is the only thing that can follow the move.
-- The stage counts its own runs, which is what keeps the case about the kept tile: a host re-running
-- would emit a fresh tile and bound it whatever the walk asked.

local t          = require('support')
local util       = require('util')
local generators = require('generators')

local arpUp  = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }
-- Continuous, so the host keeps its place on the take: what it writes is a pb stream across its window.
local sine30 = { { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } }

-- classic-55: the principal at x=0.5 maps to 0.55 of the period, so logical 1140 realises at 1148.
local c55 = {
  config = { project = { swings = { c55 = {
    factors = { { atom = 'classic', shift = 0.05, period = 1 } } } } } },
  data   = { swing = { global = 'c55' } },
}

local function note(chan, ppq, endppq, pitch, lane, delay)
  return { evType = 'note', ppq = ppq, endppq = endppq, chan = chan, pitch = pitch,
           vel = 100, detune = 0, delay = delay or 0, lane = lane }
end

-- The wire image of an authored note: what the pass left in mm, where the tail is raw.
local function wireNote(h, chan, pitch)
  for _, n in ipairs(h.fm:dump().notes) do
    if n.chan == chan and n.pitch == pitch then return n end
  end
end

-- Every authored note on a channel, on-take and parked alike, uuid -> lane bound.
local function boundsOn(h, chan)
  local out = {}
  for _, col in ipairs(h.tm:getChannel(chan).onTake.notes) do
    for _, evt in ipairs(col.events) do out[evt.uuid] = evt.endppqC end
  end
  for _, evt in ipairs(h.tm:getChannel(chan).parked.notes) do out[evt.uuid] = evt.endppqC end
  return out
end

-- The authored note at an onset, wherever the pass left it: on its column or in the stash.
local function authoredAt(h, chan, ppq)
  for _, col in ipairs(h.tm:getChannel(chan).onTake.notes) do
    for _, evt in ipairs(col.events) do if evt.ppq == ppq then return evt end end
  end
  for _, evt in ipairs(h.tm:getChannel(chan).parked.notes) do
    if evt.ppq == ppq then return evt end
  end
end

-- The pass's fx output on a channel, ascending: what the authored population is asserted against.
local function derivedOn(h, chan)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do
    if n.chan == chan and n.derived then util.add(out, { ppq = n.ppq, lane = n.lane }) end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

local function lanesWithin(derived, from, to)
  local out = {}
  for _, d in ipairs(derived) do if d.ppq >= from and d.ppq < to then out[d.lane] = true end end
  return out
end

-- The last pb seat a channel carries: where the chain writing it stopped, and so where its window closed.
local function lastPbSeat(h, chan)
  local last
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == chan and (last == nil or c.ppq > last) then last = c.ppq end
  end
  return last
end

-- One arp region over [960, 1920), fed by the lane-2 note the window covers and parks.
local function region(h)
  h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, ppq = 960, endppq = 1920, fx = arpUp } })
  h.tm:rebuild()
end

return {

  {
    -- The lane-1 tail runs to 1440, well into the region's window, so its lane is occupied where
    -- the arp would otherwise tile. Were the allocator to seed from nothing, the tiles would take
    -- lane 1 at 960 and the tail would read as clipped there -- a derived note deciding an authored
    -- note's bound.
    name = "fx output sounding inside an authored tail leaves the tail's lane bound where it was",
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(note(1, 0,   1440, 60, 1))   -- the tail the region's output sounds inside
      h.tm:addEvent(note(1, 960, 1200, 67, 2))   -- the region's input, on a lane of its own
      h.tm:flush()

      local before = boundsOn(h, 1)
      t.eq(authoredAt(h, 1, 0).endppqC, 1440,
        'fixture check: the tail sounds to its own ceiling, nothing on its lane clipping it')

      region(h)

      local derived = derivedOn(h, 1)
      t.truthy(#derived > 1, 'precondition: the arp tiles its parked member')
      t.truthy(derived[1].ppq < 1440, 'precondition: it sounds inside the authored tail')
      t.eq(authoredAt(h, 1, 0).endppqC, 1440, 'the tail keeps the bound its own ceiling gave it')
      t.deepEq(boundsOn(h, 1), before,
        'and no authored note on the channel, on take or parked, has moved')
      t.falsy(lanesWithin(derived, 0, 1440)[1],
        'the derived output taking a lane only where the authored population has ended')
    end,
  },

  {
    -- The same fixture with the lane-1 tail ending at 480: its lane is free where the arp tiles, so
    -- the output takes lane 1 and the tail walk meets a derived note as the authored note's lane
    -- successor. It is past the ceiling, so the bound is the ceiling either way.
    name = 'fx output seated on an authored lane past its tail leaves that bound where it was',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(note(1, 0,   480,  60, 1))
      h.tm:addEvent(note(1, 960, 1200, 67, 2))
      h.tm:flush()

      local before = boundsOn(h, 1)
      t.eq(authoredAt(h, 1, 0).endppqC, 480, 'fixture check: the tail ends well before the window')

      region(h)

      local derived = derivedOn(h, 1)
      t.truthy(#derived > 1, 'precondition: the arp tiles its parked member')
      t.truthy(lanesWithin(derived, 0, math.huge)[1],
        'precondition: the freed lane takes the output, so a derived note is the lane successor')

      t.eq(authoredAt(h, 1, 0).endppqC, 480, 'the tail still ends at its ceiling')
      t.deepEq(boundsOn(h, 1), before,
        'and no authored note on the channel, on take or parked, has moved')
    end,
  },

  {
    -- Both notes on lane 1, so the row-0 tail is clipped by its successor at 1140 well short of
    -- its own ceiling at 1440. The region then parks that successor. The columns no longer carry
    -- it, but the lane geometry still does, so the clip stands exactly where it stood.
    --
    -- Both bounds are exact under swing: the parked half's bound comes off the same logical
    -- expression as the on-take half's, so crossing between them converts nothing.
    name = 'a successor parked this pass keeps bounding the tail before it, on a swung channel',
    run = function(harness)
      local h = harness.mk(c55)
      h.tm:addEvent(note(1, 0,    1440, 60, 1))   -- a ceiling well past its lane successor
      h.tm:addEvent(note(1, 1140, 1320, 67, 1))   -- the region's input, sharing the lane
      h.tm:flush()

      t.eq(#h.tm:getChannel(1).onTake.notes, 1, 'fixture check: one lane, so one note clips the other')
      t.truthy(h.tm:fromLogical(1, 1140) ~= 1140, 'fixture check: the swing bites at the clipping row')

      local clipped = authoredAt(h, 1, 0).endppqC
      t.truthy(clipped < 1440, 'fixture check: the successor clips the tail, its own ceiling never reached')

      region(h)

      local stashed = h.tm:getChannel(1).parked.notes
      t.eq(#stashed, 1, 'precondition: the region parked its input, so the clipping note left the take')
      t.eq(stashed[1].ppq, 1140, 'precondition: and it is the lane successor that left')

      t.eq(authoredAt(h, 1, 0).endppqC, clipped, 'the tail keeps the bound its successor gave it')
      t.eq(stashed[1].endppqC, 1320, 'the successor, off the take, sounds to its own ceiling still')
    end,
  },

  {
    -- Two notes sharing lane 1 of a swung channel, the first with a ceiling well past the second's
    -- row. Its lane bound is that row, 1140, because that is where the successor is drawn. The wire
    -- bound is the same row realised, one conversion later.
    name = "a tail clipped by its lane successor bounds at the successor's row, under swing",
    run = function(harness)
      local h = harness.mk(c55)
      h.tm:addEvent(note(1, 0,    1440, 60, 1))
      h.tm:addEvent(note(1, 1140, 1320, 67, 1))
      h.tm:flush()

      local realised = h.tm:fromLogical(1, 1140)
      t.truthy(realised ~= 1140, 'fixture check: the swing bites at the clipping row')
      local tail = authoredAt(h, 1, 0)
      t.truthy(tail.endppqC < 1440, 'fixture check: the successor clips it short of its own ceiling')

      t.eq(tail.endppqC, 1140, "the lane bound is the successor's row")
      t.eq(wireNote(h, 1, 60).endppq, realised, 'and the wire bound is that row realised')
    end,
  },

  {
    -- One note, its ceiling at its own onset, so nothing but the floor decides its bound: a lane
    -- bound is at least the row after the onset. The note also carries a delay, which moves its raw
    -- note-on and no row. A floor taken in raw carries that delay into the drawn bound; the lane
    -- floor is the next row, and the delay shows only in the wire bound.
    name = 'a note bound by the floor takes the row after its onset, the wire tick after its own',
    run = function(harness)
      local h = harness.mk(c55)
      h.tm:addEvent(note(1, 1140, 1140, 60, 1, 100))   -- delay in milli-QN, so a good few ticks
      h.tm:flush()

      local evt, wire = authoredAt(h, 1, 1140), wireNote(h, 1, 60)
      t.truthy(wire.ppq > h.tm:fromLogical(1, 1140),
        'fixture check: the delay carries the raw onset past its row, so the two floors differ')

      t.eq(evt.endppqC, evt.ppq + 1, 'the lane bound is the row after the onset')
      t.eq(wire.endppq, wire.ppq + 1, 'and the wire bound the tick after the realised onset')
    end,
  },

  {
    -- A host with an open ceiling and an overlap of 120, sharing its lane with a note at 480. The
    -- overlap overruns that onset, so the host sounds to 600 and is drawn there -- and its chain runs
    -- the same span, since a host's window end is its lane bound. The pb stream the chain writes is
    -- where that shows: a seat past 480 says the window followed the tail over its successor's onset.
    name = "a host's fx window closes at its lane bound, overlap included",
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(util.assign(note(1, 0, util.OPEN, 60, 1), { overlap = 120, fx = sine30 }))
      h.tm:addEvent(note(1, 480, 600, 62, 1))
      h.tm:flush()

      local tail = authoredAt(h, 1, 0)
      t.eq(tail.endppqC, 600,
        "fixture check: an open ceiling, so the successor's onset plus the overlap is the bound")

      local last = lastPbSeat(h, 1)
      t.truthy(last, 'precondition: the host ran its chain')
      t.truthy(last >= 480, "the window follows the tail past its successor's onset")
      t.truthy(last < tail.endppqC, 'and closes inside the bound the tail is drawn to')
    end,
  },

  {
    -- A region on [480, 600) whose stage emits past its own window, onto lane 1, where two authored
    -- notes follow it. The first of them is the tile's lane successor, drawn at 720; two rows of
    -- delay carry its raw onset past the second note at 780, so the two readings of "next" name
    -- different notes. The bound is the row, so the tile stops where its successor is drawn.
    name = "a derived tile bounds at its lane successor's row, not at the raw order its delay leaves",
    run = function(harness)
      local h = harness.mk()
      generators.kinds.overrun = {
        expand = function(stream) return { notes = {
          { ppq = stream.window[1], endppq = 1440, pitch = 60, vel = 100, detune = 0 },
        }, delta = {} } end,
        mode = 'replace', dest = 'note', label = 'Overrun', defaults = {}, fields = {},
      }
      h.tm:addEvent(note(1, 720, 1440, 62, 1, 500))   -- the successor, delayed clear of its own row
      h.tm:addEvent(note(1, 780, 1440, 64, 1))
      h.tm:flush()
      t.truthy(wireNote(h, 1, 62).ppq > wireNote(h, 1, 64).ppq,
        'fixture check: the delay lands its raw onset past the note behind it, so raw order and row order disagree')

      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, ppq = 480, endppq = 600,
                                   fx = { { kind = 'overrun' } } } })
      h.tm:rebuild()
      generators.kinds.overrun = nil

      local tile
      for _, n in ipairs(h.fm:dump().notes) do if n.derived == 'fxr-1' then tile = n end end
      local successor = authoredAt(h, 1, 720)
      t.truthy(tile, 'precondition: the region emitted a tile')
      t.eq(tile.lane, successor.lane, 'precondition: onto the lane the two authored notes share')
      t.truthy(tile.endppq < 1440, 'precondition: and past its own window, so a lane successor decides its tail')

      t.eq(tile.endppq, successor.ppq, "the tile bounds at the row its lane successor is drawn on")
    end,
  },

  {
    name = 'a kept tile follows the lane successor that moved under it',
    run = function(harness)
      local h, runs = harness.mk(), 0
      generators.kinds.overrun = {
        expand = function(stream)
          runs = runs + 1
          return { notes = {
            { ppq = stream.window[1], endppq = 1440, pitch = 60, vel = 100, detune = 0 },
          }, delta = {} }
        end,
        mode = 'replace', dest = 'note', label = 'Overrun', defaults = {}, fields = {},
      }
      h.tm:addEvent(note(1, 960,  1440, 62, 1))   -- the tile's lane successor, well past the window
      h.tm:addEvent(note(1, 1200, 1440, 64, 1))   -- the note behind it, which the deletion promotes
      h.tm:flush()

      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, ppq = 480, endppq = 600,
                                   fx = { { kind = 'overrun' } } } })
      h.tm:rebuild()

      local function tile()
        for _, n in ipairs(h.fm:dump().notes) do if n.derived == 'fxr-1' then return n end end
      end
      t.eq(tile().lane, 1, 'precondition: the tile takes the lane the two authored notes share')
      t.eq(tile().endppq, 960,
        'fixture check: clipped by its lane successor, well short of the ceiling it was emitted with')
      local ran = runs

      h.tm:deleteEvent(authoredAt(h, 1, 960))
      h.tm:flush()
      generators.kinds.overrun = nil

      t.eq(runs, ran, 'precondition: the edit fell outside the window, so the host kept its output')
      t.eq(tile().endppq, 1200, 'the kept tile bounds at the successor the deletion promoted')
    end,
  },

}
