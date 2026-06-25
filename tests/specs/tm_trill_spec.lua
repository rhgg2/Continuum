-- Note macros, v1: trill (structural, second kind). Trill alternates the host
-- pitch with a note `step` scale-steps away, resolved through the temper to
-- per-fxNote detune -- which the absorber pass realises once the 4.9 gather
-- unions derived lane-1 fxNotes. G4 runs microtonally (19EDO) under swing+delay:
-- the frame/rounding AND detune/absorber round-trip tripwire.

local t      = require('support')
local util   = require('util')
local tuning = require('tuning')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

-- whole-tone trill: two scale steps, 1/4-QN period.
local trill2 = { { kind = 'trill', period = { 1, 4 }, step = 2 } }

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

local function hostNote(dump)
  for _, n in ipairs(dump.notes) do if n.fx then return n end end
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
    name = 'G4: flush -> rebuild -> flush byte-identical (trill, 19EDO, swing + delay)',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 }, temper = '19EDO' },
        },
        data = { swing = { global = 'c58' } },
      }
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 500, lane = 1, fx = trill2 })
      h.tm:flush()

      -- Expansion + microtonal detune + absorbers must actually have happened --
      -- else "byte-identical" is satisfied vacuously.
      local host = hostNote(h.fm:dump())
      t.truthy(host, 'host carries fx')
      local fns = fxNotesOf(h.fm:dump(), host.uuid)
      t.eq(#fns, 3, 'trill over a 1-QN window at 1/4-QN period yields 3 fxNotes')
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
    name = 'trill alternates host pitch with the stepped note; host is fxNote 1',
    run = function(harness)
      local h = harness.mk()   -- 12EDO floor
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1, fx = trill2 })
      h.tm:flush()

      local dump = h.fm:dump()
      local host = hostNote(dump)
      t.eq(host.pitch, 60, 'host (fxNote 1) keeps its pitch')
      local fns = fxNotesOf(dump, host.uuid)
      t.deepEq({ fns[1].ppq, fns[2].ppq, fns[3].ppq }, { 60, 120, 180 }, 'fxNote onsets tile the window')
      t.deepEq({ fns[1].pitch, fns[2].pitch, fns[3].pitch }, { 62, 60, 62 },
        'odd tiles step +2 semitones; even tiles return to the host')
      for _, fn in ipairs(fns) do
        t.eq(fn.vel, 100, 'trill carries host velocity (no ramp)')
        t.eq(fn.detune or 0, 0, '12EDO: a +2-step trill has no detune')
      end
      t.eq(#pbsByPpq(dump), 0, '12EDO trill seats no absorbers')
    end,
  },

  ----- Absorber union -- the 4.9 gather sees derived lane-1 fxNotes (gating work item)

  {
    name = 'a microtonal trill seats absorbers at the alternation fxNote seats',
    run = function(harness)
      local h = harness.mk{ config = { project = { temper = '19EDO' } } }
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1, fx = trill2 })
      h.tm:flush()

      local temper = tuning.findTemper('19EDO')
      local _, altDetune = tuning.transposeStep(temper, 60, 0, 2)
      local R = cents2raw(altDetune)

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

}
