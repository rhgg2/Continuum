-- Nested, gated profiler. REAPER's single defer loop means one shared singleton
-- needs no handle-threading; perf.on=false makes every entry a guarded no-op, so
-- the fake-REAPER test harness (no time_precise) is untouched.
--
-- Two axes, both fed by the same start/stop/count calls:
--   * per-operation breakdown -- frames STACK. A keystroke nests
--     flush -> mm:modify -> mm reload -> tm:rebuild -> tv:rebuild; each layer
--     brackets its work with openFrame/closeFrame, opening fresh tables and closing
--     back to its parent. A flat reset let an inner rebuild wipe the outer
--     flush's timings -- the "no flush line" bug. report() prints one line per
--     closed frame.
--   * run totals -- totSpan/totMark accumulate across every frame and survive
--     the stack, so churn counts (e.g. mm writes over a whole edit session) sum
--     up. arm resets them; disarm dumps them.
--
-- Arm/disarm live with Ctrl+Shift+P (registered in continuum.lua).

local util = require 'util'
local perf = { on = false }

local stack = {}
local span, mark, started = {}, {}, {}   -- current frame (swapped on nest)
local totSpan, totMark    = {}, {}        -- run totals (persist across frames)

----- Frame stack

function perf.openFrame()
  if not perf.on then return end
  stack[#stack + 1] = { span, mark, started }
  span, mark, started = {}, {}, {}
end

function perf.closeFrame()
  if not perf.on then return end
  local f = stack[#stack]
  if f then stack[#stack] = nil; span, mark, started = f[1], f[2], f[3] end
end

----- Sampling

function perf.start(name) if perf.on then started[name] = reaper.time_precise() end end

function perf.stop(name)
  if perf.on and started[name] then
    local dt = reaper.time_precise() - started[name]
    span[name]    = (span[name]    or 0) + dt
    totSpan[name] = (totSpan[name] or 0) + dt
    started[name] = nil
  end
end

function perf.count(name, by)
  if perf.on then
    by = by or 1
    mark[name]    = (mark[name]    or 0) + by
    totMark[name] = (totMark[name] or 0) + by
  end
end

function perf.ms(name) return (span[name] or 0) * 1000 end

----- Reporting

local function bySize(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return t[a] > t[b] end)
  return keys
end

local function printLine(headline, headMs, spans, marks, skip)
  local parts = {}
  for _, k in ipairs(bySize(spans)) do
    if k ~= skip then parts[#parts + 1] = string.format('%s %.1f', k, spans[k] * 1000) end
  end
  local tally = {}
  for _, k in ipairs(bySize(marks)) do tally[#tally + 1] = string.format('%s %d', k, marks[k]) end
  util.print(string.format('[perf] %s%s%s%s',
    headline,
    headMs and string.format(' %.1fms', headMs) or '',
    #parts > 0 and (' | ' .. table.concat(parts, ' ')) or '',
    #tally > 0 and (' | ' .. table.concat(tally, ' ')) or ''))
end

-- One line per closed frame; silent for trivial frames (no counts, nothing timed
-- beyond the label itself -- e.g. a no-op flush).
function perf.report(label)
  if not perf.on then return end
  local nSpan = 0; for _ in pairs(span) do nSpan = nSpan + 1 end
  if next(mark) == nil and nSpan <= 1 then return end
  printLine(label, perf.ms(label), span, mark, label)
end

-- Run totals since arm. Each span key is total time spent in spans of that name;
-- nested spans overlap their parents by construction.
function perf.dump()
  if next(totSpan) == nil and next(totMark) == nil then
    util.print('[perf] disarmed (no samples)'); return
  end
  printLine('totals', nil, totSpan, totMark, nil)
end

function perf.toggle()
  perf.on = not perf.on
  if perf.on then
    stack = {}
    span, mark, started = {}, {}, {}
    totSpan, totMark    = {}, {}
    util.print('[perf] armed')
  else
    perf.dump()
  end
end

function perf.line(...) if perf.on then util.print('[perf] ' .. string.format(...)) end end

return perf
