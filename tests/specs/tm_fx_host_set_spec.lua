-- Each channel of the frame keeps the set of its fx hosts: every note seated in its lanes that
-- carries an `fx` chain, parked or on the take, the `parked` flag saying which side it is on
-- (docs/trackerManager.md § Lane occupancy). The readers that find hosts -- the fx windows, the
-- expansion's host list, the park stage, `tm:eachParkedHost` -- read the set and never walk a
-- lane, so the set has to agree with the lanes after every pass that could move one.
--
-- The oracle is that walk: a scan of `tm:authoredLanes` for notes carrying fx, compared with the
-- set as event identities, on all sixteen channels. Each case drives one way a host joins or
-- leaves -- an on-take splice, a self-park, a region park, a restore, an fx toggle on either side,
-- a delete, a move, and the wholesale re-read -- and holds the agreement after it. A count of the
-- hosts a case expects guards the agreement from holding vacuously over two empty sets.
--
-- A channel the pass left clean is carried whole, so its set is the same table after an edit
-- elsewhere; a channel re-read wholesale is seated afresh, so a set carried across it would hold
-- the column events of the pass before.

local t    = require('support')
local util = require('util')

local sine30 = { { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } }  -- pb chain: sounds
local arpUp  = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }             -- replace: parks

local function addNote(h, over)
  local note = { evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                 vel = 100, detune = 0, delay = 0, lane = 1 }
  for k, v in pairs(over or {}) do note[k] = v end
  h.tm:addEvent(note)
end

local function hostsByScan(h, chan)
  local out = {}
  for _, events in ipairs(h.tm:authoredLanes(chan)) do
    for _, evt in ipairs(events) do
      if util.isNote(evt) and evt.fx then out[evt] = true end
    end
  end
  return out
end

local function count(set)
  local n = 0
  for _ in pairs(set) do n = n + 1 end
  return n
end

-- The set agrees with the scan on every channel; `expected` = { [chan] = host count } guards it.
local function agrees(h, what, expected)
  for chan = 1, 16 do
    local set, scanned = h.tm:getChannel(chan).fxHosts, hostsByScan(h, chan)
    t.truthy(set, what .. ': chan ' .. chan .. ' keeps a host set')
    for evt in pairs(scanned) do
      t.truthy(set[evt], what .. ': chan ' .. chan .. ' set holds the host at ' .. evt.ppq)
    end
    for evt in pairs(set) do
      t.truthy(scanned[evt], what .. ': chan ' .. chan .. ' set holds nothing its lanes lack')
    end
    t.eq(count(scanned), (expected or {})[chan] or 0, what .. ': chan ' .. chan .. ' host count')
  end
end

-- The seated note with this uuid, wherever it sits on the channel.
local function seated(h, chan, uuid)
  for _, events in ipairs(h.tm:authoredLanes(chan)) do
    for _, evt in ipairs(events) do
      if util.isNote(evt) and evt.uuid == uuid then return evt end
    end
  end
end

local function firstNote(h, chan)
  for _, evt in ipairs(h.tm:authoredLanes(chan)[1] or {}) do
    if util.isNote(evt) then return evt end
  end
end

local function onlyHost(h, chan)
  local host = next(hostsByScan(h, chan))
  t.truthy(host, 'fixture check: chan ' .. chan .. ' has a host')
  return host
end

local function onTakeUuids(h)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do if not n.derived then out[n.uuid] = true end end
  return out
end

return {

  {
    name = 'an on-take host joins its own channel\'s set',
    run = function(harness)
      local h = harness.mk()
      agrees(h, 'empty take')
      addNote(h, { fx = sine30 }); h.tm:flush()
      agrees(h, 'one host on chan 1', { 1 })
      addNote(h, { chan = 2, fx = sine30 }); h.tm:flush()
      agrees(h, 'a second on chan 2', { 1, 1 })
      t.falsy(onlyHost(h, 1).parked, 'the host sounds on the take')
    end,
  },

  {
    name = 'a self-parking host stays in the set, flagged parked',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { fx = arpUp }); h.tm:flush()
      agrees(h, 'arp host', { 1 })
      t.truthy(onlyHost(h, 1).parked, 'the host parked itself')
    end,
  },

  {
    name = 'a host in a region-parked chord stays in the set through park and restore',
    run = function(harness)
      local h = harness.mk()
      addNote(h)
      addNote(h, { lane = 2, pitch = 64, fx = sine30 })
      h.tm:flush()
      local uuid = onlyHost(h, 1).uuid

      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240, fx = arpUp } })
      h.tm:rebuild()
      agrees(h, 'region parks the chord', { 1 })
      t.truthy(onlyHost(h, 1).parked, 'the pb-chain host parked with its chord')
      t.falsy(onTakeUuids(h)[uuid], 'fixture check: the host left the take')

      h.ds:assign('fxRegions', util.REMOVE)
      h.tm:rebuild()
      agrees(h, 'region removed', { 1 })
      local host = onlyHost(h, 1)
      t.eq(host.uuid, uuid, 'the same host')
      t.falsy(host.parked, 'back on the take')
    end,
  },

  {
    name = 'fx toggled on an on-take note joins and leaves the set',
    run = function(harness)
      local h = harness.mk()
      addNote(h); h.tm:flush()
      agrees(h, 'plain note')
      local uuid = firstNote(h, 1).uuid

      h.tm:assignEvent(seated(h, 1, uuid), { fx = sine30 }); h.tm:flush()
      agrees(h, 'fx on', { 1 })
      h.tm:assignEvent(seated(h, 1, uuid), { fx = util.REMOVE }); h.tm:flush()
      agrees(h, 'fx off')
      t.truthy(seated(h, 1, uuid), 'fixture check: the note itself stands')
    end,
  },

  {
    name = 'fx cleared on a parked host leaves the set and restores it',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { fx = arpUp }); h.tm:flush()
      local host = onlyHost(h, 1)
      t.truthy(host.parked, 'fixture check: parked')

      h.tm:assignParked(host, { fx = util.REMOVE }); h.tm:flush()
      agrees(h, 'parked host cleared')
      local note = seated(h, 1, host.uuid)
      t.truthy(note and not note.parked, 'the note is back on the take')
    end,
  },

  {
    name = 'a host deleted, or moved across lanes or channels, follows in the sets',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { fx = sine30 }); addNote(h, { ppq = 480, endppq = 720, fx = sine30 })
      h.tm:flush()
      agrees(h, 'two hosts', { 2 })
      local early, late
      for evt in pairs(hostsByScan(h, 1)) do if evt.ppq == 0 then early = evt else late = evt end end

      h.tm:deleteEvent(early); h.tm:flush()
      agrees(h, 'one deleted', { 1 })

      h.tm:assignEvent(seated(h, 1, late.uuid), { lane = 2 }); h.tm:flush()
      agrees(h, 'moved to lane 2', { 1 })
      t.eq(onlyHost(h, 1).lane, 2, 'fixture check: the host sits on lane 2')

      h.tm:assignEvent(onlyHost(h, 1), { chan = 2 }); h.tm:flush()
      agrees(h, 'moved to chan 2', { 0, 1 })
    end,
  },

  {
    name = 'a wholesale re-read seats the set afresh',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { fx = sine30 }); addNote(h, { ppq = 480, endppq = 720, fx = arpUp })
      h.tm:flush()
      agrees(h, 'before', { 2 })
      local before = hostsByScan(h, 1)

      -- An unchanged take converges without a re-read, so the take gains a cc first, as a REAPER
      -- edit would land it; a changed take re-reads every channel wholesale.
      h.reaper.MIDI_InsertCC(h.fm:take(), false, false, 960, 0xB0, 2, 7, 64)
      h.fm:reload()
      agrees(h, 'after the re-read', { 2 })
      for evt in pairs(hostsByScan(h, 1)) do
        t.falsy(before[evt], 'fixture check: the re-read seated fresh column events')
      end
    end,
  },

  {
    name = 'an edit on one channel carries another channel\'s set whole',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { fx = sine30 }); addNote(h, { chan = 2 }); h.tm:flush()
      local set = h.tm:getChannel(1).fxHosts
      t.truthy(set, 'fixture check: chan 1 keeps a host set')

      h.tm:assignEvent(firstNote(h, 2), { pitch = 62 }); h.tm:flush()
      t.eq(firstNote(h, 2).pitch, 62, 'fixture check: the edit landed on chan 2')
      agrees(h, 'after the chan 2 edit', { 1 })
      t.truthy(h.tm:getChannel(1).fxHosts == set, 'chan 1 carries its set as it stood')
    end,
  },

}
