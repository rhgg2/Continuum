-- Phase A of the dirt spine (design/archive/dirty-channels.md § Scheme): a clean fx channel freezes and its
-- derived notes/CCs/pb seats stand in mm; here a channel frozen by another channel's edit keeps its pb seat stream byte-identical and hidden.

local t          = require('support')
local generators = require('generators')

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
  for _, cell in ipairs(h.tm:getChannel(chan).parked.notes or {}) do
    if cell.fx then return cell.uuid end
  end
end

-- A note-emitting chain, so the realisation entry carries derived notes rather than only seats.
local function trillHost(chan)
  return { evType = 'note', ppq = 0, endppq = 240, chan = chan, pitch = 60,
           vel = 100, detune = 0, delay = 0, lane = 1,
           fx = { { kind = 'trill', period = { 1, 4 }, cents = 200 } } }
end

-- The take's derived notes filed by producing host, onset-ordered: what um's per-host file is
-- asked for, read back off mm so the assertion is over what landed rather than over the file.
local function derivedOf(h, hostUuid)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do
    if n.derived == hostUuid then out[#out + 1] = n end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

-- Every derived onset on the take, for a fixture carrying exactly one host.
local function derivedOnsets(h)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do
    if n.derived then out[#out + 1] = n.ppq end
  end
  table.sort(out)
  return out
end

local function parkedCells(h, chan)
  local out = {}
  for _, cell in ipairs(h.tm:getChannel(chan).parked.notes or {}) do
    if cell.fx then out[#out + 1] = cell end
  end
  return out
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

----- The pb hold point's reach: which seeded host widens it, and so which pb host downstream re-runs

local retrigChain = { { kind = 'retrig', period = { 1, 4 } } }
local function laneNote(ppq, endppq, pitch, lane, fx)
  return { evType = 'note', ppq = ppq, endppq = endppq, chan = 1, pitch = pitch,
           vel = 100, detune = 0, delay = 0, lane = lane, fx = fx }
 end

-- Seeds the emitter under test at [480,720), then counts a downstream pb host's expansions over one
-- added note inside that window: a run means the hold point reached back past 480 and woke it, a
-- count of zero that the gate kept its output. Returns the dirt-flush count and the seeding one,
-- the latter the guard that the counter host runs at all.
-- The dirt is pitched and on lane 4, so it moves neither baseHoldFrom nor detuneHoldFrom: the
-- emitter's own base-voice-ness is the only thing left that can widen pbHoldFrom.
local function runsOverDirt(h, seedEmitter)
  local runs = 0
  generators.kinds.counter = {
    expand = function() runs = runs + 1; return { notes = {}, delta = {} } end,
    mode = 'augment', dest = 'pb', label = 'Counter', defaults = {}, fields = {},
  }
  h.tm:addEvent(laneNote(960, 1200, 72, 1, { { kind = 'counter' } })); h.tm:flush()
  seedEmitter(h)
  local seedRuns = runs
  runs = 0
  h.tm:addEvent(laneNote(600, 660, 67, 4)); h.tm:flush()
  generators.kinds.counter = nil
  return runs, seedRuns
end

-- A retrig region over notes on the given lanes. It parks them, and carries no lane of its own.
local function retrigRegion(lanes)
  return function(h)
    for i, lane in ipairs(lanes) do h.tm:addEvent(laneNote(480, 720, 60 + i, lane)) end
    h.tm:flush()
    h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, ppq = 480, endppq = 720, fx = retrigChain } })
    h.tm:rebuild()
  end
end
local function retrigNoteHost(lane)
  return function(h) h.tm:addEvent(laneNote(480, 720, 60, lane, retrigChain)); h.tm:flush() end
end

-- A note carrying fx is its own host, and an augment chain leaves it on the take.
local function hostUuid(h, chan)
  for _, e in ipairs(h.tm:getChannel(chan).onTake.notes[1].events) do
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

  -- The two readers of the base voice must name the same note. The absorber pass writes its seats
  -- through the union's detuneAt and fxCurveAt samples them back through index.detuneAt, so a
  -- divergence between the two predicates is the whole observable here -- and this fixture is where
  -- they can diverge: lane and the baseVoice stamp classify the second derived note differently.
  {
    name = 'fxCurveAt: the union that writes the seats and index.detuneAt agree which derived note is the base voice',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.twoVoice = {
        expand = function(stream)
          local from = stream.window[1]
          return { notes = {
            { ppq = from,       endppq = from + 120, pitch = 60, vel = 100, detune = 50, baseVoice = true },
            { ppq = from + 120, endppq = from + 240, pitch = 64, vel = 100, detune = -30 },
          }, delta = {} }
        end,
        mode = 'replace', dest = 'note', label = 'TwoVoice', defaults = {}, fields = {},
      }
      -- A memberless region, and derived notes take no lane at all: only the stamp separates the
      -- two voices.
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240,
                                   fx = { { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 },
                                          { kind = 'twoVoice' } } } })
      h.tm:rebuild()
      generators.kinds.twoVoice = nil

      local voices = {}
      for _, n in ipairs(h.fm:dump().notes) do
        if n.derived == 'fxr-1' then voices[#voices + 1] = n end
      end
      table.sort(voices, function(a, b) return a.ppq < b.ppq end)
      t.eq(#voices, 2, 'fixture check: both voices reached the take')
      t.truthy(voices[1].baseVoice, 'fixture check: the base voice carries the stamp')
      t.falsy(voices[2].baseVoice, 'fixture check: distinguished from it by the stamp alone')

      -- Past the second voice's onset, seats written against 50 and sampled back against -30 land
      -- 80 cents out -- the sine\'s own shape is the only thing that survives agreement.
      local vals = curveAt(h, 'fxr-1', 1, 'pb', { 135, 150, 165 })
      t.truthy(math.abs(vals[1] - 30) <= 1, 'crest a quarter cycle past the second voice\'s onset')
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
      for _, e in ipairs(h.tm:getChannel(1).onTake.notes[1].events) do
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

      t.falsy(h.tm:getChannel(2).onTake.pb, 'chan 2 seats stay hidden -- no pb column surfaces')
      t.deepEq(pbSeatsOf(h.fm:dump(), 2), before,
        'frozen chan 2 pb seat stream is byte-identical -- its generators never re-ran')
    end,
  },

  {
    name = 'hold reach: a region parking a lane-1 note widens the pb hold point, waking the host downstream',
    run = function(harness)
      local runs, seedRuns = runsOverDirt(harness.mk(), retrigRegion({ 1, 3 }))
      t.truthy(seedRuns > 0, 'fixture check: the counter host runs when it is not kept')
      t.eq(runs, 1, 'the region emits the base voice, so the hold point reaches back to its start')
    end,
  },

  {
    name = 'hold reach: a region covering no lane-1 note emits no base voice, and the pb host downstream stays kept',
    run = function(harness)
      local runs, seedRuns = runsOverDirt(harness.mk(), retrigRegion({ 2, 3 }))
      t.truthy(seedRuns > 0, 'fixture check: the counter host runs when it is not kept')
      t.eq(runs, 0, 'nothing in its membership holds the voice the stamp is inherited from')
    end,
  },

  {
    name = 'hold reach: a lane-1 note host widens it, its own note being the membership',
    run = function(harness)
      local runs, seedRuns = runsOverDirt(harness.mk(), retrigNoteHost(1))
      t.truthy(seedRuns > 0, 'fixture check: the counter host runs when it is not kept')
      t.eq(runs, 1, 'the host note is the base voice, so what stands in for it re-detunes the stream')
    end,
  },

  {
    name = 'hold reach: a lane-2 note host does not, and the pb host downstream stays kept',
    run = function(harness)
      local runs, seedRuns = runsOverDirt(harness.mk(), retrigNoteHost(2))
      t.truthy(seedRuns > 0, 'fixture check: the counter host runs when it is not kept')
      t.eq(runs, 0, 'off lane 1 there is no base voice to re-seat from')
    end,
  },

  -- um files a channel's derived notes under the uuid of the host that produced them, and fx
  -- expansion asks per host that ran. The three cases below are what that addressing buys and
  -- what it costs: orphans still fall in, a move re-seats, and a kept neighbour is not swept.

  {
    name = 'the file: a deleted host takes its derived notes off the take with it',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(plainNote(1, 480)); h.tm:flush()   -- seed dirt, so the pass is gated
      h.tm:addEvent(trillHost(1)); h.tm:flush()
      local host = parkedHostUuid(h, 1)
      t.truthy(#derivedOf(h, host) >= 2, 'fixture check: the trill emitted derived notes')

      h.tm:deleteParked(parkedCells(h, 1)[1]); h.tm:flush()

      -- No host of the pass claims the file, so it is an orphan and falls in whole.
      t.eq(#derivedOf(h, host), 0, 'no note on the take still names the deleted host')
    end,
  },

  {
    -- A region, not a note host: moving a parked note host through the view is a relocate, which
    -- mints a fresh uuid, so a region is the host form whose identity survives a move.
    name = 'the file: a moved host re-seats its derived notes rather than doubling them',
    run = function(harness)
      local row = 240
      local h = harness.mk()
      for _, at in ipairs({ 0, row }) do   -- a chord under each of the two positions
        h.tm:addEvent({ evType = 'note', ppq = at, endppq = at + 240, chan = 1, pitch = 60,
                        vel = 100, detune = 0, delay = 0, lane = 1 })
        h.tm:addEvent({ evType = 'note', ppq = at, endppq = at + 240, chan = 1, pitch = 64,
                        vel = 100, detune = 0, delay = 0, lane = 2 })
      end
      h.tm:flush()
      local function region(at)
        return { uuid = 'fxr-1', chan = 1, ppq = at, endppq = at + 240,
                 fx = { { kind = 'arp', period = { 1, 8 }, pattern = 'up' } } }
      end

      h.ds:assign('fxRegions', { region(0) }); h.tm:rebuild()
      local before = derivedOnsets(h)
      t.truthy(#before >= 2, 'fixture check: the arp emitted derived notes')

      -- The file is keyed by the host's uuid, which the move does not touch. Its prior notes sit
      -- outside every window and every seed of this pass, and are still found and re-seated.
      h.ds:assign('fxRegions', { region(row) }); h.tm:rebuild()

      local after = derivedOnsets(h)
      t.eq(#after, #before, 'the same count: re-seated, not a second set beside the first')
      for i, ppq in ipairs(after) do
        t.eq(ppq, before[i] + row, 'derived onset ' .. i .. ' moved with its host')
      end
    end,
  },

  {
    name = 'the file: a kept host is not swept by a running neighbour overlapping it',
    run = function(harness)
      local h = harness.mk()
      -- Spans overlap in [120, 240): a gather addressing the existing set by dirty window rather
      -- than by producer would take the kept host's notes out of that overlap.
      h.tm:addEvent(trillHost(1)); h.tm:flush()
      h.tm:addEvent({ evType = 'note', ppq = 120, endppq = 360, chan = 1, pitch = 67,
                      vel = 100, detune = 0, delay = 0, lane = 2,
                      fx = { { kind = 'trill', period = { 1, 4 }, cents = 200 } } })
      h.tm:flush()

      local cells = parkedCells(h, 1)
      t.eq(#cells, 2, 'fixture check: both hosts parked themselves')
      local kept, neighbour = cells[1].uuid, cells[2].uuid
      local before = derivedOf(h, kept)
      t.truthy(#before >= 2, 'fixture check: the kept host emitted derived notes')
      t.truthy(#derivedOf(h, neighbour) >= 2, 'fixture check: so did its neighbour')

      -- ppq 300 sits inside the neighbour's span and outside the kept host's, so the seed wakes
      -- one host and not the other.
      h.tm:addEvent(plainNote(1, 300)); h.tm:flush()

      t.deepEq(derivedOf(h, kept), before, 'the kept host\'s notes came through untouched')
      t.truthy(#derivedOf(h, neighbour) >= 2, 'and the neighbour still has its own')
    end,
  },

  {
    -- The case above has its two hosts overlap in time but not in pitch, so nothing of the pass's
    -- ever has to give way to the kept host's notes. Here they overlap in pitch too. A kept host
    -- re-emits nothing, so the running host's fresh output has only um's standing records to clip
    -- against -- and this clip is the tail walk's alone, a fresh spec reaching mm through the pass's
    -- own batch rather than past flush's collision scan. see design § Keep by omission
    name = 'the file: a running host\'s fresh output clips against a kept host\'s notes at its pitch',
    run = function(harness)
      local h = harness.mk()
      -- The running host emits one long note at the trill's alternation pitch, reaching well past the
      -- trill's window, so what stops it is whatever the walk finds at pitch 62 -- and only the kept
      -- host holds anything there.
      generators.kinds.oneLong = {
        expand = function(stream)
          return { notes = { { ppq = stream.window[1], endppq = stream.window[2],
                               pitch = 62, vel = 100, detune = 0 } }, delta = {} }
        end,
        mode = 'replace', dest = 'note', label = 'OneLong', defaults = {}, fields = {},
      }
      h.tm:addEvent(trillHost(1)); h.tm:flush()            -- pitch 60/62 alternating over [0, 240)
      h.tm:addEvent({ evType = 'note', ppq = 120, endppq = 360, chan = 1, pitch = 67,
                      vel = 100, detune = 0, delay = 0, lane = 2, fx = { { kind = 'oneLong' } } })
      h.tm:flush()

      local kept, neighbour
      for _, cell in ipairs(parkedCells(h, 1)) do
        if cell.pitch == 60 then kept = cell.uuid else neighbour = cell.uuid end
      end
      t.truthy(kept and neighbour, 'fixture check: both hosts parked themselves')
      local stops = 0
      for _, n in ipairs(derivedOf(h, kept)) do
        if n.pitch == 62 then stops = stops + 1 end
      end
      t.truthy(stops >= 2, 'fixture check: the kept host holds notes at the neighbour\'s pitch')

      -- ppq 300 sits inside the neighbour's span and outside the kept host's, so the seed wakes one
      -- host and not the other. The neighbour re-emits its long note; the kept host emits nothing.
      h.tm:addEvent({ evType = 'note', ppq = 300, endppq = 360, chan = 1, pitch = 72,
                      vel = 100, detune = 0, delay = 0, lane = 3 })
      h.tm:flush()
      generators.kinds.oneLong = nil

      t.eq(#derivedOf(h, neighbour), 1, 'fixture check: the neighbour still emits its one long note')
      local onChan = {}
      for _, n in ipairs(h.fm:dump().notes) do
        if n.chan == 1 then onChan[#onChan + 1] = n end
      end
      table.sort(onChan, function(a, b)
        if a.pitch ~= b.pitch then return a.pitch < b.pitch end
        return a.ppq < b.ppq
      end)
      -- In this order consecutive entries sharing a pitch are exactly "the next note at its pitch".
      local neighbours = 0
      for i = 2, #onChan do
        local prev, n = onChan[i - 1], onChan[i]
        if prev.pitch == n.pitch then
          neighbours = neighbours + 1
          t.truthy(prev.ppq < n.ppq,
            'pitch ' .. n.pitch .. ': the onset at ' .. n.ppq .. ' stands clear of the one before it')
          t.truthy(prev.endppq <= n.ppq,
            'pitch ' .. n.pitch .. ': the note at ' .. prev.ppq .. ' clips to the next onset at its pitch')
        end
      end
      t.truthy(neighbours >= 3, 'fixture check: the two hosts\' output interleaves at the pitch they share')
    end,
  },
}
