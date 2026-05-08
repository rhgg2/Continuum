-- See docs/continuum.md for the model.

--@map:invariant entry point — owns lifecycle (Main runs once per ReaScript invocation), wires the layered manager stack, drives the render loop via reaper.defer
--@map:invariant module load order is bottom-up: util first (everyone calls util.installHooks), commandManager before view layers (which self-register commands), pages last
--@map:invariant the coordinator owns the active tracker take; Main starts with no take and the coordinator polls REAPER's selection each frame while the tracker page is active (sticky on no-item or non-MIDI)
--@map:invariant no teardown path — coord:quit() sets a flag that stops scheduling further defers; REAPER reclaims state on script unload
--@map:invariant errors inside the defer loop surface through the same xpcall frame because each iteration reschedules itself

function loadModule(module)
  local info = debug.getinfo(1,'S')
  local script_path = info.source:match[[^@?(.*[\/])[^\/]-$]]
  require(script_path .. module)
end

loadModule('util')
loadModule('fs')
loadModule('configManager')
loadModule('midiManager')
loadModule('trackerManager')
loadModule('commandManager')
loadModule('editCursor')
loadModule('trackerView')
loadModule('sampleManager')
loadModule('sampleView')
loadModule('swingEditor')
loadModule('sequenceManager')
loadModule('curveEditor')
loadModule('chrome')
loadModule('trackerPage')
loadModule('samplePage')

local ImGui = require 'imgui' '0.10'

math.randomseed(os.time())

local function print(...)
  return util.print(...)
end

local function err_handler(err)
  reaper.ShowConsoleMsg('\nERROR:\n' .. tostring(err) .. '\n\n')
  reaper.ShowConsoleMsg(debug.traceback() .. '\n')
  reaper.defer(function() end)
end

local function run(fn)
  reaper.ClearConsole()
  xpcall(fn, err_handler)
end

local function createImGui()
  local ctx   = ImGui.CreateContext('Continuum Tracker')
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_ViewportsNoDecoration, 0)
  -- Body drags must not move the window — only title-bar drags do.
  -- Lane-strip and grid drags otherwise propagate as a window move.
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_WindowsMoveFromTitleBarOnly, 1)
  -- macOS' system font is private (dot-prefixed) and not reachable by
  -- family name, so load SFNS.ttf directly. Other platforms resolve by name.
  local osName = reaper.GetOS()
  local font   = ImGui.CreateFont('Source Code Pro')
  local uiFont = (osName:find('OSX') or osName:find('mac'))
               and ImGui.CreateFontFromFile('/System/Library/Fonts/SFNS.ttf')
               or  ImGui.CreateFont(osName:find('Win') and 'Segoe UI' or 'sans-serif')
  ImGui.Attach(ctx, font)
  ImGui.Attach(ctx, uiFont)
  return {ctx = ctx, font = font, uiFont = uiFont}
end

----- Keyboard router

--@map:shape dispatchResult = { consumed: bool, commandHeld: bool }
--@map:contract returns early (no dispatch) when state.suppressKbd or not state.acceptCmds
--@map:contract first-hit wins across the keychain; a command returning false declines and releases the key (clearing commandHeld) so the page char queue sees it
local function dispatchKeys(state, cmgr, ctx)
  if state.suppressKbd or not state.acceptCmds then
    return { consumed = false, commandHeld = false }
  end
  local commandHeld = false
  for _, keymap in ipairs(cmgr:keychain()) do
    for command, keys in pairs(keymap) do
      for _, spec in ipairs(keys) do
        local key, mods = cmgr:keySpec(spec, ImGui)
        if ImGui.IsKeyDown(ctx, key) and mods == ImGui.Mod_None then
          commandHeld = true
        end
        if ImGui.IsKeyPressed(ctx, key) and ImGui.GetKeyMods(ctx) == mods then
          if cmgr:invoke(command) == false then
            commandHeld = false
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

local CHROME_PAD_X, CHROME_PAD_Y = 8, 4

--@map:shape page = { renderToolbarBits(ctx), renderBody(ctx,w,h,dispatch), renderStatusBar(ctx), bind(...), unbind(), [renderFloating(ctx)] }
--@map:contract pages must be registered via coord:register(name,page); first registered becomes active
--@map:contract setActive(name) is a no-op when name == active; otherwise unbinds the outgoing page, swaps cmgr scope, and binds the incoming page (tracker→currentTake, sample→samplerTrack)
--@map:contract tick() runs once per frame before the page draws; setPrefix is republished only when the project path changes (one mailbox cell shared across instances)
--@map:contract owns the cross-cutting tracker-scope command (loadSampleAtCurrentSlot) but dispatches into samplePage which owns sm; coord never speaks sm directly
--@map:contract owns the active sampler track — the picker on samplePage delegates here, and first sample-page activation seeds the default from pages.sample:listTracks()
--@map:contract owns currentTake — refreshTakeFromReaper polls GetSelectedMediaItem→GetActiveTake→TakeIsMIDI, mutates currentTake only on a real MIDI take that differs (sticky on nothing-selected or non-MIDI), and returns true so the caller can rebind
local function newCoordinator(cm, cmgr, gui)
  local pages, active = {}, nil
  local quitting = false
  local ctx, font, uiFont = gui.ctx, gui.font, gui.uiFont
  local chrome = newChrome(cm, ctx)
  local samplerTrack = nil
  local currentTake = nil

  local function refreshTakeFromReaper()
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then return false end
    local t = reaper.GetActiveTake(item)
    if not t or not reaper.TakeIsMIDI(t) then return false end
    if t == currentTake then return false end
    currentTake = t
    return true
  end

  cmgr:scope('tracker'):register('loadSampleAtCurrentSlot', function()
    if not cm:get('trackerMode') then return end
    if pages.sample and currentTake then
      pages.sample:loadSampleIntoSlot(currentTake, cm:get('currentSample'))
    end
  end)

  local function tick()
    if active == 'tracker' and refreshTakeFromReaper() and pages.tracker then
      pages.tracker:bind(currentTake)
    end
    if pages.sample and currentTake then pages.sample:tick(currentTake) end
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
    pageButton('Tracker', 'tracker')
    ImGui.SameLine(ctx, 0, 4)
    pageButton('Sample',  'sample')
  end

  local function dispatch(state) return dispatchKeys(state, cmgr, ctx) end

  local function frame()
    tick()
    local page = pages[active]

    ImGui.PushFont(ctx, uiFont, 13)
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
    elseif visible then
      ImGui.Text(ctx, 'Select a MIDI item to begin.')
    end

    ImGui.End(ctx)

    if page and page.renderFloating then page:renderFloating(ctx) end

    ImGui.PopStyleColor(ctx, 5)
    ImGui.PopFont(ctx)

    if open and not quitting then reaper.defer(frame) end
  end

  ----- Public

  local self = {}

  function self:register(name, page)
    pages[name] = page
    if not active then self:setActive(name) end
  end

  function self:setActive(name)
    if active == name then return end
    if active and pages[active] then pages[active]:unbind() end
    active = name
    cmgr:setActive(name)
    if name == 'tracker' then
      refreshTakeFromReaper()
      pages.tracker:bind(currentTake)
    elseif name == 'sample' then
      if samplerTrack == nil then
        local tracks = pages.sample:listTracks()
        samplerTrack = tracks[1] and tracks[1].track or nil
      end
      pages.sample:bind(samplerTrack)
    end
  end

  --@map:contract stores the active sampler track and re-binds the sample page if currently active; safe to call before sample page is registered (state stashes; bind happens on next activation)
  function self:setSamplerTrack(t)
    samplerTrack = t
    if active == 'sample' and pages.sample then
      pages.sample:bind(t)
    end
  end

  function self:togglePage()
    self:setActive(active == 'tracker' and 'sample' or 'tracker')
  end

  function self:quit() quitting = true end

  function self:chrome() return chrome end

  function self:run() frame() end

  return self
end

--@map:contract Main builds the manager stack bottom-up with no take, then enters the defer loop via coord:run(); the coordinator picks up the user's MIDI selection on its first tracker-page tick
local function Main()
  local cm    = newConfigManager()
  local cmgr  = newCommandManager(cm)
  local gui   = createImGui()
  local coord = newCoordinator(cm, cmgr, gui)

  -- Globals: transport wrappers, page switching, quit. Bound on root
  -- so any page picks them up unchanged.
  cmgr:registerAll{
    play       = function() reaper.Main_OnCommand(1007,  0) end,
    playPause  = function() reaper.Main_OnCommand(40073, 0) end,
    stop       = function() reaper.Main_OnCommand(1016,  0) end,
    switchPage = function(name) coord:setActive(name)      end,
    togglePage = function()     coord:togglePage()         end,
    quit       = function()     coord:quit()               end,
  }
  cmgr:bindAll{
    playPause  = { ImGui.Key_Space },
    stop       = { ImGui.Key_F8    },
    togglePage = { {ImGui.Key_Tab, ImGui.Mod_Super} },
    quit       = { ImGui.Key_Enter },
  }

  coord:register('tracker', newTrackerPage(cm, cmgr, coord:chrome(), gui))
  coord:register('sample',  newSamplePage (cm, cmgr, coord:chrome(), gui, function(t) coord:setSamplerTrack(t) end))
  coord:run()
end

run(Main)
