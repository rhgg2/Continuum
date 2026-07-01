-- Nested, gated profiler. REAPER's single defer loop means one shared singleton
-- needs no handle-threading; perf.on=false makes every entry a guarded no-op, so
-- the fake-REAPER test harness (no time_precise) is untouched.
--
-- start/stop build a CALL TREE: start pushes a node under the currently-open one
-- (a top-level start is a fresh root), stop pops. Siblings merge by name, so a
-- span hit N times under one parent aggregates into one node carrying its call
-- count -- while the SAME name nested inside itself becomes a distinct child,
-- which is what keeps a re-entrant flush->modify->reload->modify->reload chain
-- from colliding on one flat 'reload' key (the "reload reads 0.0" bug).
--
-- Two axes, both fed by the same calls:
--   * per-gesture tree -- report() walks the last root and prints one indented
--     line per node (inclusive ms, x<count> when merged, {marks}).
--   * run totals -- totSpan/totMark accumulate across every gesture and survive
--     the tree, so churn counts (e.g. mm writes over a whole session) sum up.
--     toggle-on resets them; toggle-off dumps them.
--
-- Arm/disarm live with Ctrl+Shift+P (registered in continuum.lua).

local util = require 'util'
local perf = { on = false }

local root, cur           -- last top-level node; currently-open node (nil = none open)
local totSpan, totMark = {}, {}   -- run totals, persist across gestures

local function newNode(name, parent)
  return { name = name, incl = 0, calls = 0, marks = {}, kids = {}, order = {}, parent = parent }
end

----- Sampling

function perf.start(name)
  if not perf.on then return end
  local node
  if cur then
    node = cur.kids[name]
    if not node then
      node = newNode(name, cur)
      cur.kids[name] = node
      cur.order[#cur.order + 1] = name
    end
  else
    node = newNode(name, nil)
    root = node
  end
  node.calls = node.calls + 1
  node.t0    = reaper.time_precise()
  cur        = node
end

function perf.stop(name)
  if not perf.on or not cur then return end
  local dt = reaper.time_precise() - cur.t0
  cur.incl              = cur.incl + dt
  totSpan[cur.name]     = (totSpan[cur.name] or 0) + dt
  cur = cur.parent
end

function perf.count(name, by)
  if not perf.on then return end
  by = by or 1
  if cur then cur.marks[name] = (cur.marks[name] or 0) + by end
  totMark[name] = (totMark[name] or 0) + by
end

-- Deprecated: the tree comes from start/stop nesting. Kept as no-ops so any
-- straggler call site is harmless.
function perf.openFrame() end
function perf.closeFrame() end

----- Reporting

local function marksOf(node)
  local parts = {}
  for k, v in pairs(node.marks) do parts[#parts + 1] = string.format('%s %d', k, v) end
  table.sort(parts)
  return #parts > 0 and (' {' .. table.concat(parts, ' ') .. '}') or ''
end

local function renderNode(node, depth, out)
  local calls = node.calls > 1 and (' x' .. node.calls) or ''
  local ms    = depth == 0 and 'ms' or ''
  out[#out + 1] = string.format('%s%s %.1f%s%s%s',
    string.rep('  ', depth), node.name, node.incl * 1000, ms, calls, marksOf(node))
  local kids = {}
  for _, nm in ipairs(node.order) do kids[#kids + 1] = node.kids[nm] end
  table.sort(kids, function(a, b) return a.incl > b.incl end)
  for _, kid in ipairs(kids) do renderNode(kid, depth + 1, out) end
end

-- One indented tree per closed gesture; silent for trivial roots (nothing nested,
-- nothing counted -- e.g. a no-op flush).
function perf.report()
  if not perf.on or not root then return end
  if next(root.kids) == nil and next(root.marks) == nil then return end
  local out = {}
  renderNode(root, 0, out)
  for _, line in ipairs(out) do util.print('[perf] ' .. line) end
end

-- Run totals since arm, sorted by time. Nested same-name spans overlap, so a
-- re-entrant name's total is inclusive of its own recursion.
function perf.dump()
  if next(totSpan) == nil and next(totMark) == nil then
    util.print('[perf] disarmed (no samples)'); return
  end
  local function bySize(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return t[a] > t[b] end)
    return keys
  end
  local parts = {}
  for _, k in ipairs(bySize(totSpan)) do parts[#parts + 1] = string.format('%s %.1f', k, totSpan[k] * 1000) end
  local tally = {}
  for _, k in ipairs(bySize(totMark)) do tally[#tally + 1] = string.format('%s %d', k, totMark[k]) end
  util.print(string.format('[perf] totals%s%s',
    #parts > 0 and (' | ' .. table.concat(parts, ' ')) or '',
    #tally > 0 and (' | ' .. table.concat(tally, ' ')) or ''))
end

function perf.toggle()
  perf.on = not perf.on
  if perf.on then
    root, cur        = nil, nil
    totSpan, totMark = {}, {}
    util.print('[perf] armed')
  else
    perf.dump()
  end
end

function perf.line(...) if perf.on then util.print('[perf] ' .. string.format(...)) end end

return perf
