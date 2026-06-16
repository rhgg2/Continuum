-- See docs/util.md for the model.

--invariant: stateless module: pure helpers, no module-level mutable state beyond the REMOVE/OPEN sentinels
--invariant: util.REMOVE is the canonical delete marker honoured by assign and by mm/cm assignment APIs
local util = {}

function util.print(...)
  if not ... then
    reaper.ShowConsoleMsg('nil value\n')
    return
  end
  reaper.ShowConsoleMsg(table.concat({...}, '\t') .. '\n')
end

local function print(...)
  return util.print(...)
end

function util.print_r(root)
  local cache = {  [root] = '.' }
  local function _dump(t,space,name)
    local temp = {}
    for k,v in pairs(t) do
      local key = tostring(k)
      if cache[v] then
        temp[#temp+1] = '+' .. key .. ' {' .. cache[v]..'}'
      elseif type(v) == 'table' then
        local new_key = name .. '.' .. key
        cache[v] = new_key
        temp[#temp+1] = '+' .. key .. _dump(v,space .. (next(t,k) and '|' or ' ' ).. string.rep(' ',#key),new_key)
      else
        temp[#temp+1] = '+' .. key .. ' [' .. tostring(v)..']'
      end
    end
    return table.concat(temp,'\n'..space)
  end
  print(_dump(root, '',''))
end

util.REMOVE = { }

--invariant: util.OPEN is the canonical "deliberately unbounded tail" marker for a note's endppqL. It is math.huge, so arithmetic on an open tail just works (inf + finite = inf, inf > finite = true) — callers no longer special-case the sentinel except to communicate intent. util.serialise/unserialise round-trip the non-finite floats via explicit inf/-inf/nan literals so the on-disk form is stable. Distinct from util.REMOVE: REMOVE clears a key on assign; OPEN is a persisted *value* of endppqL.
util.OPEN = math.huge

--contract: values equal to util.REMOVE clear the key from t1 instead of being assigned
function util.assign(t1,t2)
  if t2 then
    for k, v in pairs(t2) do
      if v == util.REMOVE then
        t1[k] = nil
      else
        t1[k] = v
      end
    end
  end
  return t1
end

function util.add(tbl, val)
  tbl[#tbl+1] = val
  return val
end

-- Wrap fn so each call is one REAPER undo entry. label is the undo
-- description; the wrapper forwards args, propagates errors after
-- closing the block, and is a no-op when reaper.Undo_BeginBlock is
-- absent (test harness).
function util.atomic(label, fn)
  label = label and 'Continuum: ' .. label
  return function(...)
    if reaper.Undo_BeginBlock then reaper.Undo_BeginBlock() end
    local ok, a, b, c, d = xpcall(fn, debug.traceback, ...)
    if reaper.Undo_EndBlock then reaper.Undo_EndBlock(label, -1) end
    if not ok then error(a) end
    return a, b, c, d
  end
end

function util.pick(src, keys, adds)
  local dst = {}
  for k in keys:gmatch("%S+") do
    dst[k] = src[k]
  end
  if adds then
    util.assign(dst, adds)
  end
  return dst
end

function util.bucket(buckets, key, val)
  local b = buckets[key]
  if not b then b = {}; buckets[key] = b end
  b[#b+1] = val
  return b
end

-- Opaque compound key: join identity fields with NUL, which can't appear
-- in a guid, track-key, or stringified scalar. Never split back apart.
function util.key(...)
  local parts = {}
  for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
  return table.concat(parts, '\0')
end

function util.keys(t)
  local out = {}
  for k in pairs(t) do out[#out+1] = k end
  return out
end

-- Sparse → dense; n is the pre-sparse length.
function util.compact(t, n)
  local out = {}
  for i = 1, n do if t[i] ~= nil then out[#out+1] = t[i] end end
  return out
end

--contract: assumes items sorted by keyFn (defaults to .ppq); 'before' modes scan to first miss then stop
function util.seek(items, mode, key, filter, keyFn)
  keyFn = keyFn or function(x) return x.ppq end
  local before = mode == 'before' or mode == 'at-or-before'
  local cmp
  if     mode == 'before'       then cmp = function(k) return k <  key end
  elseif mode == 'at-or-before' then cmp = function(k) return k <= key end
  elseif mode == 'after'        then cmp = function(k) return k >  key end
  elseif mode == 'at-or-after'  then cmp = function(k) return k >= key end
  end
  local hit
  for _, item in ipairs(items) do
    if cmp(keyFn(item)) then
      if not filter or filter(item) then
        if not before then return item end
        hit = item
      end
    elseif before then
      break
    end
  end
  return hit
end

--contract: exclude applies only to the outermost table; deep recursion drops the exclude set
function util.clone(src, exclude, deep)
  if not src then return end
  local dst = {}
  for k, v in pairs(src) do
    if not (exclude and exclude[k]) then
      dst[k] = (deep and type(v) == 'table') and util.clone(v, nil, true) or v
    end
  end
  return dst
end

function util.deepClone(src) return util.clone(src, nil, true) end

function util.deepEq(a, b)
  if a == b then return true end
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  for k, v in pairs(a) do if not util.deepEq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function escape_string(s)
  -- Control bytes hex-escape to `\xHH`; structural chars stay backslash-escaped.
  -- see docs/util.md § Serialisation format
  local out = (s:gsub('[%c\\{},=]', function(c)
    if c:find('%c') then return string.format('\\x%02X', string.byte(c)) end
    return '\\' .. c
  end))
  -- Disambiguate from numbers/booleans: prepend `\e` (empty marker, decodes
  -- to nothing) when the encoded form would otherwise round-trip as a
  -- non-string scalar. The decoder uses the presence of any escape as a
  -- signal to skip number/boolean coercion.
  if tonumber(out) or out == 'true' or out == 'false' then
    out = '\\e' .. out
  end
  return out
end

--contract: listeners filter by signal name at registration; forward requires source itself ran installHooks
function util.installHooks(owner)
  local listeners = {}
  function owner:subscribe(signal, fn)
    listeners[signal] = listeners[signal] or {}
    listeners[signal][fn] = true
  end
  function owner:unsubscribe(signal, fn)
    if listeners[signal] then listeners[signal][fn] = nil end
  end
  local function fire(signal, ...)
    local subs = listeners[signal]
    if subs then for fn in pairs(subs) do fn(...) end end
  end
  function owner:forward(signal, source)
    source:subscribe(signal, function(...) fire(signal, ...) end)
  end
  return fire
end

function util.isNote(e) return e and e.endppq end

--contract: iterates events with ppq in half-open [lo, hi); adjacent windows tile without overlap
function util.between(events, lo, hi, filter)
  filter = filter or function() return true end
  local i = 0
  return function()
    while true do
      i = i + 1
      local evt = events[i]
      if not evt or evt.ppq >= hi then return end
      if evt.ppq >= lo and filter(evt) then return evt end
    end
  end
end

function util.clamp(val,min,max)
  if val < min then
    return min
  elseif val > max then
    return max
  else
    return val
  end
end

function util.setDigit(val, d, pos, base, half)
  local place = base ^ pos // 1
  local above = val - (val % (place * base))
  return above + d * place + (half and place // 2 or 0)
end

--contract: advances at least one full interval; values already on a boundary do not no-op
function util.snapTo(v, dir, interval)
  if dir > 0 then return (math.floor(v / interval) + 1) * interval end
  return (math.ceil(v / interval) - 1) * interval
end

function util.nudgedScalar(v, lo, hi, dir, interval)
  local target = interval and util.snapTo(v, dir, interval) or (v + dir)
  return util.clamp(target, lo, hi)
end

function util.oneOf(choices, txt)
  for k in choices:gmatch('%S+') do
    if txt == k then return true end
  end
  return false
end

function util.round(n, to)
  if to then
    return math.floor(n / to + 0.5) * to
  else
    return math.floor(n + 0.5)
  end
end

function util.gcd(a, b)
  a, b = math.abs(a), math.abs(b)
  while b ~= 0 do a, b = b, a % b end
  return a
end

function util.lcm(a, b) return a // util.gcd(a, b) * b end

local BASE36 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'

function util.toBase36(n)
  if n == 0 then return '0' end
  local s = ''
  while n > 0 do
    local r = n % 36
    s = string.sub(BASE36, r + 1, r + 1) .. s
    n = n // 36
  end
  return s
end

function util.fromBase36(txt)
  return tonumber(txt, 36)
end

-- Base62: digits + lowercase + uppercase. Used for slot keys (62 slots
-- per palette). Case-sensitive — 'a' and 'A' are distinct values.
local BASE62 = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'

function util.toBase62(n)
  if n == 0 then return '0' end
  local s = ''
  while n > 0 do
    local r = n % 62
    s = string.sub(BASE62, r + 1, r + 1) .. s
    n = n // 62
  end
  return s
end

function util.fromBase62(txt)
  local n = 0
  for i = 1, #txt do
    local c = string.sub(txt, i, i)
    local v = string.find(BASE62, c, 1, true)
    if not v then return nil end
    n = n * 62 + (v - 1)
  end
  return n
end

--contract: overloaded on type of v: function => call n times for side effect; else build n-array filled with v
function util.dotimes(n, v)
  if type(v) == 'function' then
    for _ = 1, n do v() end
    return
  end
  local rv = {}
  for i = 1, n do rv[i] = v end
  return rv
end

--contract: strict: cycles raise; exclude applies only to the outermost table (recursion drops it)
function util.serialise(value, exclude, seen)
  exclude = exclude or { }
  local t = type(value)

  if t == 'number' then
    -- tostring of inf/nan is platform-dependent (libc printf %g); pin the
    -- wire form so unserialise can recognise it without ambiguity.
    if value ~= value then return 'nan' end
    if value ==  math.huge then return 'inf' end
    if value == -math.huge then return '-inf' end
    return tostring(value)

  elseif t == 'boolean' then
    return tostring(value)

  elseif t == 'string' then
    return escape_string(value)

  elseif t == 'table' then
    seen = seen or {}
    if seen[value] then
      error('cycle detected during serialisation')
    end
    seen[value] = true

    local parts = {}
    for k, v in pairs(value) do
      if not exclude[k] then
        local key_str = util.serialise(k, nil, seen)
        local val_str = util.serialise(v, nil, seen)
        parts[#parts+1] = key_str .. '=' .. val_str
      end
    end

    seen[value] = nil
    return '{' .. table.concat(parts, ',') .. '}'

  else
    error('unsupported type: ' .. t)
  end
end

--contract: strict: trailing chars after the root value raise; scalars decode back to number/boolean/string
function util.unserialise(input)
  local pos = 1
  local len = #input

  local function peek()
    return input:sub(pos, pos)
  end

  local function nextChar()
    local c = input:sub(pos, pos)
    pos = pos + 1
    return c
  end

  local function parseStringToken()
    local buf = {}
    local hadEscape = false

    while pos <= len do
      local c = nextChar()

      if c == '\\' then
        local n = nextChar()

        if n == '{' or n == '}' or n == ',' or n == '=' or n == '\\' then
          buf[#buf+1] = n
          hadEscape = true
        elseif n == 'e' then
          -- empty marker: forces string interpretation downstream
          hadEscape = true
        elseif n == 'x' then
          local byte = tonumber(input:sub(pos, pos + 1), 16)
          if not byte then error('invalid hex escape') end
          pos = pos + 2
          buf[#buf+1] = string.char(byte)
          hadEscape = true
        else
          error('invalid escape: \\' .. tostring(n))
        end

      elseif c == '{' or c == '}' or c == ',' or c == '=' then
        pos = pos - 1
        break

      else
        buf[#buf+1] = c
      end
    end

    local s = table.concat(buf)

    if hadEscape then return s end

    local n = tonumber(s)
    if n then return n end
    if s == 'inf'  then return  math.huge end
    if s == '-inf' then return -math.huge end
    if s == 'true' then return true end
    if s == 'false' then return false end
    return s
  end

  local parseValue -- forward decl

  local function parseTable()
    if nextChar() ~= '{' then
      error("expected '{'")
    end

    local t = {}

    if peek() == '}' then
      nextChar()
      return t
    end

    while true do
      local key = parseValue()

      if nextChar() ~= '=' then
        error("expected '=' after key")
      end

      local val = parseValue()
      t[key] = val

      local c = nextChar()

      if c == '}' then
        break
      elseif c == ',' then
        -- continue
      else
        error("expected ',' or '}'")
      end
    end

    return t
  end

  function parseValue()
    if peek() == '{' then
      return parseTable()
    else
      return parseStringToken()
    end
  end

  local result = parseValue()

  if pos <= len then
    error('trailing characters')
  end

  return result
end

----- Lua-literal disk format (human-editable; read by load(), never P_EXT)
-- WHY two formats coexist: see design/persistence.md § Disk format.

local LUA_KEYWORDS = {}
for word in ('and break do else elseif end false for function goto if in '
          .. 'local nil not or repeat return then true until while'):gmatch('%S+') do
  LUA_KEYWORDS[word] = true
end

local function bareKey(k)
  return type(k) == 'string' and k:match('^[%a_][%w_]*$') and not LUA_KEYWORDS[k]
end

-- inf/nan are not bare Lua, but their arithmetic forms are and need no env.
local function luaNumber(n)
  if n ~= n          then return '0/0'  end
  if n ==  math.huge then return '1/0'  end
  if n == -math.huge then return '-1/0' end
  return tostring(n)
end

-- Inline note so a hand-editor recognises the arithmetic non-finite forms.
local function nonFiniteNote(v)
  if type(v) ~= 'number' or (v == v and v > -math.huge and v < math.huge) then return '' end
  if v ~= v then return '  -- nan' end
  return v > 0 and '  -- inf (util.OPEN)' or '  -- -inf'
end

local prettyEmit  -- forward decl (mutual recursion with emitTable)

local function emitTable(tbl, indent, seen)
  if seen[tbl] then error('cycle detected during prettySerialise') end
  seen[tbl] = true

  local arrLen = 0
  while tbl[arrLen + 1] ~= nil do arrLen = arrLen + 1 end
  local keyed = {}
  for k in pairs(tbl) do
    local inArray = type(k) == 'number' and k == math.floor(k) and k >= 1 and k <= arrLen
    if not inArray then keyed[#keyed+1] = k end
  end
  table.sort(keyed, function(a, b) return tostring(a) < tostring(b) end)

  if arrLen == 0 and #keyed == 0 then seen[tbl] = nil; return '{}' end

  local nested = #keyed > 0
  for i = 1, arrLen do if type(tbl[i]) == 'table' then nested = true end end

  if not nested then  -- scalar-only sequence prints inline
    local parts = {}
    for i = 1, arrLen do parts[i] = prettyEmit(tbl[i], indent, seen) end
    seen[tbl] = nil
    return '{ ' .. table.concat(parts, ', ') .. ' }'
  end

  local pad, lines = string.rep('  ', indent + 1), {}
  for i = 1, arrLen do
    lines[#lines+1] = pad .. prettyEmit(tbl[i], indent + 1, seen) .. ',' .. nonFiniteNote(tbl[i])
  end
  for _, k in ipairs(keyed) do
    local keyStr = bareKey(k) and k or '[' .. prettyEmit(k, indent + 1, seen) .. ']'
    local v = tbl[k]
    lines[#lines+1] = pad .. keyStr .. ' = ' .. prettyEmit(v, indent + 1, seen) .. ',' .. nonFiniteNote(v)
  end
  seen[tbl] = nil
  return '{\n' .. table.concat(lines, '\n') .. '\n' .. string.rep('  ', indent) .. '}'
end

function prettyEmit(value, indent, seen)
  local t = type(value)
  if t == 'number'  then return luaNumber(value) end
  if t == 'boolean' then return tostring(value) end
  if t == 'string'  then return string.format('%q', value) end
  if t == 'table'   then return emitTable(value, indent, seen) end
  error('prettySerialise: unsupported type ' .. t)
end

--contract: emits a `return <literal>` chunk for load(); non-finite → 1/0 -1/0 0/0; cycles raise
function util.prettySerialise(value)
  return 'return ' .. prettyEmit(value, 0, {}) .. '\n'
end

--contract: sandboxed load() of the disk literal (text-only, empty env); ok→value, fail→nil,err
function util.prettyUnserialise(text)
  local chunk, loadErr = load(text, '@ctm_disk', 't', {})
  if not chunk then return nil, loadErr end
  local ok, value = pcall(chunk)
  if not ok then return nil, value end
  return value
end

--contract: executes the named module file as a fresh chunk, passing `deps` as its `...` argument. Used for factory modules whose file body IS the constructor (vs. stateless `require`d tables). Test seam: a function in util._stubs[name] takes precedence and is called with deps — so harnesses can swap a fake without altering the production graph.
util._stubs = {}
function util.instantiate(name, deps)
  local stub = util._stubs[name]
  if stub then return stub(deps) end
  local path = assert(package.searchpath(name, package.path),
                      'util.instantiate: cannot find module ' .. name)
  return assert(loadfile(path))(deps)
end

return util
