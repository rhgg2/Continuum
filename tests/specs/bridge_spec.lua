-- Pin-tests for bridge.lua. Every case drives the REAL entry point — tick() ->
-- scan -> execute -> write — against a temp spool dir, faking only REAPER's
-- EnumerateFiles (the directory-listing seam, exactly as fs_spec does). The
-- request/response protocol is thus exercised end to end, not through a
-- re-implemented handler.

local util = require('util')
local t    = require('support')

local function tmpDir()
  local d = os.tmpname(); os.remove(d); os.execute('mkdir -p "' .. d .. '"'); return d
end
local function writeFile(p, s) local f = assert(io.open(p, 'w')); f:write(s); f:close() end
local function readFile(p)
  local f = io.open(p, 'r'); if not f then return nil end
  local s = f:read('*a'); f:close(); return s
end
local function fileExists(p)
  local f = io.open(p, 'r'); if f then f:close(); return true end
  return false
end

-- Parse a res file back into fields. The value section is always one line (render
-- never emits newlines); print may span lines; an error value carries a
-- multi-line traceback — all captured by the non-greedy value / greedy print cut.
local function parseRes(text)
  return {
    status = text:match('status: (%S+)'),
    value  = text:match('\n%-%-%- value %-%-%-\n(.-)\n%-%-%- print %-%-%-'),
    print  = text:match('\n%-%-%- print %-%-%-\n(.*)$'),
  }
end

-- Plant `chunk` as the sole request, tick the bridge once, return the parsed res.
-- opts.reaper(r) may add extra REAPER stubs (e.g. Undo_*) before the tick.
local function runChunk(chunk, opts)
  opts = opts or {}
  local dir, reqName = tmpDir(), 'req-1.lua'
  writeFile(dir .. '/' .. reqName, chunk)
  local reaper = {
    EnumerateFiles = function(_, i)
      if i == 0 and fileExists(dir .. '/' .. reqName) then return reqName end
    end,
    time_precise = function() return 0 end,
  }
  if opts.reaper then opts.reaper(reaper) end
  local saved = _G.reaper; _G.reaper = reaper
  local bridge = util.instantiate('bridge', { spoolDir = dir, env = opts.env or {} })
  bridge:tick()
  _G.reaper = saved
  return parseRes(readFile(dir .. '/res-1.txt') or ''), dir
end

return {
  {
    name = "round trip: request executed, response written, request deleted first",
    run = function()
      local res, dir = runChunk('return 1 + 2')
      t.eq(res.status, 'ok')
      t.eq(res.value, '3')
      t.falsy(fileExists(dir .. '/req-1.lua'), 'request must be deleted')
    end,
  },
  {
    name = "chunk sees the Lua stdlib via _G fallback (env holds only handles)",
    run = function()
      local res = runChunk('local n = 0; for _ in pairs({ a = 1, b = 2 }) do n = n + 1 end; return n')
      t.eq(res.status, 'ok')
      t.eq(res.value, '2')
    end,
  },
  {
    name = "error path carries message and traceback",
    run = function()
      local res = runChunk('error("boom")')
      t.eq(res.status, 'error')
      t.truthy(res.value:find('boom', 1, true), 'message present')
      t.truthy(res.value:find('traceback', 1, true), 'traceback present')
    end,
  },
  {
    name = "print() output is captured into the print section",
    run = function()
      local res = runChunk('print("hello", 42); return true')
      t.eq(res.value, 'true')
      t.truthy(res.print:find('hello\t42', 1, true))
    end,
  },
  {
    name = "directive --#depth caps render depth",
    run = function()
      local res = runChunk('--#depth 1\nreturn { a = { b = 1 } }')
      t.eq(res.status, 'ok')
      t.truthy(res.value:find('{…}', 1, true), 'nested table collapsed at depth 1')
    end,
  },
  {
    name = "directive --#undo wraps execution in an undo block",
    run = function()
      local rec = {}
      runChunk('--#undo my edit\nreturn 1', {
        reaper = function(r)
          r.Undo_BeginBlock = function() rec.began = true end
          r.Undo_EndBlock2  = function(_, label) rec.label = label end
        end,
      })
      t.truthy(rec.began, 'block opened')
      t.eq(rec.label, 'my edit')
    end,
  },
  {
    name = "render survives a cyclic table",
    run = function()
      local res = runChunk('local x = {}; x.self = x; return x')
      t.eq(res.status, 'ok')
      t.truthy(res.value:find('<cycle>', 1, true))
    end,
  },
  {
    name = "render prints userdata via tostring",
    run = function()
      local res = runChunk('return io.stdout')
      t.eq(res.value:sub(1, 1), '<')
      t.truthy(res.value:find('file', 1, true))
    end,
  },
  {
    name = "render truncates a wide table with a +N more marker",
    run = function()
      local res = runChunk('local x = {}; for i = 1, 50 do x[i] = i end; return x')
      t.truthy(res.value:find('+10 more', 1, true))
    end,
  },
  {
    name = "render stops at the total byte cap",
    run = function()
      local res = runChunk([[
        local inner = {}; for i = 1, 40 do inner[i] = string.rep('x', 200) end
        local outer = {}; for i = 1, 40 do outer[i] = inner end
        return outer
      ]])
      t.truthy(res.value:find('truncated', 1, true))
    end,
  },
  {
    name = "scan invalidates the EnumerateFiles cache (idx -1) before listing",
    run = function()
      local dir = tmpDir()
      writeFile(dir .. '/req-1.lua', 'return 1')
      local calls = {}
      local saved = _G.reaper
      _G.reaper = {
        EnumerateFiles = function(_, i)
          calls[#calls + 1] = i
          if i == 0 and fileExists(dir .. '/req-1.lua') then return 'req-1.lua' end
        end,
        time_precise = function() return 0 end,
      }
      local bridge = util.instantiate('bridge', { spoolDir = dir, env = {} })
      bridge:tick()
      _G.reaper = saved
      t.eq(calls[1], -1, 'first EnumerateFiles call must be the -1 cache invalidation')
    end,
  },
  {
    name = "tick over an empty spool writes nothing and does not error",
    run = function()
      local dir = tmpDir()
      local saved = _G.reaper
      _G.reaper = { EnumerateFiles = function() return nil end, time_precise = function() return 0 end }
      local bridge = util.instantiate('bridge', { spoolDir = dir, env = {} })
      bridge:tick(); bridge:tick()
      _G.reaper = saved
      t.falsy(fileExists(dir .. '/res-1.txt'))
    end,
  },
}
