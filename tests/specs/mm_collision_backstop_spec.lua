-- Phase 2 pin - design/same-pitch-enforcement.md item 2. mm's write-path
-- backstop: a verb filing over a live collisionIdx slot records (chan, pitch);
-- the outermost modify unwind resolves the settled model via
-- voicing.resolveGroup and fires collisionsResolved. bareMM on purpose:
-- with tm wired, its reload rebuild separates the collision first and the
-- backstop (correctly) finds nothing.

local t = require('support')

local function ppqsOf(mm)
  local out = {}
  for _, n in mm:notes() do out[#out + 1] = n.ppq end
  table.sort(out)
  return out
end

local function noteAt(mm, ppq)
  for _, n in mm:notes() do if n.ppq == ppq then return n end end
end

-- Two distinct voices (different ppqL) on one (chan, pitch).
local function twoVoices(harness)
  return harness.bareMM{ notes = {
    { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100, ppqL = 0 },
    { ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 100, ppqL = 240 },
  } }
end

return {
  {
    name = 'distinct voices colliding via direct mm:assign are nudged apart',
    run = function(harness)
      local mm = twoVoices(harness)
      local moved = noteAt(mm, 240).uuid
      local fired, handleLive = {}, nil
      mm:subscribe('collisionsResolved', function(info)
        fired[#fired + 1] = info
        handleLive = mm:byToken(info.events[1].uuid) ~= nil
      end)

      mm:modify(function() mm:assign(noteAt(mm, 240).token, { ppq = 0 }) end)

      t.eq(#fired, 1, 'one collisionsResolved')
      local e = fired[1].events[1]
      t.eq(e.kind, 'nudged')
      t.eq(e.ppq, 1, 'nudged to prev + 1')
      t.eq(e.uuid, moved, 'the nudge moves the voice it names; identity is untouched')
      t.truthy(handleLive, 'signal fired after the reindex - the uuid resolves')
      t.deepEq(ppqsOf(mm), { 0, 1 }, 'both voices survive, separated')
    end,
  },

  {
    name = 'true duplicates (same ppqL, same detune) collapse to the longer',
    run = function(harness)
      local mm = harness.bareMM{ notes = {
        { ppq =   0, endppq = 480, chan = 1, pitch = 60, vel = 100, ppqL = 0 },
        { ppq = 240, endppq = 360, chan = 1, pitch = 60, vel = 100, ppqL = 0 },
      } }
      local shortUuid = noteAt(mm, 240).uuid
      local fired = {}
      mm:subscribe('collisionsResolved', function(info) fired[#fired + 1] = info end)

      mm:modify(function() mm:assign(noteAt(mm, 240).token, { ppq = 0 }) end)

      t.eq(#fired, 1)
      local e = fired[1].events[1]
      t.eq(e.kind, 'killed')
      t.eq(e.uuid, shortUuid, 'the shorter duplicate dies')
      t.falsy(e.token, 'killed events carry no live token')
      t.deepEq(ppqsOf(mm), { 0 }, 'one survivor')
      t.eq(noteAt(mm, 0).endppq, 480, 'longer endppq wins')
    end,
  },

  {
    name = 'resolution is idempotent - the next modify finds nothing',
    run = function(harness)
      local mm = twoVoices(harness)
      local fired = {}
      mm:subscribe('collisionsResolved', function(info) fired[#fired + 1] = info end)

      mm:modify(function() mm:assign(noteAt(mm, 240).token, { ppq = 0 }) end)
      mm:modify(function() mm:assign(noteAt(mm, 0).token, { vel = 101 }) end)

      t.eq(#fired, 1, 'no second firing')
      t.deepEq(ppqsOf(mm), { 0, 1 }, 'geometry stable across the second modify')
    end,
  },

  {
    name = 'a transient mid-batch collision resolves to nothing',
    run = function(harness)
      local mm = twoVoices(harness)
      local fired = {}
      mm:subscribe('collisionsResolved', function(info) fired[#fired + 1] = info end)

      mm:modify(function()
        local tok = mm:assign(noteAt(mm, 240).token, { ppq = 0 })   -- collides - recorded
        mm:assign(tok, { ppq = 480 })                               -- moves away before unwind
      end)

      t.eq(#fired, 0, 'no signal for a collision a later verb dissolved')
      t.deepEq(ppqsOf(mm), { 0, 480 }, 'model untouched by the backstop')
    end,
  },
}
