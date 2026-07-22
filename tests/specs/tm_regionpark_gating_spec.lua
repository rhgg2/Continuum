-- Phase A of the dirt spine (design/archive/dirty-channels.md § Scheme): regionPark's new-park scan is
-- gated per dirty channel. A clean channel contributes no on-take candidates -- any coverage
-- transition (note moved into a window, region edited) dirties its channel first -- so skipping
-- the scan is behaviour-preserving. Its reconcile still *partitions* the prior fxParked set, so a
-- clean channel's parked spec carries through by construction (no fxCarrier-style from-scratch
-- seed). This pins that carry-through: a chan-1 edit must not drop chan 2's parked note from
-- either the persisted set or the grid render cells.

local t = require('support')

local arpUp = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }   -- replace-mode: parks the host

local function hostNote(chan)
  return { evType = 'note', ppq = 0, endppq = 240, chan = chan, pitch = 60,
           vel = 100, detune = 0, delay = 0, lane = 1 }
end

local function plainNote(chan, ppq)
  return { evType = 'note', ppq = ppq, endppq = ppq + 240, chan = chan, pitch = 62,
           vel = 100, detune = 0, delay = 0, lane = 1 }
end

local function parkedOn(list, chan)
  local out = {}
  for _, spec in ipairs(list or {}) do
    if spec.chan == chan then out[#out + 1] = spec end
  end
  return out
end

return {
  {
    -- Mechanism-independent pin for the span-covered scan: a self-parking note host carries no window
    -- (parkWindows suppresses the note arm for note-hosts), so a correct cover must find it from the
    -- fx-host set, never by walking the column. A far plain note shares the channel to make a
    -- whole-column scan and a host-set lookup observably different in reach.
    name = 'a self-parking note host parks off-take via the fx-host set, not a column scan',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                     vel = 100, detune = 0, delay = 0, lane = 1, fx = arpUp }
      h.tm:addEvent(plainNote(1, 4800))   -- far from the host window
      h.tm:flush()

      local hosts = 0
      for _, s in ipairs(parkedOn(h.ds:get('fxParked'), 1)) do
        if s.evType == 'note' and s.fx then hosts = hosts + 1 end
      end
      t.eq(hosts, 1, 'the arp note-host parked itself off-take')
      t.truthy(#h.tm:getChannel(1).parked > 0, 'and left a parked render cell for the grid')
    end,
  },
  {
    name = 'a chan-1 edit freezes chan 2 regionPark and keeps its parked spec + render cell',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(hostNote(1)); h.tm:flush()
      h.tm:addEvent(hostNote(2)); h.tm:flush()

      -- Arp region over each host: replace-mode parks the covered note off-take on both channels.
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = arpUp },
        { uuid = 'fxr-2', chan = 2, startppq = 0, endppq = 240, fx = arpUp },
      })
      h.tm:rebuild()

      local before2 = parkedOn(h.ds:get('fxParked'), 2)
      t.truthy(#before2 > 0, 'chan 2 host note parked off-take by its arp region')
      t.truthy(#h.tm:getChannel(2).parked > 0, 'chan 2 has a parked render cell for the grid')

      -- Chan-1 edit outside every region window: dirties chan 1 only, so chan 2 is derivation-clean
      -- and its park scan is gated. The prior-set partition must still carry chan 2 through.
      h.tm:addEvent(plainNote(1, 480)); h.tm:flush()
      t.deepEq(parkedOn(h.ds:get('fxParked'), 2), before2,
        'chan 2 parked spec carried untouched through the chan-1 edit')
      t.truthy(#h.tm:getChannel(2).parked > 0,
        'chan 2 parked render cell survives -- not erased by the gated reconcile')

      -- Second chan-1 edit: had chan 2 been dropped, its off-take note would be gone from both the
      -- persisted set and the grid. The carry-through keeps it whole.
      h.tm:addEvent(plainNote(1, 720)); h.tm:flush()
      t.truthy(#h.tm:getChannel(2).parked > 0,
        'chan 2 parked render cell still present after two chan-1 edits')
      t.deepEq(parkedOn(h.ds:get('fxParked'), 2), before2,
        'chan 2 parked spec still byte-identical -- its reconcile never re-ran')
    end,
  },
  {
    -- The render clip realiseParked derives (parked.endppqC) rides a per-uuid cache, dirt-gated
    -- exactly as the fx-window cache is. This pins the gate across the three transitions that must
    -- move the clip -- initial park, an in-span neighbour add, its removal -- and confirms an edit
    -- outside the cached span leaves the clip untouched. A missed reseed here strands a stale clip.
    name = 'a parked member render clip reseeks only when dirt reaches its span',
    run = function(harness)
      local h = harness.mk()
      -- A host with a long authored tail, parked by a region covering only its onset (arpUp spans
      -- [0,240)), so successors on its lane -- not its own ceiling -- set the render clip.
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 1920, chan = 1, pitch = 60,
                     vel = 100, detune = 0, delay = 0, lane = 1 }
      h.tm:addEvent{ evType = 'note', ppq = 960, endppq = 1200, chan = 1, pitch = 62,
                     vel = 100, detune = 0, delay = 0, lane = 1 }   -- on-take, the initial bound
      h.tm:flush()
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = arpUp } })
      h.tm:rebuild()

      local function member()
        for _, m in ipairs(h.tm:getChannel(1).parked) do
          if m.pitch == 60 and m.ppq == 0 then return m end
        end
      end
      t.truthy(member(), 'the host parked off-take under the region')
      t.eq(member().endppqC, 960, 'render clip bounds to the on-take note at 960')

      -- An edit far past the cached span [0,960] dirties chan 1 but not this member: clip rides.
      h.tm:addEvent{ evType = 'note', ppq = 2000, endppq = 2200, chan = 1, pitch = 72,
                     vel = 100, detune = 0, delay = 0, lane = 2 }
      h.tm:flush()
      t.eq(member().endppqC, 960, 'clip unchanged by an edit outside its cached span')

      -- A note added between the member and its bound falls inside the cached span: the gate fires
      -- and the clip shrinks to the new onset.
      h.tm:addEvent{ evType = 'note', ppq = 480, endppq = 600, chan = 1, pitch = 64,
                     vel = 100, detune = 0, delay = 0, lane = 1 }
      h.tm:flush()
      t.eq(member().endppqC, 480, 'seed-in-span reseek: clip shrinks to the new onset at 480')

      -- Removing it seeds its onset (== the cached clip): the gate fires and the clip regrows.
      local neighbour
      for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if e.ppq == 480 and e.pitch == 64 then neighbour = e end
      end
      t.truthy(neighbour, 'the neighbour note is on the take')
      h.tm:deleteEvent(neighbour); h.tm:flush()
      t.eq(member().endppqC, 960, 'reseek on removal: clip regrows to the next surviving onset')
    end,
  },
}
