-- The derivation journal: which channels a rebuild must re-derive, and how much of each.
-- see docs/trackerManager.md § Derivation dirt: the gated spine

--invariant: entry is a lattice -- clean < seed list < wholesale; add raises it, never lowers
--invariant: a list grown past the seed cap collapses to wholesale, bounding per-seed work
--invariant: swing staleness is the second axis: bindTake marks a reseat carrying no dirt of its own
--invariant: fx-host staleness is the third axis: a restore seats a host before the index knows it
--shape: entry = nil (clean) | list of birth-snapshot seeds (see trackerManager seeds) | true (wholesale)

local dirt = {}

-- Past this many distinct seeds, a whole-channel re-derive beats per-seed bookkeeping; the entry
-- collapses to the wholesale sentinel. Was intervals.merge's MAX. see design § Retirement of intervals
local WHOLESALE_SEED_CAP = 64

--contract: one journal per trackerManager: its edit side and its rebuild share the one instance
function dirt.new()
  local marks, swing, staleHosts = {}, {}, {}
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

  -- A restored fx host sits in its column before the stamp lands, so the fx-host index can neither
  -- enumerate nor resolve it. Minted only inside a rebuild, hence no part of pending().
  journal.staleHosts = {
    add   = function(chan) staleHosts[chan] = true end,
    has   = function(chan) return staleHosts[chan] == true end,
    --contract: the mid-pipeline clear, once the park stage's commit has stamped the restored cells
    clear = function() staleHosts = {} end,
  }

  return journal
end

return dirt
