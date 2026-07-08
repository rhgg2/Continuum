-- bridge.lua — live-REAPER eval bridge. See design/reaper-bridge.md for the model.
--
-- Executes a Lua chunk inside the running Continuum instance and renders the
-- result to a file, so an external process (the reaper MCP server) can observe
-- the real manager stack. Driven from the coordinator's per-frame tick().

--contract: tick() is the only entry; execute/render/scan are internal. Deps: { env, spoolDir? }.
--invariant: a bad chunk never escapes — load failure and runtime error both land in the res file
--invariant: request file is read then deleted BEFORE execute, so a mid-chunk crash cannot replay it
--invariant: chunk env = deps.env over a _G fallback (stdlib+reaper); chunk global writes stay in env
--reaper: EnumerateFiles caches per-dir; each scan invalidates with idx -1, else stale/deleted reqs linger
--shape: response = "status: ok|error\nms: N\n--- value ---\n<render>\n--- print ---\n<buffered>\n"

local deps = ... or {}
local env  = deps.env or {}
-- Chunks need the Lua stdlib; _G supplies it (plus reaper) but not Continuum's
-- module locals, so deps.env stays the sole manager surface.
setmetatable(env, { __index = _G })

local function defaultSpoolDir()
  local here = debug.getinfo(1, 'S').source:match('^@?(.*[/\\])') or './'
  return here .. '.claude/mcp/reaper/spool'
end
local spoolDir = deps.spoolDir or defaultSpoolDir()

-- env.print appends here; cleared in place per request so the closure keeps its
-- original table reference.
local printBuf = {}
env.print = function(...)
  local parts = {}
  for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
  printBuf[#printBuf + 1] = table.concat(parts, '\t')
end

----- small IO

local function join(name) return spoolDir .. '/' .. name end

local function readAll(path)
  local f = io.open(path, 'r'); if not f then return nil end
  local s = f:read('*a'); f:close(); return s
end

local function writeAtomic(path, text)
  local tmp = path .. '.tmp'
  local f = io.open(tmp, 'w'); if not f then return end
  f:write(text); f:close()
  os.rename(tmp, path)
end

local function dirExists(path)
  local f = io.open(path, 'r'); if f then f:close(); return true end
  return false
end

local function nowMs()
  if reaper.time_precise then return reaper.time_precise() * 1000 end
  return os.clock() * 1000
end

----- render — bridge-local serialiser, NOT util.prettySerialise (which targets
----- round-tripping). Survives cycles and userdata; caps depth/width/string/total
----- so a manager table can't blow the response up.

local DEFAULTS = { depth = 4, entries = 40, str = 200, total = 64 * 1024 }
local CAP = {}   -- sentinel thrown when the total byte cap is exceeded

local function render(value, opts)
  opts = opts or {}
  local depthCap = opts.depth   or DEFAULTS.depth
  local maxEnt   = opts.entries or DEFAULTS.entries
  local maxStr   = opts.str     or DEFAULTS.str
  local totalCap = opts.total   or DEFAULTS.total

  local out, total, seen = {}, 0, {}
  local function emit(s)
    total = total + #s
    if total > totalCap then error(CAP) end
    out[#out + 1] = s
  end

  local function go(v, depth)
    local tv = type(v)
    if tv == 'table' then
      if seen[v] then emit('<cycle>'); return end
      if depth >= depthCap then emit('{…}'); return end
      seen[v] = true
      local keys, n = {}, 0
      for k in pairs(v) do n = n + 1; keys[n] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      emit('{ ')
      local shown = math.min(n, maxEnt)
      for i = 1, shown do
        if i > 1 then emit(', ') end
        emit(tostring(keys[i]) .. ' = ')
        go(v[keys[i]], depth + 1)
      end
      if n > maxEnt then emit(string.format(', … +%d more', n - maxEnt)) end
      emit(' }')
      seen[v] = nil
    elseif tv == 'string' then
      if #v > maxStr then emit(string.format('%q', v:sub(1, maxStr)) .. '…')
      else emit(string.format('%q', v)) end
    elseif tv == 'number' or tv == 'boolean' or tv == 'nil' then
      emit(tostring(v))
    else
      emit('<' .. tostring(v) .. '>')
    end
  end

  local ok, err = pcall(go, value, 0)
  if not ok then
    if err == CAP then out[#out + 1] = ' …(truncated)'
    else error(err) end
  end
  return table.concat(out)
end

----- directives — leading `--#key arg` lines, stripped before load

local function parseDirectives(code)
  local d = {}
  while true do
    local line, tail = code:match('^([^\n]*)\n?(.*)$')
    local body = line:match('^%s*%-%-#(.*)$')
    if not body then break end
    local key, arg = body:match('^(%S+)%s*(.-)%s*$')
    if     key == 'undo'  then d.undo  = (arg ~= '' and arg) or 'bridge eval'
    elseif key == 'depth' then d.depth = tonumber(arg) end
    code = tail
  end
  return d, code
end

----- execute — one chunk under the bridge's own xpcall; render its return value

local function execute(rawCode)
  for i = #printBuf, 1, -1 do printBuf[i] = nil end
  local directives, code = parseDirectives(rawCode)
  local t0 = nowMs()
  local result
  local chunk, loadErr = load(code, '=bridge', 't', env)
  if not chunk then
    result = { status = 'error', value = 'load error: ' .. tostring(loadErr) }
  else
    local undo = directives.undo
    if undo and reaper.Undo_BeginBlock then reaper.Undo_BeginBlock() end
    local packed = table.pack(xpcall(chunk, debug.traceback))
    if undo and reaper.Undo_EndBlock2 then reaper.Undo_EndBlock2(0, undo, -1) end
    if packed[1] then
      local value
      if packed.n <= 2 then value = packed[2]
      else value = table.move(packed, 2, packed.n, 1, {}) end
      result = { status = 'ok', value = render(value, { depth = directives.depth }) }
    else
      result = { status = 'error', value = tostring(packed[2]) }
    end
  end
  result.ms    = nowMs() - t0
  result.print = table.concat(printBuf, '\n')
  return result
end

local function formatResponse(r)
  return table.concat({
    'status: ' .. r.status,
    string.format('ms: %.1f', r.ms or 0),
    '--- value ---', r.value or '',
    '--- print ---', r.print or '',
  }, '\n') .. '\n'
end

----- scan — process at most one pending request per call

local function firstReq()
  -- EnumerateFiles caches the listing; the early return below never enumerates to nil
  -- to free it, so force a re-read (-1) or a later tick reads a stale, deleted-req snapshot.
  reaper.EnumerateFiles(spoolDir, -1)
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(spoolDir, i)
    if not f then return nil end
    if f:match('^req%-.+%.lua$') then return f end
    i = i + 1
  end
end

local function scanOnce()
  local name = firstReq()
  if not name then return end
  local id   = name:match('^req%-(.+)%.lua$')
  local code = readAll(join(name)) or ''
  os.remove(join(name))
  writeAtomic(join('res-' .. id .. '.txt'), formatResponse(execute(code)))
end

----------- PUBLIC

-- Enable-gate: until the spool dir exists the bridge is off, re-stat'd once per
-- ~60 frames. The MCP server creating the dir switches it on; then it stays on.
local bridge = {}
local enabled, cooldown = false, 0

function bridge:tick()
  if not enabled then
    if cooldown > 0 then cooldown = cooldown - 1; return end
    cooldown = 60
    if not dirExists(spoolDir) then return end
    enabled = true
  end
  scanOnce()
end

return bridge
