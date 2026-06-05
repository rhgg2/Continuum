-- Integration spec: real midiManager + fakeReaper. A value-only assign on a
-- PA event carries its value in `vel` (not `val`). assignCC must reconstruct
-- and write the new pressure to reaper, else the edit only mutates the
-- in-memory record and is lost on reload. Pins the write-through.

local t = require('support')

local realMM = require('realMidiManager')()

local CHANMSG = { pa = 0xA0, cc = 0xB0, pc = 0xC0, at = 0xD0, pb = 0xE0 }

local function freshTake()
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-pa-assign'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')
  return take, fakeReaper
end

local function seedPA(take, reaper, pa)
  reaper:seedMidi(take, { ccs = { {
    ppq = pa.ppq, chanmsg = CHANMSG.pa, chan = (pa.chan or 1) - 1,
    msg2 = pa.pitch, msg3 = pa.vel,
  } } })
end

return {
  {
    name = 'assignCC writes a value-only PA vel through to reaper',
    run = function()
      local take = freshTake()
      seedPA(take, _G.reaper, { ppq = 240, chan = 1, pitch = 60, vel = 0x50 })

      local mm = realMM(nil)
      mm:load(take)
      local _, pa = mm:ccs()()
      t.eq(pa.vel, 0x50, 'seed vel')

      mm:modify(function() mm:assign(mm:tokenOf(pa), { vel = 0x70 }) end)

      -- Ground truth: reload fresh from reaper.
      local mm2 = realMM(nil)
      mm2:load(take)
      local _, reloaded = mm2:ccs()()
      t.truthy(reloaded, 'pa survives reload')
      t.eq(reloaded.evType, 'pa')
      t.eq(reloaded.vel, 0x70, 'new pressure persisted to reaper')
    end,
  },
}
