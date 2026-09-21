-- The derivation journal, lifted out of trackerManager, where it decides which channels the
-- rebuild re-derives and how much of each. A channel's entry is a lattice -- clean < seed list <
-- wholesale -- and `add` is the only write, so the two rules the lattice needs hold in one place:
-- an entry only ever rises, and a list that outgrows the cap collapses to the whole channel.
--
-- Both rules cost trackerManager a bug before the verb existed. The reload fold assigned its
-- deduped list over whatever stood, which drops seed dirt nothing will restate; the tail walk's
-- emission never checked the cap, so a large disturbance carried on as an unbounded seed list.
--
-- The journal also answers over what it stores: which logical positions its seeds name, which of
-- them a position or a span meets, and which uuids they name. The positions are one sorted array
-- per channel, built at the first question and dropped by the next write -- the rebuild seeds
-- mid-pass (park members, the tail walk's emission) while later stages are still asking.
--
-- The journal also mints what it stores. The three minters differ in where the raw frame comes
-- from and in whether the seed keeps the record it was taken from; the cases below pin both.

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

      local consumed = journal.byChannel()
      journal.clear()

      t.deepEq(consumed, { [1] = true, [9] = true }, 'both channels come back for the mute sweep')
      t.eq(journal.has(1), nil, 'and the journal is clean')
      t.eq(journal.has(9), nil, 'on both')
    end,
  },
  {
    -- A move's seat carries the positions its dropped duplicates named, so the array holds every
    -- position the uuid stood on during the flush -- both ends of the move, not just its birth.
    name = 'dirt: the seeded positions are sorted and distinct, and hold what the fold carried',
    run = function()
      local journal = dirt.new()
      journal.add(2, { verb = 'move',   uuid = 'u1', ppqL = 960, laterPpqs = { 240 } })
      journal.add(2, { verb = 'add',    uuid = 'u2', ppqL = 480 })
      journal.add(2, { verb = 'delete', uuid = 'u3', ppqL = 480 })

      t.deepEq(journal.ppqs(2), { 240, 480, 960 },
               'both seats of the move, the add, and one entry for the position two seeds share')
    end,
  },
  {
    name = 'dirt: the cc family answers in cells, one per column its seeds name',
    run = function()
      local journal = dirt.new()
      journal.add(3, { verb = 'add',  uuid = 'u1', evType = 'cc', cc = 10, ppqL = 480 })
      journal.add(3, { verb = 'move', uuid = 'u2', evType = 'cc', cc = 10, ppqL = 960, laterPpqs = { 240 } })
      journal.add(3, { verb = 'add',  uuid = 'u3', evType = 'cc', cc = 11, ppqL = 480 })
      journal.add(3, { verb = 'add',  uuid = 'u4', evType = 'at', ppqL = 120 })
      journal.add(3, { verb = 'add',  uuid = 'u5', evType = 'note', ppqL = 720 })

      local cells = journal.ppqs(3, 'cc')
      t.deepEq(cells[10].ppqs, { 240, 480, 960 }, 'both seats of the move joined the add, sorted')
      t.eq(cells[10].evType, 'cc', 'the cell names the column it answers for')
      t.deepEq(cells[11].ppqs, { 480 }, 'a co-row tenant in another column stands on its own')
      t.deepEq(cells.at.ppqs, { 120 }, 'at keys by evType, carrying one stream')
      t.eq(cells.note, nil, 'a seed outside the family reaches no cell')
      t.deepEq(journal.ppqs(3, 'note'), { 720 }, 'and the row families still answer rows')
    end,
  },
  {
    name = 'dirt: covers answers one position, and wholesale covers every one',
    run = function()
      local journal = dirt.new()
      t.eq(journal.covers(1, 480), false, 'a clean channel covers nothing')

      journal.add(1, { verb = 'move', uuid = 'u1', ppqL = 480, laterPpqs = { 1440 } })
      t.eq(journal.covers(1, 480), true, 'the birth snapshot')
      t.eq(journal.covers(1, 1440), true, 'and the position the fold carried onto it')
      t.eq(journal.covers(1, 960), false, 'between the two, the channel stands clean')

      journal.add(1, true)
      t.eq(journal.covers(1, 960), true, 'wholesale covers what no seed names')
    end,
  },
  {
    name = 'dirt: touches asks a span, both edges included',
    run = function()
      local journal = dirt.new()
      t.eq(journal.touches(3, 0, 3840), false, 'a clean channel touches nothing')

      journal.add(3, seed(960))
      t.eq(journal.touches(3, 960, 1920), true, 'the span opens on the seed')
      t.eq(journal.touches(3, 0, 960), true, 'and closes on it')
      t.eq(journal.touches(3, 0, 959), false, 'a span short of it misses')
      t.eq(journal.touches(3, 961, 3840), false, 'as does one past it')

      -- Sixteen positions, so the seek has to land rather than stumble onto the answer.
      journal.add(5, seedList(16))
      t.eq(journal.touches(5, 7, 7), true, 'a point span on a middle seed')
      t.eq(journal.touches(5, 17, 100), false, 'clear of the last')
      t.eq(journal.touches(5, -10, 0), false, 'and clear of the first')

      journal.add(4, true)
      t.eq(journal.touches(4, 0, 1), true, 'wholesale touches every span')
    end,
  },
  {
    -- A live seed is minted before mm stamps its uuid and filed after, so `add` resolves the uuid
    -- off the record the seed kept. What the journal holds then names its own identities.
    name = 'dirt: filing a live seed resolves its uuid off the record it kept',
    run = function()
      local journal = dirt.new()
      local evt = { chan = 1, ppq = 960, evType = 'note' }
      local live = journal.liveSeed(evt, 'add')
      t.eq(live.uuid, nil, 'the mint found no uuid on the record')

      evt.uuid = 'stamped-at-commit'   -- the commit stamps it; the flush files the seed after
      journal.add(1, live)
      t.eq(live.uuid, 'stamped-at-commit', 'filing resolved the uuid onto the seed')
    end,
  },
  {
    name = 'dirt: an answer stands only until the next write',
    run = function()
      local journal = dirt.new()
      journal.add(6, seed(480))
      t.deepEq(journal.ppqs(6), { 480 }, 'one seed, one position')
      t.eq(journal.touches(6, 900, 1000), false, 'nothing out there yet')

      journal.add(6, seed(960))   -- the rebuild's own mid-pass seeds arrive like this
      t.deepEq(journal.ppqs(6), { 480, 960 }, 'the later seed joins the answer')
      t.eq(journal.touches(6, 900, 1000), true, 'and the span question is asked afresh')
      t.eq(journal.covers(6, 960), true, 'as is membership')

      journal.clear()
      journal.add(6, seed(120))
      t.deepEq(journal.ppqs(6), { 120 }, 'a consumed journal keeps nothing of its old answer')
    end,
  },
  {
    -- A park spec is logical throughout, so the seed's row is the spec's own ppq. The raw seat is
    -- the caller's to project: the journal holds no time context, and the two sides of the split
    -- reach the pass's projection by different handles.
    name = 'dirt: a park seed reads the spec as logical and takes its raw seat from the caller',
    run = function()
      local journal = dirt.new()
      local spec = { uuid = 'u1', chan = 3, ppq = 960, endppq = 1920, lane = 2, pitch = 60 }

      local minted = journal.parkSeed(spec, 'park', 1010)

      t.eq(minted.ppqL, 960, "the spec's position is the logical row")
      t.eq(minted.ppq, 1010, 'and the raw seat is the one the caller projected')
      t.eq(minted.endppqL, 1920, 'the authored end is logical too')
      t.eq(minted.verb, 'park', 'the verb that minted it rides')
      t.eq(minted.uuid, 'u1', 'as does the identity it names')
    end,
  },
  {
    -- A raw seed comes off an mm record, which is raw with its logical row in a sidecar. A record
    -- written under no swing carries no sidecar, and then the raw position is the row.
    name = 'dirt: a raw seed keeps the mm sidecar row, falling back to the raw position',
    run = function()
      local journal = dirt.new()

      local swung = journal.rawSeed({ uuid = 'u2', chan = 1, ppq = 1010, ppqL = 960,
                                      evType = 'cc', cc = 74 }, 'park')
      t.eq(swung.ppq, 1010, 'the raw position rides')
      t.eq(swung.ppqL, 960, 'and the sidecar is the logical row')
      t.eq(swung.cc, 74, 'the cc number discriminates the column')

      local unswung = journal.rawSeed({ uuid = 'u3', ppq = 480, evType = 'pb' }, 'delete')
      t.eq(unswung.ppqL, 480, 'no sidecar, so the raw position stands for the row')
    end,
  },
  {
    -- The stager's seeds are born before mm commits, so a fresh add has no uuid to name yet. A live
    -- seed keeps the record itself and reads the uuid off it late; a raw seed, minted for an event
    -- the pass is deleting, keeps none.
    name = 'dirt: a live seed carries its record, so a uuid stamped at commit reads back off it',
    run = function()
      local journal = dirt.new()
      local evt = { chan = 1, ppq = 480, evType = 'note', pitch = 64, lane = 1 }

      local minted = journal.liveSeed(evt, 'add')
      t.eq(minted.uuid, nil, 'nothing to name at birth')

      evt.uuid = 'stamped-at-commit'
      t.eq(minted.evt.uuid, 'stamped-at-commit', 'the seed reads the uuid off the record it kept')
      t.eq(minted.ppq, 480, 'the snapshotted position is the birth one, record or no record')

      t.eq(journal.rawSeed(evt, 'delete').evt, nil, 'a raw seed keeps no record')
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
