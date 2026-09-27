-- Pins PA attachment as an INTENT relation, tested in the logical frame.
--
-- A PA carries its own ppqL and reswings from it (rebuild's CC walk), exactly like a
-- note -- it is not slaved to its host's raw onset. So attachment must be tested on
-- the logical seat: test the raw window instead and any realisation-only shift of the
-- host (a delay, a same-pitch nudge) silently detaches its PAs, and um then declines
-- to move or cull them with their host. see docs/trackerManager.md § PA binding
--
-- Delay is the cheap reachable case; the same hole opens under the tail walk's nudge.
--
-- Lane binding is the same relation read from the columns: dispatch seats a PA in the lane of the
-- note whose logical span covers its onset, the span being the note's lane bound. A delayed host
-- keeps the PAs in its own delay gap, a negatively delayed one takes none from the note ahead of
-- it, and a PA no span covers is seated nowhere. The bound includes the note's overlap past its
-- lane successor, so a PA under that overrun still binds, though a later onset sits between them.

local t = require('support')

local function uuidOfNote(mm, chan, pitch)
  for _, n in mm:notes() do
    if n.chan == chan and n.pitch == pitch then return n.uuid end
  end
end

local function pasOf(mm)
  local out = {}
  for _, c in mm:ccsRaw() do
    if c.evType == 'pa' then out[#out + 1] = c.ppq end
  end
  table.sort(out)
  return out
end

-- Host authored at logical 0 but delayed a full row (delayToPPQ(1000, 240) = 240), so it
-- sounds at raw 240 -- past the PA it owns. Raw-frame attachment cannot see the pair.
local function delayedHostWithPA(harness)
  local h = harness.mk()
  h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 480, chan = 1, pitch = 60,
                  vel = 100, detune = 0, delay = 1000, lane = 1 })
  h.tm:addEvent({ evType = 'pa', ppq = 120, chan = 1, pitch = 60, vel = 70 })
  h.tm:flush()
  return h
end

local function note(lane, ppq, endppq, pitch, extra)
  local n = { evType = 'note', ppq = ppq, endppq = endppq, chan = 1, pitch = pitch,
              vel = 100, detune = 0, lane = lane }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

local function paAt(ppq, pitch)
  return { evType = 'pa', ppq = ppq, chan = 1, pitch = pitch, vel = 70 }
end

-- The lane each chan-1 PA is seated in, keyed by its column onset; a PA no lane holds is absent.
local function paLanes(h)
  local out = {}
  for lane, events in ipairs(h.tm:authoredLanes(1)) do
    for _, e in ipairs(events) do
      if e.evType == 'pa' then out[e.ppq] = lane end
    end
  end
  return out
end

-- Two PAs under one undelayed host, so a resize strands both at once.
local function hostWithTwoPAs(harness)
  local h = harness.mk()
  h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 480, chan = 1, pitch = 60,
                  vel = 100, detune = 0, lane = 1 })
  h.tm:addEvent({ evType = 'pa', ppq = 120, chan = 1, pitch = 60, vel = 70 })
  h.tm:addEvent({ evType = 'pa', ppq = 240, chan = 1, pitch = 60, vel = 80 })
  h.tm:flush()
  return h
end

return {

  {
    name = 'a delayed host still owns the PA at its logical seat: deleting it culls the PA',
    run = function(harness)
      local h = delayedHostWithPA(harness)
      t.deepEq(pasOf(h.fm), { 120 }, 'the PA is on the take to begin with')

      h.tm:deleteEvent(uuidOfNote(h.fm, 1, 60))
      h.tm:flush()

      t.deepEq(pasOf(h.fm), {}, 'the PA died with its host rather than orphaning')
    end,
  },

  {
    name = 'moving a delayed host carries its PA, in both frames',
    run = function(harness)
      local h = delayedHostWithPA(harness)

      -- Logical 0 -> 240: a whole-note shift, so the PA rides it rather than being culled.
      h.tm:assignEvent(uuidOfNote(h.fm, 1, 60), { ppq = 240, endppq = 720 })
      h.tm:flush()

      t.deepEq(pasOf(h.fm), { 360 }, 'the PA moved with its host')
      local pa
      for _, c in h.fm:ccsRaw() do if c.evType == 'pa' then pa = c end end
      t.eq(pa.ppqL, 360, "the PA's logical seat moved too -- raw and intent stay in step")
    end,
  },

  -- The cull deletes each PA as it walks, and deleting reaches into the same collection the
  -- walk reads. Two PAs is the smallest case where a walk that skips its successor shows.
  {
    name = 'shrinking a host culls every PA it strands, not just the first',
    run = function(harness)
      local h = hostWithTwoPAs(harness)
      t.deepEq(pasOf(h.fm), { 120, 240 }, 'both PAs are on the take to begin with')

      h.tm:assignEvent(uuidOfNote(h.fm, 1, 60), { endppq = 100 })
      h.tm:flush()

      t.deepEq(pasOf(h.fm), {}, 'both PAs died with the shrink, neither was skipped')
    end,
  },

  -- Lane 2's host is authored at [0, 480) and delayed a row, so it sounds from raw 240. Lane 1
  -- holds a same-pitch note far off, which a pitch-only guess would seize.
  {
    name = "a delayed host's PAs in its delay gap land in its lane",
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(note(1, 960, 1440, 60))
      h.tm:addEvent(note(2, 0, 480, 60, { delay = 1000 }))
      for _, ppq in ipairs({ 0, 120, 360 }) do h.tm:addEvent(paAt(ppq, 60)) end
      h.tm:flush()

      t.deepEq(paLanes(h), { [0] = 2, [120] = 2, [360] = 2 },
        "every PA sits in the delayed host's lane, the two ahead of its raw onset included")
    end,
  },

  -- Lane 2's host is authored at 480 and delayed a row early, so it sounds from raw 240 -- over
  -- the PA at 360, which lane 1's note covers logically. The second pass re-dispatches the PA.
  {
    name = "a negatively delayed host does not take its neighbour's PA, across passes",
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(note(1, 0, 480, 60))
      h.tm:addEvent(note(2, 480, 960, 60, { delay = -1000 }))
      h.tm:addEvent(paAt(360, 60))
      h.tm:flush()
      t.deepEq(paLanes(h), { [360] = 1 }, 'the PA sits in the lane of the note covering it')

      local uuid
      for _, c in h.fm:ccsRaw() do if c.evType == 'pa' then uuid = c.uuid end end
      h.tm:assignEvent(uuid, { vel = 71 })
      h.tm:flush()

      t.deepEq(paLanes(h), { [360] = 1 }, 'and stays there when the next pass dispatches it again')
    end,
  },

  {
    name = 'a PA no note covers is seated in no lane',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(note(1, 0, 240, 60))
      h.tm:addEvent(paAt(480, 60))
      h.tm:flush()

      t.deepEq(pasOf(h.fm), { 480 }, 'mm holds the PA')
      t.deepEq(paLanes(h), {}, 'but no lane does, though a note of its pitch is on the channel')
    end,
  },

  -- The pitch-60 host's bound is its successor's onset at 240 plus its overlap of 20, so it covers
  -- the PA at 250 from behind the pitch-62 note, the latest onset on the lane.
  {
    name = "a PA under a host's overlap binds to the host past the successor's onset",
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(note(1, 0, 480, 60, { overlap = 20 }))
      h.tm:addEvent(note(1, 240, 480, 62))
      h.tm:addEvent(paAt(250, 60))
      h.tm:flush()
      local host = h.tm:authoredLanes(1)[1][1]
      t.truthy(host.pitch == 60 and host.endppqC == 260,
        "fixture check: the host leads lane 1, bound at its successor's onset plus its overlap")

      t.deepEq(paLanes(h), { [250] = 1 }, "the PA sits in the host's lane")
    end,
  },

}
