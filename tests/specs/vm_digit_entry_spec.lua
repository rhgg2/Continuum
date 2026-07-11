-- Shift-held value entry: a left-to-right overwrite cursor over a numeric
-- field's places. Each digit overwrites only its own place keep-below (lower
-- places intact), the sub-caret steps right, and the row stays pinned until
-- shift release. Backspace restores the place the last digit overwrote;
-- commit jumps back to the entry column, then advances. Drives tv:digits*
-- directly -- gridPane's key drain is a thin router over it.

local t = require('support')

----- pb column helpers

local function pbCol(h)
  for i, c in ipairs(h.vm.grid.cols) do
    if c.type == 'pb' then return c, i end
  end
end

-- Normalized bipolar pb (the pattern editor's curve substrate): gesture writes
-- land on evt.val directly as the display integer (cap 1000, four decimal
-- places). A raw ccs seed round-trips through pitchbend and quantizes, so the
-- seed sets only presence -- tests build magnitudes with the gesture, not it.
-- One breakpoint at row 0 materialises the column; other rows stay empty.
local function mkPB(harness, val)
  local h = harness.mk{
    seed = { ccs = { { evType = 'pb', ppq = 0, chan = 1, val = val or 0 } } },
    data = { columnDisplay = { [1] = { pb = { normalized = true, bipolar = true } } } },
  }
  h.vm:setGridSize(80, 40)
  return h
end

local function pbValAt(h, row)
  local col = pbCol(h)
  local evt = col.cells and col.cells[row]
  return evt and evt.val
end

----- note column helpers (vel is a 2-nibble hex field)

local function noteCol(h)
  for i, c in ipairs(h.vm.grid.cols) do
    if c.type == 'note' then return c, i end
  end
end

-- The note sits at raw ppq 120 (delay 0) -> logical row 2 (60 ppq/row).
local function mkNote(harness, vel)
  local h = harness.mk{
    seed = { notes = {
      { ppq = 120, endppq = 240, chan = 1, pitch = 60, vel = vel or 0x10, detune = 0, delay = 0 },
    } },
  }
  h.vm:setGridSize(80, 40)
  return h
end

local function velAt(h)
  local col = noteCol(h)
  local evt = col.cells and col.cells[2]
  return evt and evt.vel
end

local function firstStop(col, part)
  for stop = 1, 64 do
    if col.partAt[stop] == part then return stop end
  end
end

local function strike(h, ch) return h.vm:digitsStrike(string.byte(ch)) end

return {
  {
    name = 'place-walk: shift-547 on the hundreds of 023 keeps the lower places',
    run = function(harness)
      local h = mkPB(harness, 0)
      local _, ci = pbCol(h)
      -- Lay an exact 23 with a first gesture (a raw seed would quantize).
      h.ec:setPos(0, ci, 3); strike(h, '2')
      h.ec:setPos(0, ci, 4); strike(h, '3')
      h.vm:digitsCommit()
      t.eq(pbValAt(h, 0), 23, 'base value laid down')

      -- Fresh gesture, first strike on the hundreds: that is the entry column.
      h.ec:setPos(0, ci, 2); strike(h, '5')
      t.eq(pbValAt(h, 0), 523, 'keep-below: hundreds set, the 23 below survives (not 500)')
      strike(h, '4'); strike(h, '7')
      t.eq(pbValAt(h, 0), 547, 'sub-caret walked left-to-right through tens then ones')
      t.eq(h.ec:row(), 0, 'row pinned while shift is held')
      t.truthy(h.vm:digitsActive(), 'gesture live')

      h.vm:digitsCommit()
      t.falsy(h.vm:digitsActive(), 'commit drops the gesture')
      t.eq(h.ec:row(), 1, 'commit advanced one row')
      local _, _, stop = h.ec:pos()
      t.eq(stop, 2, 'cursor jumped back to the entry (hundreds) column before advancing')
    end,
  },

  {
    name = 'backspace restores the overwritten place so you can retype it',
    run = function(harness)
      local h = mkPB(harness, 0)
      local _, ci = pbCol(h)
      h.ec:setPos(0, ci, 2)
      strike(h, '5'); strike(h, '2'); strike(h, '3')   -- build 523 left-to-right
      t.eq(pbValAt(h, 0), 523, 'typed 523')
      t.truthy(h.vm:digitsBackspace(), 'backspace the ones')
      t.eq(pbValAt(h, 0), 520, 'ones place restored to its pre-strike 0')
      strike(h, '9')                                   -- retype the ones
      t.eq(pbValAt(h, 0), 529, 'retyped into the restored place')
    end,
  },

  {
    name = 'hex velocity: nibbles overwrite high then low, keep-below',
    run = function(harness)
      local h = mkNote(harness, 0x10)
      local col, ci = noteCol(h)
      local hi = firstStop(col, 'vel')
      h.ec:setPos(2, ci, hi)
      t.truthy(strike(h, '4'), 'high nibble consumed')
      t.eq(velAt(h), 0x40, 'high nibble set, low kept')
      t.truthy(strike(h, 'c'), 'low nibble consumed')
      t.eq(velAt(h), 0x4c, 'low nibble set keep-below')
    end,
  },

  {
    name = 'backspace on a gesture-created cell deletes it',
    run = function(harness)
      local h = mkPB(harness, 0)          -- lone breakpoint at row 0; row 4 empty
      local _, ci = pbCol(h)
      h.ec:setPos(4, ci, 2)
      strike(h, '5')
      t.eq(pbValAt(h, 4), 500, 'gesture created the breakpoint')
      t.truthy(h.vm:digitsBackspace(), 'backspace consumed')
      t.falsy(pbValAt(h, 4), 'created breakpoint removed')
    end,
  },

  {
    name = 'declines on the pitch part (not a value field)',
    run = function(harness)
      local h = mkNote(harness, 0x40)
      local col, ci = noteCol(h)
      local ps = firstStop(col, 'pitch')
      h.ec:setPos(2, ci, ps)
      t.eq(strike(h, '4'), false, 'pitch is not a gesture-editable field')
      t.falsy(h.vm:digitsActive(), 'no gesture armed')
    end,
  },

  {
    name = 'declines a char that is not a digit of the field',
    run = function(harness)
      local h = mkPB(harness, 500)
      local _, ci = pbCol(h)
      h.ec:setPos(0, ci, 2)
      t.eq(strike(h, 'q'), false, 'q is not a decimal digit')
      t.falsy(h.vm:digitsActive())
    end,
  },

  {
    name = 'a take switch abandons the gesture',
    run = function(harness)
      local h = mkPB(harness, 223)
      local _, ci = pbCol(h)
      h.ec:setPos(0, ci, 2)
      strike(h, '2')
      t.truthy(h.vm:digitsActive(), 'gesture armed')
      h.vm:rebuild(true)
      t.falsy(h.vm:digitsActive(), 'gesture abandoned on take change')
    end,
  },
}
