-- See docs/wiringPage.md for the model.
-- @noindex

--invariant: render + input only — wiringPage draws the canvas and reads keyboard / mouse. It holds no wm reference: every graph query goes through wv, every mutation will go through wv (the manager-facing surface).
--invariant: wiring page is project-wide — bind() takes no take and never re-keys cm; the tracker take and the sampler track are unaffected by switching to / from wiring.
--invariant: the page owns every pixel — node-box geometry, port slot layout, hit-test boxes are all derived here from wv's viewport-independent nodeViews. wv carries label + category + audio/MIDI counts; the page turns those into rects and tints.
--invariant: at Stage 1.3a the page draws only — no editing, no wiring-scope commands, no palette. Hover reveals ports (visual cue, no interaction). Selection / drag arrive in 1.3b.

local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local cm, cmgr, chrome, gui, modalHost =
  (...).cm, (...).cmgr, (...).chrome, (...).gui, (...).modalHost

local ctx      = gui and gui.ctx or nil
local wireFont = gui and gui.wireFont or nil
local wireSize = gui and gui.fontSize and gui.fontSize.wire or 14

local wv = util.instantiate('wiringView', { cm = cm, cmgr = cmgr })

local wp = {}

local NODE_W           = 96
local NODE_H           = 72
local CORNER_R         = 4
local PORT_SIZE        = 8
local PORT_GAP         = 4
local PORT_BAND_OFFSET = 6   -- gap between node edge and the hover-only port row

----- Pixel geometry (page-owned)

-- pos is the node's centre in canvas-local coordinates (origin = centre
-- of the viewport, set up in renderCanvas); rect is laid out symmetrically.
local function nodeRect(nv)
  local hw, hh = NODE_W / 2, NODE_H / 2
  return nv.pos.x - hw, nv.pos.y - hh, nv.pos.x + hw, nv.pos.y + hh
end

----- Drawing

local function drawNode(dl, nv, ox, oy)
  local lx0, ly0, lx1, ly1 = nodeRect(nv)
  local x0, y0, x1, y1 = ox + lx0, oy + ly0, ox + lx1, oy + ly1
  local fill = chrome.colour('wiring.node.' .. nv.category)
  local text = chrome.colour('text')
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, fill, CORNER_R)
  if wireFont then ImGui.PushFont(ctx, wireFont, wireSize) end
  local tw, th = ImGui.CalcTextSize(ctx, nv.label)
  ImGui.DrawList_AddText(dl,
    x0 + math.floor((NODE_W - tw) / 2),
    y0 + math.floor((NODE_H - th) / 2),
    text, nv.label)
  if wireFont then ImGui.PopFont(ctx) end
end

-- Horizontal row of port squares centred over [x0,x1] at vertical `y`.
-- Audio squares first, then MIDI; counts may be 0.
local function drawPortBand(dl, x0, x1, y, audio, midi, audioCol, midiCol)
  local total = audio + midi
  if total == 0 then return end
  local rowW = total * PORT_SIZE + (total - 1) * PORT_GAP
  local cx   = math.floor((x0 + x1 - rowW) / 2)
  for i = 1, audio do
    local px = cx + (i - 1) * (PORT_SIZE + PORT_GAP)
    ImGui.DrawList_AddRectFilled(dl, px, y, px + PORT_SIZE, y + PORT_SIZE, audioCol)
  end
  for i = 1, midi do
    local px = cx + (audio + i - 1) * (PORT_SIZE + PORT_GAP)
    ImGui.DrawList_AddRectFilled(dl, px, y, px + PORT_SIZE, y + PORT_SIZE, midiCol)
  end
end

local function drawHoverPorts(dl, nv, ox, oy)
  local lx0, ly0, lx1, ly1 = nodeRect(nv)
  local x0, y0, x1, y1 = ox + lx0, oy + ly0, ox + lx1, oy + ly1
  local audioCol = chrome.colour('wiring.port.audio')
  local midiCol  = chrome.colour('wiring.port.midi')
  drawPortBand(dl, x0, x1,
    y0 - PORT_BAND_OFFSET - PORT_SIZE,
    nv.ins.audio,  nv.ins.midi,  audioCol, midiCol)
  drawPortBand(dl, x0, x1,
    y1 + PORT_BAND_OFFSET,
    nv.outs.audio, nv.outs.midi, audioCol, midiCol)
end

local function renderCanvas(w, h)
  local dl     = ImGui.GetWindowDrawList(ctx)
  local sx, sy = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddRectFilled(dl, sx, sy, sx + w, sy + h, chrome.colour('bg'))
  -- Canvas origin is the centre of the viewport: logical (0,0) draws
  -- in the middle, positions extend in all four quadrants from there.
  local ox, oy = sx + math.floor(w / 2), sy + math.floor(h / 2)

  local hoveredNV = nil
  for _, nv in ipairs(wv:nodeViews()) do
    local lx0, ly0, lx1, ly1 = nodeRect(nv)
    if ImGui.IsMouseHoveringRect(ctx,
         ox + lx0, oy + ly0, ox + lx1, oy + ly1) then
      hoveredNV = nv
    end
    drawNode(dl, nv, ox, oy)
  end
  if hoveredNV then drawHoverPorts(dl, hoveredNV, ox, oy) end
  wv:setHover(hoveredNV and hoveredNV.id or nil)

  -- Reserve canvas area so the child window sizes itself; without this
  -- the drawlist paints into a zero-sized child and hover never fires.
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
