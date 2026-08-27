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

----- tracker (bodies in trackerView + trackerRender; editCursor's and clipboard's
----- register onto the same scope, returnToArrange's in continuum's Main)

-- A delete binding carries Backspace beside Delete: on a Mac laptop the bare key
-- is Backspace, and Key_Delete (\xe2\x8c\xa6) needs Fn.

manifest.tracker = {
  cursorUp             = { label = 'Up',                        keys = { ImGui.Key_UpArrow, {ImGui.Key_P, ImGui.Mod_Super} } },
  cursorDown           = { label = 'Down',                      keys = { ImGui.Key_DownArrow, {ImGui.Key_N, ImGui.Mod_Super} } },
  cursorLeft           = { label = 'Left',                      keys = { ImGui.Key_LeftArrow, {ImGui.Key_B, ImGui.Mod_Super} } },
  cursorRight          = { label = 'Right',                     keys = { ImGui.Key_RightArrow, {ImGui.Key_F, ImGui.Mod_Super} } },
  prevTrack            = { label = 'Previous track',            keys = { {ImGui.Key_LeftArrow, ImGui.Mod_Alt} } },
  nextTrack            = { label = 'Next track',                keys = { {ImGui.Key_RightArrow, ImGui.Mod_Alt} } },
  prevTake             = { label = 'Previous take',             keys = { {ImGui.Key_Comma, ImGui.Mod_Alt} } },
  nextTake             = { label = 'Next take',                 keys = { {ImGui.Key_Period, ImGui.Mod_Alt} } },
  prevInstance         = { label = 'Previous instance',         keys = { {ImGui.Key_UpArrow, ImGui.Mod_Alt} } },
  nextInstance         = { label = 'Next instance',             keys = { {ImGui.Key_DownArrow, ImGui.Mod_Alt} } },
  goTop                = { label = 'Top',                       keys = { ImGui.Key_Home, {ImGui.Key_Comma, ImGui.Mod_Ctrl, ImGui.Mod_Shift} } },
  goBottom             = { label = 'Bottom',                    keys = { ImGui.Key_End, {ImGui.Key_Period, ImGui.Mod_Ctrl, ImGui.Mod_Shift} } },
  goLeft               = { label = 'First column',              keys = { {ImGui.Key_A, ImGui.Mod_Super} } },
  goRight              = { label = 'Last filled column',        keys = { {ImGui.Key_E, ImGui.Mod_Super} } },
  pageUp               = { label = 'Page up',                   keys = { ImGui.Key_PageUp, {ImGui.Key_V, ImGui.Mod_Shift, ImGui.Mod_Super} } },
  pageDown             = { label = 'Page down',                 keys = { ImGui.Key_PageDown, {ImGui.Key_V, ImGui.Mod_Super} } },
  colLeft              = { label = 'Column left',               keys = { {ImGui.Key_Tab, ImGui.Mod_Shift} } },
  colRight             = { label = 'Column right',              keys = { ImGui.Key_Tab } },
  channelLeft          = { label = 'Channel left',              keys = { {ImGui.Key_B, ImGui.Mod_Ctrl} } },
  channelRight         = { label = 'Channel right',             keys = { {ImGui.Key_F, ImGui.Mod_Ctrl} } },
  noteOff              = { label = 'Note off',                  keys = { ImGui.Key_1 } },
  shrinkNote           = { label = 'Shrink note',               keys = { {ImGui.Key_UpArrow, ImGui.Mod_Super, ImGui.Mod_Shift} } },
  growNote             = { label = 'Grow note',                 keys = { {ImGui.Key_DownArrow, ImGui.Mod_Super, ImGui.Mod_Shift} } },
  nudgeBack            = { label = 'Push back',                 keys = { {ImGui.Key_UpArrow, ImGui.Mod_Super} } },
  nudgeForward         = { label = 'Push forward',              keys = { {ImGui.Key_DownArrow, ImGui.Mod_Super} } },
  eventShiftLeft       = { label = 'Push left',                 keys = { {ImGui.Key_LeftArrow, ImGui.Mod_Super} } },
  eventShiftRight      = { label = 'Push right',                keys = { {ImGui.Key_RightArrow, ImGui.Mod_Super} } },
  insertRow            = { label = 'Insert row (all columns)',  keys = { {ImGui.Key_DownArrow, ImGui.Mod_Ctrl, ImGui.Mod_Shift} } },
  insertRowCol         = { label = 'Insert row in column',      keys = { {ImGui.Key_DownArrow, ImGui.Mod_Ctrl} } },
  deleteRowCol         = { label = 'Delete row in column',      keys = { {ImGui.Key_UpArrow, ImGui.Mod_Ctrl} } },
  deleteRow            = { label = 'Delete row (all columns)',  keys = { {ImGui.Key_UpArrow, ImGui.Mod_Ctrl, ImGui.Mod_Shift} } },
  addNoteLane          = { label = 'Add note lane',             keys = { {ImGui.Key_RightArrow, ImGui.Mod_Ctrl} } },
  addTypedCol          = { label = 'Add cc/pb/at/pc column',    keys = { {ImGui.Key_RightArrow, ImGui.Mod_Ctrl, ImGui.Mod_Shift} } },
  hideExtraCol         = { label = 'Remove column',             keys = { {ImGui.Key_LeftArrow, ImGui.Mod_Ctrl} } },
  delete               = { label = 'Clear cell',                keys = { ImGui.Key_Period } },
  interpolate          = { label = 'Interpolate',               keys = { {ImGui.Key_I, ImGui.Mod_Ctrl} } },
  selectUp             = { label = 'Select up',                 keys = { {ImGui.Key_UpArrow, ImGui.Mod_Shift} } },
  selectDown           = { label = 'Select down',               keys = { {ImGui.Key_DownArrow, ImGui.Mod_Shift} } },
  selectLeft           = { label = 'Select left',               keys = { {ImGui.Key_LeftArrow, ImGui.Mod_Shift} } },
  selectRight          = { label = 'Select right',              keys = { {ImGui.Key_RightArrow, ImGui.Mod_Shift} } },
  cycleBlock           = { label = 'Cycle selection H',         keys = { {ImGui.Key_O, ImGui.Mod_Super} } },
  cycleVBlock          = { label = 'Cycle selection V',         keys = { {ImGui.Key_Space, ImGui.Mod_Super} } },
  swapBlockEnds        = { label = 'Swap block ends',           keys = { {ImGui.Key_GraveAccent, ImGui.Mod_Ctrl} } },
  selectClear          = { label = 'Clear selection',           keys = { {ImGui.Key_G, ImGui.Mod_Super} } },
  selectAll            = { label = 'Select all',                keys = { {ImGui.Key_A, ImGui.Mod_Ctrl} } },
  cut                  = { label = 'Cut',                       keys = { {ImGui.Key_W, ImGui.Mod_Super}, {ImGui.Key_X, ImGui.Mod_Ctrl} } },
  copy                 = { label = 'Copy',                      keys = { {ImGui.Key_W, ImGui.Mod_Ctrl}, {ImGui.Key_C, ImGui.Mod_Ctrl} } },
  paste                = { label = 'Paste',                     keys = { {ImGui.Key_Y, ImGui.Mod_Super}, {ImGui.Key_V, ImGui.Mod_Ctrl} } },
  duplicateDown        = { label = 'Duplicate',                 keys = { {ImGui.Key_D, ImGui.Mod_Ctrl} } },
  deleteSel            = { label = 'Delete selection',          keys = { ImGui.Key_Delete, ImGui.Key_Backspace } },
  nudgeCoarseUp        = { label = 'Nudge val ++',              keys = { {ImGui.Key_Equal, ImGui.Mod_Ctrl} } },
  nudgeCoarseDown      = { label = 'Nudge val --',              keys = { {ImGui.Key_Minus, ImGui.Mod_Ctrl} } },
  nudgeFineUp          = { label = 'Nudge val +',               keys = { {ImGui.Key_Equal, ImGui.Mod_Shift} } },
  nudgeFineDown        = { label = 'Nudge val -',               keys = { {ImGui.Key_Minus, ImGui.Mod_Shift} } },
  scaleHalf            = { label = 'Scale \xc3\x97\xc2\xbd',    keys = { {ImGui.Key_9, ImGui.Mod_Shift} } },  -- '('
  scaleDouble          = { label = 'Scale \xc3\x972',           keys = { {ImGui.Key_0, ImGui.Mod_Shift} } },  -- ')'
  doubleRPB            = { label = 'Double',                    keys = { {ImGui.Key_Equal, ImGui.Mod_Super} } },
  halveRPB             = { label = 'Halve',                     keys = { {ImGui.Key_Minus, ImGui.Mod_Super} } },
  incRPB               = { label = 'Rows / beat +1',            keys = { {ImGui.Key_Equal, ImGui.Mod_Super, ImGui.Mod_Shift} } },
  decRPB               = { label = 'Rows / beat -1',            keys = { {ImGui.Key_Minus, ImGui.Mod_Super, ImGui.Mod_Shift} } },
  setRPB               = { label = 'Set',                       keys = { {ImGui.Key_Z, ImGui.Mod_Super} } },
  takeProperties       = { label = 'Take properties',           keys = { {ImGui.Key_P, ImGui.Mod_Alt} } },
  newTakeBelow         = { label = 'New take',                  keys = { {ImGui.Key_Enter, ImGui.Mod_Alt} } },
  duplicateBelow       = { label = 'Duplicate',                 keys = { {ImGui.Key_DownArrow, ImGui.Mod_Alt, ImGui.Mod_Shift} } },
  deleteInstance       = { label = 'Delete instance',           keys = { {ImGui.Key_UpArrow, ImGui.Mod_Alt, ImGui.Mod_Shift} } },
  prevVariant          = { label = 'Previous variant',          keys = { {ImGui.Key_LeftArrow, ImGui.Mod_Alt, ImGui.Mod_Shift} } },
  nextVariant          = { label = 'Next variant / vary',       keys = { {ImGui.Key_RightArrow, ImGui.Mod_Alt, ImGui.Mod_Shift} } },
  deleteBoundSlot      = { label = 'Delete take + instances',   keys = { {ImGui.Key_Delete, ImGui.Mod_Ctrl},
                                                                         {ImGui.Key_Backspace, ImGui.Mod_Ctrl} } },
  matchGridToCursor    = { label = 'Match',                     keys = { {ImGui.Key_M, ImGui.Mod_Super} } },
  groupDuplicate       = { label = 'Duplicate group',           keys = { {ImGui.Key_D, ImGui.Mod_Ctrl, ImGui.Mod_Shift} } },
  groupPaste           = { label = 'Paste group',               keys = { {ImGui.Key_V, ImGui.Mod_Ctrl, ImGui.Mod_Shift} } },
  groupLocalToggle     = { label = 'Toggle local',              keys = { {ImGui.Key_Backslash, ImGui.Mod_Shift} } },
  regionArm            = { label = 'Region mode',               keys = { ImGui.Key_Backslash } },
  groupInstPrev        = { label = 'Prev instance',             keys = { ImGui.Key_LeftBracket } },
  groupInstNext        = { label = 'Next instance',             keys = { ImGui.Key_RightBracket } },
  inputOctaveUp        = { label = 'Octave +',                  keys = { {ImGui.Key_8, ImGui.Mod_Shift} } },
  inputOctaveDown      = { label = 'Octave -',                  keys = { {ImGui.Key_7, ImGui.Mod_Shift} } },
  inputSampleUp        = { label = 'Sample +',                  keys = { {ImGui.Key_Period, ImGui.Mod_Shift} } },  -- '>'
  inputSampleDown      = { label = 'Sample -',                  keys = { {ImGui.Key_Comma, ImGui.Mod_Shift} } },  -- '<'
  playFromTop          = { label = 'Play from top',             keys = { ImGui.Key_F6 } },
  playFromCursor       = { label = 'Play from cursor',          keys = { ImGui.Key_F7 } },
  loopToItemNow        = { label = 'Loop to item',              keys = { {ImGui.Key_L, ImGui.Mod_Super} } },
  toggleLoopToItem     = { label = 'Loop to item on each move', keys = { {ImGui.Key_L, ImGui.Mod_Ctrl} } },
  toggleFollowPlay     = { label = 'Follow play',               keys = { {ImGui.Key_P, ImGui.Mod_Ctrl} } },
  clearLoop            = { label = 'Clear loop',                keys = { ImGui.Key_Escape } },
  openTemperPicker     = { label = 'Pick tuning',               keys = { {ImGui.Key_T, ImGui.Mod_Super} } },
  openSwingPicker      = { label = 'Pick swing',                keys = { {ImGui.Key_S, ImGui.Mod_Super} } },
  quantize             = { label = 'Quantize',                  keys = { {ImGui.Key_K, ImGui.Mod_Ctrl} } },
  quantizeKeepRealised = { label = 'Quantize (keep realised)',  keys = { {ImGui.Key_K, ImGui.Mod_Ctrl, ImGui.Mod_Shift} } },
  retune               = { label = 'Retune',                    keys = { {ImGui.Key_T, ImGui.Mod_Ctrl} } },
  editNoteFx           = { label = 'Edit note FX',              keys = { {ImGui.Key_X, ImGui.Mod_Super} } },
  freezeFxRegion       = { label = 'Freeze / explode FX',       keys = { {ImGui.Key_E, ImGui.Mod_Ctrl} } },
  freezeFxGroup        = { label = 'Freeze FX to group',        keys = { {ImGui.Key_E, ImGui.Mod_Ctrl, ImGui.Mod_Shift} } },
  focusParamPalette    = { label = 'Focus param palette',       keys = { {ImGui.Key_R, ImGui.Mod_Super} } },
  pinMap               = { label = 'Pin the arrange map',       keys = { {ImGui.Key_M, ImGui.Mod_Alt} } },
  returnToArrange      = { label = 'Back to arrange',           keys = { ImGui.Key_Enter, ImGui.Key_KeypadEnter } },
}

-- Universal-argument digit prefixes: Ctrl+0..9 arm advBy0..advBy9.
for i = 0, 9 do
  manifest.tracker['advBy' .. i] = { label = 'Advance by ' .. i, keys = { {ImGui.Key_0 + i, ImGui.Mod_Ctrl} } }
end

----- region (overlay within the tracker page; bodies + springLoaded config on ec)

manifest.region = {
  regionExit        = { label = 'Leave region mode',             keys = { ImGui.Key_Escape, ImGui.Key_Enter, ImGui.Key_KeypadEnter } },
  regionBail        = { label = 'Leave region, clear selection', keys = { {ImGui.Key_G, ImGui.Mod_Super} } },
  regionPaintExtend = { label = 'Add column to region',          keys = { ImGui.Key_Equal } },
  regionPaintShrink = { label = 'Drop column from region',       keys = { ImGui.Key_Minus } },
}

return manifest
