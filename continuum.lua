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
local perf  = require 'perf'

math.randomseed(os.time())

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
  local isMac  = osName:find('OSX') or osName:find('mac')
  local uiFamily = isMac and 'Helvetica Neue'
                          or (osName:find('Win') and 'Segoe UI' or 'sans-serif')
  local uiFont     = ImGui.CreateFont(uiFamily)
  -- Wiring node labels want a heavier face; FontFlags_Bold is rasterizer-simulated (same family).
  local wireFont   = ImGui.CreateFont(uiFamily, ImGui.FontFlags_Bold)
  ImGui.Attach(ctx, font)
  ImGui.Attach(ctx, uiFont)
  ImGui.Attach(ctx, wireFont)
  -- Chrome (toolbar, status, popups, swing editor) all scale off the
  -- grid size so the two registers stay in proportion if either moves.
  local GRID_SIZE = 15
  local UI_SIZE   = 11
  local WIRE_SIZE = 12
  return {
    ctx        = ctx,
    font       = font,
    uiFont     = uiFont,
    wireFont   = wireFont,
    fontSize   = { grid = GRID_SIZE, ui = UI_SIZE, wire = WIRE_SIZE },
  }
end

--contract: Main builds the manager stack bottom-up, then enters the defer loop via coord:run()
--contract: each page owns its cross-page state, exposed through the facade registry coord wires
local function Main()
  local gui   = createImGui()
  local ps    = util.instantiate('pextStore')
  local cm    = util.instantiate('configManager', { ps = ps })
  local ds    = util.instantiate('dataStore', { ps = ps })
  local eventMeta = util.instantiate('eventMeta', { ps = ps })
  local cmgr  = util.instantiate('commandManager', { cm = cm })
  local coord = util.instantiate('coordinator', { cm = cm, ds = ds, eventMeta = eventMeta, cmgr = cmgr, gui = gui })

  -- Wiring registered first so Continuum boots into it (coord:register makes
  -- the first registered page active). seedCursorFromReaper still seeds arrange.
  local wp = coord:register('wiring',  'wiringPage')
  local ap = coord:register('arrange', 'arrangePage')
  coord:register('tracker', 'trackerPage')
  coord:register('sample',  'samplePage')
  coord:register('editor',  'editorPage')
  wp:enableLive()
  ap:seedCursorFromReaper()

  -- Globals: transport wrappers, page switching, quit. Bound on root
  -- so any page picks them up unchanged.
  -- Remember the top of REAPER's undo stack at open time; refuse to undo
  -- past it. Undo_OnStateChange without a real diff doesn't add an entry,
  -- so we can't drop our own sentinel — we use what's already there (or
  -- nil if the stack was empty). Edits outside Continuum (REAPER's own
  -- Ctrl-Z) bypass this guard by design.
  local undoFence = reaper.Undo_CanUndo2(0)

  -- F11 toggles FX windows: first press stashes+closes all floating FX;
  -- next press re-floats exactly that set. Master included; FX chain only.
  local hiddenFxFloats = nil   -- list of fxGUIDs we closed, awaiting restore
  local function toggleAllFxWindows()
    local function eachFx(fn)
      fn(reaper.GetMasterTrack(0))
      for i = 0, reaper.CountTracks(0) - 1 do fn(reaper.GetTrack(0, i)) end
    end
    -- "Hide what's open" always wins: only restore when nothing is floating,
    -- so a live window can't be mistaken for hidden state (desync → no-op).
    local open = {}
    eachFx(function(track)
      for fxIdx = 0, reaper.TrackFX_GetCount(track) - 1 do
        if reaper.TrackFX_GetFloatingWindow(track, fxIdx) then
          open[#open + 1] = { track = track, fxIdx = fxIdx,
                              guid = reaper.TrackFX_GetFXGUID(track, fxIdx) }
        end
      end
    end)
    if #open > 0 then
      local stash = {}
      for _, fx in ipairs(open) do
        stash[#stash + 1] = fx.guid
        reaper.TrackFX_Show(fx.track, fx.fxIdx, 2)   -- 2 = hide floating
      end
      hiddenFxFloats = stash
    elseif hiddenFxFloats then
      local want = {}
      for _, fxGuid in ipairs(hiddenFxFloats) do want[fxGuid] = true end
      eachFx(function(track)
        for fxIdx = 0, reaper.TrackFX_GetCount(track) - 1 do
          if want[reaper.TrackFX_GetFXGUID(track, fxIdx)] then
            reaper.TrackFX_Show(track, fxIdx, 3)     -- 3 = show floating
          end
        end
      end)
      hiddenFxFloats = nil
    end
  end

  cmgr:registerAll{
    play        = function() reaper.Main_OnCommand(1007,  0) end,
    playPause   = function() reaper.Main_OnCommand(40073, 0) end,
    stop        = function() reaper.Main_OnCommand(1016,  0) end,
    undo        = function()
      if reaper.Undo_CanUndo2(0) == undoFence then return end
      reaper.Main_OnCommand(40029, 0); coord:reloadAfterExternalMutation()
    end,
    redo        = function() reaper.Main_OnCommand(40030, 0); coord:reloadAfterExternalMutation() end,
    switchPage      = function(_, name) coord:setActive(name) end,
    switchToArrange = function() coord:setActive('arrange') end,
    switchToWiring  = function() coord:setActive('wiring')  end,
    switchToTracker = function() coord:setActive('tracker') end,
    switchToSample  = function() coord:setActive('sample')  end,
    switchToEditor  = function() coord:setActive('editor')  end,
    editTuning      = function() coord:getFacade('editor').edit('temper'); coord:setActive('editor') end,
    editSwing       = function() coord:getFacade('editor').edit('swing');  coord:setActive('editor') end,
    closeEditor     = function() coord:setActive(coord:previousPage() or 'tracker') end,
    diveToSampler   = function(_, track) coord:getFacade('sample').setTrack(track); coord:setActive('sample') end,
    togglePage      = function() coord:togglePage()         end,
    quit            = function() coord:getFacade('tracker').restorePerfFlags(); coord:quit()               end,
    beginPrefix     = function() cmgr:beginPrefix()         end,
    toggleFxWindows = toggleAllFxWindows,
    toggleProfiler  = function() perf.toggle() end,
  }
  cmgr:bindAll{
    playPause       = { ImGui.Key_Space },
    stop            = { ImGui.Key_F8    },
    undo            = { {ImGui.Key_Z, ImGui.Mod_Ctrl} },
    redo            = { {ImGui.Key_Z, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
    togglePage      = { {ImGui.Key_Tab, ImGui.Mod_Alt }},
    switchToArrange = { ImGui.Key_F2 },
    switchToWiring  = { ImGui.Key_F3 },
    switchToTracker = { ImGui.Key_F4 },
    switchToSample  = { ImGui.Key_F9 },
    switchToEditor  = { ImGui.Key_F10 },
    quit            = { {ImGui.Key_Q, ImGui.Mod_Ctrl} },
    beginPrefix     = { {ImGui.Key_U, ImGui.Mod_Super} },
    toggleFxWindows = { ImGui.Key_F11 },
    toggleProfiler  = { {ImGui.Key_P, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  }

  -- ImGui only delivers keys while Continuum holds focus; the REAPER-keymap
  -- bridge (see coordinator § External commands) covers the floating-FX case.
  coord:onExternalCommand('toggleFxWindows', 'toggleFxWindows')

  -- Enter on the tracker scope returns to the arrange page — the inverse
  -- of arrange's Tab/Enter dive. Tracker-scoped, not root: each page owns
  -- what Enter does (arrange dives, tracker returns).
  local trackerScope = cmgr:scope('tracker')
  trackerScope:registerAll{ returnToArrange = function() coord:returnToArrange() end }
  trackerScope:bindAll{ returnToArrange = { ImGui.Key_Enter, ImGui.Key_KeypadEnter } }

  -- Overlay persisted user rebindings on top of the code defaults above.
  cmgr:loadOverrides(ImGui)

  coord:run(err_handler)
end

run(Main)
