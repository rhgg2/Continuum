-- See docs/continuum.md for the model.

--invariant: entry point — owns lifecycle (Main runs once per ReaScript invocation), wires the layered manager stack, drives the render loop via reaper.defer
--invariant: module load order is bottom-up: util first (everyone calls util.installHooks), commandManager before view layers (which self-register commands), pages last

do
  local script_path = debug.getinfo(1,'S').source:match[[^@?(.*[\/])[^\/]-$]]
  package.path = script_path .. '?.lua;' .. package.path
  if not reaper.ImGui_GetBuiltinPath then
    reaper.MB('ReaImGui is required. Install it via ReaPack.', 'Continuum', 0)
    return
  end
  package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
end

local util = require 'util'
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
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_WindowsMoveFromTitleBarOnly, 1)

  local osName = reaper.GetOS()
  local font   = ImGui.CreateFont('Source Code Pro')
  local uiFont = (osName:find('OSX') or osName:find('mac'))
               and ImGui.CreateFontFromFile('/System/Library/Fonts/SFNS.ttf')
               or  ImGui.CreateFont(osName:find('Win') and 'Segoe UI' or 'sans-serif')
  ImGui.Attach(ctx, font)
  ImGui.Attach(ctx, uiFont)
  return {ctx = ctx, font = font, uiFont = uiFont}
end

--contract: Main builds the manager stack bottom-up with no take, then enters the defer loop via coord:run(); the coordinator picks up the user's MIDI selection on its first tracker-page tick
local function Main()
  local gui   = createImGui()
  local cm    = util.instantiate('configManager')
  local cmgr  = util.instantiate('commandManager', { cm = cm })
  local coord = util.instantiate('coordinator', { cm = cm, cmgr = cmgr, gui = gui })

  local chrome = coord:chrome()
  local function onPickTrack(t) coord:setSamplerTrack(t) end
  local tp = util.instantiate('trackerPage', { cm = cm, cmgr = cmgr, chrome = chrome, gui = gui })
  local sp = util.instantiate('samplePage', { cm = cm, cmgr = cmgr, chrome = chrome, gui = gui, onPickTrack = onPickTrack })

  coord:register('tracker', tp)
  coord:register('sample',  sp)

  -- Globals: transport wrappers, page switching, quit. Bound on root
  -- so any page picks them up unchanged.
  -- Remember the top of REAPER's undo stack at open time; refuse to undo
  -- past it. Undo_OnStateChange without a real diff doesn't add an entry,
  -- so we can't drop our own sentinel — we use what's already there (or
  -- nil if the stack was empty). Edits outside Continuum (REAPER's own
  -- Ctrl-Z) bypass this guard by design.
  local undoFence = reaper.Undo_CanUndo2(0)

  cmgr:registerAll{
    play        = function() reaper.Main_OnCommand(1007,  0) end,
    playPause   = function() reaper.Main_OnCommand(40073, 0) end,
    stop        = function() reaper.Main_OnCommand(1016,  0) end,
    undo        = function()
      if reaper.Undo_CanUndo2(0) == undoFence then return end
      reaper.Main_OnCommand(40029, 0); coord:reloadAfterExternalMutation()
    end,
    redo        = function() reaper.Main_OnCommand(40030, 0); coord:reloadAfterExternalMutation() end,
    switchPage  = function(name) coord:setActive(name)      end,
    togglePage  = function()     coord:togglePage()         end,
    quit        = function()     coord:quit()               end,
    beginPrefix = function()     cmgr:beginPrefix()         end,
  }
  cmgr:bindAll{
    playPause   = { ImGui.Key_Space },
    stop        = { ImGui.Key_F8    },
    undo        = { {ImGui.Key_Z, ImGui.Mod_Ctrl} },
    redo        = { {ImGui.Key_Z, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
    togglePage  = { {ImGui.Key_Tab, ImGui.Mod_Super} },
    quit        = { ImGui.Key_Enter },
    beginPrefix = { {ImGui.Key_U, ImGui.Mod_Super} },
  }

  coord:run()
end

run(Main)
