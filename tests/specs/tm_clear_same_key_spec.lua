-- Same-(chan, pitch) overlap is hard MIDI physics: one voice per
-- (chan, pitch), so a realised collision truncates the earlier note's
-- raw note-off. Under the universal tail model that clip is REALISED
-- only -- endppqL is intent and survives it, so removing the blocker
-- regrows the raw tail back up to the authored ceiling. The vm-side
-- delayRange gate still prevents legitimate edits from manufacturing
-- these collisions.
--
-- The clip reaches the wire and stops there: same-pitch is a projection
-- artefact, and an overlap across two lanes is perfectly drawable, so the
-- column keeps its lane bound and shows the overlap as authored. Three
-- frames, not two -- endppqL intent, endppqC the lane bound the screen
-- draws, endppq the clipped wire. Same-lane cases cannot tell them apart
-- (the lane bound sits on the peer onset either way); the cross-lane case
-- below is the one that separates them.
-- see design/interval-dirt.md § Same-pitch is a projection artefact
--
-- F3 #3: tm:addEvent must not shift endppq by delay (endppq is intent,
-- delay a realisation-level shift on the note-on only). No caller
-- passes delay≠0 to addEvent today; this pins it as the contract.

local t = require('support')

return {

  -- F3 #3: tm:addEvent must not shift endppq by delay. Caller's
  -- endppq is authored intent (logical ceiling); realiseAddPpq stamps
  -- it as endppqL and derives raw via fromLogical(endppqL) -- the
  -- delay is NOT applied to the note-off. Step 4.8's raw-frame floor
  -- (no negative-duration MIDI) then clips endppq to ppq+1 when the
  -- forward delay shoves the realised note-on past the authored
  -- ceiling -- a degenerate 1-tick note rather than the bug-shape
  -- where endppq itself drifted by delay.
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
      t.eq(n.delay,   500, 'delay survives')
      t.eq(n.ppq,     220, 'realised onset = caller ppq + delayToPPQ(delay)')
      t.eq(n.endppqL, 200, 'endppqL unchanged — addEvent did not shift intent by delay')
      t.eq(n.endppq,  221, 'realised endppq floored at ppq+1 (forward delay pushed onset past authored ceiling)')
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

  -- The peer sits in ANOTHER lane, so A's own lane never bounds it: the
  -- clip is pure same-pitch, and it must not reach the column.
  {
    name = 'cross-lane same-pitch peer clips the wire only; the column draws the lane bound',
    run = function(harness)
      local h = harness.mk{
        seed = { length = 1920, notes = {
          { ppq = 0,   endppq = 480, ppqL = 0,   endppqL = 480,
            chan = 1, pitch = 60, vel = 100, uuid = 1, lane = 1 },
          { ppq = 240, endppq = 480, ppqL = 240, endppqL = 480,
            chan = 1, pitch = 60, vel = 100, uuid = 2, lane = 2 },
        } },
        data = { extraColumns = { [1] = { notes = 2 } } },
      }

      local wire
      for _, n in ipairs(h.fm:dump().notes) do if n.ppq == 0 then wire = n end end
      t.truthy(wire, 'the earlier note survived')
      t.eq(wire.endppq,  240, 'the wire clips at the peer onset -- one voice per (chan, pitch)')
      t.eq(wire.endppqL, 480, 'endppqL is intent and never sees the clip')

      local col
      for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if e.ppq == 0 then col = e end
      end
      t.truthy(col, 'the earlier note holds its column cell')
      t.eq(col.endppq,  480, 'the column shows the authored ceiling')
      t.eq(col.endppqC, 480,
        'endppqC is the LANE bound -- lane 1 has no successor, so the same-pitch clip never reaches the screen')
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
