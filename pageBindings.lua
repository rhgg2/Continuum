-- The keymaps of the page scopes that have not yet moved to manifest.lua, where a
-- command's keys are declared beside its label. see docs/commandManager.md § Manifest

-- A delete binding carries Backspace beside Delete: on a Mac laptop the bare key
-- is Backspace, and Key_Delete (⌦) needs Fn.

--shape: { scope = { command = { keySpec, ... } } } -- keySpec is ImGui.Key_* or { Key, Mod }

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'
local util  = require 'util'

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

----- arrange (command bodies in arrangeRender + arrangeView)

-- Cursor-nav and take-edit commands reuse the tracker scope's keys but not its
-- names: cmgr.commands is flat, so a shared name would clobber the other gate.

local arrange = {
  arrangeCursorUp               = { ImGui.Key_UpArrow   },
  arrangeCursorDown             = { ImGui.Key_DownArrow },
  arrangeCursorLeft             = { ImGui.Key_LeftArrow },
  arrangeCursorRight            = { ImGui.Key_RightArrow},
  arrangePageUp                 = { ImGui.Key_PageUp    },
  arrangePageDown               = { ImGui.Key_PageDown  },
  arrangeHome                   = { ImGui.Key_Home      },
  arrangeEnd                    = { ImGui.Key_End       },
  arrangeNextDrop               = { { ImGui.Key_DownArrow,  ImGui.Mod_Alt } },
  arrangePrevDrop               = { { ImGui.Key_UpArrow,        ImGui.Mod_Alt } },
  arrangeSelectUp               = { { ImGui.Key_UpArrow,    ImGui.Mod_Shift } },
  arrangeSelectDown             = { { ImGui.Key_DownArrow,  ImGui.Mod_Shift } },
  arrangeSelectLeft             = { { ImGui.Key_LeftArrow,  ImGui.Mod_Shift } },
  arrangeSelectRight            = { { ImGui.Key_RightArrow, ImGui.Mod_Shift } },
  createSlot                    = { { ImGui.Key_Enter,      ImGui.Mod_Super } },
  arrangeNudgeBack              = { { ImGui.Key_UpArrow,    ImGui.Mod_Super } },
  arrangeNudgeForward           = { { ImGui.Key_DownArrow,  ImGui.Mod_Super } },
  arrangeEdgeUp                 = { { ImGui.Key_UpArrow,    ImGui.Mod_Super, ImGui.Mod_Shift } },
  arrangeEdgeDown               = { { ImGui.Key_DownArrow,  ImGui.Mod_Super, ImGui.Mod_Shift } },
  arrangeSplit                  = { { ImGui.Key_S,          ImGui.Mod_Ctrl } },
  arrangeDeleteTake             = { ImGui.Key_Delete, ImGui.Key_Backspace },
  arrangeDeleteAdvance          = { ImGui.Key_Period },
  arrangeDeleteRetreat          = { { ImGui.Key_UpArrow,    ImGui.Mod_Alt, ImGui.Mod_Shift } },
  deleteSlot                    = { { ImGui.Key_Delete,      ImGui.Mod_Ctrl },
                                    { ImGui.Key_Backspace,   ImGui.Mod_Ctrl } },
  arrangeDive                   = { ImGui.Key_Enter },
  arrangeTakeProperties         = { { ImGui.Key_Backspace,  ImGui.Mod_Super } },
  arrangeDuplicateBelow         = { { ImGui.Key_D,          ImGui.Mod_Ctrl },
                                    { ImGui.Key_DownArrow,  ImGui.Mod_Alt, ImGui.Mod_Shift } },
  arrangePrevVariant            = { { ImGui.Key_LeftArrow,  ImGui.Mod_Alt, ImGui.Mod_Shift } },
  arrangeNextVariant            = { { ImGui.Key_RightArrow, ImGui.Mod_Alt, ImGui.Mod_Shift } },
  -- Shadows the global universal-argument prefix, which no arrange command reads.
  arrangeReplaceMode            = { { ImGui.Key_U,          ImGui.Mod_Super } },
  arrangeAdvanceMode            = { { ImGui.Key_GraveAccent, ImGui.Mod_Ctrl } },
  arrangeSetLoopStart           = { { ImGui.Key_B,          ImGui.Mod_Super } },
  arrangeSetLoopEnd             = { { ImGui.Key_E,          ImGui.Mod_Super } },
  arrangeLoopToItem             = { { ImGui.Key_L,          ImGui.Mod_Super } },
  toggleFollowPlay              = { { ImGui.Key_F,          ImGui.Mod_Super } },
  arrangePlayFromCursor         = { ImGui.Key_F6 },
  arrangeClearLoop              = { ImGui.Key_Escape },
  arrangeClearSelection         = { { ImGui.Key_G,          ImGui.Mod_Super } },
  arrangeZoomIn                 = { { ImGui.Key_Equal,      ImGui.Mod_Super } },
  arrangeZoomOut                = { { ImGui.Key_Minus,      ImGui.Mod_Super } },
}

-- Place-command keys: 0..9 → digit keys, 10..35 → letters, 36..61 →
-- Shift+letter. ImGui.Key_0 + n and Key_A + n are contiguous.
local function placeKey(slotIdx)
  if slotIdx < 10 then return { ImGui.Key_0 + slotIdx } end
  if slotIdx < 36 then return { ImGui.Key_A + (slotIdx - 10) } end
  return { ImGui.Key_A + (slotIdx - 36), ImGui.Mod_Shift }
end
-- Slot key = util.toBase62(i); matches arrangeView's drop-command registration.
for i = 0, 61 do
  arrange['drop' .. util.toBase62(i)] = { placeKey(i) }
end
for i = 0, 9 do
  arrange['arrangeAdvanceBy' .. i] = { { ImGui.Key_0 + i, ImGui.Mod_Ctrl } }
end
pageBindings.arrange = arrange

return pageBindings
