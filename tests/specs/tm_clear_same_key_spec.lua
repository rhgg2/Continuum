-- Same-(chan, pitch) overlap is hard MIDI physics: one voice per
-- (chan, pitch), so a realised collision truncates the earlier note's
-- raw note-off. Under the universal tail model that clip is REALISED
-- only -- endppqL is intent and survives it, so removing the blocker
-- regrows the raw tail back up to the authored ceiling. The vm-side
-- delayRange gate still prevents legitimate edits from manufacturing
-- these collisions.
--
-- F3 #3: tm:addEvent must not shift endppq by delay (endppq is intent,
-- delay a realisation-level shift on the note-on only). No caller
-- passes delay≠0 to addEvent today; this pins it as the contract.

local t = require('support')

return {

  -- F3 #3: tm:addEvent must not shift endppq by delay.
  {
    name = 'F3 #3: tm:addEvent with delay≠0 leaves endppq at caller value',
    run = function(harness)
      local h = harness.mk()

      -- delayToPPQ(500, 240) = round(240 * 500 / 1000) = 120.
      h.tm:addEvent({ evType = 'note',
        ppq = 100, endppq = 200, chan = 1, pitch = 60, vel = 100,
        detune = 0, delay = 500, lane = 1,
      })
      h.tm:flush()

      local n = h.fm:dump().notes[1]
      t.truthy(n, 'note added')
      t.eq(n.delay,  500, 'delay survives')
      t.eq(n.ppq,    220, 'realised onset = caller ppq + delayToPPQ(delay)')
      t.eq(n.endppq, 200, 'endppq unchanged — F3 (was 320 pre-fix)')
    end,
  },

  -- The realised same-pitch clip shortens raw endppq only; endppqL is
  -- intent and is never pulled down to the peer onset (deleting the
  -- peer would regrow the raw tail back up to it).
  {
    name = 'same-pitch peer clips realised endppq; endppqL (intent) survives',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 480, ppqL = 0, endppqL = 480,
                             chan = 1, pitch = 60, vel = 100, uuid = 1, lane = 1 } } },
      }
      h.tm:addEvent({ evType = 'note', ppq = 240, endppq = 480, ppqL = 240, endppqL = 480,
                              chan = 1, pitch = 60, vel = 100, lane = 1 })
      h.tm:flush()

      local notes = h.fm:dump().notes
      local first
      for _, n in ipairs(notes) do if n.ppq == 0 then first = n end end
      t.truthy(first, 'first note survived')
      t.eq(first.endppq,  240, 'realised tail clipped to the peer onset (MIDI physics)')
      t.eq(first.endppqL, 480, 'endppqL is intent — the realised clip never shortens it')
    end,
  },

  {
    name = 'self clamped by a later same-pitch peer; endppqL (intent) survives',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 480, endppq = 600, ppqL = 480, endppqL = 600,
                             chan = 1, pitch = 60, vel = 100, uuid = 1, lane = 1 } } },
      }
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 720, ppqL = 0, endppqL = 720,
                              chan = 1, pitch = 60, vel = 100, lane = 1 })
      h.tm:flush()

      local notes = h.fm:dump().notes
      local self_
      for _, n in ipairs(notes) do if n.ppq == 0 then self_ = n end end
      t.truthy(self_, 'self note added')
      t.eq(self_.endppq,  480, 'self realised-clamped to the next peer onset')
      t.eq(self_.endppqL, 720, 'endppqL is intent — the clamp never shortens it')
    end,
  },
}
