-- regions.lua — pure helpers for region storage.
--
-- A region is one contiguous logical-ppq slab intersected with a sparse
-- set of column-parts:
--
--   region = { id, colour, ppqLo, ppqHi, parts = { [colKey] = true, ... } }
--
-- colKey shape:
--   note: "note:chan:lane:part"   part ∈ {pitch, vel, delay}
--   cc:   "cc:chan:cc"
--   pb:   "pb:chan"
--   pc:   "pc:chan"
--   at:   "at:chan"
--
-- Only notes carry a :part suffix — the other column types have a single
-- implicit part each.
--
-- ppq ranges are logical (pre-swing), half-open [ppqLo, ppqHi).

local util = require('util')

local M = {}

----- colKey

function M.colKey(col, partName)
  local t = col.type
  if t == 'note' then
    return string.format('note:%d:%d:%s', col.midiChan, col.lane, partName)
  elseif t == 'cc' then
    return string.format('cc:%d:%d', col.midiChan, col.cc)
  elseif t == 'pb' or t == 'pc' or t == 'at' then
    return string.format('%s:%d', t, col.midiChan)
  end
  error('regions.colKey: unknown col.type ' .. tostring(t))
end

function M.parseColKey(key)
  local parts = {}
  for s in key:gmatch('[^:]+') do parts[#parts+1] = s end
  local t = parts[1]
  if t == 'note' then
    return { type='note', chan=tonumber(parts[2]), lane=tonumber(parts[3]), part=parts[4] }
  elseif t == 'cc' then
    return { type='cc', chan=tonumber(parts[2]), cc=tonumber(parts[3]) }
  elseif t == 'pb' or t == 'pc' or t == 'at' then
    return { type=t, chan=tonumber(parts[2]) }
  end
  error('regions.parseColKey: unknown key ' .. tostring(key))
end

----- Parts set ops

function M.partsUnion(a, b)
  local out = {}
  for k in pairs(a) do out[k] = true end
  for k in pairs(b) do out[k] = true end
  return out
end

function M.partsDifference(a, b)
  local out = {}
  for k in pairs(a) do if not b[k] then out[k] = true end end
  return out
end

function M.partsCopy(p)
  return util.deepClone(p)
end

function M.partsIsEmpty(p)
  return next(p) == nil
end

function M.partsCount(p)
  local n = 0
  for _ in pairs(p) do n = n + 1 end
  return n
end

----- Region predicates and seed

function M.containsCell(region, key, ppq)
  return region.parts[key] ~= nil
     and ppq >= region.ppqLo
     and ppq <  region.ppqHi
end

function M.seed(ppqLo, ppqHi, parts)
  return { ppqLo = ppqLo, ppqHi = ppqHi, parts = M.partsCopy(parts) }
end

return M
