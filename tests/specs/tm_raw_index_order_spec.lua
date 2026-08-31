-- tm's rawIndex holds one raw-then-logical-sorted list per channel per type, and the tail walk reads
-- those lists in order to find each note's same-pitch successor -- so a misplaced entry mis-clips a
-- tail. The index is maintained two ways: built in bulk at load (sort per list), patched per-event by
-- the add/assign verbs. Only the bulk path is self-evidently ordered. These cases pin the two against
-- each other -- whatever tm derives from a freshly-loaded index, the patched index must derive
-- identically -- so the verbs stay free to reseat by any means that preserves the order.
--
-- The index is written during a rebuild too, not just by the verbs: the tail walk's settleOnset
-- nudges a colliding note forward through setRaw, which re-trues the containing list because ppq is
-- a sort key. Nothing enforces that at runtime, so the last two cases are the backstop -- one catches
-- a binary-seek reader answering from the stale order, one pins every entry's ppq against mm's.

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

-- pbRange default = 2 semitones = 200 cents total.
local function cents2raw(c) return math.floor(c * 8192 / 200 + 0.5) end

local function pbsAt(dump, ppq)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'pb' and c.ppq == ppq then out[#out + 1] = c end
  end
  return out
end

-- The nudge fixture. Three lane-1 notes on chan 1: the mover is edited onto the blocker's raw, they
-- share a pitch and differ in ppqL (so voicing separates rather than dedupes), and the walk gives the
-- mover way by one tick -- onto the neighbour's raw, where its later ppqL puts it last in
-- raw-then-logical order. It moves in value without moving in slot, which is the whole stain.
--
-- Built by edit, not by seed: mm's load dedup runs voicing itself, so a seeded same-raw pair arrives
-- already separated and the walk never nudges (tests/specs/mm_load_dedup_spec.lua).
local BLOCKER_PPQ, NEIGHBOUR_PPQ, MOVER_PPQ = 300, 301, 360
local MOVER_DETUNE, NEIGHBOUR_DETUNE = 40, -30
-- Signed milli-QN: -250 is -60 ppq at res 240, carrying the mover's raw back onto the blocker.
local MOVER_DELAY = -250

local function nudgedOntoNeighbour(harness)
  local function laneOneNote(ppq, endppq, pitch, detune)
    return { evType = 'note', ppq = ppq, endppq = endppq, ppqL = ppq, endppqL = endppq,
             chan = 1, pitch = pitch, vel = 100, detune = detune, delay = 0, lane = 1 }
  end
  local h = harness.mk{ seed = { notes = {
    laneOneNote(BLOCKER_PPQ,   320, 60, 0),
    laneOneNote(NEIGHBOUR_PPQ, 320, 72, NEIGHBOUR_DETUNE),
    laneOneNote(MOVER_PPQ,     380, 60, MOVER_DETUNE),
  } } }

  -- A delay edit, not a ppq edit: assignEvent's ppq arrives logical and restamps ppqL with it, which
  -- would move the mover onto the blocker's seat as well as its raw. Delay moves the raw alone.
  local moverUuid = uuidAtOnset(h.fm, MOVER_PPQ)
  h.tm:assignEvent({ uuid = moverUuid }, { delay = MOVER_DELAY })
  h.tm:flush()
  return h, moverUuid
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

  {
    name = 'a nudged note re-trues its list: the detune seek answers it, not the note it passed',
    run = function(harness)
      local h, moverUuid = nudgedOntoNeighbour(harness)

      t.eq(h.tm:byUuid(moverUuid).ppq, NEIGHBOUR_PPQ,
        'the walk nudged the mover off the blocker -- nothing else stains the list')

      -- At raw 301 the mover sorts last (ppqL 360 against the neighbour's 301), so it is the
      -- prevailing lane-1 detune there. A list left stale by the nudge still reads the mover in its
      -- old slot, ahead of 301, and the seek answers the neighbour instead.
      local seats = pbsAt(h.fm:dump(), NEIGHBOUR_PPQ)
      t.eq(#seats, 1, 'one absorber seat at the nudged onset')
      t.eq(seats[1].val, cents2raw(MOVER_DETUNE), 'the seat absorbs the mover\'s detune')
    end,
  },

  {
    name = 'every index entry agrees with mm on ppq after a nudging rebuild',
    run = function(harness)
      local h, moverUuid = nudgedOntoNeighbour(harness)

      -- settleOnset stages its own mm write beside the setRaw, so the two frames must not drift.
      local moverPpq
      for _, n in ipairs(h.fm:dump().notes) do
        local entry = h.tm:byUuid(n.uuid)
        t.truthy(entry, 'mm note ' .. n.uuid .. ' has an index entry')
        t.eq(entry.ppq, n.ppq, 'index and mm agree on the raw onset of note ' .. n.uuid)
        if n.uuid == moverUuid then moverPpq = n.ppq end
      end

      t.eq(moverPpq, NEIGHBOUR_PPQ,
        'a note actually moved -- the agreement above holds vacuously otherwise')
    end,
  },
}
