-- See design/interval-dirt.md for the model.
-- @noindex

--invariant: pure, stateless; a set is `true` (whole chan) or a ppq-ascending, non-overlapping list
--shape: interval = { loPpq, hiPpq: number; loUuid, hiUuid: string? } -- nil uuid edge = open toward channel start/end
local util = require 'util'

local intervals = {}

-- Past this many disjoint intervals, one whole-channel re-derive beats the bookkeeping.
local MAX = 64

----- Construction

function intervals.seed(loPpq, hiPpq, loUuid, hiUuid)
  if loPpq > hiPpq then
    loPpq, hiPpq = hiPpq, loPpq
    loUuid, hiUuid = hiUuid, loUuid
  end
  return { loPpq = loPpq, hiPpq = hiPpq, loUuid = loUuid, hiUuid = hiUuid }
end

--contract: coalesces edge-inclusive touching/overlapping intervals; returns `true` past MAX; input not mutated
function intervals.merge(set)
  if set == true then return true end
  if #set <= 1 then return set end

  local sorted = {}
  for _, iv in ipairs(set) do util.add(sorted, iv) end
  table.sort(sorted, function(a, b) return a.loPpq < b.loPpq end)

  local out = {}
  local cur
  for _, iv in ipairs(sorted) do
    if cur and iv.loPpq <= cur.hiPpq then
      if iv.hiPpq > cur.hiPpq then
        cur.hiPpq, cur.hiUuid = iv.hiPpq, iv.hiUuid
      end
    else
      cur = { loPpq = iv.loPpq, hiPpq = iv.hiPpq, loUuid = iv.loUuid, hiUuid = iv.hiUuid }
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
    if iv.loPpq <= hi and iv.hiPpq >= lo then return true end
  end
  return false
end

----- Reload fold

-- Reload fold: a seeded chan narrows to the merge of its seeds; an unseeded payload chan
-- (mm-internal writes -- dedup, collision backstop) still folds whole. See design/interval-dirt.md § phase 2.
--contract: mutates+returns dirt; seeded chan -> merge(seeds[chan]), unseeded payload chan -> true
function intervals.absorbSeeds(dirt, seeds, payloadChans)
  for chan, list in pairs(seeds) do
    dirt[chan] = intervals.merge(list)
  end
  for chan in pairs(payloadChans) do
    if not seeds[chan] then dirt[chan] = true end
  end
  return dirt
end

return intervals
