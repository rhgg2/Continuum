-- The derivation journal, lifted out of trackerManager, where it decides which channels the
-- rebuild re-derives and how much of each. A channel's entry is a lattice -- clean < seed list <
-- wholesale -- and `add` is the only write, so the two rules the lattice needs hold in one place:
-- an entry only ever rises, and a list that outgrows the cap collapses to the whole channel.
--
-- Both rules cost trackerManager a bug before the verb existed. The reload fold assigned its
-- deduped list over whatever stood, which drops seed dirt nothing will restate; the tail walk's
-- emission never checked the cap, so a large disturbance carried on as an unbounded seed list.

local t    = require('support')
local dirt = require('dirt')

local function seed(row) return { verb = 'add', uuid = row, ppqL = row } end

-- n distinct seeds, rows 1..n.
local function seedList(n)
  local list = {}
  for row = 1, n do list[row] = seed(row) end
  return list
end

return {
  {
    name = 'dirt: a clean channel is nil, and seeds accumulate on it in arrival order',
    run = function()
      local journal = dirt.new()
      t.eq(journal.has(3), nil, 'clean until something is added')

      journal.add(3, seed(120))
      journal.add(3, seed(240))

      t.eq(#journal.has(3), 2, 'both seeds stand')
      t.eq(journal.has(3)[1].ppqL, 120, 'first added, first held')
      t.eq(journal.wholesale(3), false, 'seeds are not the top of the lattice')
      t.eq(journal.has(4), nil, 'a neighbour channel is untouched')
    end,
  },
  {
    name = 'dirt: a seed and a list of seeds are the same verb',
    run = function()
      local journal = dirt.new()
      journal.add(1, seed(0))
      journal.add(1, seedList(3))
      t.eq(#journal.has(1), 4, 'the list joined onto the standing seed')
    end,
  },
  {
    -- The reload fold's bug: it assigned its own deduped list, so seed dirt that no later pass
    -- restates -- a region trigger, a park member -- vanished.
    name = 'dirt: a list joins onto standing seeds instead of replacing them',
    run = function()
      local journal = dirt.new()
      journal.add(2, seed(960))
      journal.add(2, seedList(2))

      local rows = {}
      for _, s in ipairs(journal.has(2)) do rows[s.ppqL] = true end
      t.truthy(rows[960], 'the standing seed survived the join')
      t.eq(#journal.has(2), 3, 'and the joined list stands alongside it')
    end,
  },
  {
    name = 'dirt: wholesale is the top -- it absorbs every later add',
    run = function()
      local journal = dirt.new()
      journal.add(5, true)
      journal.add(5, seed(120))
      journal.add(5, seedList(4))

      t.eq(journal.has(5), true, 'still wholesale')
      t.eq(journal.wholesale(5), true, 'and reads as such')
    end,
  },
  {
    -- The tail walk's bug: its emission joined a batch of nudged-note seeds by hand and never
    -- checked the cap, so the channel carried a seed list past the point where per-seed
    -- bookkeeping costs more than re-deriving the lot.
    name = 'dirt: a channel carried past the seed cap collapses to wholesale',
    run = function()
      local journal = dirt.new()
      journal.add(7, seedList(64))
      t.eq(journal.wholesale(7), false, 'at the cap the seeds still stand')

      journal.add(7, seed(65))
      t.eq(journal.has(7), true, 'one over, and the channel collapses')

      local crossing = dirt.new()
      crossing.add(7, seedList(40))
      crossing.add(7, seedList(40))
      t.eq(crossing.has(7), true, 'a list crossing the cap collapses the same way')
    end,
  },
  {
    name = 'dirt: a nil channel means all sixteen',
    run = function()
      local journal = dirt.new()
      journal.add(nil, true)
      for chan = 1, 16 do t.eq(journal.wholesale(chan), true, 'chan ' .. chan .. ' wholesale') end

      local seeded = dirt.new()
      seeded.add(nil, seed(480))
      t.eq(#seeded.has(1), 1, 'a seed reaches every channel too')
      t.eq(#seeded.has(16), 1, 'including the last')
    end,
  },
  {
    name = 'dirt: clear empties the journal and hands back the channels it held',
    run = function()
      local journal = dirt.new()
      journal.add(1, true)
      journal.add(9, seed(120))

      local consumed = journal.clear()

      t.deepEq(consumed, { [1] = true, [9] = true }, 'both channels come back for the mute sweep')
      t.eq(journal.has(1), nil, 'and the journal is clean')
      t.eq(journal.has(9), nil, 'on both')
    end,
  },
  {
    name = 'dirt: swing staleness is a second axis, cleared on its own',
    run = function()
      local journal = dirt.new()
      t.eq(journal.pending(), false, 'a fresh journal has nothing to do')

      journal.swing.add(4)
      t.eq(journal.swing.has(4), true, 'the channel is stale')
      t.eq(journal.has(4), nil, 'without dirt of its own -- bindTake marks exactly this')
      t.eq(journal.pending(), true, 'yet the rebuild gate opens')

      journal.swing.clear()
      t.eq(journal.swing.has(4), false, 'the mid-pipeline clear settles it')
      t.eq(journal.pending(), false, 'and nothing remains')

      journal.add(4, true)
      journal.clear()
      journal.swing.add(nil)
      t.eq(journal.swing.has(16), true, 'a nil channel marks all sixteen stale')
      t.eq(journal.pending(), true, 'stale swing alone keeps the gate open')
    end,
  },
}
