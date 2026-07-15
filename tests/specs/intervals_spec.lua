-- intervals is the pure dirt-interval algebra (design/interval-dirt.md).
-- A set is `true` (whole channel) or a ppqL-ascending, non-overlapping
-- list of { loPpqL, hiPpqL, loUuid, hiUuid }. seed normalises; merge
-- coalesces edge-inclusive and collapses to `true` past the cap;
-- intersects is edge-inclusive; close widens each seed to its stage's
-- anchoring onsets (forward always, back only under stepBack) without
-- mutating its input.

local t = require('support')
local intervals = require('intervals')

-- An event as the closure consumes it: a logical position, a uuid anchor,
-- and whatever fields opts.key groups on (lane, pitch).
local function evt(ppqL, uuid, lane, pitch)
  return { ppqL = ppqL, uuid = uuid, lane = lane, pitch = pitch }
end

local byPitch = { key = function(e) return e.pitch end, stepBack = true }   -- tails-shaped
local forward = { key = function(e) return e.pitch end, stepBack = false }  -- seats/PCs-shaped

return {
  ---------- seed

  {
    name = 'seed normalises reversed bounds, swapping uuids with them',
    run = function()
      local iv = intervals.seed(100, 40, 'hi', 'lo')
      t.eq(iv.loPpqL, 40); t.eq(iv.hiPpqL, 100)
      t.eq(iv.loUuid, 'lo'); t.eq(iv.hiUuid, 'hi')
    end,
  },

  {
    name = 'seed keeps a point interval degenerate',
    run = function()
      local iv = intervals.seed(50, 50, 'u', 'u')
      t.eq(iv.loPpqL, 50); t.eq(iv.hiPpqL, 50); t.eq(iv.loUuid, 'u')
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
      t.eq(m[1].loPpqL, 0);  t.eq(m[1].hiPpqL, 20)
      t.eq(m[1].loUuid, 'a0'); t.eq(m[1].hiUuid, 'b20')
      t.eq(m[2].loPpqL, 50); t.eq(m[2].hiPpqL, 60)
    end,
  },

  {
    name = 'merge sorts before coalescing and does not mutate its input order',
    run = function()
      local set = { intervals.seed(50, 60), intervals.seed(0, 10) }
      local m = intervals.merge(set)
      t.eq(#m, 2); t.eq(m[1].loPpqL, 0)
      t.eq(set[1].loPpqL, 50)   -- caller's list untouched
    end,
  },

  {
    name = 'merge subsumes a fully-contained interval without extending the outer hi',
    run = function()
      local m = intervals.merge{ intervals.seed(0, 100, 'a', 'z'), intervals.seed(20, 30, 'p', 'q') }
      t.eq(#m, 1); t.eq(m[1].hiPpqL, 100); t.eq(m[1].hiUuid, 'z')
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

  ---------- close

  {
    name = 'close passes true through',
    run = function()
      t.eq(intervals.close(true, {}, byPitch), true)
    end,
  },

  {
    name = 'tails: stepBack widens to the previous and next same-pitch onset',
    run = function()
      -- pitch 60 onsets at 0,100,200,300; a seed at 100 must cover [0,200].
      local events = { evt(0,'a',1,60), evt(100,'b',1,60), evt(200,'c',1,60), evt(300,'d',1,60) }
      local m = intervals.close({ intervals.seed(100, 100, 'b', 'b') }, events, byPitch)
      t.eq(#m, 1)
      t.eq(m[1].loPpqL, 0);   t.eq(m[1].loUuid, 'a')
      t.eq(m[1].hiPpqL, 200); t.eq(m[1].hiUuid, 'c')
    end,
  },

  {
    name = 'tails: grouping picks the same-pitch neighbour, not the nearest onset',
    run = function()
      -- interleaved pitches; the seed on pitch 60 must skip the pitch-64 notes.
      local events = {
        evt(0,'a',1,60), evt(50,'x',1,64), evt(100,'b',1,60),
        evt(150,'y',1,64), evt(200,'c',1,60),
      }
      local m = intervals.close({ intervals.seed(100, 100, 'b', 'b') }, events, byPitch)
      t.eq(m[1].loPpqL, 0);   t.eq(m[1].hiPpqL, 200)   -- same-pitch anchors, not 50/150
    end,
  },

  {
    name = 'tails: a missing neighbour opens the edge toward the channel bound',
    run = function()
      local events = { evt(0,'a',1,60), evt(100,'b',1,60) }
      local m = intervals.close({ intervals.seed(0, 0, 'a', 'a') }, events, byPitch)
      t.eq(m[1].loPpqL, -math.huge); t.eq(m[1].loUuid, nil)   -- nothing earlier
      t.eq(m[1].hiPpqL, 100);        t.eq(m[1].hiUuid, 'b')
    end,
  },

  {
    name = 'forward closure holds the lower edge at the seed and steps only forward',
    run = function()
      local events = { evt(0,'a',1,60), evt(100,'b',1,60), evt(200,'c',1,60) }
      local m = intervals.close({ intervals.seed(100, 100, 'b', 'b') }, events, forward)
      t.eq(m[1].loPpqL, 100); t.eq(m[1].loUuid, 'b')   -- no step back
      t.eq(m[1].hiPpqL, 200); t.eq(m[1].hiUuid, 'c')
    end,
  },

  {
    name = 'close unions extensions across every group the interval touches',
    run = function()
      -- one wide seed covering a pitch-60 and a pitch-64 note; each contributes
      -- its own next onset, and the union takes the farther upper edge.
      local events = {
        evt(100,'b',1,60), evt(110,'y',1,64),
        evt(200,'c',1,60), evt(400,'z',1,64),
      }
      local m = intervals.close({ intervals.seed(100, 110, 'b', 'y') }, events, forward)
      t.eq(#m, 1); t.eq(m[1].hiPpqL, 400); t.eq(m[1].hiUuid, 'z')
    end,
  },

  {
    name = 'close steps in ppqL order -- delay-reordered raw is a phase-4 gap (design q5)',
    run = function()
      -- Two same-pitch notes whose per-note delay crosses their onsets: A is
      -- authored earlier (ppqL 100) but pushed late (raw 300); B authored later
      -- (ppqL 200) but pulled early (raw 150). The tail walk consumes them in RAW
      -- order [B, A], where B's tail reaches A -- so editing A should pull B into
      -- the interval. close compares ppqL, not raw position, so it currently does
      -- NOT (B.ppqL 200 > A.ppqL 100 fails the stepBack guard). Pinned as the
      -- known limitation until the interval tail walk (phase 4) steps in the raw
      -- frame against mm's per-channel index. See design/interval-dirt.md q5.
      local A = { ppqL = 100, uuid = 'A', pitch = 60 }
      local B = { ppqL = 200, uuid = 'B', pitch = 60 }
      local m = intervals.close({ intervals.seed(100, 100, 'A', 'A') }, { B, A }, byPitch)
      t.eq(#m, 1)
      t.eq(m[1].loPpqL, 100); t.eq(m[1].loUuid, 'A')   -- B NOT captured (the gap)
      t.eq(m[1].hiPpqL, math.huge)                      -- A is raw-last -> open end
    end,
  },

  {
    name = 'close does not mutate its input set',
    run = function()
      local set = { intervals.seed(100, 100, 'b', 'b') }
      local events = { evt(0,'a',1,60), evt(100,'b',1,60), evt(200,'c',1,60) }
      intervals.close(set, events, byPitch)
      t.eq(set[1].loPpqL, 100); t.eq(set[1].hiPpqL, 100)   -- untouched
    end,
  },
}
