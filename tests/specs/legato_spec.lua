-- The shared, frame-agnostic legato primitive. tv (placeNewNote /
-- queueDeleteNotes) and mirm (group-frame Step 1 / manifest Step 2) both
-- speak it: a note's tail runs to the next onset in its column; deleting
-- a note that legato-owned the run grows its predecessor over the gap.
-- One rule, pinned once here so the two call sites cannot drift.

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
  {
    name = 'deleteFixups: deleting a legato note grows its predecessor to the next survivor',
    run = function()
      local a = note(0, 120)
      local b = note(120, 240)   -- legato into c
      local c = note(240, 360)
      local d = note(360, 480)
      local fx = legato.deleteFixups({ a, b, c, d }, { [c] = true }, 960)
      t.eq(#fx, 1, 'one predecessor fixup')
      t.eq(fx[1].evt, b, 'b owned the run into c')
      t.eq(fx[1].endppq, 360, 'b grows to d.ppq')
    end,
  },
  {
    name = 'deleteFixups: a gap before the deleted note means no extension',
    run = function()
      local a = note(0, 120)     -- ends well before c (a gap)
      local c = note(240, 360)
      local fx = legato.deleteFixups({ a, c }, { [c] = true }, 960)
      t.eq(#fx, 0, 'a did not legato-own c, so nothing grows')
    end,
  },
  {
    name = 'deleteFixups: a consecutive run is bridged by one fixup',
    run = function()
      local a = note(0, 120)
      local b = note(120, 240)
      local c = note(240, 360)
      local d = note(360, 480)
      local fx = legato.deleteFixups({ a, b, c, d }, { [b] = true, [c] = true }, 960)
      t.eq(#fx, 1, 'the b,c run collapses to a single predecessor fixup')
      t.eq(fx[1].evt, a)
      t.eq(fx[1].endppq, 360, 'a grows over the whole run to d.ppq')
    end,
  },
  {
    name = 'deleteFixups: deleting the last note grows its predecessor to fallback',
    run = function()
      local a = note(0, 120)
      local b = note(120, 240)
      local fx = legato.deleteFixups({ a, b }, { [b] = true }, 960)
      t.eq(#fx, 1)
      t.eq(fx[1].evt, a)
      t.eq(fx[1].endppq, 960, 'nothing survives after a -> fallback')
    end,
  },
}
