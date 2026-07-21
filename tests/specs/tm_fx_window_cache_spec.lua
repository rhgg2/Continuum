-- Fx note-host window cache: a host's window (authored/take ceiling clipped to its strict-next
-- same-lane onset) is cached per uuid across rebuilds and recomputed only when the host's own uuid
-- seeds the dirt, a neighbour onset seeds a ppq inside its span, or the take length changes (which
-- arrives as a wholesale reload, so the column walk reclips every window). A depth-30 vibrato host
-- seats a pb stream across exactly its window, so the max pb-seat ppq tracks the window end -- the
-- observable these cases lean on. see design/interval-dirt-v2.md § 2

local t    = require('support')
local util = require('util')

local VIB = { { kind = 'vibrato', period = { 1, 4 }, depth = 30, onset = 0 } }

-- Author an OPEN-ended vibrato note-host on ch1 lane1; its pb seats fill [0, windowEnd).
local function addVibHost(h)
  h.tm:addEvent({ evType = 'note', ppq = 0, endppq = util.OPEN, chan = 1, pitch = 60, vel = 100,
                  detune = 0, delay = 0, lane = 1, fx = VIB })
  h.tm:flush()
end

local function addNote(h, chan, lane, ppq)
  h.tm:addEvent({ evType = 'note', ppq = ppq, endppq = ppq + 60, chan = chan, pitch = 64, vel = 100,
                  detune = 0, delay = 0, lane = lane })
  h.tm:flush()
end

-- The last pb seat ppq on a channel -- the far edge of the seated vibrato stream, i.e. the window end.
local function maxPbPpq(h, chan)
  local hi
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == chan and (hi == nil or c.ppq > hi) then hi = c.ppq end
  end
  return hi
end

return {

  {
    -- A plain note dropped after the host on its own lane becomes the strict-next onset: its seed
    -- lands inside the host's cached span, so the per-host path reseeks and the window clips to it.
    name = 'neighbour onset inside a host window reseeks and clips it on the next rebuild',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      t.truthy(maxPbPpq(h, 1) > 480, 'precondition: the OPEN host seats pb across the whole take')

      addNote(h, 1, 1, 480)
      t.eq(maxPbPpq(h, 1), 480,
        'the window clipped to the new lane-1 successor -- the seat stream ends at its onset')
    end,
  },

  {
    -- An edit on another channel never seeds ch1, so its clean host takes the pure reuse branch and
    -- returns byte-identical seats -- the cached window must not drift when nothing touches it.
    name = 'an edit on another channel leaves a clean host window untouched (reuse path)',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      local before = maxPbPpq(h, 1)

      addNote(h, 2, 1, 240)
      t.eq(maxPbPpq(h, 1), before, 'ch1 host window is reused verbatim across a ch2-only rebuild')
    end,
  },

  {
    -- Growing the take reclips every OPEN window. The grow routes through mm:setLength, which fires a
    -- wholesale reload -- so the column walk recomputes ch1's window at the new take length even though
    -- the grow seeds no dirt. A later unrelated ch2 edit then reuses that freshly-grown cache, not a stale one.
    name = 'growing the take extends a clean OPEN host window (the grow reloads wholesale)',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      local before = maxPbPpq(h, 1)

      h.tm:setLength(4800)     -- grow past the default 3840; the reload reclips the OPEN window
      addNote(h, 2, 1, 240)    -- an unrelated ch2 edit rebuilds; ch1 reuses the grown window, not a stale one
      t.truthy(maxPbPpq(h, 1) > before,
        'the OPEN host window followed the grown take -- the wholesale reload reclipped it')
    end,
  },

}
