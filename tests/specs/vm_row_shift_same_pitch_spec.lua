-- Row-shift same-pitch bug: writePlans iterates forward, so when N
-- same-pitch back-to-back notes get shifted, each write's
-- clearSameKeyRange kills the next-still-at-old-ppq peer.
--
-- Repro:
--   * AAA at rows 0,1,2; insertRow at row 0 → expect rows 1,2,3.
--     Without the fix, row-2 note dies and we end up with .A.A.
--   * AB at rows 0,1; deleteRow at row 0 → expect B at row 0.

local t = require('support')

local function byPpq(notes)
  local out = {}
  for _, n in ipairs(notes) do out[#out+1] = n end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

return {

  {
    name = 'insertRow at row 0 on three back-to-back same-pitch notes keeps all three',
    run = function(harness)
      -- rpb=4 default, resolution=240 → 60 ppq/row.
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0,   endppq = 60,  chan = 1, pitch = 60, vel = 100,
            detune = 0, delay = 0 },
          { ppq = 60,  endppq = 120, chan = 1, pitch = 60, vel = 100,
            detune = 0, delay = 0 },
          { ppq = 120, endppq = 180, chan = 1, pitch = 60, vel = 100,
            detune = 0, delay = 0 },
        }},
      }
      h.vm:setGridSize(80, 40)

      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('insertRow')

      local notes = byPpq(h.fm:dump().notes)
      t.eq(#notes, 3, 'all three notes survive insertRow')
      t.eq(notes[1].ppq,  60,  'first note moved to row 1')
      t.eq(notes[2].ppq, 120,  'second note moved to row 2 (did not get killed)')
      t.eq(notes[3].ppq, 180,  'third note moved to row 3')
    end,
  },

  {
    name = 'deleteRow at row 0 on AB shifts B cleanly to row 0',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0,  endppq = 60,  chan = 1, pitch = 60, vel = 100,
            detune = 0, delay = 0 },
          { ppq = 60, endppq = 120, chan = 1, pitch = 62, vel = 100,
            detune = 0, delay = 0 },
        }},
      }
      h.vm:setGridSize(80, 40)

      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('deleteRow')

      local notes = h.fm:dump().notes
      t.eq(#notes, 1, 'A gone, B remains')
      t.eq(notes[1].pitch,  62, 'surviving note is B')
      t.eq(notes[1].ppq,    0,  'B shifted up to row 0')
      t.eq(notes[1].endppq, 60, 'B tail shifted up too')
    end,
  },

}
