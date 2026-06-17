-- See docs/editorPage.md for the model.
-- @noindex
--
-- editorPage is the library-workbench page's controller — the object coord
-- drives. It hosts the swing and temper editors as content panes behind a
-- toolbar pane-selector, and returns to the previous page on close.

--contract: hosts swing + temper panes; pane state persists across visits; close returns to coord's previous page (via the closeEditor command)
--contract: body editor — focusState always page-suppresses (root globals stay live, page bindings off)
local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local cm, ds, cmgr, chrome, gui, modalHost, facade =
  (...).cm, (...).ds, (...).cmgr, (...).chrome, (...).gui, (...).modalHost, (...).facade
local ctx, uiFont, uiSize = gui.ctx, gui.uiFont, gui.fontSize.ui

local swingEditor  = util.instantiate('swingEditor',
  { cm = cm, ds = ds, chrome = chrome, ctx = ctx, facade = facade })
local temperEditor = util.instantiate('temperEditor',
  { cm = cm, chrome = chrome, ctx = ctx, facade = facade })

local pane = 'swing'   -- 'swing' | 'temper'
local function activePane() return pane == 'temper' and temperEditor or swingEditor end

local ep = {}
local function onClose() cmgr:invoke('closeEditor') end

----------- PUBLIC

-- Fast path: set the pane + selection here; the editTuning/editSwing commands
-- (which hold coord) switch the page. Mirrors samplePage's diveToSampler.
facade.publish('editor', {
  edit = function(lib, name)
    if lib == 'temper' then
      pane = 'temper'; temperEditor:select(name)
    else
      pane = 'swing';  swingEditor:open(name)
    end
  end,
})

----- Page lifecycle — no take binding; pane state persists across visits
function ep:bind()   end
function ep:unbind() end

function ep:renderToolbarBits(_)
  local function paneButton(label, id)
    local isActive = pane == id
    if isActive then ImGui.PushStyleColor(ctx, ImGui.Col_Button, chrome.colour('toolbar.buttonActive')) end
    if ImGui.Button(ctx, label) and not isActive then pane = id end
    if isActive then ImGui.PopStyleColor(ctx, 1) end
  end
  paneButton('Swing',  'swing')
  ImGui.SameLine(ctx, 0, 4)
  paneButton('Temper', 'temper')
  ImGui.SameLine(ctx, 0, 12)
  chrome.verticalSeparator()
  ImGui.SameLine(ctx, 0, 12)
  if ImGui.Button(ctx, 'Close (Esc)') then onClose() end
end

function ep:renderBody(_, w, h, dispatch)
  -- Dispatch BEFORE render so focusState reads modal-active while it's set
  -- (same ordering as the tracker path).
  if dispatch then dispatch(self:focusState()) end
  local p = activePane()
  -- Page-level Esc returns to the previous page; guarded so an active
  -- InputText/slider keeps Esc to cancel itself, and a sub-modal owns it.
  if not p:modalActive() and not ImGui.IsAnyItemActive(ctx)
     and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    onClose(); return
  end
  if pane == 'swing' and not swingEditor:isOpen() then swingEditor:open() end
  ImGui.PushFont(ctx, uiFont, uiSize)
  p:render(w, h, onClose)
  ImGui.PopFont(ctx)
end

function ep:renderStatusBar(_)
  ImGui.Text(ctx, ('Editor — %s · Esc returns'):format(pane == 'temper' and 'Temper' or 'Swing'))
end

--shape: focusState = { suppressKbd:bool, pageSuppressed:bool, acceptCmds:bool }
function ep:focusState()
  if not ctx then return { suppressKbd = false, pageSuppressed = false, acceptCmds = false } end
  local suppressKbd = modalHost:isOpen() or chrome.pickerIsActive() or activePane():modalActive()
  return {
    suppressKbd    = suppressKbd,
    pageSuppressed = true,
    acceptCmds     = (not suppressKbd) and not ImGui.IsAnyItemActive(ctx),
  }
end

return ep
