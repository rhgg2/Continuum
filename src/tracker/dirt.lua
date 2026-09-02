-- The derivation journal: which channels a rebuild must re-derive, and how much of each.
-- see docs/trackerManager.md § Derivation dirt: the gated spine

--invariant: entry is a lattice -- clean < seed list < wholesale; add raises it, never lowers
--invariant: a list grown past the seed cap collapses to wholesale, bounding per-seed work
--invariant: swing staleness is the second axis: bindTake marks a reseat carrying no dirt of its own
--shape: entry = nil (clean) | list of birth-snapshot seeds (parkSeed/rawSeed/liveSeed) | true (wholesale)
--shape: seed = { uuid, verb, ppq, ppqL, lane, pitch, endppqL, evType, cc, evt }; evt is the record the seed was minted from

local dirt = {}

-- Past this many distinct seeds, a whole-channel re-derive beats per-seed bookkeeping; the entry
-- collapses to the wholesale sentinel. Was intervals.merge's MAX. see design § Retirement of intervals
local WHOLESALE_SEED_CAP = 64

----- Seeds

-- A birth snapshot of the event a verb disturbed, minted where the disturbance happens and read by
-- the gated stages. see docs/trackerManager.md § Interval seeds

--pre: ppq is spec.ppq projected into the raw frame -- the journal holds no time context
local function parkSeed(spec, verb, ppq)
  return { uuid = spec.uuid, verb = verb, ppq = ppq,
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
  local marks, swing = {}, {}
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
    if d == true then marks[chan] = true; return end
    -- A birth snapshot carries the verb that minted it; a list of them does not.
    local incoming = d.verb and { d } or d
    if #incoming == 0 then return end   -- an empty batch leaves a clean channel clean
    if standing == nil then standing = {}; marks[chan] = standing end
    for _, seed in ipairs(incoming) do standing[#standing + 1] = seed end
    if #standing > WHOLESALE_SEED_CAP then marks[chan] = true end
  end

  --contract: the channel's entry, so a gate reads it as a truth test and a stage as its seed list
  function journal.has(chan)       return marks[chan] end
  function journal.wholesale(chan) return marks[chan] == true end

  --contract: either axis holds something -- the rebuild(∅) gate
  function journal.pending() return next(marks) ~= nil or next(swing) ~= nil end

  --contract: consumes the dirt, returning the channels it held for the caller's mute-conform sweep
  function journal.clear()
    local consumed = {}
    for chan in pairs(marks) do consumed[chan] = true end
    marks = {}
    return consumed
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

  return journal
end

return dirt
