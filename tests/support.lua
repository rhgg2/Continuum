-- Tiny assertion helpers. Hand-rolled, zero deps.

local M = {}

local util = require('util')

-- Same opaque compound-key join prod uses, so specs assert against the
-- real class-key shape without hardcoding the separator.
M.key = util.key

local function repr(v, depth)
  depth = depth or 0
  if depth > 4 then return '...' end
  local t = type(v)
  if t == 'string' then return string.format('%q', v) end
  if t ~= 'table' then return tostring(v) end
  local parts, isArr, n = {}, true, 0
  for k in pairs(v) do
    n = n + 1
    if type(k) ~= 'number' then isArr = false end
  end
  if isArr then
    for i = 1, n do parts[i] = repr(v[i], depth + 1) end
    return '[' .. table.concat(parts, ', ') .. ']'
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for i, k in ipairs(keys) do
    parts[i] = tostring(k) .. '=' .. repr(v[k], depth + 1)
  end
  return '{' .. table.concat(parts, ', ') .. '}'
end

local function deepEq(a, b)
  if a == b then return true end
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

function M.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or 'eq') .. ': expected ' .. repr(expected) .. ', got ' .. repr(actual), 2)
  end
end

function M.deepEq(actual, expected, msg)
  if not deepEq(actual, expected) then
    error((msg or 'deepEq') .. ':\n  expected ' .. repr(expected) .. '\n  got      ' .. repr(actual), 2)
  end
end

-- Multiset equality: same values under deepEq, ignoring keys/order.
function M.bagEq(actual, expected, msg)
  local av, ev = {}, {}
  for _, v in pairs(actual)   do av[#av+1] = v end
  for _, v in pairs(expected) do ev[#ev+1] = v end
  local ok = #av == #ev
  if ok then
    local matched = {}
    for _, a in ipairs(av) do
      local hit
      for j, e in ipairs(ev) do
        if not matched[j] and deepEq(a, e) then matched[j] = true; hit = true; break end
      end
      if not hit then ok = false; break end
    end
  end
  if not ok then
    error((msg or 'bagEq') .. ':\n  expected ' .. repr(expected) .. '\n  got      ' .. repr(actual), 2)
  end
end

function M.truthy(v, msg)
  if not v then error((msg or 'expected truthy') .. ', got ' .. repr(v), 2) end
end

function M.falsy(v, msg)
  if v then error((msg or 'expected falsy') .. ', got ' .. repr(v), 2) end
end

-- Assert that an event array contains events matching each expected spec,
-- in order, matching only the fields present on the spec (subset match).
function M.eventsMatch(actual, expected, msg)
  M.eq(#actual, #expected, (msg or 'eventsMatch') .. ' length')
  for i, spec in ipairs(expected) do
    for k, v in pairs(spec) do
      if not deepEq(actual[i][k], v) then
        error(string.format('%s: event[%d].%s: expected %s, got %s',
          msg or 'eventsMatch', i, k, repr(v), repr(actual[i][k])), 2)
      end
    end
  end
end

M.repr = repr
M.deepEqRaw = deepEq

-- Sidecar byte codec — mirrors midiManager.lua's ccSidecarEncode/Decode.
-- Lives here so test fixtures can plant sidecar bytes into fakeReaper before
-- mm:load runs, without reaching into mm internals. Keep in sync if the
-- on-wire format ever changes.
do
  local SIDECAR_MAGIC = '\x7D\x52\x44\x4D'
  local CHANMSG_LUT = { pa = 0xA0, cc = 0xB0, pc = 0xC0, at = 0xD0, pb = 0xE0 }
  local CHANMSG_TYPES = {}
  for k, v in pairs(CHANMSG_LUT) do CHANMSG_TYPES[v] = k end

  local B36 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  local function toBase36(n)
    if n == 0 then return '0' end
    local s = ''
    while n > 0 do s = B36:sub((n % 36) + 1, (n % 36) + 1) .. s; n = n // 36 end
    return s
  end

  function M.encodeSidecar(cc)
    local typeByte = CHANMSG_LUT[cc.evType]
    if not typeByte then return nil end
    local lo, hi
    if cc.evType == 'pb' then
      local raw = (cc.val or 0) + 8192
      lo, hi = raw & 0x7F, (raw >> 7) & 0x7F
    elseif cc.evType == 'pa' then
      lo, hi = (cc.vel or 0) & 0x7F, 0
    else
      lo, hi = (cc.val or 0) & 0x7F, 0
    end
    return SIDECAR_MAGIC
      .. string.char(typeByte >> 4)
      .. string.char((cc.chan or 1) - 1)
      .. string.char(cc.cc or cc.pitch or 0)
      .. string.char(lo)
      .. string.char(hi)
      .. toBase36(cc.uuid)
  end

  function M.decodeSidecar(body)
    if not body or #body < 10 then return nil end
    if body:sub(1, 4) ~= SIDECAR_MAGIC then return nil end
    local out = {}
    out.evType = CHANMSG_TYPES[body:byte(5) << 4]
    out.uuid = tonumber(body:sub(10), 36)
    if not out.evType or not out.uuid then return nil end
    local lo, hi = body:byte(8), body:byte(9)
    out.chan = body:byte(6) + 1
    if     out.evType == 'pb' then out.val = ((hi << 7) | lo) - 8192
    elseif out.evType == 'pa' then out.vel = lo
    else                           out.val = lo end
    if     out.evType == 'cc' then out.cc    = body:byte(7)
    elseif out.evType == 'pa' then out.pitch = body:byte(7)
    end
    return out
  end
end

-- Per-event metadata persists via eventMeta at project scope, keyed by the take's
-- POOLEDEVTS pool guid. These helpers seed and read it the way production does, so
-- fixtures need not re-derive the guid or the storage shape.
local function newEventMeta()
  return util.instantiate('eventMeta', { ps = util.instantiate('pextStore') })
end

function M.poolGuidOf(take)
  local item = reaper.GetMediaItemTake_Item(take)
  local _, chunk = reaper.GetItemStateChunk(item, '', false)
  return chunk and chunk:match('POOLEDEVTS%s+({[^}]+})')
end

function M.seedMeta(take, uuid, fields)
  newEventMeta():flush(M.poolGuidOf(take), { [uuid] = fields }, {})
end

function M.loadMeta(take)
  return newEventMeta():load(M.poolGuidOf(take))
end

-- Minimal dataStore fake for gm specs: get/assign/subscribe over a flat store.
-- _rewind simulates a REAPER undo rewinding a blob (fires dataChanged invalidate=true).
function M.fakeDs()
  local store, listeners = {}, {}
  return {
    get       = function(_, name) return store[name] end,
    assign    = function(_, name, v)
      store[name] = v
      for fn in pairs(listeners.dataChanged or {}) do fn{ name = name } end
    end,
    subscribe = function(_, sig, fn)
      listeners[sig] = listeners[sig] or {}
      listeners[sig][fn] = true
    end,
    _rewind   = function(name, blob)
      store[name] = blob
      for fn in pairs(listeners.dataChanged or {}) do fn{ name = name, invalidate = true } end
    end,
  }
end

return M
