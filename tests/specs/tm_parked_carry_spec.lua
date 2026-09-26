-- A lane holding parked notes is subject to the same renewal rule as any other
-- (docs/trackerManager.md § Note-lane renewal): its events table changes identity iff its contents
-- changed. tv's cell carry keys on the table `tm:authoredLanes` hands back, so a parked-bearing
-- lane whose population held must hand back the same table across a rebuild, or it re-places every
-- pass. Parked notes are seated in the lane itself, so the pass that reseats them from the stash
-- must leave a seated note whose spec held where it is.
--
-- `endppqC` is derived from the lane's strict-next onset, so a parked host's clip moves only when
-- its own lane's membership does. Case 3 is that case: the lane renews on the one change.
--
-- The rule is the column's, not the note lane's. A cc column seats its parked ccs as a lane seats its
-- parked notes, and park and restore flip the event in place, which is a content change like any other.
-- A parked pa is seated the same way, flagged in its host's lane beside the host: its spec carries
-- the lane, so the stash alone says where it sits. A pa parks with its host, so it parks only under a
-- parked host in its own lane, and restore returns it to mm under the uuid it left with.
--
-- pb alone keeps its parked events in a list of its own, and tm publishes the stream's whole
-- population (`tm:authoredPb`) as it publishes a lane's. Its carry needs that list to carry across
-- the pass boundary, or a dirty channel re-mints it every pass and re-places its cells.
--
-- The fixture is a self-parking arp host at 480 on chan 1 lane 1, alone on its lane, and a plain
-- note on chan 2 -- a second channel to dirty, so a pass can run without touching chan 1. The cc and
-- pb fixtures park through a replace region instead, and dirty chan 1 itself, which is where the
-- carry used to be lost.

local t = require('support')
local generators = require('generators')
local util = require('util')

local arpUp = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }   -- replace-mode: parks its host

local function note(ppq, pitch, chan, extra)
  local n = { evType = 'note', ppq = ppq, endppq = ppq + 240, chan = chan, pitch = pitch,
              vel = 100, detune = 0, delay = 0, lane = 1 }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

local function parkedHostOf(h)
  local parked = require('harness').parkedNotes(h.tm, 1)
  t.eq(#parked, 1, 'fixture check: one parked host on chan 1')
  return parked[1]
end

local function holds(list, evt)
  for _, e in ipairs(list) do if e == evt then return true end end
  return false
end

-- chan 1 holds one parked host, alone on lane 1; chan 2 one plain note.
local function parkedHost(harness)
  local h = harness.mk()
  h.tm:addEvent(note(480, 62, 1, { fx = arpUp }))
  h.tm:addEvent(note(0, 60, 2))
  h.tm:flush()
  return h, parkedHostOf(h)
end

local region = { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240, fx = { { kind = 'rep' } } } }

-- A cc-replace region parking the authored cc 74 at ppq 60 on chan 1. The kind stays registered
-- across the case's passes -- dropping it would take the window with it and restore the cc -- so
-- each case clears it at the end.
local function coverCC(h)
  generators.kinds.rep = {
    expand = function(host) return { notes = {}, delta = {
      { ppq = host.window[1], val = 100, shape = 'step' } } } end,
    mode = 'replace', dest = 74, label = 'Rep', defaults = {}, fields = {},
  }
  h.ds:assign('fxRegions', region)
  h.tm:rebuild()
  local parked = require('harness').parkedCCs(h.tm, 1)
  t.eq(#parked, 1, 'fixture check: the covered cc parked off the take')
  return parked[1]
end

local function parkedCC(harness)
  local h = harness.mk()
  h.tm:addEvent({ evType = 'cc', ppq = 60, chan = 1, cc = 74, val = 30 })
  h.tm:flush()
  return h, coverCC(h)
end

-- The same, on pb: the authored breakpoint at 0 leaves the take and the region's own curve seats.
local function parkedPb(harness)
  local h = harness.mk()
  h.tm:addEvent({ evType = 'pb', ppq = 0, chan = 1, val = 40 })
  h.tm:flush()
  generators.kinds.rep = {
    expand = function(host) return { notes = {}, delta = {
      { ppq = host.window[1], val = 50, shape = 'step' },
      { ppq = host.window[2], val = 0,  shape = 'step' } } } end,
    mode = 'replace', dest = 'pb', label = 'Rep', defaults = {}, fields = {},
  }
  h.ds:assign('fxRegions', region)
  h.tm:rebuild()
  t.eq(#h.tm:getChannel(1).parked.pb, 1, 'fixture check: the authored pb parked off the take')
  return h
end

local function lanePAs(h, lane)
  local out = {}
  for _, e in ipairs(h.tm:authoredLanes(1)[lane] or {}) do
    if e.evType == 'pa' then out[#out + 1] = e end
  end
  return out
end

local function stashPAs(h)
  local out = {}
  for _, spec in ipairs(h.ds:get('fxParked') or {}) do
    if spec.evType == 'pa' then out[#out + 1] = spec end
  end
  return out
end

local function mmPAs(h)
  local out = {}
  for _, c in ipairs(h.fm:dump().ccs) do if c.evType == 'pa' then out[#out + 1] = c end end
  return out
end

local arpRegion = { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240, fx = arpUp } }

-- A plain host on chan 1 lane 2 (so a pa's lane is observable) carrying one pa at 120, then parked
-- by an arp region; chan 2 holds one plain note. Hands back the pa's on-take event and its uuid.
local function parkedHostWithPA(harness)
  local h = harness.mk()
  h.tm:addEvent(note(0, 60, 1, { lane = 2 }))
  h.tm:addEvent({ evType = 'pa', ppq = 120, chan = 1, pitch = 60, vel = 70 })
  h.tm:addEvent(note(0, 60, 2))
  h.tm:flush()
  local onTake = lanePAs(h, 2)[1]
  t.truthy(onTake and not onTake.parked and onTake.uuid,
    "fixture check: the pa sits on the take in its host's lane")
  local uuid = onTake.uuid

  h.ds:assign('fxRegions', arpRegion)
  h.tm:rebuild()
  t.eq(#harness.parkedNotes(h.tm, 1), 1, 'fixture check: the region parked the host')
  return h, onTake, uuid
end

return {

  {
    name = 'a pass that leaves the parked population alone keeps the lane table and its seated host',
    run = function(harness)
      local h, host = parkedHost(harness)
      local lane = h.tm:authoredLanes(1)[1]
      t.eq(#lane, 1, 'fixture check: the lane reads as its parked host alone')

      h.tm:addEvent(note(960, 64, 2)); h.tm:flush()

      t.truthy(h.tm:authoredLanes(1)[1] == lane, "the lane carried, so tv's cell carry stands")
      t.truthy(parkedHostOf(h) == host, 'and the host stayed seated rather than being reseated')
    end,
  },

  {
    name = 'a parked host that took an edit sheds its lane table',
    run = function(harness)
      local h, host = parkedHost(harness)
      local lane = h.tm:authoredLanes(1)[1]

      h.tm:assignParked(host, { pitch = 67 }); h.tm:flush()

      t.eq(parkedHostOf(h).pitch, 67, 'fixture check: the edit reached the seated host')
      t.truthy(h.tm:authoredLanes(1)[1] ~= lane, 'the lane whose host moved shed its table')
    end,
  },

  {
    -- The new note lands at the host's own authored ceiling, so no window covers it and it stays on
    -- the take: the parked population is untouched. What moves is the host's clip, from its authored
    -- endppq down to its lane's new strict-next onset -- a content change the stash cannot see.
    name = 'a parked host whose clip moved is read from a renewed lane, though its spec stood still',
    run = function(harness)
      local h, host = parkedHost(harness)
      local lane = h.tm:authoredLanes(1)[1]
      t.eq(host.endppqC, 720, 'fixture check: the host clips at its authored ceiling')

      h.tm:addEvent(note(600, 64, 1)); h.tm:flush()

      t.eq(parkedHostOf(h).endppqC, 600, 'the clip fell to the lane\'s new strict-next onset')
      t.truthy(h.tm:authoredLanes(1)[1] ~= lane, 'the lane whose clip moved shed its table')
    end,
  },

  {
    -- The added note dirties chan 1 without touching cc 74, so nothing in that column moved.
    name = 'a cc column holding a parked cc keeps its table and its seated cc across a pass',
    run = function(harness)
      local h, parked = parkedCC(harness)
      local column = h.tm:authoredCCs(1)[74]
      t.truthy(holds(column, parked), 'fixture check: the parked cc is part of the column population')

      h.tm:addEvent(note(960, 60, 1)); h.tm:flush()

      t.truthy(h.tm:authoredCCs(1)[74] == column, "the column carried, so tv's cell carry stands")
      t.truthy(require('harness').parkedCCs(h.tm, 1)[1] == parked,
        'and the cc stayed seated rather than being reseated')
      generators.kinds.rep = nil
    end,
  },

  {
    -- Park is a flip within the column's population, as restore is: the event the region covers is
    -- the event the column seats parked, with no clone standing in for it.
    name = 'a covered cc parks where it stands, the on-take event itself flagged',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'cc', ppq = 60, chan = 1, cc = 74, val = 30 }); h.tm:flush()
      local onTake = h.tm:authoredCCs(1)[74][1]
      t.truthy(onTake and not onTake.parked, 'fixture check: the cc sits on the take')

      t.truthy(coverCC(h) == onTake, 'the parked cc is the on-take event, flipped where it stood')
      generators.kinds.rep = nil
    end,
  },

  {
    name = 'a cc column whose parked cc took an edit sheds its table',
    run = function(harness)
      local h, parked = parkedCC(harness)
      local column = h.tm:authoredCCs(1)[74]

      h.tm:assignParked(parked, { val = 81 }); h.tm:flush()

      t.eq(require('harness').parkedCCs(h.tm, 1)[1].val, 81, 'fixture check: the edit reached the parked cc')
      t.truthy(h.tm:authoredCCs(1)[74] ~= column, 'the column whose parked cc moved shed its table')
      generators.kinds.rep = nil
    end,
  },

  {
    -- Dropping the region takes its window, so the cc comes back onto the take. Membership holds --
    -- the same cc at the same onset -- but the cell now renders as on-take, so the table must go.
    name = 'a cc column whose parked cc was restored sheds its table',
    run = function(harness)
      local h = parkedCC(harness)
      local column = h.tm:authoredCCs(1)[74]

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()
      generators.kinds.rep = nil

      t.eq(#require('harness').parkedCCs(h.tm, 1), 0, 'fixture check: nothing is parked any more')
      local restored
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.evType == 'cc' and c.cc == 74 and c.ppq == 60 then restored = c end
      end
      t.truthy(restored and restored.val == 30, 'fixture check: the authored cc is back on the take')
      t.truthy(h.tm:authoredCCs(1)[74] ~= column, 'the column whose cc came back shed its table')
    end,
  },

  {
    -- pb is one stream per channel, so its population needs no bucketing; it carries by the same
    -- rule, and a channel holding neither half is answered with nil rather than an empty column.
    name = 'a channel holding a parked pb answers with the same population across a pass',
    run = function(harness)
      local h = parkedPb(harness)
      local parked = h.tm:getChannel(1).parked.pb[1]
      local column = h.tm:authoredPb(1)
      t.truthy(holds(column, parked), 'fixture check: the parked pb is part of the channel population')

      h.tm:addEvent(note(960, 60, 1)); h.tm:flush()

      t.truthy(h.tm:authoredPb(1) == column, "the union carried, so tv's cell carry stands")
      t.eq(h.tm:authoredPb(2), nil, 'a channel with neither half shows no pb column at all')
      generators.kinds.rep = nil
    end,
  },

  {
    -- Order is the column's own, as it is for a note lane: a parked cc is spliced in at its onset
    -- rather than appended. The ghost interpolation walks successive events, so a population out of
    -- order interpolates between the wrong pair.
    name = 'a cc column seats its parked cc in ppq order among its on-take ones',
    run = function(harness)
      local h, parked = parkedCC(harness)
      h.tm:addEvent({ evType = 'cc', ppq = 600, chan = 1, cc = 74, val = 90 }); h.tm:flush()

      local column, parkedAt, followerAt = h.tm:authoredCCs(1)[74]
      local last = -1
      for i, e in ipairs(column) do
        t.truthy(e.ppq >= last, 'the population reads in ppq order across both halves')
        last = e.ppq
        if e == parked   then parkedAt = i end
        if e.ppq == 600  then followerAt = i end
      end
      t.truthy(parkedAt and followerAt, 'fixture check: both the parked cc and its follower are in the column')
      t.truthy(parkedAt < followerAt, 'the parked cc reads before the on-take event that follows it')
      generators.kinds.rep = nil
    end,
  },

  {
    -- What the carry is for. tv keys its built cells on the events table a column hands back, so a
    -- column that renewed every pass would re-place its cells every pass.
    name = 'a parked-bearing cc column keeps its built cells across a pass',
    run = function(harness)
      local h = parkedCC(harness)
      local function ccColumn()
        for _, col in ipairs(h.vm.grid.cols) do
          if col.type == 'cc' and col.midiChan == 1 and col.cc == 74 then return col end
        end
      end
      local cells = ccColumn().cells
      t.truthy(next(cells) ~= nil, 'fixture check: the column placed at least one cell')

      h.tm:addEvent(note(960, 60, 1)); h.tm:flush()

      t.truthy(ccColumn().cells == cells, 'the column carried its built cells rather than re-placing')
      generators.kinds.rep = nil
    end,
  },

  {
    -- Park flips the pa where it stands, as it does a cc: the event the lane held on the take is
    -- the event it now holds parked. The stash spec carries the lane, so it can reseat there.
    name = "a newly parked host's pa flips in place in its lane and leaves mm",
    run = function(harness)
      local h, onTake, uuid = parkedHostWithPA(harness)

      local parked = harness.parkedPAs(h.tm, 1)
      t.eq(#parked, 1, 'one parked pa on chan 1')
      t.truthy(parked[1] == onTake, 'the parked pa is the on-take event, flipped where it stood')
      t.truthy(holds(h.tm:authoredLanes(1)[2], onTake), "it sits in its host's lane")
      t.eq(#mmPAs(h), 0, 'the pa left mm')
      local stash = stashPAs(h)
      t.eq(#stash, 1, 'the stash holds the pa')
      t.eq(stash[1].lane, 2, 'with its lane')
      t.eq(stash[1].uuid, uuid, 'and its uuid')
    end,
  },

  {
    name = 'a pass that leaves the parked pa alone keeps its lane table and its seat',
    run = function(harness)
      local h, pa = parkedHostWithPA(harness)
      local lane = h.tm:authoredLanes(1)[2]
      t.truthy(pa.parked and holds(lane, pa), 'fixture check: the pa sits parked in lane 2')

      h.tm:addEvent(note(960, 64, 2)); h.tm:flush()

      t.truthy(h.tm:authoredLanes(1)[2] == lane, "the lane carried, so tv's cell carry stands")
      t.truthy(harness.parkedPAs(h.tm, 1)[1] == pa, 'and the pa stayed seated rather than being reseated')
    end,
  },

  {
    -- A wholesale pass starts from fresh columns, so the stash is the only source for the seat.
    name = 'a wholesale pass reseats a parked pa from the stash in its lane',
    run = function(harness)
      local h = parkedHostWithPA(harness)

      h.tm:rebuild(true)

      local pas = lanePAs(h, 2)
      t.eq(#pas, 1, "exactly one pa in the host's lane")
      t.truthy(pas[1].parked, 'and it is flagged parked')
      local spec = stashPAs(h)[1]
      t.truthy(spec, 'fixture check: the stash still holds the pa')
      t.truthy(util.deepEq(util.clone(pas[1], { parked = true }), spec),
        'the seat is the stash spec, field for field')
    end,
  },

  {
    -- lane is display-only: rebuildPA overlays it at dispatch, so mm must not hold a stale copy.
    name = 'restoring a parked pa returns it to mm under its own uuid, once in its lane',
    run = function(harness)
      local h, _, uuid = parkedHostWithPA(harness)

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()

      local restored = mmPAs(h)
      t.eq(#restored, 1, 'mm holds the one pa again')
      t.eq(restored[1].uuid, uuid, 'under its original uuid')
      t.eq(restored[1].lane, nil, 'and with no lane')
      local pas = lanePAs(h, 2)
      t.eq(#pas, 1, 'lane 2 holds exactly one pa')
      t.falsy(pas[1].parked, 'and it is on the take')
    end,
  },

  {
    name = 'an mm pa added under an already-parked host parks the same pass',
    run = function(harness)
      local h = parkedHostWithPA(harness)

      h.tm:addEvent({ evType = 'pa', ppq = 180, chan = 1, pitch = 60, vel = 90 }); h.tm:flush()

      t.eq(#mmPAs(h), 0, 'the new pa is not in mm')
      local seated
      for _, e in ipairs(lanePAs(h, 2)) do if e.ppq == 180 then seated = e end end
      t.truthy(seated and seated.parked, 'it sits flagged in the host\'s lane')
      local stashed
      for _, spec in ipairs(stashPAs(h)) do if spec.ppq == 180 then stashed = spec end end
      t.truthy(stashed, 'and the stash holds it')
    end,
  },

  {
    -- A wholesale pass seats the host from the stash with no lane bound yet, and dispatch runs before
    -- the lane-bound pass stamps one. So a foreign pa meeting that host on the same pass must bind
    -- against the host's span as the lane defines it, not against a clip that is not there.
    name = 'a foreign mm pa under a parked host parks on a wholesale pass',
    run = function(harness)
      local h = parkedHostWithPA(harness)

      -- A foreign write behind mm's back (chan 1 is 0 on the wire), so load genuinely re-reads.
      h.reaper.MIDI_InsertCC(h.fm:take(), false, false, 180, 0xA0, 0, 60, 90)
      h.fm:load(h.fm:take())

      local seated
      for _, e in ipairs(lanePAs(h, 2)) do if e.ppq == 180 then seated = e end end
      t.truthy(seated and seated.parked, "the foreign pa sits flagged in the host's lane")
      t.eq(#mmPAs(h), 0, 'and has left mm')
    end,
  },

  {
    -- The parked host's span covers the pa, but the pa belongs to the on-take same-pitch note in
    -- lane 1, which sits past the region: a pa parks with its host, not with any span over its pitch.
    name = "a pa in another lane's on-take note stays on the take under a parked host's span",
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(note(0, 60, 1, { lane = 2, endppq = 480 }))
      h.tm:addEvent(note(240, 60, 1, { lane = 1, endppq = 480 }))
      h.tm:addEvent({ evType = 'pa', ppq = 300, chan = 1, pitch = 60, vel = 70 })
      h.tm:flush()
      t.eq(#lanePAs(h, 1), 1, 'fixture check: the pa sits in lane 1')

      h.ds:assign('fxRegions', arpRegion)
      h.tm:rebuild()
      local parkedHosts = harness.parkedNotes(h.tm, 1)
      t.truthy(#parkedHosts == 1 and parkedHosts[1].lane == 2 and parkedHosts[1].endppqC > 300,
        "fixture check: the lane-2 host parked, its span over the pa's onset")

      t.eq(#mmPAs(h), 1, 'the pa stays in mm')
      t.eq(#stashPAs(h), 0, 'and out of the stash')
    end,
  },

}
