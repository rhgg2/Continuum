-- See docs/util.md for the model.

--@map:invariant stateless module: pure helpers, no module-level mutable state beyond the REMOVE sentinel
--@map:invariant util.REMOVE is the canonical delete marker honoured by assign and by mm/cm assignment APIs

util = {}

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

--@map:contract values equal to util.REMOVE clear the key from t1 instead of being assigned
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

--@map:contract assumes items sorted by keyFn (defaults to .ppq); 'before' modes scan to first miss then stop
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

--@map:contract exclude applies only to the outermost table; deep recursion drops the exclude set
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

local function escape_string(s)
  return (s:gsub('[\\{},=]', function(c)
    return '\\' .. c
  end))
end

--@map:contract listeners filter by signal name at registration; forward requires source itself ran installHooks
function util.installHooks(owner)
  local listeners = {}
  function owner:subscribe(signal, fn)
    listeners[signal] = listeners[signal] or {}
    listeners[signal][fn] = true
  end
  function owner:unsubscribe(signal, fn)
    if listeners[signal] then listeners[signal][fn] = nil end
  end
  local function fire(signal, data)
    local subs = listeners[signal]
    if subs then for fn in pairs(subs) do fn(data) end end
  end
  function owner:forward(signal, source)
    source:subscribe(signal, function(data) fire(signal, data) end)
  end
  return fire
end

function util.isNote(e) return e and e.endppq end

--@map:contract iterates events with ppq in half-open [lo, hi); adjacent windows tile without overlap
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

--@map:contract advances at least one full interval; values already on a boundary do not no-op
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

--@map:contract overloaded on type of v: function => call n times for side effect; else build n-array filled with v
function util.dotimes(n, v)
  if type(v) == 'function' then
    for _ = 1, n do v() end
    return
  end
  local rv = {}
  for i = 1, n do rv[i] = v end
  return rv
end

--@map:contract strict: cycles raise; exclude applies only to the outermost table (recursion drops it)
function util.serialise(value, exclude, seen)
  exclude = exclude or { }
  local t = type(value)

  if t == 'number' or t == 'boolean' then
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

--@map:contract strict: trailing chars after the root value raise; scalars decode back to number/boolean/string
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

    while pos <= len do
      local c = nextChar()

      if c == '\\' then
        local n = nextChar()

        if n == '{' or n == '}' or n == ',' or n == '=' or n == '\\' then
          buf[#buf+1] = n
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

    -- number detection
    local n = tonumber(s)
    if n then return n end

    -- boolean
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
