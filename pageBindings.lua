-- The keymaps of the page scopes that have not yet moved to manifest.lua, where a
-- command's keys are declared beside its label. see docs/commandManager.md § Manifest

--shape: { scope = { command = { keySpec, ... } } } -- keySpec is ImGui.Key_* or { Key, Mod }

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local pageBindings = {}

----- sample (command bodies + slot-clamp invariant in sampleRender)

pageBindings.sample = {
  browserUp      = { { ImGui.Key_UpArrow,    ImGui.Mod_Ctrl  } },
  browserPreview = { { ImGui.Key_DownArrow,  ImGui.Mod_Ctrl  } },
  browserAssign  = { { ImGui.Key_RightArrow, ImGui.Mod_Ctrl  } },
  slotNext       = { { ImGui.Key_Period,     ImGui.Mod_Shift } },
  slotPrev       = { { ImGui.Key_Comma,      ImGui.Mod_Shift } },
  slotRename     = { ImGui.Key_Enter, ImGui.Key_KeypadEnter },
}

----- wiring

pageBindings.wiring = {
  wiringAddFx          = { ImGui.Key_N      },
  wiringClearSelection = { ImGui.Key_Escape },
}

return pageBindings
