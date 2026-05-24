-- See docs/wiringPage.md for the model.
-- @noindex

--invariant: render + input only — wiringPage draws the canvas and reads keyboard / mouse. It holds no wm reference: every graph query goes through wv, every mutation will go through wv (the manager-facing surface).
--invariant: wiring page is project-wide — bind() takes no take and never re-keys cm; the tracker take and the sampler track are unaffected by switching to / from wiring.
--invariant: the page owns every pixel — node-box geometry, port slot layout, hit-test boxes are all derived here from wv's viewport-independent nodeViews. wv carries label + audio/midi counts; the page turns those into rects.
--invariant: at Stage 1.3a the page draws only — no editing, no wiring-scope commands, no palette. Selection / hover / drag arrive in 1.3b.

local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local cm, cmgr, chrome, gui, modalHost =
  (...).cm, (...).cmgr, (...).chrome, (...).gui, (...).modalHost

local ctx    = gui and gui.ctx or nil
local uiSize = gui and gui.fontSize and gui.fontSize.ui or 12

local wv = util.instantiate('wiringView', { cm = cm, cmgr = cmgr })

local wp = {}

local NODE_W          = 120
local NODE_HEADER_H   = 18
local PORT_SIZE       = 8
local PORT_SPACING    = 4
local PORT_EDGE_INSET = 6

----- Pixel geometry (page-owned)

local function totalPortCount(side) return side.audio + side.midi end

-- Per-node pixel rect in canvas-local coordinates (origin = top-left of the
-- canvas child window). Height grows with port count so ports never overflow.
local function nodeRect(nv)
  local rows  = math.max(totalPortCount(nv.ins), totalPortCount(nv.outs))
  local bodyH = math.max(NODE_HEADER_H,
                         rows * (PORT_SIZE + PORT_SPACING) + PORT_SPACING)
  local h     = NODE_HEADER_H + bodyH
  return nv.pos.x, nv.pos.y, nv.pos.x + NODE_W, nv.pos.y + h
end

----- Drawing

local function drawNode(dl, nv, ox, oy, fill, border, textCol)
  local lx0, ly0, lx1, ly1 = nodeRect(nv)
  local x0, y0, x1, y1 = ox + lx0, oy + ly0, ox + lx1, oy + ly1
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, fill)
  ImGui.DrawList_AddRect      (dl, x0, y0, x1, y1, border, 0, 0, 1)
  ImGui.DrawList_AddLine      (dl, x0, y0 + NODE_HEADER_H,
                                   x1, y0 + NODE_HEADER_H, border, 1)
  local tw = ImGui.CalcTextSize(ctx, nv.label)
  ImGui.DrawList_AddText(dl,
    x0 + math.floor((NODE_W - tw) / 2), y0 + 2, textCol, nv.label)

  -- Ports: small filled squares on the body edges, in/out columns. Audio
  -- rows above MIDI rows.
  local bodyTop = y0 + NODE_HEADER_H + PORT_SPACING
  local function drawColumn(count, atX)
    for i = 1, count do
      local py = bodyTop + (i - 1) * (PORT_SIZE + PORT_SPACING)
      ImGui.DrawList_AddRectFilled(dl,
        atX, py, atX + PORT_SIZE, py + PORT_SIZE, border)
    end
  end
  drawColumn(totalPortCount(nv.ins),  x0 + PORT_EDGE_INSET)
  drawColumn(totalPortCount(nv.outs), x1 - PORT_EDGE_INSET - PORT_SIZE)
end

local function renderCanvas(w, h)
  local dl       = ImGui.GetWindowDrawList(ctx)
  local ox, oy   = ImGui.GetCursorScreenPos(ctx)
  local bgFill   = chrome.colour('bg')
  local border   = chrome.colour('separator')
  local textCol  = chrome.colour('text')
  ImGui.DrawList_AddRectFilled(dl, ox, oy, ox + w, oy + h, bgFill)
  for _, nv in ipairs(wv:nodeViews()) do
    drawNode(dl, nv, ox, oy, bgFill, border, textCol)
  end
  -- Reserve the canvas area so the child window sizes itself; without
  -- this the drawlist paints into a zero-sized child.
  ImGui.Dummy(ctx, w, h)
end

local function pushBodyStyles()
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, chrome.colour('text'))
end
local function popBodyStyles() ImGui.PopStyleColor(ctx, 1) end

----------- PUBLIC

--contract: bind takes no take — wiring is project-wide. coord may call with no args (or a take, ignored).
function wp:bind() end
function wp:unbind() end

function wp:renderToolbarBits(_) end

--contract: pushes body palette, draws the canvas, invokes dispatch at end-of-body so wiring-scope keys (when 1.3b adds them) reach the dispatcher.
function wp:renderBody(_, w, h, dispatch)
  if not ctx then return end
  pushBodyStyles()
  if ImGui.BeginChild(ctx, '##wiringCanvas', w, h,
                      ImGui.ChildFlags_None,
                      ImGui.WindowFlags_NoNav) then
    renderCanvas(w, h)
  end
  ImGui.EndChild(ctx)
  popBodyStyles()
  if dispatch then dispatch(self:focusState()) end
end

function wp:renderStatusBar(_)
  if not ctx then return end
  ImGui.Text(ctx, 'wiring')
end

--contract: acceptCmds=false if picker active, any item active, or modal was open at frame start.
function wp:focusState()
  if not ctx then return { suppressKbd = false, acceptCmds = false } end
  local pa = chrome and chrome.pickerIsActive() or false
  return {
    suppressKbd = pa,
    acceptCmds  = (not pa)
                  and not ImGui.IsAnyItemActive(ctx)
                  and not modalHost:wasOpenAtFrameStart(),
  }
end


return wp
