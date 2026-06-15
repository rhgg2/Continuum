-- curveEditor regression net, written BEFORE the painter migration so it
-- pins behaviour the migration must preserve: the forward map (anchors and
-- the axis draw at their mapped screen positions) and — the real prize — the
-- inverse map (a click resolves to the right anchor, a drag maps the cursor
-- back to t/val, insert/delete/cycle fire with the right indices).
--
-- The fixture is deliberately contract-agnostic: it feeds NAMES as colours
-- and an identity chrome, and the fake's GetWindowDrawList returns the same
-- 'DL' passed as drawList. So whether curveEditor draws straight to a.drawList
-- with pre-resolved colours (today) or through a painter that grabs the window
-- drawlist and resolves names (after), the recorded calls are identical and
-- this spec stays green across the change.

local t    = require('support')
local util = require('util')

-- Transform chosen so every mapped coordinate is an integer:
--   toScreen(t, v) = (100 + 20*t, 150 - v)   for t in [0,10], v in [0,100]
-- which keeps draw-position assertions exact across the migration (painter
-- rounds its origin to whole pixels; integer params make that a no-op).
local RECT = { x0 = 100, yTop = 50, w = 200, h = 100 }   -- yBot = 150
local TMIN, TMAX = 0, 10
local VMIN, VMAX = 0, 100

local rec, cb
local mouse = { x = 0, y = 0 }
local btn   = { clicked = false, double = false, down = false, mods = 0 }

local function record(name)
  return function(...) rec[#rec + 1] = { fn = name, args = { ... } } end
end

local n = 0
local fakeImGui = setmetatable({}, {
  __index = function(tbl, k) n = n + 1; rawset(tbl, k, n); return n end,
})
for _, name in ipairs{
  'DrawList_AddLine', 'DrawList_AddRectFilled', 'DrawList_AddPolyline', 'DrawList_AddCircleFilled',
  'DrawList_PushClipRect', 'DrawList_PopClipRect',
} do fakeImGui[name] = record(name) end
fakeImGui.GetWindowDrawList     = function(_) return 'DL' end
fakeImGui.GetMousePos           = function(_) return mouse.x, mouse.y end
fakeImGui.IsMouseClicked        = function(_) return btn.clicked end
fakeImGui.IsMouseDoubleClicked  = function(_) return btn.double end
fakeImGui.IsMouseDown           = function(_) return btn.down end
fakeImGui.GetKeyMods            = function(_) return btn.mods end
fakeImGui.Mod_Shift      = 4
fakeImGui.DrawFlags_None   = 0
fakeImGui.DrawFlags_Closed = 1

_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end
_G.reaper.new_array            = function(a) return a end   -- painter.polyline hands it screen coords

-- identity chrome: colour(name) -> name, so a recorded colour proves the NAME
-- reached the draw call (pre-migration passes names straight through; the
-- painter version resolves through this same identity).
local chrome = { colour = function(name) return name end }

local callbacks = {
  onMove       = function(i, tt, v) cb.move     = { i, tt, v } end,
  onMoveFree   = function(i, tt, v) cb.moveFree = { i, tt, v } end,
  onInsert     = function(tt, v)    cb.insert   = { tt, v }; return 99 end,
  onDelete     = function(i)        cb.delete   = i end,
  onTension    = function(i, tau)   cb.tension  = { i, tau } end,
  onCycleShape = function(i)        cb.cycle    = i end,
}

local function newEd()
  -- Re-assert our imgui binding at test time: earlier specs' module-load
  -- preloads may have overwritten it, and painter is cached against whatever
  -- fake first loaded it. Nil both so curveEditor and painter rebind to ours.
  package.preload['imgui'] = function() return function(_) return fakeImGui end end
  package.loaded['imgui']   = nil
  package.loaded['painter'] = nil
  return util.instantiate('curveEditor', { ctx = 'CTX', chrome = chrome })
end

-- Three anchors: (t,val) -> screen  (0,20)->(100,130) (5,80)->(200,70) (10,40)->(300,110)
local function events()
  return { { t = 0, val = 20 }, { t = 5, val = 80 }, { t = 10, val = 40 } }
end

local function frameArgs(extra)
  local a = {
    drawList  = 'DL',
    rect      = { x0 = RECT.x0, yTop = RECT.yTop, w = RECT.w, h = RECT.h },
    vMin = VMIN, vMax = VMAX, tMin = TMIN, tMax = TMAX,
    events    = events(),
    tOf       = function(e) return e.t end,
    evalCurve = function(A, B, frac) return A.val + (B.val - A.val) * frac end,
    snap      = function(tt) return math.floor(tt + 0.5) end,
    hovered   = true,
    dragId    = 'd1',
    colours   = { axis = 'laneAxis', envelope = 'laneEnvelope',
                  anchor = 'laneAnchor', anchorActive = 'laneAnchorActive' },
    callbacks = callbacks,
  }
  for k, v in pairs(extra or {}) do a[k] = v end
  return a
end

local function setMouse(x, y, b)
  mouse.x, mouse.y = x, y
  btn.clicked, btn.double, btn.down, btn.mods = false, false, false, 0
  for k, v in pairs(b or {}) do btn[k] = v end
end

local function frame(ed, extra) return ed:frame(frameArgs(extra)) end

local function recsOf(name)
  local out = {}
  for _, c in ipairs(rec) do if c.fn == name then out[#out + 1] = c end end
  return out
end

return {
  {
    name = 'forward map: axis, envelope, clip and anchors draw at mapped positions; idle frame consumes nothing',
    run = function()
      rec, cb = {}, {}
      local ed = newEd()
      setMouse(-100, -100)            -- nowhere near any anchor
      local consumed = frame(ed, { hovered = false })
      t.eq(consumed, false, 'an idle frame returns false')

      local axis = recsOf('DrawList_AddRectFilled')
      t.deepEq(axis[1].args, { 'DL', 100, 150, 300, 151, 'laneAxis' },
        'axis spans x0..x0+w at the val=0 row, 1px filled strip, by name')

      local clip = recsOf('DrawList_PushClipRect')
      t.deepEq(clip[1].args, { 'DL', 96, 46, 304, 154, true },
        'clip is the lane plus a 4px screen gutter')

      local env = recsOf('DrawList_AddPolyline')
      t.eq(#env, 1, 'one envelope polyline')
      t.eq(env[1].args[3], 'laneEnvelope', 'envelope drawn by name')
      t.eq(env[1].args[5], 1.5, 'envelope keeps its screen-px thickness')

      local dots = recsOf('DrawList_AddCircleFilled')
      t.eq(#dots, 3, 'one dot per anchor')
      local function centre(c) return { c.args[2], c.args[3], c.args[4], c.args[5] } end
      t.deepEq(centre(dots[1]), { 100, 130, 2.5, 'laneAnchor' }, 'anchor 1 at (100,130) passive')
      t.deepEq(centre(dots[2]), { 200, 70,  2.5, 'laneAnchor' }, 'anchor 2 at (200,70) passive')
      t.deepEq(centre(dots[3]), { 300, 110, 2.5, 'laneAnchor' }, 'anchor 3 at (300,110) passive')
    end,
  },
  {
    name = 'inverse map: click hits the nearest anchor, then a held drag maps the cursor back to t/val',
    run = function()
      rec, cb = {}, {}
      local ed = newEd()

      setMouse(200, 70, { clicked = true, down = true })   -- exactly on anchor 2
      t.eq(frame(ed), true, 'a click on an anchor consumes the mouse')

      rec, cb = {}, {}
      setMouse(220, 50, { down = true })                   -- drag right+up: t=6, val=100
      frame(ed)
      t.deepEq(cb.move, { 2, 6, 100 },
        'onMove carries the hit-tested index and the inverse-mapped, snapped t/val')
    end,
  },
  {
    name = 'double-click on an anchor deletes it',
    run = function()
      rec, cb = {}, {}
      local ed = newEd()
      setMouse(100, 130, { double = true })                -- on anchor 1
      t.eq(frame(ed), true, 'delete consumes the mouse')
      t.eq(cb.delete, 1, 'onDelete targets the hit anchor')
    end,
  },
  {
    name = 'click on a snapped, unoccupied grid line inserts at the evaluated curve value',
    run = function()
      rec, cb = {}, {}
      local ed = newEd()
      -- t=3 snaps to 3 (no anchor there); curve there = 20 + (80-20)*0.6 = 56,
      -- screen (160, 94). Click on it inserts.
      setMouse(160, 94, { clicked = true, down = true })
      t.eq(frame(ed), true, 'insert consumes the mouse')
      t.deepEq(cb.insert, { 3, 56 }, 'onInsert gets the snapped t and the evaluated val')
    end,
  },
  {
    name = 'double-click on a segment (between snap lines) cycles its shape',
    run = function()
      rec, cb = {}, {}
      local ed = newEd()
      -- t=2.5 is off the snap grid but on the curve (val 50 -> screen 100):
      -- segHover, not anchor/preview hover.
      setMouse(150, 100, { double = true })
      t.eq(frame(ed), true, 'cycle consumes the mouse')
      t.eq(cb.cycle, 1, 'onCycleShape targets the hovered segment')
    end,
  },
}
