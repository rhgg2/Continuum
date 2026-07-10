-- Signed-decimal grid entry: '-' is an in-place sign flip (no advance) and, on
-- a zero cell, arms a transient sign flip consumed by the next digit; empty
-- cells inherit their sign from the displayed ghost, else the previous visible
-- breakpoint; 'f' enters full scale on normalized pb columns; half=true
-- (Shift) adds half a place. Born with the curve-entry UX rework.

local t = require('support')

----- pb column helpers

local function pbCol(h)
  for i, c in ipairs(h.vm.grid.cols) do
    if c.type == 'pb' then return c, i end
  end
end

-- Normalized bipolar pb column (the pattern editor's curve substrate) unless
-- flags override; one pb breakpoint at row 0 so the column materialises.
-- Rows are 60 ppq apart (rpb 4, resolution 240).
local function mkCurve(harness, flags, events)
  local h = harness.mk{
    seed = { ccs = events or { { evType = 'pb', ppq = 0, chan = 1, val = 0 } } },
    data = { columnDisplay = { [1] = { pb = flags or { normalized = true, bipolar = true } } } },
  }
  h.vm:setGridSize(80, 40)
  return h
end

-- Stops 1..4 = thousands..ones. Re-pins the cursor each call; a commit
-- auto-steps the row, a bare '-' must not (asserted per test).
local function typePB(h, row, stop, ch, half)
  local col, ci = pbCol(h)
  h.ec:setPos(row, ci, stop)
  h.vm:editEvent(col, col.cells and col.cells[row], stop, string.byte(ch), half or false)
end

local function pbValAt(h, row)
  local col = pbCol(h)
  local evt = col.cells and col.cells[row]
  return evt and evt.val
end

-- Seed ppq is the raw note-on; cells key on the logical row, so pin the note
-- to row 4 (logical 240) by adding the delay's ppq offset back onto the raw.
local function mkDelayed(harness, delay)
  local rawPpq = 240 + delay * 240 // 1000
  local h = harness.mk{
    seed = {
      notes = {
        { ppq = rawPpq, endppq = rawPpq + 240, chan = 1, pitch = 60, vel = 100,
          detune = 0, delay = delay },
      },
    },
    data = { noteDelay = { [1] = { [1] = true } } },
  }
  h.vm:setGridSize(80, 40)
  return h
end

return {
  {
    name = 'coarse entry: 5 at the hundreds stop -> 500, cursor advances',
    run = function(harness)
      local h = mkCurve(harness)
      typePB(h, 0, 2, '5')
      t.eq(pbValAt(h, 0), 500, 'hundreds place set')
      t.eq(h.ec:row(), 1, 'commit auto-advanced')
    end,
  },

  {
    name = "'-' on a nonzero value flips the sign in place, no advance",
    run = function(harness)
      local h = mkCurve(harness)
      typePB(h, 0, 2, '5')
      typePB(h, 0, 2, '-')
      t.eq(pbValAt(h, 0), -500, 'sign flipped')
      t.eq(h.ec:row(), 0, 'cursor stayed put')
      typePB(h, 0, 2, '-')
      t.eq(pbValAt(h, 0), 500, 'flips back')
    end,
  },

  {
    name = "'-' on zero arms a transient -0; the next digit lands negative",
    run = function(harness)
      local h = mkCurve(harness)
      local _, ci = pbCol(h)
      typePB(h, 0, 2, '-')
      t.eq(pbValAt(h, 0), 0, 'no value written by the arm')
      local part, sign = h.vm:entrySignAt(0, ci)
      t.eq(part, 'pb', 'cell armed')
      t.eq(sign, -1, 'armed sign is negative')
      typePB(h, 0, 2, '5')
      t.eq(pbValAt(h, 0), -500, 'digit consumed the arm')
      h.ec:setPos(0, ci, 2)
      t.eq(h.vm:entrySignAt(0, ci), nil, 'nonzero cell carries its own sign')
    end,
  },

  {
    name = "a second '-' disarms; the digit then lands positive",
    run = function(harness)
      local h = mkCurve(harness)
      local _, ci = pbCol(h)
      typePB(h, 0, 2, '-')
      typePB(h, 0, 2, '-')
      local _, sign = h.vm:entrySignAt(0, ci)
      t.eq(sign, 1, 'toggled off')
      typePB(h, 0, 2, '5')
      t.eq(pbValAt(h, 0), 500, 'positive entry')
    end,
  },

  {
    name = 'an armed cell is inert while the cursor is elsewhere, live again on return',
    run = function(harness)
      local h = mkCurve(harness)
      local _, ci = pbCol(h)
      typePB(h, 0, 2, '-')
      h.ec:setPos(3, ci, 2)
      t.eq(h.vm:entrySignAt(0, ci), nil, 'arm invisible off-cell')
      h.ec:setPos(0, ci, 2)
      local part, sign = h.vm:entrySignAt(0, ci)
      t.eq(part, 'pb', 'arm revives with the cursor -- rendered, so WYSIWYG')
      t.eq(sign, -1, 'and still reads negative')
    end,
  },

  {
    name = "'f' enters full scale; sign comes from the arm or the old value",
    run = function(harness)
      local h = mkCurve(harness)
      typePB(h, 0, 1, 'f')
      t.eq(pbValAt(h, 0), 1000, 'full scale from any stop')
      typePB(h, 2, 3, '-')
      typePB(h, 2, 3, 'f')
      t.eq(pbValAt(h, 2), -1000, 'armed full scale is negative')
    end,
  },

  {
    name = 'a digit preserves the sign of an existing value',
    run = function(harness)
      local h = mkCurve(harness)
      typePB(h, 0, 2, '-')
      typePB(h, 0, 2, '5')
      typePB(h, 0, 2, '3')
      t.eq(pbValAt(h, 0), -300, 'magnitude edited, sign kept')
    end,
  },

  {
    name = 'half=true adds half a place: Shift+5 at hundreds -> 550',
    run = function(harness)
      local h = mkCurve(harness)
      typePB(h, 0, 2, '5', true)
      t.eq(pbValAt(h, 0), 550, 'half-place entry')
    end,
  },

  {
    name = 'normalized magnitude caps at 1000: 9 at the thousands stop',
    run = function(harness)
      local h = mkCurve(harness)
      typePB(h, 0, 1, '9')
      t.eq(pbValAt(h, 0), 1000, 'clamped to full scale')
    end,
  },

  {
    name = 'full scale wraps at a sub-thousands stop: 1000 then 9 at hundreds -> 900',
    run = function(harness)
      local h = mkCurve(harness)
      typePB(h, 0, 1, 'f')
      typePB(h, 0, 2, '9')
      t.eq(pbValAt(h, 0), 900, 'stale thousands digit cleared')
      typePB(h, 2, 3, 'f')
      typePB(h, 2, 2, '9', true)
      t.eq(pbValAt(h, 2), 950, 'half-place entry wraps too')
    end,
  },

  ----- empty cells inherit their sign: ghost first, else previous breakpoint

  {
    name = 'a digit on a negative ghost lands negative, and the hint says so',
    run = function(harness)
      local h = mkCurve(harness, nil, {
        { evType = 'pb', ppq = 0,   chan = 1, val = -500, shape = 'linear' },
        { evType = 'pb', ppq = 480, chan = 1, val = -100, shape = 'linear' },
      })
      local _, ci = pbCol(h)
      h.ec:setPos(4, ci, 2)
      local part, sign = h.vm:entrySignAt(4, ci)
      t.eq(part, 'pb', 'unarmed hint on a ghost cell')
      t.eq(sign, -1, 'inherits the ghost sign')
      typePB(h, 4, 2, '5')
      t.eq(pbValAt(h, 4), -500, 'digit landed with the displayed sign')
    end,
  },

  {
    name = "'-' on a negative ghost flips the inheritance; digit lands positive",
    run = function(harness)
      local h = mkCurve(harness, nil, {
        { evType = 'pb', ppq = 0,   chan = 1, val = -500, shape = 'linear' },
        { evType = 'pb', ppq = 480, chan = 1, val = -100, shape = 'linear' },
      })
      local _, ci = pbCol(h)
      typePB(h, 4, 2, '-')
      local _, sign = h.vm:entrySignAt(4, ci)
      t.eq(sign, 1, 'flip reads positive against the negative ghost')
      typePB(h, 4, 2, '5')
      t.eq(pbValAt(h, 4), 500, 'digit landed flipped')
    end,
  },

  {
    name = 'no ghost (step curve): sign inherits from the previous breakpoint',
    run = function(harness)
      local h = mkCurve(harness, nil, {
        { evType = 'pb', ppq = 0, chan = 1, val = -500, shape = 'step' },
      })
      typePB(h, 4, 2, '5')
      t.eq(pbValAt(h, 4), -500, 'coarse negative run continues without re-arming')
    end,
  },

  {
    name = 'an explicit zero breakpoint does not inherit: digit lands positive',
    run = function(harness)
      local h = mkCurve(harness, nil, {
        { evType = 'pb', ppq = 0,   chan = 1, val = -500, shape = 'linear' },
        { evType = 'pb', ppq = 480, chan = 1, val = 0,    shape = 'linear' },
      })
      typePB(h, 8, 2, '5')
      t.eq(pbValAt(h, 8), 500, 'authored zero displays unsigned, so entry is positive')
    end,
  },

  {
    name = "unipolar column refuses '-' outright: no flip, no arm",
    run = function(harness)
      local h = mkCurve(harness, { normalized = true })
      local _, ci = pbCol(h)
      typePB(h, 0, 2, '5')
      typePB(h, 0, 2, '-')
      t.eq(pbValAt(h, 0), 500, 'value untouched')
      t.eq(h.vm:entrySignAt(0, ci), nil, 'no arm on unipolar')
    end,
  },

  ----- delay part shares the semantics (sans 'f')

  {
    name = "delay: '-' on zero arms; the digit lands negative",
    run = function(harness)
      local h = mkDelayed(harness, 0)
      local col = h.vm.grid.cols[1]
      h.ec:setPos(4, 1, 5)
      h.vm:editEvent(col, col.cells[4], 5, string.byte('-'), false)
      t.eq(h.fm:dump().notes[1].delay, 0, 'arm writes nothing')
      t.eq(h.vm:entrySignAt(4, 1), 'delay', 'delay cell armed')
      h.vm:editEvent(col, col.cells[4], 5, string.byte('5'), false)
      t.eq(h.fm:dump().notes[1].delay, -500, 'digit consumed the arm')
    end,
  },

  {
    name = "delay: '-' on a nonzero value flips in place, no advance",
    run = function(harness)
      local h = mkDelayed(harness, 300)
      local col = h.vm.grid.cols[1]
      h.ec:setPos(4, 1, 5)
      h.vm:editEvent(col, col.cells[4], 5, string.byte('-'), false)
      t.eq(h.fm:dump().notes[1].delay, -300, 'sign flipped')
      t.eq(h.ec:row(), 4, 'no advance on a sign flip')
    end,
  },

  ----- command coexistence: clashing bindings decline outside their context

  {
    name = 'inputOctaveUp declines off the pitch part, fires on it',
    run = function(harness)
      local h = mkDelayed(harness, 0)
      h.ec:setPos(0, 1, 3)   -- vel nibble: Shift+8 must reach digit entry
      t.eq(h.cmgr:invoke('inputOctaveUp'), false, 'declined on a value part')
      h.ec:setPos(0, 1, 1)   -- pitch part: the command claims the key
      t.eq(h.cmgr:invoke('inputOctaveUp') ~= false, true, 'fires on the pitch part')
    end,
  },

  {
    name = 'scaleHalf and scaleDouble decline without a selection',
    run = function(harness)
      local h = mkCurve(harness)
      local _, ci = pbCol(h)
      h.ec:setPos(0, ci, 2)
      t.eq(h.cmgr:invoke('scaleHalf'), false, 'Shift+9 falls through to 950 entry')
      t.eq(h.cmgr:invoke('scaleDouble'), false, 'Shift+0 falls through to digit entry')
    end,
  },
}
