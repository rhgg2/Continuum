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
-- The case after them asks the same of a note mm holds no ceiling for. With no `endppqL` stamp there
-- is no authored end to draw, so the column shows the lane bound in its place -- and that is a row
-- like every other term, not the wire bound it realises to. See docs/trackerManager.md § Columns.
--
-- The next case pins how far the one expression reaches. `overlap` is a term of the lane bound, so a
-- note carrying one is drawn past its lane successor -- and the fx window its chain runs in closes on
-- that same number. The tail walk and the window census are two readers of one statement.
--
-- The next case takes the other half of that expression. A derived note is no part of any lane's
-- population: its bound is the end its generator stated, clipped by the window its host ran in, and
-- the lane it is drawn on is a display coordinate. So a tile emitted past its own window stops at
-- that window, and an authored note further down the lane it took is no term of the bound.
--
-- The next case asks the same of a tile nothing re-derived. Nothing outside a host's window reaches
-- its output's end now, so deleting the lane-mate behind the tile leaves it exactly where the window
-- left it. The stage counts its own runs, which is what keeps the case about the kept tile: a host
-- re-running would emit a fresh tile and bound it the same way, for a reason the case isn't asking.
--
-- The next case states that bound in the frame it belongs to. A window end is logical, so a tile
-- clipped by one stops on that row and reaches the wire as the row converted once -- the same
-- discipline the authored cases above pin, asked of the term that replaced the lane.
--
-- The last two pin the terms that survive. The end a generator states is the first of them, so a
-- tile emitted well inside its host's window ends where it was emitted to and the window is no term
-- of it. The same-pitch successor is the second: a derived note holds a (chan, pitch) voice like any
-- other, so the next note of its pitch cuts it short whatever lane either of them is drawn on.

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
    if n.chan == chan and n.derived then util.add(out, { ppq = n.ppq }) end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
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
    -- The lane-1 tail runs to 1440, well into the region's window, so the arp tiles inside it. A
    -- derived note sits in no column, so it is a lane-mate of nothing and a term of no lane bound:
    -- were it one, the tail would read as clipped at 960 by output it merely sounds alongside.
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
    end,
  },

  {
    -- The same fixture with the lane-1 tail ending at 480, so the arp tiles past its end rather than
    -- inside it. The bound is the note's own ceiling either way, no derived note being a successor
    -- of it in any column.
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
      t.truthy(derived[1].ppq > 480, 'precondition: past the tail it would otherwise have succeeded')

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
    -- The tail is seeded straight into mm without an `endppqL` stamp, its raw end at 1440 (a period
    -- boundary, so the same number in both frames). Its lane successor at row 1140 clips it, so what
    -- the column draws is that row, and only the wire carries the swung 1148.
    name = "an uncached tail is drawn to its lane bound's row, not to the wire bound",
    run = function(harness)
      local h = harness.mk{ config = c55.config, data = c55.data, seed = { notes = {
        { ppq = 0,    endppq = 1440, ppqL = 0, chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
        { ppq = 1148, endppq = 1332, ppqL = 1140, endppqL = 1320,
          chan = 1, pitch = 67, vel = 100, lane = 1, uuid = 2 },
      } } }

      local realised = h.tm:fromLogical(1, 1140)
      t.truthy(realised ~= 1140, 'fixture check: the swing bites at the clipping row')
      t.eq(wireNote(h, 1, 60).endppqL, nil, 'fixture check: mm holds no ceiling for the tail')
      local tail = authoredAt(h, 1, 0)
      t.eq(tail.endppqC, 1140, "fixture check: the lane bound is the successor's row")

      t.eq(tail.endppq, 1140, 'the column draws the tail to that row')
      t.eq(wireNote(h, 1, 60).endppq, realised, 'and the wire bound is the row realised')
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
    name = "a derived tile bounds at its host's window end, not at the lane-mate behind it",
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
      t.eq(tile.lane, nil, 'precondition: off the columns, so no lane-mate of its own to bound it')
      t.truthy(tile.endppq < 1440, 'precondition: and past its own window, so something clipped its tail')

      t.eq(tile.endppq, 600, 'the tile bounds at its host window end')
      t.truthy(tile.endppq < successor.ppq, 'and the note behind it is no term of the bound')
    end,
  },

  {
    name = 'a kept tile holds its host window bound when a lane-mate moves under it',
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
      t.eq(tile().lane, nil, 'precondition: the tile sits in no column the two authored notes share')
      t.eq(tile().endppq, 600,
        'fixture check: clipped by its host window, well short of the ceiling it was emitted with')
      local ran = runs

      h.tm:deleteEvent(authoredAt(h, 1, 960))
      h.tm:flush()
      generators.kinds.overrun = nil

      t.eq(runs, ran, 'precondition: the edit fell outside the window, so the host kept its output')
      t.eq(tile().endppq, 600, 'the kept tile stands where its host window left it')
    end,
  },

  {
    -- A region closing on a row the swing moves, its stage emitting past it. The bound is the row,
    -- so the wire tail is that row realised; a window end read in the raw frame lands elsewhere.
    name = "a derived tile's window bound is a row, and reaches the wire converted once",
    run = function(harness)
      local h = harness.mk(c55)
      generators.kinds.overrun = {
        expand = function(stream) return { notes = {
          { ppq = stream.window[1], endppq = 1440, pitch = 60, vel = 100, detune = 0 },
        }, delta = {} } end,
        mode = 'replace', dest = 'note', label = 'Overrun', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, ppq = 480, endppq = 1140,
                                   fx = { { kind = 'overrun' } } } })
      h.tm:rebuild()
      generators.kinds.overrun = nil

      local realised = h.tm:fromLogical(1, 1140)
      t.truthy(realised ~= 1140, 'fixture check: the swing bites at the row the window closes on')

      local tile
      for _, n in ipairs(h.fm:dump().notes) do if n.derived == 'fxr-1' then tile = n end end
      t.truthy(tile, 'precondition: the region emitted a tile')
      t.truthy(tile.endppq < 1440, 'precondition: past its own window, so the window end clipped it')

      t.eq(tile.endppq, realised, 'the tile bounds on the window end row, realised')
    end,
  },

  {
    -- The other side of the min: the clip is a ceiling, not the bound. A stage emitting a tile a
    -- quarter of the way through its host's window leaves it ending there, with the window, the
    -- host's own lane and the take all well past it.
    name = "a derived note ends where its generator ended it, its host's window no term of that",
    run = function(harness)
      local h = harness.mk()
      generators.kinds.stamp = {
        expand = function(stream) return { notes = {
          { ppq = stream.window[1], endppq = stream.window[1] + 120, pitch = 67, vel = 100, detune = 0 },
        }, delta = {} } end,
        mode = 'replace', dest = 'note', label = 'Stamp', defaults = {}, fields = {},
      }
      h.tm:addEvent(util.assign(note(1, 0, 480, 60, 1), { fx = { { kind = 'stamp' } } }))
      h.tm:flush()
      generators.kinds.stamp = nil

      local tile
      for _, n in ipairs(h.fm:dump().notes) do if n.derived then tile = n end end
      t.truthy(tile, 'precondition: the host stamped a tile inside its own window')
      t.eq(authoredAt(h, 1, 0).endppqC, 480,
        "precondition: the host's window closes at its lane bound, well past the tile")

      t.eq(tile.endppq, 120, 'the tile ends where its generator ended it')
    end,
  },

  {
    name = 'a derived note is cut by a same-pitch authored note on another lane',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.stamp = {
        expand = function(stream) return { notes = {
          { ppq = stream.window[1], endppq = stream.window[2], pitch = 67, vel = 100, detune = 0 },
        }, delta = {} } end,
        mode = 'replace', dest = 'note', label = 'Stamp', defaults = {}, fields = {},
      }
      h.tm:addEvent(util.assign(note(1, 0, 480, 60, 1), { fx = { { kind = 'stamp' } } }))
      h.tm:addEvent(note(1, 240, 480, 67, 2))   -- the tile's pitch, another lane
      h.tm:flush()
      generators.kinds.stamp = nil

      local tile
      for _, n in ipairs(h.fm:dump().notes) do if n.derived then tile = n end end
      t.truthy(tile, 'precondition: the host stamped a tile across its own window')
      t.eq(tile.endppq, 240, 'the tile ends where the next note of its pitch begins')
    end,
  },

}
