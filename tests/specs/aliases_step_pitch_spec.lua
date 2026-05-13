-- Pitch/octave alias xform ops are tuning-step deltas resolved at emit
-- via tuning.transposeStep against the root's (pitch, detune). detune
-- is not in the alias vocabulary. Lane-1 alias children whose detune
-- differs from the prior carry have a fake-pb absorber seated at
-- their onset, same as user-authored notes.

local t = require('support')
local tuning = require('tuning')

local function cents2raw(c) return math.floor(c * 8192 / 200 + 0.5) end

local function aliasKid(dump, uuid)
  for _, n in ipairs(dump.notes) do
    if n.parentUuid == uuid then return n end
  end
end

local function pbAt(dump, ppq)
  for _, c in ipairs(dump.ccs) do
    if c.msgType == 'pb' and c.ppq == ppq then return c end
  end
end

local function rootNote(extras)
  local n = { uuid = 1, ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, lane = 1 }
  for k, v in pairs(extras or {}) do n[k] = v end
  return n
end

local TEMPER_19 = tuning.presets['19EDO']

local function temperedHarness(harness, root)
  return harness.mk{
    config = {
      track   = { rowPerBeat = 1, temper = '19EDO' },
      project = { tempers = { ['19EDO'] = TEMPER_19 } },
    },
    seed = { notes = { root } },
  }
end

return {
  --------------------------------------------------------------------
  -- pitch +1 step in 19EDO transposes via transposeStep
  --------------------------------------------------------------------
  {
    name = 'pitch +1 step in 19EDO maps to (pitch, detune) via transposeStep',
    run = function(harness)
      local h = temperedHarness(harness, rootNote{
        aliasCtr = 2,
        aliases  = {
          { id = '1', xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} },
            children = {} },
        },
      })
      local kid = aliasKid(h.fm:dump(), 1)
      local expP, expD = tuning.transposeStep(TEMPER_19, 60, 0, 1)
      t.eq(kid.pitch,  expP, 'midi pitch matches transposeStep')
      t.eq(kid.detune, expD, 'detune matches transposeStep')
    end,
  },

  --------------------------------------------------------------------
  -- octave +1 shifts by temper.octaveStep steps
  --------------------------------------------------------------------
  {
    name = 'octave +1 shifts by temper.octaveStep steps',
    run = function(harness)
      local h = temperedHarness(harness, rootNote{
        aliasCtr = 2,
        aliases  = {
          { id = '1', xform = { ppqL = {{'add', 240}}, octave = {{'add', 1}} },
            children = {} },
        },
      })
      local kid = aliasKid(h.fm:dump(), 1)
      local expP, expD = tuning.transposeStep(TEMPER_19, 60, 0, TEMPER_19.octaveStep)
      t.eq(kid.pitch,  expP)
      t.eq(kid.detune, expD)
    end,
  },

  --------------------------------------------------------------------
  -- combined pitch + octave deltas add into one step count
  --------------------------------------------------------------------
  {
    name = 'pitch + octave compose additively',
    run = function(harness)
      local h = temperedHarness(harness, rootNote{
        aliasCtr = 2,
        aliases  = {
          { id = '1', xform = {
              ppqL   = {{'add', 240}},
              pitch  = {{'add', 2}},
              octave = {{'add', 1}},
            }, children = {} },
        },
      })
      local kid = aliasKid(h.fm:dump(), 1)
      local steps = 2 + TEMPER_19.octaveStep
      local expP, expD = tuning.transposeStep(TEMPER_19, 60, 0, steps)
      t.eq(kid.pitch,  expP)
      t.eq(kid.detune, expD)
    end,
  },

  --------------------------------------------------------------------
  -- transitive: parent pitch +1, child pitch +1 → +2 steps total
  --------------------------------------------------------------------
  {
    name = 'transitive pitch composition: +1, +1 → +2 steps',
    run = function(harness)
      local h = temperedHarness(harness, rootNote{
        aliasCtr = 2,
        aliases  = {
          { id = '1', xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} },
            children = {
              { id = '1', xform = { ppqL = {{'add', 240}}, pitch = {{'add', 1}} },
                children = {} },
            } },
        },
      })
      local kids = {}
      for _, n in ipairs(h.fm:dump().notes) do
        if n.parentUuid == 1 then
          local idx = h.tm:specPathOf(n)
          if idx then kids[table.concat(idx, '.')] = n end
        end
      end
      local expP, expD = tuning.transposeStep(TEMPER_19, 60, 0, 2)
      t.eq(kids['1.1'].pitch,  expP)
      t.eq(kids['1.1'].detune, expD)
    end,
  },

  --------------------------------------------------------------------
  -- Zero step delta short-circuits transposeStep: an off-scale root
  -- detune is NOT silently snapped to the nearest scale step.
  --------------------------------------------------------------------
  {
    name = 'zero step delta passes through root (pitch, detune) untouched',
    run = function(harness)
      local h = temperedHarness(harness, rootNote{
        detune  = 25,        -- off the 19EDO grid
        aliasCtr = 2,
        aliases  = {
          { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
        },
      })
      local kid = aliasKid(h.fm:dump(), 1)
      t.eq(kid.pitch,  60, 'pitch unchanged')
      t.eq(kid.detune, 25, 'detune unchanged (no snap)')
    end,
  },

  --------------------------------------------------------------------
  -- detune is not in the alias vocabulary: silently ignored.
  --------------------------------------------------------------------
  {
    name = 'xform detune is silently ignored (not in alias vocab)',
    run = function(harness)
      local h = temperedHarness(harness, rootNote{
        aliasCtr = 2,
        aliases  = {
          { id = '1', xform = { ppqL = {{'add', 240}}, detune = {{'add', 50}} },
            children = {} },
        },
      })
      local kid = aliasKid(h.fm:dump(), 1)
      t.eq(kid.detune, 0, 'xform detune skipped; inherits root detune (0)')
    end,
  },

  --------------------------------------------------------------------
  -- Fake-pb absorber seated at alias child onset when D ≠ carry.
  -- Setup: root A at 0 (detune 60, with alias spec ppqL +480); plain
  -- note B at 240 (detune 0). Carry at the child's onset (ppq 480) is
  -- 0 (from B); child's inherited detune is 60 (zero step delta keeps
  -- root detune intact). Realiser must seat a fake-pb at 480, same as
  -- the user-edit pathway would.
  --------------------------------------------------------------------
  {
    name = 'alias child whose detune differs from carry seats a fake-pb at onset',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed = { notes = {
          { uuid = 1, ppq = 0,   endppq = 240, ppqL = 0,   endppqL = 240,
            chan = 1, pitch = 60, vel = 100, detune = 60, delay = 0, lane = 1,
            aliasCtr = 2,
            aliases  = {
              { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
            } },
          { uuid = 2, ppq = 240, endppq = 480, ppqL = 240, endppqL = 480,
            chan = 1, pitch = 62, vel = 100, detune = 0,  delay = 0, lane = 1 },
        } },
      }
      local dump = h.fm:dump()
      local kid  = aliasKid(dump, 1)
      t.truthy(kid, 'alias child materialised')
      t.eq(kid.ppq,    480, 'lands at ppq 480')
      t.eq(kid.detune, 60,  'inherits root detune')

      local fake = pbAt(dump, 480)
      t.truthy(fake,           'fake-pb seated at child onset')
      t.eq(fake.fake, true,    'tagged fake')
      t.eq(fake.val, cents2raw(60),
           'absorbs the 60-cent jump from prior carry (0) to child detune')
    end,
  },
}
