-- The derivation journal: which channels a rebuild must re-derive, and how much of each.
-- see docs/trackerManager.md § Derivation dirt: the gated spine

--invariant: entry is a lattice -- clean < seed list < wholesale; add raises it, never lowers
--invariant: a list grown past the seed cap collapses to wholesale, bounding per-seed work
--invariant: swing staleness is the second axis: bindTake marks a reseat carrying no dirt of its own
--shape: entry = nil (clean) | list of birth-snapshot seeds (parkSeed/rawSeed/liveSeed) | true (wholesale)
--shape: seed = { uuid, verb, ppq, ppqL, lane, pitch, endppqL, evType, cc, evt, laterPpqs }; evt is the record the seed was minted from, laterPpqs the logical positions its uuid took after the snapshot

local dirt = {}

-- Past this many distinct seeds, a whole-channel re-derive beats per-seed bookkeeping; the entry
-- collapses to the wholesale sentinel. Was intervals.merge's MAX. see design § Retirement of intervals
local WHOLESALE_SEED_CAP = 64

local SEED_FAMILY = { note = 'note', pa = 'note', cc = 'cc', at = 'cc', pc = 'cc', pb = 'pb' }

----- Seeds

-- A birth snapshot of the event a verb disturbed, minted where the disturbance happens and read by
-- the gated stages. see docs/trackerManager.md § Interval seeds

--pre: ppq is spec.ppq projected into the raw frame -- the journal holds no time context
local function parkSeed(spec, verb, ppq)
  return { uuid = spec.uuid, verb = verb, ppq = ppq, evType = spec.evType,
           ppqL = spec.ppq, lane = spec.lane, pitch = spec.pitch, endppqL = spec.endppq }
end

--post: fresh result.ppqL = evt.ppqL, or evt.ppq where the record carries no logical sidecar
local function rawSeed(evt, verb)
  return { uuid = evt.uuid, verb = verb, ppq = evt.ppq, ppqL = evt.ppqL or evt.ppq,
           evType = evt.evType, cc = evt.cc,
           lane = evt.lane, pitch = evt.pitch, endppqL = evt.endppqL }
end

--post: result.evt aliases evt, so a uuid stamped on it after the mint reads back off the seed
local function liveSeed(evt, verb)
  local seed = rawSeed(evt, verb)
  seed.evt = evt
  return seed
end

--contract: one journal per trackerManager: its edit side and its rebuild share the one instance
function dirt.new()
  local marks, swing, foreign, tails = {}, {}, {}, {}
  local memo = {}
  local journal = {}

  --contract: d is true, one seed, or a list of seeds; chan nil adds to all 16
  --contract: the sole write -- standing wholesale absorbs, and a grown list collapses at the cap
  function journal.add(chan, d)
    if not chan then
      for i = 1, 16 do journal.add(i, d) end
      return
    end
    local standing = marks[chan]
    if standing == true then return end
    memo[chan] = nil   -- past here the write changes what the channel names
    if d == true then marks[chan] = true; return end
    -- A birth snapshot carries the verb that minted it; a list of them does not.
    local incoming = d.verb and { d } or d
    if #incoming == 0 then return end   -- an empty batch leaves a clean channel clean
    if standing == nil then standing = {}; marks[chan] = standing end
    -- A live seed reads its uuid off the record it kept, and filing is past the commit that stamps
    -- it: resolve it here, and what the journal holds names its own identities.
    for _, seed in ipairs(incoming) do
      seed.uuid = seed.uuid or (seed.evt and seed.evt.uuid)
      standing[#standing + 1] = seed
    end
    if #standing > WHOLESALE_SEED_CAP then marks[chan] = true end
  end

  --contract: the channel's entry, so a gate reads it as a truth test and a stage as its seed list
  function journal.has(chan)       return marks[chan] end
  function journal.wholesale(chan) return marks[chan] == true end

  ----- What the seeds name

  -- Hold a logical position on a bucket of them, distinct: the seats a fold carried onto a seed
  -- join the snapshot's own. The bucket sorts once it is closed.
  local function hold(bucket, ppq)
    if ppq ~= nil and not bucket.seen[ppq] then
      bucket.seen[ppq] = true
      bucket.ppqs[#bucket.ppqs + 1] = ppq
    end
  end

  -- What a channel's seeds name, held until the next write to it drops the lot: a row bucket per
  -- family, and the cc family's cells.
  local function memoFor(chan)
    local held = memo[chan]
    if not held then held = { families = {} }; memo[chan] = held end
    return held
  end

  -- The logical positions a channel's seeds name, scoped to one stage's family (nil: every family):
  -- each snapshot's ppqL plus those the flush folded onto it, distinct and sorted; memoized per
  -- family until the next write invalidates the channel's whole memo.
  local function seeded(chan, family)
    family = family or 'all'
    local byFamily = memoFor(chan).families
    local held = byFamily[family]
    if held then return held end
    held = { ppqs = {}, seen = {} }
    for _, seed in ipairs(marks[chan]) do
      -- A seed naming no event type names no family restriction: a region is a span over whatever
      -- sits inside it. Erring wide costs a re-place; erring narrow renders stale (§ Note-lane renewal).
      local seedFamily = SEED_FAMILY[seed.evType]
      if family == 'all' or seedFamily == nil or seedFamily == family then
        hold(held, seed.ppqL)
        for _, later in ipairs(seed.laterPpqs or {}) do hold(held, later) end
      end
    end
    table.sort(held.ppqs)
    byFamily[family] = held
    return held
  end

  -- The cc family's seeds bucketed by the column each names -- its cc number, or its evType where
  -- it has none, at and pc carrying one stream apiece. Rows folded and sorted as seeded's are.
  local function ccCells(chan)
    local memoized = memoFor(chan)
    if memoized.cells then return memoized.cells end
    local cells = {}
    for _, seed in ipairs(marks[chan]) do
      -- A seed naming no evType names no column either, so it reaches no cell: a region trigger's
      -- real cc dirt is the fx walk's own emitted seeds, and erring wide here means seeking every
      -- column the channel carries -- the O(channel) pass the cell exists to retire.
      if SEED_FAMILY[seed.evType] == 'cc' then
        local column = seed.cc or seed.evType
        local cell = cells[column]
        if not cell then cell = { evType = seed.evType, cc = seed.cc, ppqs = {}, seen = {} }; cells[column] = cell end
        hold(cell, seed.ppqL)
        for _, later in ipairs(seed.laterPpqs or {}) do hold(cell, later) end
      end
    end
    for _, cell in pairs(cells) do
      table.sort(cell.ppqs)
      cell.seen = nil   -- closed: the cell is an answer now, not a bucket to hold onto
    end
    memoized.cells = cells
    return cells
  end

  --pre: the channel holds a seed list -- wholesale names no positions, and a clean one holds none
  --contract: family scopes to one stage's own seeds ('note' / 'cc' / 'pb'); nil answers every family
  --contract: the answer has the shape of what that family names, and the caller reads, never writes.
  --  note and pb name rows: those positions sorted, for a stage that seeks to each. cc names columns
  --  of rows -- a channel can hold 130 of them, so its stage excises and refills one at a time and
  --  asks by column where the note lane asks by row.
  --shape: result = sorted ppqs | cells keyed by cc number or evType, cell = { evType, cc, ppqs }
  function journal.ppqs(chan, family)
    if family == 'cc' then return ccCells(chan) end
    return seeded(chan, family).ppqs
  end

  --contract: is this logical position seeded -- wholesale covers every one, a clean channel none
  --contract: family as ppqs -- an excise and the refill gating it must scope alike, or the pair
  --  either strands an event the excise dropped or doubles one it left standing
  function journal.covers(chan, ppq, family)
    local standing = marks[chan]
    if standing == nil then return false end
    if standing == true then return true end
    return seeded(chan, family).seen[ppq] == true
  end

  --contract: is any seeded position inside this logical span, both edges included
  function journal.touches(chan, startPpq, endPpq)
    local standing = marks[chan]
    if standing == nil then return false end
    if standing == true then return true end
    local list = seeded(chan).ppqs
    local lo, hi = 1, #list + 1
    while lo < hi do
      local mid = (lo + hi) // 2
      if list[mid] < startPpq then lo = mid + 1 else hi = mid end
    end
    return list[lo] ~= nil and list[lo] <= endPpq
  end

  --contract: either axis holds something -- the rebuild(∅) gate
  function journal.pending() return next(marks) ~= nil or next(swing) ~= nil end

  --contract: the channels the dirt holds, for the caller's mute-conform sweep
  function journal.byChannel()
    local isDirty = {}
    for chan in pairs(marks) do isDirty[chan] = true end
    return isDirty
  end

  function journal.clear()
    marks, memo = {}, {}
  end

  -- The minters ride the journal, so holding the journal is the whole of holding the dirt.
  journal.parkSeed, journal.rawSeed, journal.liveSeed = parkSeed, rawSeed, liveSeed

  journal.swing = {
    --contract: chan nil marks all 16
    add   = function(chan)
      if chan then swing[chan] = true; return end
      for i = 1, 16 do swing[i] = true end
    end,
    has   = function(chan) return swing[chan] == true end,
    --contract: the mid-pipeline clear, once the partition and the cc walk have consumed it
    clear = function() swing = {} end,
  }

  -- The lane pass's news for the tail walk: the uuids whose lane bound it moved, over both its
  -- runs. Outside the lattice deliberately -- a moved bound names no position, so it is no reason
  -- to re-derive anything, and a bulk move (a take-length change, a region park) must not escalate
  -- its channel to wholesale. see docs/trackerManager.md § The lane pass
  journal.tails = {
    add   = function(chan, uuid)
      local named = tails[chan]
      if not named then named = {}; tails[chan] = named end
      named[#named + 1] = uuid
    end,
    --contract: the channel's uuid list, nil where the pass moved no bound on it
    has   = function(chan) return tails[chan] end,
    --contract: cleared at the head of the lane pass, the one stage that writes it
    clear = function() tails = {} end,
  }

  -- Provenance, not arithmetic: raw that moved with no seed of ours behind it. Only on a channel
  -- marked here may a record's raw outrank its own logical stamp.
  journal.foreign = {
    --contract: chan nil marks all 16
    add   = function(chan)
      if chan then foreign[chan] = true; return end
      for i = 1, 16 do foreign[i] = true end
    end,
    has   = function(chan) return foreign[chan] == true end,
    --contract: the mid-pipeline clear, alongside swing's -- the same stages consume both
    clear = function() foreign = {} end,
  }

  return journal
end

return dirt
