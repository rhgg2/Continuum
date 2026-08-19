-- Note macros, v1: trill (structural, second kind). Trill alternates the host
-- pitch with a note `cents` away from what it sounds, the remainder landing as
-- per-fxNote detune -- which the absorber pass realises once the 4.9 gather
-- unions derived lane-1 fxNotes. G4 runs microtonally under swing+delay:
-- the frame/rounding AND detune/absorber round-trip tripwire.

local t      = require('support')
local util   = require('util')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

-- whole-tone trill: 200 cents, 1/4-QN period.
local trill2 = { { kind = 'trill', period = { 1, 4 }, cents = 200 } }
-- microtonal trill: 130 cents, so the alternation lands a pitch up with 30 cents of detune.
local trillMicro = { { kind = 'trill', period = { 1, 4 }, cents = 130 } }

-- Matches tm's centsToRaw at the default pbRange (2 semitones = 200 cents).
local function cents2raw(c) return util.clamp(util.round(c * 8192 / 200), -8192, 8191) end

local function fxNotesOf(dump, hostUuid)
  local out = {}
  for _, n in ipairs(dump.notes) do
    if n.derived == hostUuid then out[#out + 1] = n end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

local function pbsByPpq(dump)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'pb' then out[#out + 1] = c end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

-- Stable, order-independent view of notes + pbs for byte-identical assertions.
local function fullView(dump)
  local notes = {}
  for _, n in ipairs(dump.notes) do notes[#notes + 1] = n end
  table.sort(notes, function(a, b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    if a.pitch ~= b.pitch then return a.pitch < b.pitch end
    return (a.uuid or '') < (b.uuid or '')
  end)
  return { notes = notes, pbs = pbsByPpq(dump) }
end

return {

  ----- G4 -- round-trip stability (FIRST: frame + detune/absorber rounding tripwire)

  {
    name = 'G4: flush -> rebuild -> flush byte-identical (trill, microtonal, swing + delay)',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
        },
        data = { swing = { global = 'c58' } },
      }
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 500, lane = 1, fx = trillMicro })
      h.tm:flush()

      -- Expansion + microtonal detune + absorbers must actually have happened --
      -- else "byte-identical" is satisfied vacuously.
      local host = h.tm:getChannel(1).parked[1]
      t.truthy(host, 'the host is parked off-take')
      local fns = fxNotesOf(h.fm:dump(), host.uuid)
      t.eq(#fns, 4, 'trill over a 1-QN window at 1/4-QN period yields 4 fxNotes (all hits derived)')
      local anyDetuned = false
      for _, fn in ipairs(fns) do if (fn.detune or 0) ~= 0 then anyDetuned = true end end
      t.truthy(anyDetuned, 'the alternation note carries a non-zero (microtonal) detune')
      t.truthy(#pbsByPpq(h.fm:dump()) > 0, 'absorbers seated for the alternation detune')

      local before = fullView(h.fm:dump())
      h.tm:rebuild()
      h.tm:flush()
      local after = fullView(h.fm:dump())
      t.deepEq(after, before, 'no churn across the round trip (notes + absorbers)')
    end,
  },

  ----- Structural realisation -- pitch alternation (12EDO: no detune, no absorbers)

  {
    name = 'trill alternates host pitch with the stepped note; the host parks, all hits derived',
    run = function(harness)
      local h = harness.mk()   -- 12EDO floor
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1, fx = trill2 })
      h.tm:flush()

      local dump = h.fm:dump()
      local host = h.tm:getChannel(1).parked[1]
      t.eq(host.pitch, 60, 'the parked host keeps its pitch')
      local fns = fxNotesOf(dump, host.uuid)
      t.deepEq({ fns[1].ppq, fns[2].ppq, fns[3].ppq, fns[4].ppq }, { 0, 60, 120, 180 },
        'fxNote onsets tile the window from its start')
      t.deepEq({ fns[1].pitch, fns[2].pitch, fns[3].pitch, fns[4].pitch }, { 60, 62, 60, 62 },
        'even tiles carry the host pitch; odd tiles stand 200 cents above it')
      for _, fn in ipairs(fns) do
        t.eq(fn.vel, 100, 'trill carries host velocity (no ramp)')
        t.eq(fn.detune or 0, 0, 'a whole-semitone demand needs no detune')
      end
      t.eq(#pbsByPpq(dump), 0, 'a trill with no detune seats no absorbers')
    end,
  },

  ----- Absorber union -- the 4.9 gather sees derived lane-1 fxNotes (gating work item)

  {
    name = 'a microtonal trill seats absorbers at the alternation fxNote seats',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1, fx = trillMicro })
      h.tm:flush()

      local R = cents2raw(30)   -- 130 cents places as pitch 61 carrying 30 cents

      -- Realised lane-1: host@0(d=0) alt@60(d=alt) host@120(d=0) alt@180(d=alt).
      -- Anchor at 0 (pb-active channel), then one absorber per detune transition.
      local pbs = pbsByPpq(h.fm:dump())
      t.eq(#pbs, 4, 'anchor + one absorber per detune jump across the 4 lane-1 onsets')
      t.deepEq({ pbs[1].ppq, pbs[2].ppq, pbs[3].ppq, pbs[4].ppq }, { 0, 60, 120, 180 },
        'absorbers seat at the host + fxNote onsets')
      t.deepEq({ pbs[1].val, pbs[2].val, pbs[3].val, pbs[4].val }, { 0, R, 0, R },
        'alternation seats carry the stepped detune; return seats re-centre')
      for _, pb in ipairs(pbs) do t.eq(pb.derived, 'absorber', 'every seat is a fake absorber') end
    end,
  },

  ----- The notation is not a derivation input -- a lens change renames, never re-sounds

  {
    name = 'a temper change leaves the trill it renames sounding as it was',
    run = function(harness)
      local h = harness.mk()   -- 12EDO floor
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1, fx = trill2 })
      h.tm:flush()

      local host = h.tm:getChannel(1).parked[1]
      local fns  = fxNotesOf(h.fm:dump(), host.uuid)
      t.deepEq({ fns[2].pitch, fns[2].detune or 0 }, { 62, 0 },
        'the alternation stands 200 cents above the host')

      -- Two steps of 19EDO is 126.3 cents, so a step-resolved trill would move here.
      local before = fullView(h.fm:dump())
      h.cm:set('project', 'temper', '19EDO')
      h.tm:flush()
      t.deepEq(fullView(h.fm:dump()), before, 'the notation moved and the derived notes did not')
    end,
  },

  ----- The intent rides the derivation onto the take

  {
    name = 'each derived note carries a written step of its own, the alternation a tone above',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 60, delay = 0, lane = 1, intentCents = 6000,
                      fx = trill2 })
      h.tm:flush()

      local host = h.tm:getChannel(1).parked[1]
      t.eq(host.intentCents, 6000, 'fixture check: the parked host keeps the step it was written on')
      local fns = fxNotesOf(h.fm:dump(), host.uuid)
      t.deepEq({ fns[1].intentCents, fns[2].intentCents, fns[3].intentCents, fns[4].intentCents },
        { 6000, 6200, 6000, 6200 },
        'the take holds one name per tile: the host\'s step, then the one 200 cents above it')
    end,
  },

  {
    name = 'renaming the host with no change to its pitch renames the notes it derives',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 60, delay = 0, lane = 1, intentCents = 6000,
                      fx = trill2 })
      h.tm:flush()

      local sounded = {}
      for i, n in ipairs(fxNotesOf(h.fm:dump(), h.tm:getChannel(1).parked[1].uuid)) do
        sounded[i] = { n.pitch, n.detune }
      end

      -- Only the intent moves, so the take sounds exactly as it did and nothing but the
      -- name can tell the reconcile that the notes standing there are stale.
      h.tm:assignParked(h.tm:getChannel(1).parked[1], { intentCents = 6100 })
      h.tm:flush()

      local fns = fxNotesOf(h.fm:dump(), h.tm:getChannel(1).parked[1].uuid)
      t.deepEq({ fns[1].intentCents, fns[2].intentCents, fns[3].intentCents, fns[4].intentCents },
        { 6100, 6300, 6100, 6300 },
        'the derived notes follow the host onto the step it now names')
      for i, n in ipairs(fns) do
        t.deepEq({ n.pitch, n.detune }, sounded[i], 'tile ' .. i .. ' goes on sounding where it did')
      end
    end,
  },

}
