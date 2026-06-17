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

local cm, ds, cmgr, gui = (...).cm, (...).ds, (...).cmgr, (...).gui
local ctx, uiFont   = gui.ctx, gui.uiFont
local uiSize        = gui.fontSize.ui

local chrome = util.instantiate('chrome',
  { cm = cm, ctx = ctx, uiFontBold = gui.uiFontBold, uiSize = uiSize })
local modalHost = util.instantiate('modalHost', { ctx = ctx, chrome = chrome })
local help      = util.instantiate('help', { ctx = ctx, chrome = chrome, cmgr = cmgr })

-- F1 toggles the keybinding cheat-sheet (root scope, so every page picks it
-- up). Held off while a modal owns input — the overlay would cover the dialog.
cmgr:register('toggleHelp', function() if not modalHost:isOpen() then help:toggle() end end)
cmgr:bind('toggleHelp', { ImGui.Key_F1 })

-- see docs/coordinator.md § Façade registry
local facades = {}
local facade  = {
  publish = function(name, iface) facades[name] = iface end,
  get     = function(name) return facades[name] or error('no facade: ' .. name) end,
}
local STD = { cm = cm, ds = ds, cmgr = cmgr, chrome = chrome, gui = gui, modalHost = modalHost, help = help, facade = facade }

local CHROME_PAD_X, CHROME_PAD_Y = 8, 4

local pages, active, previous = {}, nil, nil
local quitting      = false
local errHandler    = nil

----- Keyboard router

-- Capture digits and '/' into the prefix buffer; Esc cancels. Returns
-- 'consumed' if a prefix-accumulating key fired this frame; nil otherwise
-- (so the normal keychain walk proceeds). The prefix is NOT finished here
-- on fall-through: dispatchKeys calls finishPrefix only at the moment a
-- bound command is about to fire, so idle frames don't kill the buffer.
-- In prefix mode, digit keys count even with Ctrl/Super held: holding the
-- chord open while typing a count is a natural reach, and any Ctrl-N or
-- Super-N command binding is overridden for the duration of prefix mode.
-- Shift/Alt still disqualify (Shift-digit emits a different char).
local function isDigitMods(mods)
  return (mods & ~(ImGui.Mod_Ctrl | ImGui.Mod_Super)) == 0
end

local function handlePrefixCapture(cmgr, ctx)
  if not cmgr:isPrefixActive() then return nil end
  local mods = ImGui.GetKeyMods(ctx)
  for d = 0, 9 do
    if ImGui.IsKeyPressed(ctx, ImGui.Key_0 + d) and isDigitMods(mods) then
      cmgr:appendPrefix(tostring(d)); return 'consumed'
    end
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Slash) and isDigitMods(mods) then
    cmgr:appendPrefix('/'); return 'consumed'
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    cmgr:cancelPrefix(); return 'consumed'
  end
  return nil
end

--shape: dispatchResult = { consumed: bool, commandHeld: { [imguiKey]=true } } — commandHeld holds only keys that are command-bound AND down
--contract: returns early (no dispatch) when state.suppressKbd or not state.acceptCmds
--contract: state.pageSuppressed shrinks the walk to the root keymap only — body-region editors (swing, tuning) suppress page bindings without shadowing globals like playPause/quit
--contract: first-hit wins; false declines, releases the key, and lets the page char queue see it
--contract: while cmgr:isPrefixActive(), digits and '/' are captured (no dispatch); Esc cancels; any other key freezes the prefix and falls through to the keychain walk so commands can consumePrefix()
local function dispatchKeys(state, cmgr, ctx)
  if state.suppressKbd or not state.acceptCmds then
    return { consumed = false, commandHeld = {} }
  end
  local cap = handlePrefixCapture(cmgr, ctx)
  if cap == 'consumed' then
    return { consumed = true, commandHeld = {} }
  end
  local commandHeld = {}
  local keychain = state.pageSuppressed and { cmgr:rootKeymap() } or cmgr:keychain()
  for _, keymap in ipairs(keychain) do
    for command, keys in pairs(keymap) do
      for _, spec in ipairs(keys) do
        local key, mods = cmgr:keySpec(spec, ImGui)
        if ImGui.IsKeyDown(ctx, key) and mods == ImGui.Mod_None then
          commandHeld[key] = true
        end
        if ImGui.IsKeyPressed(ctx, key) and ImGui.GetKeyMods(ctx) == mods then
          -- Freeze the prefix buffer immediately before invoke so
          -- pendingPrefix is set when invoke reads it as the first arg.
          if cmgr:isPrefixActive() and command ~= 'beginPrefix' then
            cmgr:finishPrefix()
          end
          if cmgr:invoke(command) == false then
            commandHeld[key] = nil
          else
            return { consumed = true, commandHeld = commandHeld }
          end
        end
      end
    end
  end
  return { consumed = false, commandHeld = commandHeld }
end

----- Coordinator

--contract: tick() runs once per frame before the page draws; no selection bus here
local function tick()
  modalHost:tick()
  if pages.sample then pages.sample:tick() end
  if pages.wiring then
    pages.wiring:tick()
    if active == 'wiring' then pages.wiring:syncExternal() end
  end
end

local function drawSwitcher()
  local function pageButton(label, name)
    local isActive = active == name
    if isActive then
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, chrome.colour('toolbar.buttonActive'))
    end
    if ImGui.Button(ctx, label) and not isActive then
      cmgr:invoke('switchPage', name)
    end
    if isActive then ImGui.PopStyleColor(ctx, 1) end
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

local function dispatch(state)
  -- While the cheat-sheet is up, all dispatch is suppressed; help:draw closes
  -- on any key or an off-box click, swallowing the gesture.
  if help:isOpen() then
    state = { suppressKbd = true, pageSuppressed = true, acceptCmds = false }
  end
  return dispatchKeys(state, cmgr, ctx)
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

local function frame()
  cm:pollUndo()
  pollExternalCommands()
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

  if visible and page then
    -- Toolbar band
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, chrome.colour('toolbar.bg'))
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, CHROME_PAD_X, CHROME_PAD_Y)
    if ImGui.BeginChild(ctx, '##toolbar', 0, 0,
                        ImGui.ChildFlags_AutoResizeY | ImGui.ChildFlags_AlwaysUseWindowPadding,
                        ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoNav) then
      chrome.pushChromeStyles()
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 10, 3)
      drawSwitcher()
      ImGui.SameLine(ctx, 0, 12)
      chrome.verticalSeparator()
      ImGui.SameLine(ctx, 0, 12)
      page:renderToolbarBits(ctx)
      ImGui.PopStyleVar(ctx, 1)
      chrome.popChromeStyles()
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

--shape: page = { renderToolbarBits(ctx), renderBody(ctx,w,h,dispatch), renderStatusBar(ctx), bind(...), unbind() }
--contract: register instantiates page; first registered becomes active; returns page handle
local coord = {}

function coord:register(name, moduleName, extra)
  local page = util.instantiate(moduleName, util.assign(util.assign({}, STD), extra))
  pages[name] = page
  if not active then self:setActive(name) end
  return page
end

--contract: setActive(name) no-ops if name==active; else unbind outgoing, swap scope, bind incoming
--contract: tracker self-binds from the cursor in renderBody; activation binds nothing for it
function coord:setActive(name)
  if active == name then return true end
  previous = active
  if active and pages[active] then
    pages[active]:unbind()
    cmgr:pop(active)
  end
  active = name
  help:setPage(name)
  cmgr:push(name)
  if name ~= 'tracker' then pages[name]:bind() end
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
function coord:reloadAfterExternalMutation()
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

return coord
