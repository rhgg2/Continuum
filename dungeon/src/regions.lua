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

local util    = require('util')
local aliases = require('aliases')

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
    return { evType='note', chan=tonumber(parts[2]), lane=tonumber(parts[3]), part=parts[4] }
  elseif t == 'cc' then
    return { evType='cc', chan=tonumber(parts[2]), cc=tonumber(parts[3]) }
  elseif t == 'pb' or t == 'pc' or t == 'at' then
    return { evType=t, chan=tonumber(parts[2]) }
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

----- Template & xform (a region with template events is a block).

--contract: allocates a fresh base36 vuid on region.template; initialises template/eventCtr lazily. Returned vuid is stable across rebuilds and save/load.
function M.allocVuid(region)
  region.template = region.template or { events = {}, eventCtr = 0 }
  region.template.eventCtr = (region.template.eventCtr or 0) + 1
  return util.toBase36(region.template.eventCtr)
 end

--contract: appends `op` into region.xform[slotKey][field] via aliases.appendOp; lazily initialises region.xform and the slot. slotKey is '*' (geometric, all template events) or a colKey (content, only events on that col).
function M.composeOp(region, slotKey, field, op)
  region.xform = region.xform or {}
  region.xform[slotKey] =
    aliases.appendOp(region.xform[slotKey] or aliases.emptyXform(), field, op)
end

--contract: predicate for the command-surface refusal of block-wide val shifts across heterogeneous columns. True iff slotKey is '*' AND field is 'val' — nonsense across CCs and pitchbend.
function M.refuseStarVal(slotKey, field)
  return slotKey == '*' and field == 'val'
end

--contract: composes xformStar then xformCol onto templateEvent via per-field op-list concatenation, then applies through aliases.applyXform. Either xform may be nil (treated as empty). Cross-event-type fail-closed comes from applyXform.
function M.resolveEvent(templateEvent, xformStar, xformCol, evtType, rng)
  local merged = {}
  local function mergeIn(src)
    if not src then return end
    for field, ops in pairs(src) do
      local list = merged[field] or {}
      for _, op in ipairs(ops) do list[#list+1] = op end
      merged[field] = list
    end
  end
  mergeIn(xformStar)
  mergeIn(xformCol)
  return aliases.applyXform(templateEvent, merged, evtType, rng)
end

--contract: resolves a (region, vuid) synthetic root to its emit-time field set. Synthesises base from template[vuid] (drops `col` and `spec`), shifts ppqL by region.ppqLo, hydrates evType/chan plus lane (note) or cc (cc) from the colKey, composes region.xform['*'] then region.xform[te.col] via resolveEvent, then te.spec.xform if present. For notes, derives endppqL = ppqL + durL after composition. Frame-dependent ppq/endppq are NOT computed here — caller (tm) supplies swing. Raises if no template event for vuid.
function M.resolveSyntheticRoot(region, vuid, rng)
  local te = region.template and region.template.events and region.template.events[vuid]
  if not te then
    error('regions.resolveSyntheticRoot: no template event for vuid ' .. tostring(vuid))
  end
  local meta = M.parseColKey(te.col)
  local et   = (meta.evType == 'note') and 'note' or 'cc'
  local base = util.clone(te, { col = true, spec = true })
  base.ppqL   = (region.ppqLo or 0) + (base.ppqL or 0)
  base.evType = meta.evType
  base.chan   = meta.chan
  if meta.evType == 'note' then
    base.lane = meta.lane
  elseif meta.evType == 'cc' then
    base.cc = meta.cc
  end
  local xform    = region.xform or {}
  local resolved = M.resolveEvent(base, xform['*'], xform[te.col], et, rng)
  if te.spec and te.spec.xform then
    resolved = aliases.applyXform(resolved, te.spec.xform, et, rng)
  end
  if meta.evType == 'note' then
    resolved.endppqL = resolved.ppqL + (resolved.durL or 0)
  end
  return resolved
end

return M
