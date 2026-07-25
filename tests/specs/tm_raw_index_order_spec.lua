-- tm's rawIndex holds one rawThenLogical-sorted list per channel per type, and the tail walk reads
-- those lists in order to find each note's same-pitch successor -- so a misplaced entry mis-clips a
-- tail. The index is maintained two ways: built in bulk at load (sort per list), patched per-event by
-- the add/assign verbs. Only the bulk path is self-evidently ordered. These cases pin the two against
-- each other -- whatever tm derives from a freshly-loaded index, the patched index must derive
-- identically -- so the verbs stay free to reseat by any means that preserves the order.

local t = require('support')

-- Same pitch, overlapping authored tails: the walk clips each note at its successor's onset, which
-- reads the raw order back out as data. Distinct onsets, so none of these is a collision kill.
local ONSETS = { 0, 240, 480, 720 }

local function longNote(ppq)
  return { evType = 'note', ppq = ppq, endppq = 1920, chan = 1, pitch = 60,
           vel = 100, detune = 0, delay = 0, lane = 1 }
end

local function uuidAtOnset(mm, ppq)
  for _, n in mm:notes() do
    if n.chan == 1 and n.ppq == ppq then return n.uuid end
  end
end

-- (onset, clipped end) per chan-1 note, onset-ordered: the walk's verdict, and order-sensitive.
local function clips(h)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do
    if n.chan == 1 then out[#out + 1] = { ppq = n.ppq, endppq = n.endppq } end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

-- The bulk control: seeded straight through mm, so tm builds the whole index at load.
local function seeded(harness, onsets)
  local notes = {}
  for _, ppq in ipairs(onsets) do notes[#notes + 1] = longNote(ppq) end
  return harness.mk{ seed = { notes = notes } }
end

return {
  {
    name = 'notes added out of onset order clip as if the index were built in bulk',
    run = function(harness)
      local expected = clips(seeded(harness, ONSETS))
      t.eq(#expected, #ONSETS, 'control keeps every note (no collision kills)')
      t.truthy(expected[1].endppq < 1920,
        'control actually clips a tail -- otherwise the comparison below passes vacuously')

      local h = harness.mk()
      -- Descending, one flush each: every add lands ahead of entries already in the list, so a
      -- reseat that seeks the wrong slot surfaces as a mis-clipped tail.
      for i = #ONSETS, 1, -1 do
        h.tm:addEvent(longNote(ONSETS[i])); h.tm:flush()
      end

      t.deepEq(clips(h), expected, 'incremental adds leave the same clipped tails as a bulk load')
    end,
  },

  {
    name = 'a note moved across its neighbours clips as if the index were built in bulk',
    run = function(harness)
      local expected = clips(seeded(harness, { 240, 480, 720, 960 }))

      -- Same set, then move the first note past all three others: a same-list reseat, where the
      -- entry has to leave its slot and land at the far end of the list.
      local h = seeded(harness, ONSETS)
      h.tm:assignEvent({ uuid = uuidAtOnset(h.fm, 0) }, { ppq = 960, ppqL = 960, endppq = 1920 })
      h.tm:flush()

      t.deepEq(clips(h), expected, 'the moved entry reseats where a full re-sort would put it')
    end,
  },
}
