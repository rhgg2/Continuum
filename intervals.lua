-- See design/interval-dirt.md for the model.
-- @noindex

--invariant: pure module: no state; a set is `true` (whole channel) or a ppqL-ascending, non-overlapping list
--shape: interval = { loPpqL, hiPpqL: number; loUuid, hiUuid: string? } -- nil uuid edge = open toward channel start/end
local util = require 'util'

local intervals = {}

-- Past this many disjoint intervals, one whole-channel re-derive beats the bookkeeping.
local MAX = 64

----- Construction

function intervals.seed(loPpqL, hiPpqL, loUuid, hiUuid)
  if loPpqL > hiPpqL then
    loPpqL, hiPpqL = hiPpqL, loPpqL
    loUuid, hiUuid = hiUuid, loUuid
  end
  return { loPpqL = loPpqL, hiPpqL = hiPpqL, loUuid = loUuid, hiUuid = hiUuid }
end

--contract: coalesces edge-inclusive touching/overlapping intervals; returns `true` past MAX; input not mutated
function intervals.merge(set)
  if set == true then return true end
  if #set <= 1 then return set end

  local sorted = {}
  for _, iv in ipairs(set) do util.add(sorted, iv) end
  table.sort(sorted, function(a, b) return a.loPpqL < b.loPpqL end)

  local out = {}
  local cur
  for _, iv in ipairs(sorted) do
    if cur and iv.loPpqL <= cur.hiPpqL then
      if iv.hiPpqL > cur.hiPpqL then
        cur.hiPpqL, cur.hiUuid = iv.hiPpqL, iv.hiUuid
      end
    else
      cur = { loPpqL = iv.loPpqL, hiPpqL = iv.hiPpqL, loUuid = iv.loUuid, hiUuid = iv.hiUuid }
      util.add(out, cur)
    end
  end

  if #out > MAX then return true end
  return out
end

----- Queries

--contract: edge-inclusive overlap of [lo, hi] against any interval; `true` set always intersects
function intervals.intersects(set, lo, hi)
  if set == true then return true end
  for _, iv in ipairs(set) do
    if iv.loPpqL <= hi and iv.hiPpqL >= lo then return true end
  end
  return false
end

----- Closure

-- Widen each seed to its stage's anchoring onsets: forward to the next in-group onset (all stages),
-- and back to the previous in-group onset when opts.stepBack (tails only). See design § The crux.
-- Does not mutate set: each stage closes the same merged seed set against its own ordering.
--contract: opts = { key = fn(e)->groupKey|nil, stepBack: bool }; events in the stage's consumption order
function intervals.close(set, sortedEvents, opts)
  if set == true then return true end

  local groups = {}
  for _, e in ipairs(sortedEvents) do
    local k = opts.key(e)
    if k ~= nil then util.bucket(groups, k, e) end
  end

  local closed = {}
  for _, iv in ipairs(set) do
    local loPpqL, hiPpqL = iv.loPpqL, iv.hiPpqL
    local loUuid, hiUuid = iv.loUuid, iv.hiUuid
    for _, g in pairs(groups) do
      local firstInside, lastInside
      for i, e in ipairs(g) do
        if e.ppqL >= iv.loPpqL and e.ppqL <= iv.hiPpqL then
          firstInside = firstInside or i
          lastInside = i
        end
      end
      if firstInside then
        if opts.stepBack then
          local prev = g[firstInside - 1]
          if not prev then
            loPpqL, loUuid = -math.huge, nil
          elseif prev.ppqL < loPpqL then
            loPpqL, loUuid = prev.ppqL, prev.uuid
          end
        end
        local nxt = g[lastInside + 1]
        if not nxt then
          hiPpqL, hiUuid = math.huge, nil
        elseif nxt.ppqL > hiPpqL then
          hiPpqL, hiUuid = nxt.ppqL, nxt.uuid
        end
      end
    end
    util.add(closed, { loPpqL = loPpqL, hiPpqL = hiPpqL, loUuid = loUuid, hiUuid = hiUuid })
  end

  return intervals.merge(closed)
end

return intervals
