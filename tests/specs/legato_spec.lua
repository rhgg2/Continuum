-- The shared, frame-agnostic legato primitive. tv calls `place` from
-- placeNewNote: a note's tail runs to the next onset in its column.
-- Pinned once here. (Delete-time tail regrowth is no longer a legato
-- op -- tm's universal tail pass re-derives it; see tm_conform_tail_spec.)

local t      = require('support')
local legato = require('legato')

local function note(ppq, endppq) return { ppq = ppq, endppq = endppq } end

return {
  {
    name = 'place into an empty column: no neighbours, tail = fallback',
    run = function()
      local prev, nxt, endppq = legato.place({}, 100, 960)
      t.eq(prev, nil)
      t.eq(nxt, nil)
      t.eq(endppq, 960, 'nothing follows -> fallback')
    end,
  },
  {
    name = 'place between two notes: tail clips to the next onset',
    run = function()
      local a, b = note(0, 240), note(480, 720)
      local prev, nxt, endppq = legato.place({ a, b }, 240, 960)
      t.eq(prev, a, 'predecessor is the note before the onset')
      t.eq(nxt, b, 'successor is the note after the onset')
      t.eq(endppq, 480, 'tail = next onset, not fallback')
    end,
  },
  {
    name = 'place after the last note: tail = fallback',
    run = function()
      local a = note(0, 240)
      local prev, nxt, endppq = legato.place({ a }, 480, 960)
      t.eq(prev, a)
      t.eq(nxt, nil)
      t.eq(endppq, 960)
    end,
  },
}
