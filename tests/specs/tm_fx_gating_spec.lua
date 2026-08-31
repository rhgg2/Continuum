-- Phase A of the dirt spine (design/archive/dirty-channels.md § Scheme): a clean fx channel freezes and its
-- derived notes/CCs/pb seats stand in mm; here a channel frozen by another channel's edit keeps its pb seat stream byte-identical and hidden.

local t    = require('support')

local sine30 = { { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } }

local function pbSeatsOf(dump, chan)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'pb' and c.chan == chan then
      out[#out + 1] = { ppq = c.ppq, val = c.val, shape = c.shape }
    end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

-- A trill parks its host and stands its own notes in the lane, so the host's uuid comes off
-- the parked cell.
local function parkedHostUuid(h, chan)
  for _, cell in ipairs(h.tm:getChannel(chan).parked or {}) do
    if cell.fx then return cell.uuid end
  end
end

-- A note-emitting chain, so the realisation entry carries derived notes rather than only seats.
local function trillHost(chan)
  return { evType = 'note', ppq = 0, endppq = 240, chan = chan, pitch = 60,
           vel = 100, detune = 0, delay = 0, lane = 1,
           fx = { { kind = 'trill', period = { 1, 4 }, cents = 200 } } }
end

local function vibHost(chan)
  return { evType = 'note', ppq = 0, endppq = 240, chan = chan, pitch = 60,
           vel = 100, detune = 0, delay = 0, lane = 1, fx = sine30 }
end

local function plainNote(chan, ppq)
  return { evType = 'note', ppq = ppq, endppq = ppq + 240, chan = chan, pitch = 62,
           vel = 100, detune = 0, delay = 0, lane = 1 }
end

-- The chain's realised curve sampled at each of a row's ppqs, as the ghost display reads it.
local function curveAt(h, uuid, chan, target, ppqs)
  local out = {}
  for _, ppq in ipairs(ppqs) do out[#out + 1] = h.tm:fxCurveAt(uuid, chan, target, ppq) end
  return out
end

-- A note carrying fx is its own host, and an augment chain leaves it on the take.
local function hostUuid(h, chan)
  for _, e in ipairs(h.tm:getChannel(chan).columns.notes[1].events) do
    if e.fx then return e.uuid end
  end
end

return {
  {
    name = 'fxCurveAt: a chain\'s pb curve samples back in the column\'s units, inside its window only',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(vibHost(1)); h.tm:flush()   -- sine, 30 cents, 1/4 QN period, over [0,240)
      local host = hostUuid(h, 1)

      -- One cycle per 60 ppq: rest at the edges, extrema a quarter-cycle in.
      local vals = curveAt(h, host, 1, 'pb', { 0, 15, 30, 45 })
      t.eq(vals[1], 0, 'the sine rests where its window opens')
      -- Cents, as the pb column projects them; the same excursion in raw would be ~1200.
      t.truthy(math.abs(vals[2] - 30) <= 1,  'a quarter cycle in, the full 30-cent depth')
      t.truthy(math.abs(vals[3]) <= 1,       'back through the rest at the half cycle')
      t.truthy(math.abs(vals[4] + 30) <= 1,  'and the trough at three quarters')

      t.eq(h.tm:fxCurveAt(host, 1, 'pb', 300), nil, 'past the host\'s window there is no curve')
      t.eq(h.tm:fxCurveAt(host, 1, 10, 0),     nil, 'nor on a target this chain never claimed')
      t.eq(h.tm:fxRealisation('no-such-host'), nil, 'and a uuid that runs no chain has nothing to sample')
    end,
  },

  -- Pins index.detuneAt's lane walk where it is observable: the absorber pass re-derives flush's wire
  -- values itself, so only this sample-time subtraction answers for the seek's lane filter.
  {
    name = 'fxCurveAt: pb projects back through the prevailing lane-1 detune, not a nearer lane-2 note',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 50, delay = 0, lane = 1, fx = sine30 })
      -- The interloper: nearer the sample points than the host, wrong lane, different detune. A
      -- index.detuneAt landing at-or-before without walking back to lane 1 answers -30 for 50, and every
      -- sample past its onset comes back 80 cents sharp.
      h.tm:addEvent({ evType = 'note', ppq = 120, endppq = 240, chan = 1, pitch = 64,
                      vel = 100, detune = -30, delay = 0, lane = 2 })
      h.tm:flush()
      local host = hostUuid(h, 1)

      local vals = curveAt(h, host, 1, 'pb', { 135, 150, 165 })
      t.truthy(math.abs(vals[1] - 30) <= 1, 'crest a quarter cycle past the lane-2 onset')
      t.truthy(math.abs(vals[2]) <= 1,      'rest at the half cycle')
      t.truthy(math.abs(vals[3] + 30) <= 1, 'trough at three quarters')
    end,
  },

  {
    name = 'fxCurveAt: a kept host\'s curve stands, because it reads the take not the emission',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(vibHost(1)); h.tm:flush()
      h.tm:addEvent(plainNote(1, 1920)); h.tm:flush()
      local host = hostUuid(h, 1)
      local rows = { 0, 15, 30, 45, 60, 120, 180 }
      local before = curveAt(h, host, 1, 'pb', rows)
      t.truthy(before[2] ~= nil, 'fixture check: the curve is up')

      -- The far note is the dirt; the host at [0,240) is out of every emit scope, so it is
      -- kept rather than re-run and emits no record this rebuild.
      local far
      for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if e.ppq == 1920 then far = e end
      end
      h.tm:assignEvent(far, { pitch = 65 }); h.tm:flush()

      t.deepEq(curveAt(h, host, 1, 'pb', rows), before, 'the kept host\'s seats are still on the take')
    end,
  },

  {
    name = 'gating: a frozen chan 2 keeps its derived notes in the realisation entry',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(trillHost(2)); h.tm:flush()
      local host = parkedHostUuid(h, 2)

      local before = {}
      for _, note in ipairs(h.tm:fxRealisation(host).notes) do
        before[#before + 1] = { ppq = note.ppq, pitch = note.pitch }
      end
      t.truthy(#before >= 2, 'fixture check: the trill emits derived notes on chan 2')

      -- Chan 2 is derivation-clean through both edits, so its fx pass never runs and emits no
      -- record; the notes it keyed by host last time are what the entry gathers.
      h.tm:addEvent(plainNote(1, 480)); h.tm:flush()
      h.tm:addEvent(plainNote(1, 720)); h.tm:flush()

      local after = {}
      for _, note in ipairs(h.tm:fxRealisation(host).notes) do
        after[#after + 1] = { ppq = note.ppq, pitch = note.pitch }
      end
      t.deepEq(after, before, 'the frozen chain still realises the notes it emitted')
    end,
  },

  {
    name = 'gating: a chan-1 edit freezes chan 2 fx and keeps its pb seat stream',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(vibHost(1)); h.tm:flush()
      h.tm:addEvent(vibHost(2)); h.tm:flush()

      local before = pbSeatsOf(h.fm:dump(), 2)
      t.truthy(#before >= 8, 'chan 2 seats a sine pb stream')

      -- Two chan-1 edits: chan 2 is derivation-clean and freezes both times. Its seats stand in mm,
      -- carried whole -- the generators never re-run.
      h.tm:addEvent(plainNote(1, 480)); h.tm:flush()
      h.tm:addEvent(plainNote(1, 720)); h.tm:flush()

      t.falsy(h.tm:getChannel(2).columns.pb, 'chan 2 seats stay hidden -- no pb column surfaces')
      t.deepEq(pbSeatsOf(h.fm:dump(), 2), before,
        'frozen chan 2 pb seat stream is byte-identical -- its generators never re-ran')
    end,
  },
}
