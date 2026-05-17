-- Plain duplicate cascade (tv:duplicateCascade, clip payload + cursorRect
-- fallback). The single-shot 1x1/no-sel part dispatch is pinned in
-- edit_cursor_spec; this pins the *run* semantics the unification added:
-- an unmoved cursor stacks the next copy one region below the last, a
-- moved cursor redirects it to the cursor, and every copy leaves the
-- new region selected so a follow-up dup/move targets it.

local t = require('support')

local function noteH(harness)
  local h = harness.mk{
    seed = { notes = { { ppq = 240, endppq = 360, chan = 1, pitch = 60,
                         vel = 100, detune = 0, delay = 0 } } },
  }
  h.vm:setGridSize(80, 40)
  h.ec:setPos(4, 1, 1)  -- pitch stop on the row-4 note
  return h
end

local function ppqs(h)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do out[#out + 1] = n.ppq end
  table.sort(out)
  return out
end

return {
  {
    name = 'unmoved cursor stacks each copy one region below the last',
    run = function(harness)
      local h = noteH(harness)
      h.cmgr:invoke('duplicateDown')   -- seed: copy at row 5 (ppq 300)
      h.cmgr:invoke('duplicateDown')   -- no move: stack at row 6 (ppq 360)
      t.deepEq(ppqs(h), { 240, 300, 360 }, 'source + two stacked copies')
    end,
  },
  {
    name = 'a cursor move redirects the next copy to the cursor row',
    run = function(harness)
      local h = noteH(harness)
      h.cmgr:invoke('duplicateDown')   -- copy at row 5; cursor follows
      h.cmgr:invoke('cursorDown')
      h.cmgr:invoke('cursorDown')
      h.cmgr:invoke('cursorDown')      -- cursor now row 8
      h.cmgr:invoke('duplicateDown')   -- redirected: copy at row 8 (ppq 480)
      local p = ppqs(h)
      t.deepEq(p, { 240, 300, 480 }, 'second copy at the moved cursor, not stacked at 360')
    end,
  },
  {
    name = 'after a cursor-move redirect, repeated dups keep stacking from there',
    run = function(harness)
      local h = noteH(harness)
      h.cmgr:invoke('duplicateDown')   -- seed: copy at row 5 (ppq 300)
      h.cmgr:invoke('cursorDown')
      h.cmgr:invoke('cursorDown')
      h.cmgr:invoke('cursorDown')      -- cursor now row 8
      h.cmgr:invoke('duplicateDown')   -- redirect: copy at row 8 (ppq 480)
      h.cmgr:invoke('duplicateDown')   -- no move: stack at row 9 (ppq 540)
      h.cmgr:invoke('duplicateDown')   -- no move: stack at row 10 (ppq 600)
      t.deepEq(ppqs(h), { 240, 300, 480, 540, 600 },
               'redirect then two stacked copies below it')
    end,
  },
  {
    name = 'a mouse-style cursor move (selClear+setPos, no cmgr) keeps the cascade',
    run = function(harness)
      local h = noteH(harness)
      h.cmgr:invoke('duplicateDown')   -- seed: copy at row 5
      h.ec:selClear(); h.ec:setPos(8, 1, 1)  -- what handleMouse does
      h.cmgr:invoke('duplicateDown')   -- redirect to row 8 (ppq 480)
      h.cmgr:invoke('duplicateDown')   -- no move: stack at row 9 (ppq 540)
      t.deepEq(ppqs(h), { 240, 300, 480, 540 },
               'mouse move redirects, then stacking continues')
    end,
  },
  {
    name = 'selection seed: redirect then repeated dups keep stacking',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 240, endppq = 300, chan = 1, pitch = 60,
                             vel = 100, detune = 0, delay = 0 } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(4, 1, 1)
      h.ec:extendTo(4, 1, 1)           -- a real 1-row selection at row 4
      h.cmgr:invoke('duplicateDown')   -- seed: copy at row 5
      h.cmgr:invoke('cursorDown')      -- real cursor move (selClear inside)
      h.cmgr:invoke('cursorDown')
      h.cmgr:invoke('cursorDown')      -- cursor row 8
      h.cmgr:invoke('duplicateDown')   -- redirect to row 8 (ppq 480)
      h.cmgr:invoke('duplicateDown')   -- stack row 9 (ppq 540)
      h.cmgr:invoke('duplicateDown')   -- stack row 10 (ppq 600)
      t.deepEq(ppqs(h), { 240, 300, 480, 540, 600 },
               'selection seed cascades through a redirect')
    end,
  },
  {
    name = 'channel-change cursor move: redirect then repeated dups keep stacking',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 240, endppq = 300, chan = 1, pitch = 60, vel = 100,
            detune = 0, delay = 0 },
          { ppq = 0,   endppq = 60,  chan = 2, pitch = 64, vel = 100,
            detune = 0, delay = 0 },
        } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(4, 1, 1)             -- chan-1 note, row 4
      h.cmgr:invoke('duplicateDown')   -- seed: chan-1 copy at row 5
      h.cmgr:invoke('channelRight')    -- cursor jumps to chan 2
      h.cmgr:invoke('cursorDown')
      h.cmgr:invoke('cursorDown')
      h.cmgr:invoke('cursorDown')      -- chan 2, row 8
      h.cmgr:invoke('duplicateDown')   -- redirect (ppq 480)
      h.cmgr:invoke('duplicateDown')   -- stack (ppq 540)
      h.cmgr:invoke('duplicateDown')   -- stack (ppq 600)
      local onChan2 = {}
      for _, n in ipairs(h.fm:dump().notes) do
        if n.chan == 2 and n.ppq >= 480 then onChan2[#onChan2 + 1] = n.ppq end
      end
      table.sort(onChan2)
      t.deepEq(onChan2, { 480, 540, 600 },
               'redirected copies land on the cursor channel (chan 2)')
    end,
  },
  {
    name = 'no-selection seed leaves no selection (classic cell duplicate)',
    run = function(harness)
      local h = noteH(harness)
      t.eq(h.ec:hasSelection(), false, 'no selection before the first dup')
      h.cmgr:invoke('duplicateDown')
      t.eq(h.ec:hasSelection(), false, 'cell dup does not select the copy')
      h.cmgr:invoke('duplicateDown')
      t.eq(h.ec:hasSelection(), false, 'still unselected after a stacked dup')
    end,
  },
  {
    name = 'selection seed re-selects each copy',
    run = function(harness)
      local h = noteH(harness)
      h.ec:extendTo(4, 1, 1)           -- a real 1-row selection
      h.cmgr:invoke('duplicateDown')
      t.eq(h.ec:hasSelection(), true, 'the freshly placed copy is selected')
    end,
  },
}
