-- Carrier MSB allocation (design/note-macros.md § Delta-code allocation):
-- unlikely-authored-first priority, and a 14-bit pair (n, n+32) is usable only
-- when both halves are free.

local t = require('support')
local generators = require('generators')

local function occ(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

local function bandTaken(lo, hi)
  local s = {}
  for n = lo, hi do s[n] = true end
  return s
end

return {

  {
    name = 'an empty channel draws the coldest code first (20)',
    run = function()
      t.eq(generators.allocateCarrier({}), 20)
    end,
  },

  {
    name = 'a taken MSB code is skipped to the next priority code',
    run = function()
      t.eq(generators.allocateCarrier(occ{ 20 }), 21)
    end,
  },

  {
    name = 'a taken LSB partner (n+32) disqualifies the whole pair',
    run = function()
      -- 52 = 20+32, so the (20,52) pair is unusable; 21 is the next free pair.
      t.eq(generators.allocateCarrier(occ{ 52 }), 21)
    end,
  },

  {
    name = 'the cold band exhausted falls through to the next undefined code (3)',
    run = function()
      t.eq(generators.allocateCarrier(bandTaken(20, 31)), 3)
    end,
  },

  {
    name = 'conventional codes are the last resort -- bank-select (0) is the final pick',
    run = function()
      local taken = bandTaken(0, 63)
      taken[0], taken[32] = nil, nil   -- free only the (0,32) pair
      t.eq(generators.allocateCarrier(taken), 0)
    end,
  },

  {
    name = 'a saturated band returns nil',
    run = function()
      t.eq(generators.allocateCarrier(bandTaken(0, 63)), nil)
    end,
  },

}
