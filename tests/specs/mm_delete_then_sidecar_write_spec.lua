-- A note delete and a surviving note's sidecar WRITE in ONE mm:modify must
-- land the write on the survivor's OWN notation event, not a neighbour's.
--
-- Notation (text type 15) sidecars share one MIDI_*TextSysexEvt index space.
-- MIDI_DeleteNote cascade-removes the deleted note's notation, shifting every
-- later notation's wire index down by one. A structural assign on a survivor
-- then rewrites its notation; if it uses a uuidIdx cached before the cascade
-- shifted it, the write lands on a DIFFERENT note's notation — overwriting it
-- with the survivor's uuid. On the load that closes the modify, the clobbered
-- note finds no matching notation, mints a fresh uuid with empty metadata, and
-- silently loses its detune. This pins the write path the same way
-- mm_note_cascade_sidecar_spec pins the delete path.

local t = require('support')
local realMM = require('realMidiManager')()

local function freshTake()
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-delete-then-sidecar-write'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')
  return take
end

return {
  {
    name = 'delete + survivor sidecar-write in one modify keeps every survivor detune',
    run = function()
      local take = freshTake()
      local mm = realMM(take)

      -- Three notes at distinct (ppq, pitch) so notation content-match is
      -- unique; each carries detune metadata persisted on the closing reload.
      mm:modify(function()
        mm:add{ evType = 'note', ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = -3 }
        mm:add{ evType = 'note', ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100, detune = -7 }
        mm:add{ evType = 'note', ppq = 480, endppq = 720, chan = 1, pitch = 64, vel = 100, detune = -11 }
      end)

      local tokByPpq = {}
      for _, n in mm:notes() do tokByPpq[n.ppq] = mm:tokenOf(n) end

      -- Delete the first note (cascade shifts the shared notation stream), then
      -- transpose the second in the SAME modify. The transpose is structural, so
      -- it rewrites note B's notation sidecar — which must hit B's slot, post-shift.
      mm:modify(function()
        mm:delete(tokByPpq[0])
        mm:assign(tokByPpq[240], { pitch = 63 })
      end)

      local byPpq = {}
      for _, e in mm:notes() do byPpq[e.ppq] = e end

      t.truthy(byPpq[240] and byPpq[480], 'both survivors present')
      t.eq(byPpq[240].pitch,  63,  'B transposed to 63')
      t.eq(byPpq[240].detune, -7,  'B detune preserved through its own sidecar rewrite')
      t.eq(byPpq[480].pitch,  64,  'C pitch untouched')
      t.eq(byPpq[480].detune, -11, 'C detune preserved (not clobbered by B\'s sidecar write)')
    end,
  },
}
