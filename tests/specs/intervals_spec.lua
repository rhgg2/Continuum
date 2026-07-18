-- intervals is the pure dirt-interval algebra (design/interval-dirt.md).
-- A set is `true` (whole channel) or a ppq-ascending, non-overlapping
-- list of { loPpq, hiPpq, loUuid, hiUuid }. seed normalises; merge
-- coalesces edge-inclusive and collapses to `true` past the cap;
-- intersects is edge-inclusive. (The reload fold moved to trackerManager
-- with the seed model -- see design § The model, inverted.)

local t = require('support')
local intervals = require('intervals')

return {
  ---------- seed

  {
    name = 'seed normalises reversed bounds, swapping uuids with them',
    run = function()
      local iv = intervals.seed(100, 40, 'hi', 'lo')
      t.eq(iv.loPpq, 40); t.eq(iv.hiPpq, 100)
      t.eq(iv.loUuid, 'lo'); t.eq(iv.hiUuid, 'hi')
    end,
  },

  {
    name = 'seed keeps a point interval degenerate',
    run = function()
      local iv = intervals.seed(50, 50, 'u', 'u')
      t.eq(iv.loPpq, 50); t.eq(iv.hiPpq, 50); t.eq(iv.loUuid, 'u')
    end,
  },

  ---------- merge

  {
    name = 'merge passes true through and leaves a singleton alone',
    run = function()
      t.eq(intervals.merge(true), true)
      local one = { intervals.seed(0, 10, 'a', 'b') }
      t.eq(intervals.merge(one), one)
    end,
  },

  {
    name = 'merge coalesces overlapping and edge-touching intervals, keeping outer uuids',
    run = function()
      local set = {
        intervals.seed(0, 10, 'a0', 'a10'),
        intervals.seed(10, 20, 'b10', 'b20'),   -- touches at 10 -> coalesces
        intervals.seed(50, 60, 'c50', 'c60'),   -- disjoint
      }
      local m = intervals.merge(set)
      t.eq(#m, 2)
      t.eq(m[1].loPpq, 0);  t.eq(m[1].hiPpq, 20)
      t.eq(m[1].loUuid, 'a0'); t.eq(m[1].hiUuid, 'b20')
      t.eq(m[2].loPpq, 50); t.eq(m[2].hiPpq, 60)
    end,
  },

  {
    name = 'merge sorts before coalescing and does not mutate its input order',
    run = function()
      local set = { intervals.seed(50, 60), intervals.seed(0, 10) }
      local m = intervals.merge(set)
      t.eq(#m, 2); t.eq(m[1].loPpq, 0)
      t.eq(set[1].loPpq, 50)   -- caller's list untouched
    end,
  },

  {
    name = 'merge subsumes a fully-contained interval without extending the outer hi',
    run = function()
      local m = intervals.merge{ intervals.seed(0, 100, 'a', 'z'), intervals.seed(20, 30, 'p', 'q') }
      t.eq(#m, 1); t.eq(m[1].hiPpq, 100); t.eq(m[1].hiUuid, 'z')
    end,
  },

  {
    name = 'merge collapses to true past the size cap',
    run = function()
      local set = {}
      for i = 0, 100 do set[#set + 1] = intervals.seed(i * 10, i * 10 + 1) end
      t.eq(intervals.merge(set), true)
    end,
  },

  ---------- intersects

  {
    name = 'intersects is edge-inclusive and short-circuits on true',
    run = function()
      local set = { intervals.seed(10, 20), intervals.seed(40, 50) }
      t.eq(intervals.intersects(set, 20, 25), true)   -- touches at the 20 edge
      t.eq(intervals.intersects(set, 25, 35), false)  -- in the gap
      t.eq(intervals.intersects(true, 999, 1000), true)
    end,
  },
}
