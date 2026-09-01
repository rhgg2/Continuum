-- The parked half of a channel is subject to the same renewal rule as the on-take half
-- (docs/trackerManager.md § Note-lane renewal): the list changes identity iff its contents
-- changed. tv's cell carry keys on the table `tm:authoredLanes` hands back, so a parked-bearing
-- lane whose population held must hand back the same table across a rebuild, or it re-places every
-- pass -- which is what it did before renderUnion reconciled, since it minted all sixteen lists
-- afresh whether or not anything parked.
--
-- `endppqC` is the reason the rule is about contents and not about the stash: the clip is derived
-- after installation from the lane's strict-next onset, so it can move with the parked spec
-- standing still. Case 3 is that case.
--
-- The rule is the column's, not the note lane's: a cc column and a channel's pb stream have the same
-- two halves, and tm publishes each one's whole population (`tm:authoredCCs`, `tm:authoredPb`) as it
-- publishes a lane's. Their carry needs the parked list itself to carry across the pass boundary,
-- which for ccs, pb and pa it did not: only notes did, so a dirty channel re-minted the other three
-- every pass and any column holding one of them re-placed its cells.
--
-- The fixture is a self-parking arp host at 480 on chan 1 lane 1, alone on its lane, and a plain
-- note on chan 2 -- a second channel to dirty, so a pass can run without touching chan 1. The cc and
-- pb fixtures park through a replace region instead, and dirty chan 1 itself, which is where the
-- carry used to be lost.

local t = require('support')
local generators = require('generators')

local arpUp = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }   -- replace-mode: parks its host

local function note(ppq, pitch, chan, extra)
  local n = { evType = 'note', ppq = ppq, endppq = ppq + 240, chan = chan, pitch = pitch,
              vel = 100, detune = 0, delay = 0, lane = 1 }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

local function parkedList(h) return h.tm:getChannel(1).parked.notes end

local function holds(list, evt)
  for _, e in ipairs(list) do if e == evt then return true end end
  return false
end

-- chan 1 holds one parked host, chan 2 one plain note; the parked list is returned by identity.
local function parkedHost(harness)
  local h = harness.mk()
  h.tm:addEvent(note(480, 62, 1, { fx = arpUp }))
  h.tm:addEvent(note(0, 60, 2))
  h.tm:flush()
  t.eq(#parkedList(h), 1, 'fixture check: the arp host parked itself off the take')
  return h, parkedList(h)
end

local region = { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240, fx = { { kind = 'rep' } } } }

-- A cc-replace region parking the authored cc 74 at ppq 60 on chan 1. The kind stays registered
-- across the case's passes -- dropping it would take the window with it and restore the cc -- so
-- each case clears it at the end.
local function parkedCC(harness)
  local h = harness.mk()
  h.tm:addEvent({ evType = 'cc', ppq = 60, chan = 1, cc = 74, val = 30 })
  h.tm:flush()
  generators.kinds.rep = {
    expand = function(host) return { notes = {}, delta = {
      { ppq = host.window[1], val = 100, shape = 'step' } } } end,
    mode = 'replace', dest = 74, label = 'Rep', defaults = {}, fields = {},
  }
  h.ds:assign('fxRegions', region)
  h.tm:rebuild()
  t.eq(#h.tm:getChannel(1).parked.ccs, 1, 'fixture check: the covered cc parked off the take')
  return h
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

return {

  {
    name = 'a pass that leaves the parked population alone keeps the list and its events',
    run = function(harness)
      local h, parked = parkedHost(harness)
      local host = parked[1]

      h.tm:addEvent(note(960, 64, 2)); h.tm:flush()

      t.truthy(parkedList(h) == parked, 'the parked list carried across the pass')
      t.truthy(parkedList(h)[1] == host, 'and so did the event in it')
    end,
  },

  {
    name = 'a lane holding a parked event answers with the same population table across a pass',
    run = function(harness)
      local h = parkedHost(harness)
      local lane = h.tm:authoredLanes(1)[1]
      t.eq(#lane, 1, 'fixture check: the lane reads as its parked host alone')

      h.tm:addEvent(note(960, 64, 2)); h.tm:flush()

      t.truthy(h.tm:authoredLanes(1)[1] == lane, "the union carried, so tv's cell carry stands")
    end,
  },

  {
    name = 'a parked population that changed sheds the list',
    run = function(harness)
      local h, parked = parkedHost(harness)

      h.tm:assignParked(parked[1], { pitch = 67 }); h.tm:flush()

      t.eq(parkedList(h)[1].pitch, 67, 'fixture check: the edit reached the parked event')
      t.truthy(parkedList(h) ~= parked, 'the list that took an edit shed its table')
    end,
  },

  {
    -- The new note lands at the host's own authored ceiling, so no window covers it and it stays on
    -- the take: the parked population is untouched. What moves is the host's clip, from its authored
    -- endppq down to its lane's new strict-next onset -- a content change the stash cannot see.
    name = 'a parked event whose clip moved sheds the list, though its spec stood still',
    run = function(harness)
      local h, parked = parkedHost(harness)
      local host = parked[1]
      t.eq(host.endppqC, 720, 'fixture check: the host clips at its authored ceiling')

      h.tm:addEvent(note(600, 64, 1)); h.tm:flush()

      t.eq(#parkedList(h), 1, 'fixture check: the added note stayed on the take, nothing new parked')
      t.eq(parkedList(h)[1].endppqC, 600, 'the clip fell to the lane\'s new strict-next onset')
      t.truthy(parkedList(h) ~= parked, 'the list whose clip moved shed its table')
    end,
  },

  {
    -- The added note dirties chan 1 without touching cc 74, so neither half of that column moved.
    name = 'a cc column holding a parked event answers with the same population across a pass',
    run = function(harness)
      local h = parkedCC(harness)
      local parked = h.tm:getChannel(1).parked.ccs[1]
      local column = h.tm:authoredCCs(1)[74]
      t.truthy(holds(column, parked), 'fixture check: the parked cc is part of the column population')

      h.tm:addEvent(note(960, 60, 1)); h.tm:flush()

      t.truthy(h.tm:authoredCCs(1)[74] == column, "the union carried, so tv's cell carry stands")
      generators.kinds.rep = nil
    end,
  },

  {
    name = 'a cc column holding nothing parked is answered with its own events table',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'cc', ppq = 60, chan = 1, cc = 74, val = 30 }); h.tm:flush()
      t.eq(#h.tm:getChannel(1).parked.ccs, 0, 'fixture check: nothing is parked on the channel')

      t.truthy(h.tm:authoredCCs(1)[74] == h.tm:getChannel(1).onTake.ccs[74].events,
        'the common column pays nothing for a union it has no need of')
    end,
  },

  {
    name = 'a cc column whose parked half took an edit sheds its population table',
    run = function(harness)
      local h = parkedCC(harness)
      local column = h.tm:authoredCCs(1)[74]

      h.tm:assignParked(h.tm:getChannel(1).parked.ccs[1], { val = 81 }); h.tm:flush()

      t.eq(h.tm:getChannel(1).parked.ccs[1].val, 81, 'fixture check: the edit reached the parked cc')
      t.truthy(h.tm:authoredCCs(1)[74] ~= column, 'the column whose parked half moved shed its table')
      generators.kinds.rep = nil
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
    -- Order is the column's own, as it is for a note lane: the parked half merges into it rather
    -- than being appended and everything re-sorted. The ghost interpolation walks successive events,
    -- so a population out of order interpolates between the wrong pair.
    name = 'a cc column reads its parked and on-take halves in one ppq order',
    run = function(harness)
      local h = parkedCC(harness)
      local parked = h.tm:getChannel(1).parked.ccs[1]
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
    -- What the carry is for. tv keys its built cells on the events table a column hands back, and
    -- until the union was memoised it built a fresh one for any column holding a parked event.
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

}
