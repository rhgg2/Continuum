-- 14-bit cc grid entry. A `14bit` column flag (the columnDisplay take-DS key,
-- stamped onto the gridCol at rebuild) widens the scalar to 4 hex digits over a
-- display integer (val*256, even last: 0000..7FFE). editEvent stores the
-- fractional cc mm's blob splits to an MSB/LSB pair. see design/fx-patterns.md

local t = require('support')

local function ccCol(h)
  for i, c in ipairs(h.vm.grid.cols) do
    if c.type == 'cc' and c.cc == 7 then return c, i end
  end
end

local function mk(harness)
  local h = harness.mk{
    seed = { ccs = { { evType = 'cc', ppq = 0, chan = 1, cc = 7, val = 0, shape = 'linear' } } },
    data = { columnDisplay = { [1] = { ccs = { [7] = { ['14bit'] = true } } } } },
  }
  h.vm:setGridSize(80, 40)
  return h
end

-- One hex nibble at `stop` (1..4 = MS..LS), row 0 re-pinned each call since
-- editEvent's commit auto-steps the cursor row.
local function typeHex(h, stop, ch)
  local col, ci = ccCol(h)
  h.ec:setPos(0, ci, stop)
  h.vm:editEvent(col, col.cells and col.cells[0], stop, string.byte(ch), false)
end

local function ccVal(h)
  local cs = h.fm:dump().ccs
  return cs[1] and cs[1].val
end

return {
  {
    name = 'flagged cc column widens to 4 hex stops',
    run = function(harness)
      local col = ccCol(mk(harness))
      t.truthy(col and col['14bit'], 'cc column picked up the 14-bit flag from columnDisplay')
      t.deepEq(col.stopPos, {0, 1, 2, 3}, 'four hex-digit stops')
    end,
  },

  {
    name = 'MS nibble sets the high byte: 7 at stop 1 -> val 112',
    run = function(harness)
      local h = mk(harness)
      typeHex(h, 1, '7')
      t.eq(ccVal(h), 112, '0x7000 display / 256 = 112')
    end,
  },

  {
    name = 'value clamps to 0x7FFE: F at stop 1 -> 127+127/128',
    run = function(harness)
      local h = mk(harness)
      typeHex(h, 1, 'F')
      t.eq(ccVal(h), 32766 / 256, '0xF000 clamps to 0x7FFE')
    end,
  },

  {
    name = 'last nibble forced even: 3 at stop 4 -> 2/256',
    run = function(harness)
      local h = mk(harness)
      typeHex(h, 4, '3')
      t.eq(ccVal(h), 2 / 256, '0x0003 -> 0x0002; the 14-bit LSB never fills bit 0')
    end,
  },
}
