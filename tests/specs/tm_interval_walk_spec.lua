-- Pins the tail walk's sweep against the escape that has no net below it.
--
-- The walk visits its whole channel today, so nothing here can escape. Phase 4's
-- interval walk seeds from dirty intervals and sweeps outward instead, and the risk
-- it carries is a nudge that chains past the seeded region onto a note the sweep
-- never reached. These pin the surviving voices, so a sweep that stops short goes red.
--
-- The cascade must land on a DERIVED note for this to bite. mm's backstop covers an
-- escape between two authored notes -- it nudges them apart at the unwind, exactly as
-- it covered the nudges deleted in commit 2. It cannot cover an fxNote: resolveGroup
-- kills on a derived/authored mismatch (voicing.lua:20) before comparing anything, so
-- an fxNote cascaded onto an authored note is deleted rather than separated, and the
-- voice is gone with no signal. see design/interval-dirt.md § The tails closure is the
-- walk's output, not its input

local t = require('support')

-- Step 60 at res 240: tiles land on the region's quarter grid.
local retrig = { { kind = 'retrig', period = { 1, 4 }, ramp = 0 } }

-- Two same-pitch voices on one raw, one tick below the region's first tile. They are not
-- redundant -- distinct detune, so voicing separates rather than dedups -- and separating
-- them walks the second onto the tile, which is the chain the sweep must follow.
local function collidingPairBelowTile(harness)
  local h = harness.mk()
  -- The region parks the host and tiles its pitch across [120,240): onsets 120 and 180.
  h.tm:addEvent({ evType = 'note', ppq = 120, endppq = 240, chan = 1, pitch = 60,
                  vel = 100, detune = 0, delay = 0, lane = 1 })
  h.tm:flush()
  h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 120, endppq = 240,
                               fx = retrig } })
  h.tm:rebuild()

  h.tm:addEvent({ evType = 'note', ppq = 119, endppq = 180, chan = 1, pitch = 60,
                  vel = 100, detune = 0, delay = 0, lane = 2 })
  h.tm:addEvent({ evType = 'note', ppq = 119, endppq = 180, chan = 1, pitch = 60,
                  vel = 100, detune = 20, delay = 0, lane = 3 })
  h.tm:flush()
  return h
end

local function pitch60Raws(h)
  local out = {}
  for _, n in h.fm:notes() do
    if n.pitch == 60 then out[#out + 1] = n.ppq end
  end
  table.sort(out)
  return out
end

local function tileAt(h, ppq)
  for _, n in h.fm:notes() do
    if n.derived and n.pitch == 60 and n.ppq == ppq then return n end
  end
end

return {

  {
    name = 'a same-pitch cascade reaching past the seeded onsets keeps the derived voice',
    run = function(harness)
      local h = collidingPairBelowTile(harness)

      -- 119 and 119 separate to 119 and 120; 120 is the first tile's onset, so the chain
      -- runs on and that tile takes 121. A sweep fenced to the edited onsets stops before
      -- the tile, leaves it on 120 against the nudged authored note, and the backstop eats it.
      t.deepEq(pitch60Raws(h), { 119, 120, 121, 180 },
        'four distinct raws: the cascade reached the tile instead of colliding with it')
    end,
  },

  {
    name = 'the cascaded tile survives as a tile, not as a killed duplicate',
    run = function(harness)
      local h = collidingPairBelowTile(harness)

      t.truthy(tileAt(h, 121), 'the fxNote is still on the wire, nudged to 121')
      local derived = 0
      for _, n in h.fm:notes() do if n.derived then derived = derived + 1 end end
      t.eq(derived, 2, 'both retrig tiles live -- the cascade cost no derived voice')
    end,
  },

}
