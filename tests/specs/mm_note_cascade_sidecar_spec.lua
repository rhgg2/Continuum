-- A note delete and a pb-sidecar delete in ONE mm:modify must not
-- collateral-damage a surviving note's notation sidecar.
--
-- Notation (text type 15) and pb/cc (text type -1) sidecars share one
-- MIDI_*TextSysexEvt index space. MIDI_DeleteNote cascade-removes the
-- deleted note's notation event, shifting that shared stream. The old
-- code deleted the pb's sidecar by a uuidIdx cached before the cascade
-- shifted it — landing on the *survivor's* notation event. The survivor
-- was then orphaned and, on the load that closes the modify, minted a
-- fresh uuid with empty metadata: its detune silently became 0.
--
-- Reproduces the user's 19EDO stacked-group repro: D then E in the first
-- copy; deleting the predecessor (D) zeroed the survivor (E)'s detune
-- while pb/sound stayed correct (detune 0 = no pb). Order-dependent —
-- deleting the predecessor hoses the survivor; the reverse is clean.

local t = require('support')
local realMM = require('realMidiManager')()

local function freshTake()
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-note-cascade-sidecar'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')
  return take
end

return {
  {
    name = 'mixed note-cascade + pb-sidecar multi-delete keeps every survivor detune',
    run = function()
      local take = freshTake()
      local mm = realMM(take)

      -- Two stacked group instances' worth of state: D,E at 0/240 and the
      -- duplicate D,E at 480/720 (the user's "one above the other"), plus
      -- fake pb absorbers at the first two onsets. Each note gets a type-15
      -- notation sidecar + detune metadata on the closing reload; each pb a
      -- type-1 sidecar — exactly the tuning stack's persisted shape.
      mm:modify(function()
        mm:add{ evType = 'note', ppq =   0, endppq = 240, chan = 1, pitch = 62, vel = 100, detune = -11 }
        mm:add{ evType = 'note', ppq = 240, endppq = 480, chan = 1, pitch = 64, vel = 100, detune = -21 }
        mm:add{ evType = 'note', ppq = 480, endppq = 720, chan = 1, pitch = 62, vel = 100, detune = -11 }
        mm:add{ evType = 'note', ppq = 720, endppq = 960, chan = 1, pitch = 64, vel = 100, detune = -21 }
        mm:add{ evType = 'pb',   ppq =   0, chan = 1, val = -50, fake = true }
        mm:add{ evType = 'pb',   ppq = 240, chan = 1, val = -90, fake = true }
      end)

      local noteTok, pbTok = {}, {}
      for tok, e in mm:events() do
        if e.evType == 'note' then noteTok[e.ppq] = tok else pbTok[e.ppq] = tok end
      end

      -- Delete both predecessor D's and both pb absorbers in one modify,
      -- interleaved D1 → pb240 → D2 → pb0. A note delete cascade-removes its
      -- notation (shifting the shared text stream); the explicit pb-sidecar
      -- delete then ran on a uuidIdx the cascade had desynced, deleting a
      -- *survivor's* notation. That survivor was orphaned and reloaded with a
      -- fresh uuid + empty metadata — detune silently zeroed. Order-dependent,
      -- matching the user's repro.
      mm:modify(function()
        mm:delete(noteTok[0])
        mm:delete(pbTok[240])
        mm:delete(noteTok[480])
        mm:delete(pbTok[0])
      end)

      local survivors = {}
      for _, e in mm:events() do
        if e.evType == 'note' then survivors[e.ppq] = e end
      end

      local e1, e2 = survivors[240], survivors[720]
      t.truthy(e1 and e2, 'both E notes survive')
      t.truthy(e1.uuid and e2.uuid, 'survivors kept their notation sidecars (still uuid-bound)')
      t.eq(e1.detune, -21, 'E1 detune preserved (not zeroed by an orphan)')
      t.eq(e2.detune, -21, 'E2 detune preserved (not zeroed by an orphan)')
    end,
  },
}
