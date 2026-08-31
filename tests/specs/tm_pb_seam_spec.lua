-- The seam between seating and synthesis in the absorber pass. Seating asks which seats a detune
-- arrangement calls for: from the realised lane-1 sequence and the prevailing authored pb stream it
-- derives a seat per detune jump, carrying the stream's value at that tick. Synthesis answers with
-- the absorbers the channel already holds -- one standing at a seat is adopted, a spare moves to an
-- unfilled seat, a shortfall mints, and the leftovers are deleted -- and writes each seat to the
-- wire as raw = centsToRaw(cents + the detune carried there).
-- see docs/tuning.md § Absorber reconciliation
--
-- The two halves are told apart by what each is a function of. Seating depends on the arrangement
-- alone, so a channel edited into an arrangement lands on the same seats as one built with it.
-- Synthesis depends on the standing pool, and uuids read it: an adopted or moved absorber keeps the
-- uuid it had, a minted one is a uuid the channel has not held before, and a deleted one is gone.
-- Which spare fills which seat is not fixed where several of each are in play, so the assertions
-- here are over the pool as a set.
--
-- The base fixture is lane-1 notes a row apart under a pb holding the stream flat, so a seat's value
-- is known without interpolating anything; the cases that need a value to change step the stream
-- with a second pb. The last one puts the arrangement across the edge of a pb replace window, where
-- a seat persists as native MIDI.

local t    = require('support')
local util = require('util')

-- Independent of the module: cents to raw over the default 2-semitone pb range.
local function centsToRaw(cents) return util.round(cents * 8192 / 200) end

local ROW        = 240   -- one lane-1 row at the harness resolution
local BASE_CENTS = 30    -- the authored pb every seat in the flat-stream fixtures samples

local function note(ppq, pitch, detune)
  return { evType = 'note', ppq = ppq, endppq = ppq + ROW, chan = 1, pitch = pitch,
           vel = 100, lane = 1, detune = detune, delay = 0 }
end

-- One lane-1 note per detune, a row apart, under a pb held flat at BASE_CENTS. Authored through tm,
-- so each event is minted the way an edit mints it.
local function arrangement(harness, detunes)
  local h = harness.mk{ seed = { length = 3840 } }
  h.tm:addEvent({ evType = 'pb', ppq = 0, chan = 1, val = BASE_CENTS, shape = 'step' })
  for i, detune in ipairs(detunes) do h.tm:addEvent(note((i - 1) * ROW, 58 + 2 * i, detune)) end
  h.tm:flush()
  return h
end

-- The channel's pb wire, by raw tick.
local function wire(h)
  local byPpq = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == 1 then byPpq[c.ppq] = c end
  end
  return byPpq
end

-- The wire read without its identities: what seating asked for, with synthesis's answer stripped out.
local function seatReading(h)
  local out = {}
  for ppq, c in pairs(wire(h)) do
    out[ppq] = { val = c.val, shape = c.shape, derived = c.derived, cents = c.cents, ppqL = c.ppqL }
  end
  return out
end

-- The standing absorber pool: tick -> uuid, and the uuids as a set.
local function pool(h)
  local byPpq, uuids = {}, {}
  for ppq, c in pairs(wire(h)) do
    if c.derived then byPpq[ppq] = c.uuid; uuids[c.uuid] = true end
  end
  return byPpq, uuids
end

local function lane1Cell(h, ppq)
  for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
    if e.ppq == ppq then return e end
  end
  t.truthy(false, 'fixture check: a lane-1 note stands at ' .. ppq)
end

return {

  ----- What the arrangement calls for

  {
    name = 'the seats an arrangement calls for do not depend on how the channel reached it',
    run = function(harness)
      -- Built with its detunes, against edited into them from a different set. The first channel
      -- mints its absorbers fresh and the second moves the ones it already stands, so the two
      -- differ in everything synthesis decides and in nothing seating does.
      local built  = arrangement(harness, { 0, 50, 0 })
      local edited = arrangement(harness, { 0, 0, 50 })
      local _, standing = pool(edited)
      t.truthy(next(standing), 'fixture check: the starting arrangement seats absorbers of its own')

      edited.tm:assignEvent(lane1Cell(edited, ROW), { detune = 50 })
      edited.tm:assignEvent(lane1Cell(edited, 2 * ROW), { detune = 0 })
      edited.tm:flush()

      local reading = seatReading(built)
      t.truthy(reading[ROW] and reading[2 * ROW], 'fixture check: a jump each way seats two absorbers')
      t.deepEq(seatReading(edited), reading, 'the same arrangement, the same seats and values')
    end,
  },

  {
    name = 'a seat holds the stream value it samples, and lands on the wire summed with its detune',
    run = function(harness)
      -- Neither rung alone: the sidecar keeps the authored value the seat sampled, the wire carries
      -- that value plus the detune the seat sits in. see docs/tuning.md § Value-aware seats
      local h = arrangement(harness, { 0, 50, 0 })
      local pbs = wire(h)

      t.eq(pbs[0].val, centsToRaw(BASE_CENTS), 'the authored pb stands at its own value')
      t.falsy(pbs[0].derived, 'fixture check: the stream is authored, not a seat')

      t.eq(pbs[ROW].cents, BASE_CENTS, 'the seat at the 0->50 jump samples the held stream')
      t.eq(pbs[ROW].val, centsToRaw(BASE_CENTS + 50), 'and reaches the wire summed with 50c of detune')
      t.eq(pbs[2 * ROW].cents, BASE_CENTS, 'the seat closing the jump samples the same stream')
      t.eq(pbs[2 * ROW].val, centsToRaw(BASE_CENTS), 'and lands on it, the detune it returns to being 0')
    end,
  },

  {
    name = 'the anchor is called for only where nothing pins the stream at the first onset',
    run = function(harness)
      -- I2a: a pb-active channel is anchored at its first lane-1 onset, so playback never inherits
      -- the synth's prior bend. An authored pb at-or-before that onset pins it already, and the
      -- arrangement calls for no seat there. see docs/tuning.md § Absorber reconciliation
      local function channel(pbPpq)
        local h = harness.mk{ seed = { length = 3840 } }
        h.tm:addEvent({ evType = 'pb', ppq = pbPpq, chan = 1, val = BASE_CENTS, shape = 'step' })
        for i = 1, 2 do h.tm:addEvent(note(i * ROW, 58 + 2 * i, 0)) end
        h.tm:flush()
        return h
      end

      local pinned = channel(0)
      t.truthy(wire(pinned)[0], 'fixture check: an authored pb makes the channel pb-active')
      local _, standing = pool(pinned)
      t.falsy(next(standing), 'pinned before the first onset, the arrangement calls for no seat at all')

      local unpinned = channel(3 * ROW)
      local seatedAt = pool(unpinned)
      t.truthy(seatedAt[ROW], 'a stream starting past the first onset leaves it to be anchored')
      t.eq(wire(unpinned)[ROW].val, 0, 'and the anchor holds the value before the first breakpoint: 0')
    end,
  },

  ----- How the absorbers answer

  {
    name = 'an absorber standing at a seat is adopted, its uuid intact',
    run = function(harness)
      local h = arrangement(harness, { 0, 50, 0 })
      local before = pool(h)
      t.truthy(before[ROW] and before[2 * ROW], 'fixture check: an absorber at each seat')

      -- Retuning the stream moves what every seat is worth without moving a seat.
      h.tm:assignEvent(wire(h)[0], { val = 2 * BASE_CENTS })
      h.tm:flush()

      local after = pool(h)
      t.eq(after[ROW], before[ROW], 'the absorber at the jump is the one that stood there')
      t.eq(after[2 * ROW], before[2 * ROW], 'as is the one closing it')
      t.eq(wire(h)[ROW].val, centsToRaw(2 * BASE_CENTS + 50), 'and its value is refreshed to the new stream')
    end,
  },

  {
    name = 'a spare moves to the seat the arrangement opened',
    run = function(harness)
      -- A second authored pb steps the stream up between the two seats, so the one the absorber
      -- moves to is worth something the one it leaves is not.
      local h = arrangement(harness, { 0, 50 })
      h.tm:addEvent({ evType = 'pb', ppq = 400, chan = 1, val = 2 * BASE_CENTS, shape = 'step' })
      h.tm:flush()
      local before, beforeUuids = pool(h)
      t.truthy(before[ROW], 'fixture check: the lone jump seats one absorber')
      t.eq(wire(h)[ROW].val, centsToRaw(BASE_CENTS + 50), 'fixture check: seated on the lower step')

      -- The jump travels with its note, vacating one seat and opening another.
      h.tm:assignEvent(lane1Cell(h, ROW), { ppq = 2 * ROW })
      h.tm:flush()

      local after, afterUuids = pool(h)
      t.falsy(after[ROW], 'the vacated seat holds nothing')
      t.eq(after[2 * ROW], before[ROW], 'the absorber moved to the opened seat, keeping its uuid')
      t.deepEq(afterUuids, beforeUuids, 'the pool is the one it was: nothing minted, nothing deleted')
      t.eq(wire(h)[2 * ROW].val, centsToRaw(2 * BASE_CENTS + 50),
           'and it holds what the seat is worth, not what it carried there')
      t.eq(wire(h)[2 * ROW].ppqL, 2 * ROW, 'and the seat\'s logical tick, not the one it left')
    end,
  },

  {
    name = 'an absorber with no seat left to fill is deleted',
    run = function(harness)
      local h = arrangement(harness, { 0, 50, 0 })
      local before = pool(h)
      t.truthy(before[ROW] and before[2 * ROW], 'fixture check: an absorber at each seat')

      -- Carrying the detune through the third note flattens the jump that closed it.
      h.tm:assignEvent(lane1Cell(h, 2 * ROW), { detune = 50 })
      h.tm:flush()

      local after, afterUuids = pool(h)
      t.eq(after[ROW], before[ROW], 'the surviving seat keeps the absorber it had')
      t.falsy(wire(h)[2 * ROW], 'the leftover is off the wire entirely')
      t.falsy(afterUuids[before[2 * ROW]], 'its uuid is gone with it')
    end,
  },

  {
    name = 'a seat beyond the pool mints a fresh absorber',
    run = function(harness)
      local h = arrangement(harness, { 0, 50, 50 })
      local before, beforeUuids = pool(h)
      t.truthy(before[ROW], 'fixture check: one jump, one absorber')
      t.falsy(before[2 * ROW], 'fixture check: the detune carries through, so there is no second seat')

      h.tm:assignEvent(lane1Cell(h, 2 * ROW), { detune = 0 })
      h.tm:flush()

      local after = pool(h)
      t.eq(after[ROW], before[ROW], 'the standing absorber is left where it stands')
      t.truthy(after[2 * ROW], 'the opened seat is filled')
      t.falsy(beforeUuids[after[2 * ROW]], 'by an absorber the channel had not held before')
    end,
  },

  ----- How a seat persists

  {
    name = 'a seat inside a replace window persists native MIDI only',
    run = function(harness)
      -- One sine window over [0, 480) hosted on lane 2 -- pb is channel-wide, so the host's lane is
      -- free -- with an authored pb past it and lane-1 jumps on both sides of its end.
      local h = harness.mk{ seed = { length = 3840 } }
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 2 * ROW, chan = 1, pitch = 70, vel = 100,
                      detune = 0, delay = 0, lane = 2,
                      fx = { { kind = 'sine', period = { 1, 1 }, depth = 10, onset = 0 } } })
      h.tm:flush()
      h.tm:addEvent({ evType = 'pb', ppq = 600, chan = 1, val = BASE_CENTS, shape = 'step' })
      for i, detune in ipairs({ 0, 50, 50, 20 }) do
        h.tm:addEvent(note((i - 1) * ROW, 58 + 2 * i, detune))
      end
      h.tm:flush()

      local pbs = wire(h)
      local inside, outside = pbs[ROW], pbs[3 * ROW]
      t.truthy(inside, 'fixture check: the 0->50 jump inside the window is seated')
      t.truthy(outside, 'fixture check: as is the 50->20 jump past its end')

      -- Inside a window a seat is recognised by the window it lies in, so it needs no marker and
      -- carries no sidecar. see docs/trackerManager.md § CC walk
      t.truthy(inside.plain, 'the seat inside the window is a plain cc: no sidecar row in the take')
      t.eq(inside.cents, nil, 'so it carries no authored value')
      t.eq(inside.ppqL, nil, 'and no logical tick')
      t.eq(inside.derived, nil, 'nor the marker that would name it a seat')
      t.eq(inside.val - pbs[ROW - 1].val, centsToRaw(50),
           'while the wire still steps the detune across the window curve, on a dual point')

      -- Outside every window the seat is nothing but itself, so it says what it is.
      t.eq(outside.derived, 'absorber', 'the seat past the window is marked')
      t.eq(outside.cents, BASE_CENTS, 'and carries the stream value it sampled')
      t.eq(outside.ppqL, 3 * ROW, 'and its logical tick')
      t.eq(outside.val, centsToRaw(BASE_CENTS + 20), 'summed with its detune on the wire')
    end,
  },
}
