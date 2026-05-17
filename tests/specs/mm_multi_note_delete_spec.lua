-- Multi-deleteNote in one mm:modify must resolve REAPER note idxs against
-- the live array, not against idxs captured before the deletes started
-- shifting things. MIDI_DeleteNote shifts all higher idxs down by one;
-- a subsequent delete using a stale captured idx hits the wrong note.
--
-- Reproduces the symptom the user hit: notes ABAB in one column, select
-- first AB, delete → .B.B (A1 deleted as expected, but the second delete
-- hit A2 instead of B1, leaving B1 and B2 surviving).

local t = require('support')
local realMM = require('realMidiManager')()

local function freshTake()
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-multi-note-delete'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')
  return take, fakeReaper
end

return {
  {
    name = 'multi-deleteNote in one modify deletes exactly the tokens passed',
    run = function()
      local take = freshTake()
      local mm = realMM(take)

      -- Seed ABAB: pitch 60, 62, 60, 62 at ppq 0, 240, 480, 720.
      mm:modify(function()
        mm:add{ evType = 'note', ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100 }
        mm:add{ evType = 'note', ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100 }
        mm:add{ evType = 'note', ppq = 480, endppq = 720, chan = 1, pitch = 60, vel = 100 }
        mm:add{ evType = 'note', ppq = 720, endppq = 960, chan = 1, pitch = 62, vel = 100 }
      end)

      local tokByPpq = {}
      for _, n in mm:notes() do tokByPpq[n.ppq] = mm:tokenOf(n) end

      -- Delete the first A and the first B (rows 1 and 2 of ABAB).
      mm:modify(function()
        mm:delete(tokByPpq[0])
        mm:delete(tokByPpq[240])
      end)

      local survivors = {}
      for _, n in mm:notes() do survivors[#survivors+1] = { ppq = n.ppq, pitch = n.pitch } end

      t.eq(#survivors, 2, 'exactly two notes survive (A2 and B2)')
      table.sort(survivors, function(a, b) return a.ppq < b.ppq end)
      t.eq(survivors[1].ppq, 480, 'A2 at ppq=480 survives')
      t.eq(survivors[1].pitch, 60, 'A2 pitch=60')
      t.eq(survivors[2].ppq, 720, 'B2 at ppq=720 survives')
      t.eq(survivors[2].pitch, 62, 'B2 pitch=62')
    end,
  },
}
