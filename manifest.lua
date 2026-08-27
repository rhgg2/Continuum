-- Every command declared once: the label it shows under, and the keys that
-- reach it. see docs/commandManager.md § Manifest

--shape: { scope = { command = { label = 'Play / pause', keys = { keyspec, ... }? } } }

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local manifest = {}

----- global (bodies in continuum's Main, except toggleHelp, which is coordinator's)

-- switchPage, diveToSampler and editTuning/editSwing/closeEditor are reached
-- programmatically (toolbar click, dive, editor exit): label, no keys.

manifest.global = {
  play            = { label = 'Play' },
  playPause       = { label = 'Play / pause',      keys = { ImGui.Key_Space } },
  stop            = { label = 'Stop',              keys = { ImGui.Key_F8 } },
  undo            = { label = 'Undo',              keys = { {ImGui.Key_Z, ImGui.Mod_Ctrl} } },
  redo            = { label = 'Redo',              keys = { {ImGui.Key_Z, ImGui.Mod_Ctrl, ImGui.Mod_Shift} } },
  switchPage      = { label = 'Go to page' },
  switchToArrange = { label = 'Arrange page',      keys = { ImGui.Key_F2 } },
  switchToWiring  = { label = 'Wiring page',       keys = { ImGui.Key_F3 } },
  switchToTracker = { label = 'Tracker page',      keys = { ImGui.Key_F4 } },
  switchToSample  = { label = 'Sampler page',      keys = { ImGui.Key_F9 } },
  switchToEditor  = { label = 'Editor page',       keys = { ImGui.Key_F10 } },
  editTuning      = { label = 'Edit tuning' },
  editSwing       = { label = 'Edit swing' },
  closeEditor     = { label = 'Close editor' },
  diveToSampler   = { label = 'Dive to sampler' },
  togglePage      = { label = 'Switch page' },
  quit            = { label = 'Quit',              keys = { {ImGui.Key_Q, ImGui.Mod_Ctrl} } },
  beginPrefix     = { label = 'Numeric prefix',    keys = { {ImGui.Key_U, ImGui.Mod_Super} } },
  toggleFxWindows = { label = 'Toggle FX windows', keys = { ImGui.Key_F11 } },
  toggleProfiler  = { label = 'Toggle profiler',   keys = { {ImGui.Key_P, ImGui.Mod_Ctrl, ImGui.Mod_Shift} } },
  toggleHelp      = { label = 'This help',         keys = { ImGui.Key_F1 } },
}

return manifest
