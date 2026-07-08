-- Tracker-scope key bindings, lifted out so the fx-pattern mini cmgr can bind
-- a filtered subset (design/fx-patterns.md P3); command bodies live in trackerRender.

--shape: { commandName = { keySpec, ... } } -- keySpec is ImGui.Key_* or { Key, Mod, ... }

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local bindings = {
  cursorUp               = { ImGui.Key_UpArrow,    {ImGui.Key_P, ImGui.Mod_Super} },
  cursorDown             = { ImGui.Key_DownArrow,  {ImGui.Key_N, ImGui.Mod_Super} },
  cursorLeft             = { ImGui.Key_LeftArrow,  {ImGui.Key_B, ImGui.Mod_Super} },
  cursorRight            = { ImGui.Key_RightArrow, {ImGui.Key_F, ImGui.Mod_Super} },
  prevTrack              = { {ImGui.Key_LeftArrow,  ImGui.Mod_Alt} },
  nextTrack              = { {ImGui.Key_RightArrow, ImGui.Mod_Alt} },
  prevTake               = { {ImGui.Key_UpArrow,    ImGui.Mod_Alt} },
  nextTake               = { {ImGui.Key_DownArrow,  ImGui.Mod_Alt} },
  goTop                  = { ImGui.Key_Home,       {ImGui.Key_Comma,  ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  goBottom               = { ImGui.Key_End,        {ImGui.Key_Period, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  pageUp                 = { ImGui.Key_PageUp },
  pageDown               = { ImGui.Key_PageDown },
  colLeft                = { {ImGui.Key_B, ImGui.Mod_Ctrl} },
  colRight               = { {ImGui.Key_F, ImGui.Mod_Ctrl} },
  channelLeft            = { {ImGui.Key_Tab, ImGui.Mod_Shift} },
  channelRight           = { ImGui.Key_Tab },
  noteOff                = { ImGui.Key_1 },
  shrinkNote             = { {ImGui.Key_UpArrow,  ImGui.Mod_Super, ImGui.Mod_Shift} },
  growNote               = { {ImGui.Key_DownArrow, ImGui.Mod_Super, ImGui.Mod_Shift} },
  nudgeBack              = { {ImGui.Key_UpArrow,   ImGui.Mod_Super} },
  nudgeForward           = { {ImGui.Key_DownArrow,   ImGui.Mod_Super} },
  eventShiftLeft         = {{ImGui.Key_LeftArrow,   ImGui.Mod_Super} },
  eventShiftRight        = {{ImGui.Key_RightArrow,   ImGui.Mod_Super} },
  insertRowCol           = { {ImGui.Key_DownArrow, ImGui.Mod_Ctrl} },
  deleteRowCol           = { {ImGui.Key_UpArrow,   ImGui.Mod_Ctrl} },
  addTypedCol            = { {ImGui.Key_RightArrow, ImGui.Mod_Ctrl} },
  hideExtraCol           = { {ImGui.Key_LeftArrow, ImGui.Mod_Ctrl} },
  delete                 = { ImGui.Key_Period },
  interpolate            = { {ImGui.Key_I, ImGui.Mod_Ctrl} },
  selectUp               = { {ImGui.Key_UpArrow,    ImGui.Mod_Shift} },
  selectDown             = { {ImGui.Key_DownArrow,  ImGui.Mod_Shift} },
  selectLeft             = { {ImGui.Key_LeftArrow,  ImGui.Mod_Shift} },
  selectRight            = { {ImGui.Key_RightArrow, ImGui.Mod_Shift} },
  cycleBlock             = { {ImGui.Key_Space,       ImGui.Mod_Super} },
  cycleVBlock            = { {ImGui.Key_O,           ImGui.Mod_Super} },
  swapBlockEnds          = { {ImGui.Key_GraveAccent, ImGui.Mod_Ctrl} },
  selectClear            = { {ImGui.Key_G, ImGui.Mod_Super} },
  cut                    = { {ImGui.Key_W, ImGui.Mod_Super}, {ImGui.Key_X, ImGui.Mod_Ctrl} },
  copy                   = { {ImGui.Key_W, ImGui.Mod_Ctrl},  {ImGui.Key_C, ImGui.Mod_Ctrl} },
  paste                  = { {ImGui.Key_Y, ImGui.Mod_Super}, {ImGui.Key_V, ImGui.Mod_Ctrl} },
  duplicateDown          = { {ImGui.Key_D, ImGui.Mod_Ctrl} },
  deleteSel              = { ImGui.Key_Delete },
  nudgeCoarseUp          = { {ImGui.Key_Equal, ImGui.Mod_Ctrl} },
  nudgeCoarseDown        = { {ImGui.Key_Minus, ImGui.Mod_Ctrl} },
  nudgeFineUp            = { {ImGui.Key_Equal, ImGui.Mod_Shift} },
  nudgeFineDown          = { {ImGui.Key_Minus, ImGui.Mod_Shift} },
  scaleHalf              = { {ImGui.Key_9, ImGui.Mod_Shift} },  -- '('
  scaleDouble            = { {ImGui.Key_0,  ImGui.Mod_Shift} },  -- ')'
  doubleRPB              = { {ImGui.Key_Equal, ImGui.Mod_Super} },
  halveRPB               = { {ImGui.Key_Minus, ImGui.Mod_Super} },
  setRPB                 = { {ImGui.Key_Z,     ImGui.Mod_Super} },
  takeProperties         = { {ImGui.Key_Backspace, ImGui.Mod_Super} },
  newTakeBelow           = { {ImGui.Key_Enter, ImGui.Mod_Super} },
  duplicateUnpooledBelow = { {ImGui.Key_Enter, ImGui.Mod_Super, ImGui.Mod_Shift} },
  matchGridToCursor      = { {ImGui.Key_M, ImGui.Mod_Super} },
  groupDuplicate         = { {ImGui.Key_D, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  groupPaste             = { {ImGui.Key_V, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  groupLocalToggle       = { {ImGui.Key_Backslash, ImGui.Mod_Shift} },
  regionArm              = { ImGui.Key_Backslash },
  groupInstPrev          = { ImGui.Key_LeftBracket },
  groupInstNext          = { ImGui.Key_RightBracket },
  inputOctaveUp          = { {ImGui.Key_8, ImGui.Mod_Shift} },
  inputOctaveDown        = { ImGui.Key_Slash },
  inputSampleUp          = { {ImGui.Key_Period, ImGui.Mod_Shift} },  -- '>'
  inputSampleDown        = { {ImGui.Key_Comma,  ImGui.Mod_Shift} },  -- '<'
  playFromTop            = { ImGui.Key_F6 },
  playFromCursor         = { ImGui.Key_F7 },
  openTemperPicker       = { {ImGui.Key_T, ImGui.Mod_Super} },
  openSwingPicker        = { {ImGui.Key_S, ImGui.Mod_Super} },
  quantize               = { {ImGui.Key_K, ImGui.Mod_Ctrl} },
  quantizeKeepRealised   = { {ImGui.Key_K, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  editNoteFx             = { {ImGui.Key_X, ImGui.Mod_Super} },
}

-- Universal-argument digit prefixes: Ctrl+0..9 arm advBy0..advBy9.
for i = 0, 9 do
  bindings['advBy' .. i] = { {ImGui.Key_0 + i, ImGui.Mod_Ctrl} }
end

return bindings
