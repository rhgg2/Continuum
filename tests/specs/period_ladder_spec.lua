-- Pin the period ladder's entry and stepping arithmetic: the fx strip's Period
-- widget writes {num,den} through parsePeriod and reads it back through
-- formatPeriod, and its arrows walk the ladder by magnitude.

local t = require('support')
local timing = require('timing')

local L = timing.periodLadder

-- QN of a ladder entry, for the ordering assertions.
local function qn(p) return timing.periodQN(p) end

return {
  {
    name = 'ladder runs long to short, strictly descending',
    run = function()
      t.truthy(#L > 12, 'ladder has the binary, dotted and triplet families')
      for i = 2, #L do
        t.truthy(qn(L[i]) < qn(L[i - 1]),
             ('entry %d (%s) must be shorter than %d (%s)')
               :format(i, timing.formatPeriod(L[i]), i - 1, timing.formatPeriod(L[i - 1])))
      end
    end,
  },
  {
    name = 'ladder carries each base with its dotted and triplet',
    run = function()
      local seen = {}
      for _, p in ipairs(L) do seen[timing.formatPeriod(p)] = true end
      for _, want in ipairs{ '1', '3/2', '2/3', '1/4', '3/8', '1/6', '1/32', '3/64', '1/48' } do
        t.truthy(seen[want], 'ladder holds ' .. want)
      end
    end,
  },

  {
    name = 'formatPeriod writes bare fractions, whole QN without a denominator',
    run = function()
      t.eq(timing.formatPeriod{ 3, 8 }, '3/8')
      t.eq(timing.formatPeriod{ 7, 19 }, '7/19')
      t.eq(timing.formatPeriod{ 4, 1 }, '4')
      t.eq(timing.formatPeriod(2), '2')
    end,
  },

  {
    name = 'parsePeriod takes integers and fractions',
    run = function()
      t.deepEq(timing.parsePeriod('7/19'), { 7, 19 })
      t.deepEq(timing.parsePeriod('7/4'),  { 7, 4 })
      t.deepEq(timing.parsePeriod('4'),    { 4, 1 })
      t.deepEq(timing.parsePeriod(' 3 / 5 '), { 3, 5 })
    end,
  },
  {
    name = 'parsePeriod reduces, so a typed period matches its ladder entry',
    run = function()
      t.deepEq(timing.parsePeriod('6/8'),  { 3, 4 })
      t.deepEq(timing.parsePeriod('2/6'),  { 1, 3 })
    end,
  },
  {
    name = 'parsePeriod rejects what it cannot mean',
    run = function()
      t.eq(timing.parsePeriod(''), nil)
      t.eq(timing.parsePeriod('0'), nil)
      t.eq(timing.parsePeriod('1/0'), nil)
      t.eq(timing.parsePeriod('-1/4'), nil)
      t.eq(timing.parsePeriod('0.75'), nil)      -- decimals are not the entry form
      t.eq(timing.parsePeriod('quaver'), nil)
      t.eq(timing.parsePeriod('1/1000'), nil)    -- past the denominator cap
    end,
  },

  {
    name = 'stepping walks the ladder, right toward shorter',
    run = function()
      t.deepEq(timing.steppedPeriod(L, { 1, 4 }, 1),  { 3, 16 })
      t.deepEq(timing.steppedPeriod(L, { 1, 4 }, -1), { 1, 3 })
    end,
  },
  {
    name = 'an off-ladder period enters between its neighbours, not at the top',
    run = function()
      -- 7/19 ≈ 0.368 QN, between 3/8 (0.375) and 1/3.
      t.deepEq(timing.steppedPeriod(L, { 7, 19 }, 1),  { 1, 3 })
      t.deepEq(timing.steppedPeriod(L, { 7, 19 }, -1), { 3, 8 })
    end,
  },
  {
    name = 'stepping past either end stays put',
    run = function()
      t.eq(timing.steppedPeriod(L, L[1], -1), nil)
      t.eq(timing.steppedPeriod(L, L[#L], 1), nil)
    end,
  },
  {
    name = 'coarse halves or doubles, landing on the nearest entry',
    run = function()
      t.deepEq(timing.steppedPeriod(L, { 1, 4 }, 1, true),  { 1, 8 })
      t.deepEq(timing.steppedPeriod(L, { 1, 4 }, -1, true), { 1, 2 })
      t.deepEq(timing.steppedPeriod(L, { 3, 8 }, 1, true),  { 3, 16 })
      -- Off the ladder: halve, then snap to whatever sits closest.
      t.deepEq(timing.steppedPeriod(L, { 7, 19 }, 1, true), { 3, 16 })
    end,
  },
  {
    name = 'coarse at the end still moves, so the arrow is never inert',
    run = function()
      t.eq(timing.steppedPeriod(L, L[#L], 1, true), nil)
      t.deepEq(timing.steppedPeriod(L, L[#L], -1, true), { 1, 24 })
    end,
  },
}
