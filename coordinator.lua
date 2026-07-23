-- See docs/coordinator.md for the model.

--invariant: owns the active tracker take; polls REAPER's selection each frame while tracker page is active (sticky on no-item or non-MIDI)
--invariant: no teardown path — quit() sets a flag that stops scheduling further defers; REAPER reclaims state on script unload
--invariant: each deferred frame xpcalls via coord:run's handler; reaper.defer drops the xpcall

local util  = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB('ReaImGui is required. Install it via ReaPack.', 'Continuum', 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'
local keyDispatch = require 'keyDispatch'

local cm, ds, eventMeta, cmgr, gui = (...).cm, (...).ds, (...).eventMeta, (...).cmgr, (...).gui
local ctx, uiFont   = gui.ctx, gui.uiFont
local uiSize        = gui.fontSize.ui

local lib = util.instantiate('library',
  { cm = cm, synthetic = { swings = { identity = true }, tempers = { ['12EDO'] = true } } })

local chrome = util.instantiate('chrome',
  { cm = cm, ctx = ctx, uiSize = uiSize, lib = lib })
local toolbar = chrome.makeToolbar()   -- one shared toolbar; renders the active page's row
local modalHost = util.instantiate('modalHost', { ctx = ctx, chrome = chrome })
local help      = util.instantiate('help', { ctx = ctx, chrome = chrome, cmgr = cmgr })
local masterMix = util.instantiate('masterMix', { ctx = ctx, chrome = chrome })
-- Live-REAPER eval bridge — assigned after coord (its env captures coord). See docs/bridge.md.
local bridge

-- F1 toggles the keybinding cheat-sheet (root scope, so every page picks it
-- up). Held off while a modal owns input — the overlay would cover the dialog.
cmgr:register('toggleHelp', function() if not modalHost:isOpen() then help:toggle() end end)
cmgr:bind('toggleHelp', { ImGui.Key_F1 })

-- see docs/coordinator.md § Façade registry
local facades, debugHandles = {}, {}
local facade  = {
  publish = function(name, iface) facades[name] = iface end,
  get     = function(name) return facades[name] or error('no facade: ' .. name) end,
  -- Raw page stack for the reaper bridge ONLY — diagnostics, not a production surface. See docs/bridge.md § The eval environment.
  publishDebug = function(name, stack) debugHandles[name] = stack end,
}
local STD = { cm = cm, ds = ds, eventMeta = eventMeta, cmgr = cmgr, chrome = chrome, gui = gui,
              modalHost = modalHost, help = help, facade = facade, lib = lib }

local CHROME_PAD_X, CHROME_PAD_Y = 8, 4

local pages, active, previous = {}, nil, nil
local lastToolbarActive = nil   -- last page measured; a switch re-pins the band height
local bootSettled   = false  -- latched once boot transients (fonts, window width) settle
local bootFrames    = 0
local lastAvailW    = nil
local quitting      = false
local errHandler    = nil
local focusFrames   = 0      -- >0: re-focus our window this many frames, counting down
local fxFloatOpen   = false  -- an FX float window was open at the last poll
local weHadFocus    = false  -- our window held focus at the end of the last frame
local myHwnd                 -- our OS window HWND, captured via js while we hold focus
local jsFocus       = reaper.JS_Window_GetForeground ~= nil   -- js_ReaScriptAPI present

----- Coordinator

--contract: tick() runs once per frame before the page draws; no selection bus here
local function tick()
  modalHost:tick()
  if pages.sample then pages.sample:tick() end
  if pages.wiring and active == 'wiring' then pages.wiring:syncExternal() end
  bridge:tick()
end

local function drawSwitcher()
  local function pageButton(label, name)
    local isActive = active == name
    if isActive then
      -- Match hover to the active fill so a selected button stays put on hover.
      ImGui.PushStyleColor(ctx, ImGui.Col_Button,        chrome.colour('toolbar.buttonActive'))
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, chrome.colour('toolbar.buttonActive'))
    end
    if ImGui.Button(ctx, label) and not isActive then
      cmgr:invoke('switchPage', name)
    end
    if isActive then ImGui.PopStyleColor(ctx, 2) end
  end
  pageButton('A', 'arrange')
  ImGui.SameLine(ctx, 0, 4)
  pageButton('W', 'wiring')
  ImGui.SameLine(ctx, 0, 4)
  pageButton('T', 'tracker')
  ImGui.SameLine(ctx, 0, 4)
  pageButton('S', 'sample')
  ImGui.SameLine(ctx, 0, 4)
  pageButton('E', 'editor')
end

-- The switcher is the row's first toolbar segment, so the whole row wraps and
-- measures as one chrome.toolbar list (every page records at least this rect).
local switcherSeg = { id = 'switcher', render = drawSwitcher }

local function dispatch(state)
  -- While the cheat-sheet is up, all dispatch is suppressed; help:draw closes
  -- on any key or an off-box click, swallowing the gesture.
  if help:isOpen() then
    state = { suppressKbd = true, pageSuppressed = true, acceptCmds = false }
  end
  return keyDispatch.dispatchKeys(state, cmgr, ctx)
end

----- External commands (REAPER-keymap bridge)

-- Companion REAPER actions set ExtState('Continuum', key); consumed each frame
-- to fire commands, bridging REAPER-keymap keys (reachable over focused FX).
local externalCommands = {}   -- list of { extKey, command }

local function pollExternalCommands()
  for _, ec in ipairs(externalCommands) do
    if reaper.GetExtState('Continuum', ec.extKey) ~= '' then
      reaper.DeleteExtState('Continuum', ec.extKey, false)
      cmgr:invoke(ec.command)
    end
  end
end

-- Any floating FX window open across master + tracks. The poll in frame() reads
-- its open→closed edge (X button or F11) to reclaim OS focus from REAPER.
local function anyFxFloating()
  local function trackFloats(track)
    for fxIdx = 0, reaper.TrackFX_GetCount(track) - 1 do
      if reaper.TrackFX_GetFloatingWindow(track, fxIdx) then return true end
    end
    return false
  end
  if trackFloats(reaper.GetMasterTrack(0)) then return true end
  for i = 0, reaper.CountTracks(0) - 1 do
    if trackFloats(reaper.GetTrack(0, i)) then return true end
  end
  return false
end

local function frame()
  cm:pollUndo()
  pollExternalCommands()
  -- While we lack focus, watch the floating-FX set: its open→closed edge means
  -- the user dismissed the last one (X or F11) and REAPER stole focus — reclaim.
  if jsFocus and not weHadFocus then
    local nowOpen = anyFxFloating()
    if fxFloatOpen and not nowOpen then focusFrames = 2 end
    fxFloatOpen = nowOpen
  end
  tick()
  help:beginFrame()
  local page = pages[active]

  ImGui.PushFont(ctx, uiFont, uiSize)
  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg,     chrome.colour('bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg,      chrome.colour('toolbar.bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive,chrome.colour('toolbar.bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarBg,  chrome.colour('scrollBg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrab,chrome.colour('scrollHandle'))

  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 0, 0)
  if focusFrames > 0 then
    ImGui.SetNextWindowFocus(ctx)              -- ImGui-internal focus; must precede Begin
    if myHwnd then reaper.JS_Window_SetForeground(myHwnd) end   -- the OS-level focus grab
    focusFrames = focusFrames - 1
  end
  local visible, open = ImGui.Begin(ctx, 'Continuum', true,
    ImGui.WindowFlags_NoScrollbar
    | ImGui.WindowFlags_NoScrollWithMouse
    | ImGui.WindowFlags_NoDocking
    | ImGui.WindowFlags_NoNav
    | ImGui.WindowFlags_NoMove)
  ImGui.PopStyleVar(ctx)
  -- Active-item drags (e.g. the lane strip's curve editor) can otherwise
  -- accumulate auto-scroll on the parent window, pushing the grid below
  -- the visible region for the duration of the drag.
  if visible then ImGui.SetScrollY(ctx, 0); ImGui.SetScrollX(ctx, 0) end
  -- Cache our OS window while we hold focus, so focusFrames can restore it later.
  weHadFocus = visible and ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows)
  if weHadFocus and jsFocus then myHwnd = reaper.JS_Window_GetForeground() end

  -- Boot warm-up: hold content a few frames until ReaImGui builds the font
  -- atlas and the window width settles, then latch (never re-gates on resize).
  if visible and not bootSettled then
    bootFrames = bootFrames + 1
    local availW = ImGui.GetContentRegionAvail(ctx)
    if bootFrames >= 4 and availW == lastAvailW then bootSettled = true end
    lastAvailW = availW
  end

  if visible and page and bootSettled then
    -- Toolbar band. The row wraps to a 2nd line at narrow widths and the child
    -- auto-resizes to fit. See docs/coordinator.md § Toolbar band height.
    local function drawToolbarRow()
      chrome.pushChromeStyles()
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 6, 2)
      local segs = { switcherSeg, masterMix.segment }
      for _, s in ipairs(page:toolbarSegments()) do segs[#segs + 1] = s end
      toolbar(segs)
      ImGui.PopStyleVar(ctx, 1)
      chrome.popChromeStyles()
    end

    -- Uniform band height: lineCount × standard row height, identical on every page.
    -- Hidden pass on switch warms widths + line count so frame-1 pins correctly.
    if active ~= lastToolbarActive then
      lastToolbarActive = active
      local sx, sy = ImGui.GetCursorScreenPos(ctx)
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_Alpha, 0)
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, CHROME_PAD_X, CHROME_PAD_Y)
      if ImGui.BeginChild(ctx, '##toolbarMeasure', 0, 0,
                          ImGui.ChildFlags_AutoResizeY | ImGui.ChildFlags_AlwaysUseWindowPadding,
                          ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoNav) then
        drawToolbarRow()
      end
      ImGui.EndChild(ctx)
      ImGui.PopStyleVar(ctx, 2)
      ImGui.SetCursorScreenPos(ctx, sx, sy)
    end

    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 9, 2)
    local rowH = ImGui.GetFrameHeight(ctx)
    ImGui.PopStyleVar(ctx, 1)
    local _, spacingY = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
    local lines       = chrome.toolbarLineCount()
    local bandH       = lines * rowH + (lines - 1) * spacingY

    chrome.resetPickerActive()
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, chrome.colour('toolbar.bg'))
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, CHROME_PAD_X, CHROME_PAD_Y)
    ImGui.SetNextWindowContentSize(ctx, 0, bandH)
    if ImGui.BeginChild(ctx, '##toolbar', 0, 0,
                        ImGui.ChildFlags_AutoResizeY | ImGui.ChildFlags_AlwaysUseWindowPadding,
                        ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoNav) then
      drawToolbarRow()
    end
    ImGui.EndChild(ctx)
    ImGui.PopStyleVar(ctx)
    ImGui.PopStyleColor(ctx)

    -- Body region: reserve a fixed footer for the status bar; the
    -- page paints into the remaining viewport at (CHROME_PAD_X,
    -- toolbarBottom + CHROME_PAD_Y).
    local cursorY     = ImGui.GetCursorPosY(ctx)
    local availW0, availH = ImGui.GetContentRegionAvail(ctx)
    local footerH     = ImGui.GetFrameHeightWithSpacing(ctx) + 4
    local bodyH       = availH - footerH

    ImGui.Indent(ctx, CHROME_PAD_X)
    ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + CHROME_PAD_Y)
    page:renderBody(ctx,
      availW0 - CHROME_PAD_X * 2,
      bodyH   - CHROME_PAD_Y,
      dispatch)
    ImGui.Unindent(ctx, CHROME_PAD_X)

    -- Status band pinned to (toolbarBottom + bodyH); the parchment
    -- gap above is the leftover.
    ImGui.SetCursorPosY(ctx, cursorY + bodyH)
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, chrome.colour('statusBar.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_Text,    chrome.colour('statusBar.text'))
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, CHROME_PAD_X + 4, CHROME_PAD_Y)
    if ImGui.BeginChild(ctx, '##statusBar', 0, footerH,
                        ImGui.ChildFlags_AlwaysUseWindowPadding,
                        ImGui.WindowFlags_NoScrollbar) then
      page:renderStatusBar(ctx)
    end
    ImGui.EndChild(ctx)
    ImGui.PopStyleVar(ctx)
    ImGui.PopStyleColor(ctx, 2)
  end

  if visible then help:draw() end
  if visible then modalHost:draw() end

  ImGui.End(ctx)

  ImGui.PopStyleColor(ctx, 5)
  ImGui.PopFont(ctx)

  if open and not quitting then reaper.defer(function() xpcall(frame, errHandler) end) end
end

---------- PUBLIC

--shape: page = { toolbarSegments(), renderBody(ctx,w,h,dispatch), renderStatusBar(ctx), bind(...), unbind() }
--contract: register instantiates page; first registered becomes active; returns page handle
local coord = {}

function coord:register(name, moduleName, extra)
  local page = util.instantiate(moduleName, util.assign(util.assign({}, STD), extra))
  pages[name] = page
  if not active then self:setActive(name) end
  return page
end

--contract: setActive(name) no-ops if name==active; else unbind outgoing, swap scope, bind incoming
--contract: tracker's no-arg bind resolves its stored selection; renderBody keeps it current
function coord:setActive(name)
  if active == name then return true end
  previous = active
  if active and pages[active] then
    pages[active]:unbind()
    chrome.resetToolbar()
    cmgr:pop(active)
  end
  active = name
  help:setPage(name)
  cmgr:push(name)
  pages[name]:bind()
  return true
end

--contract: tracker back to arrange; no reveal (cursor never left). No-op if arrange unregistered.
function coord:returnToArrange()
  if not pages.arrange then return end
  self:setActive('arrange')
end

--contract: resolve a published page facade by name; the contents are owned by the publishing page
function coord:getFacade(name) return facade.get(name) end

--contract: the page active immediately before the current one; closeEditor returns here
function coord:previousPage() return previous end

-- Cycle tracker → arrange → sample → wiring → tracker. Unregistered pages
-- are skipped; with ≥1 track every page activates.
function coord:togglePage()
  local order = { 'tracker', 'arrange', 'sample', 'wiring' }
  local idx
  for i, name in ipairs(order) do if name == active then idx = i; break end end
  for step = 1, #order do
    local next = order[((idx or 0) + step - 1) % #order + 1]
    if pages[next] and self:setActive(next) then return end
  end
end

--contract: invoke after firing a REAPER action that mutates the bound take from inside a frame (Ctrl-Z, Ctrl-Shift-Z). The watcher's end-of-frame baseline would otherwise absorb the mutation; this reloads now so tm/vm stay coherent with the take.
--invariant: mirror resync precedes reload — see docs/coordinator.md § Undo mid-frame
function coord:reloadAfterExternalMutation()
  cm:pollUndo()
  if active == 'tracker' and pages.tracker then
    pages.tracker:reloadFromReaper()
  end
end

--contract: registers an ExtState key→command bridge polled each frame to fire Continuum commands
function coord:onExternalCommand(extKey, command)
  externalCommands[#externalCommands + 1] = { extKey = extKey, command = command }
end

function coord:quit()      quitting = true end
--contract: handler wraps every deferred frame; without it, post-frame-1 errors raise raw dialogs
function coord:run(handler) errHandler = handler or function(e) error(e) end; frame() end

-- Eval env for the bridge. page() is a labelled hole in the layering rule: raw page
-- stacks for diagnostics, while facades stay the curated surface. See docs/bridge.md.
bridge = util.instantiate('bridge', { env = {
  reaper = reaper, util = util,
  cm = cm, ds = ds, eventMeta = eventMeta, cmgr = cmgr, coord = coord,
  facade = function(name) return coord:getFacade(name) end,
  page   = function(name) return debugHandles[name] end,
} })

return coord
