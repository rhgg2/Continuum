-- Every page scope's keymap in one place — cross-page coherence auditable here;
-- the fx-pattern mini cmgr binds a filtered tracker subset (design/fx-patterns.md P1).

--shape: { scope = { command = { keySpec, ... } } } -- keySpec is ImGui.Key_* or { Key, Mod }

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'
local util  = require 'util'

local M = {}

----- tracker (command bodies in trackerRender + trackerView)

M.tracker = {
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
  M.tracker['advBy' .. i] = { {ImGui.Key_0 + i, ImGui.Mod_Ctrl} }
end

----- region (overlay within the tracker page; springLoaded scope config lives on ec)

M.region = {
  regionExit        = { ImGui.Key_Escape, ImGui.Key_Enter, ImGui.Key_KeypadEnter },
  regionBail        = { {ImGui.Key_G, ImGui.Mod_Super} },
  regionPaintExtend = { ImGui.Key_Equal },
  regionPaintShrink = { ImGui.Key_Minus },
}

----- sample (command bodies + slot-clamp invariant in sampleRender)

M.sample = {
  browserUp      = { { ImGui.Key_UpArrow,    ImGui.Mod_Ctrl  } },
  browserPreview = { { ImGui.Key_DownArrow,  ImGui.Mod_Ctrl  } },
  browserAssign  = { { ImGui.Key_RightArrow, ImGui.Mod_Ctrl  } },
  slotNext       = { { ImGui.Key_Period,     ImGui.Mod_Shift } },
  slotPrev       = { { ImGui.Key_Comma,      ImGui.Mod_Shift } },
  slotRename     = { ImGui.Key_Enter, ImGui.Key_KeypadEnter },
}

----- wiring

M.wiring = {
  wiringAddFx          = { ImGui.Key_N      },
  wiringClearSelection = { ImGui.Key_Escape },
}

----- arrange (command bodies in arrangeRender + arrangeView)

-- Cursor-nav and take-edit commands reuse the tracker scope's keys but not its
-- names: cmgr.commands is flat, so a shared name would clobber the other gate.

local arrange = {
  arrangeCursorUp     = { ImGui.Key_UpArrow   },
  arrangeCursorDown   = { ImGui.Key_DownArrow },
  arrangeCursorLeft   = { ImGui.Key_LeftArrow },
  arrangeCursorRight  = { ImGui.Key_RightArrow},
  arrangePageUp       = { ImGui.Key_PageUp    },
  arrangePageDown     = { ImGui.Key_PageDown  },
  arrangeHome         = { ImGui.Key_Home      },
  arrangeEnd          = { ImGui.Key_End       },
  createSlot          = { { ImGui.Key_Enter, ImGui.Mod_Super } },
  arrangeNudgeBack    = { { ImGui.Key_UpArrow,   ImGui.Mod_Super } },
  arrangeNudgeForward = { { ImGui.Key_DownArrow, ImGui.Mod_Super } },
  arrangeShrinkTake   = { { ImGui.Key_UpArrow,   ImGui.Mod_Super, ImGui.Mod_Shift } },
  arrangeGrowTake     = { { ImGui.Key_DownArrow, ImGui.Mod_Super, ImGui.Mod_Shift } },
  arrangeDeleteTake             = { ImGui.Key_Delete },
  arrangeDeleteAdvance          = { ImGui.Key_Period },
  arrangeDive                   = { ImGui.Key_Enter },
  arrangeTakeProperties         = { { ImGui.Key_Backspace, ImGui.Mod_Super } },
  arrangeDuplicateBelow         = { { ImGui.Key_D, ImGui.Mod_Ctrl } },
  arrangeDuplicateUnpooledBelow = { { ImGui.Key_Enter, ImGui.Mod_Super, ImGui.Mod_Shift } },
  arrangeSetLoopStart           = { { ImGui.Key_B, ImGui.Mod_Ctrl } },
  arrangeSetLoopEnd             = { { ImGui.Key_E, ImGui.Mod_Ctrl } },
  arrangePlayFromCursor         = { ImGui.Key_F6 },
  toggleFollowPlay              = { { ImGui.Key_F, ImGui.Mod_Super } },
  arrangeClearLoop              = { ImGui.Key_Escape },
  arrangeClearSelection         = { { ImGui.Key_G, ImGui.Mod_Ctrl } },
  arrangeZoomIn                 = { { ImGui.Key_Equal, ImGui.Mod_Super } },
  arrangeZoomOut                = { { ImGui.Key_Minus, ImGui.Mod_Super } },
  arrangeSetBeatPerRow          = { { ImGui.Key_Z,     ImGui.Mod_Super } },
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
M.arrange = arrange

return M
