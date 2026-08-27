-- Every command declared once, in the order it reads: the label it shows
-- under, and the keys that reach it. see docs/commandManager.md § Manifest

--shape: { scope = { entry, ... } }
--shape: entry = { name, label = 'Play / pause', keys = { 'Ctrl+Z', ... }?, path? }

local util = require 'util'

local manifest = {}

-- Keys are the binding tokens of docs/commandManager.md § Binding tokens, and
-- installManifest turns them into keyspecs. A single chord needs no list.
local function command(name, label, keys, path)
  return { name = name, label = label,
           keys = type(keys) == 'string' and { keys } or keys, path = path }
end

----- global (bodies in continuum's Main, except toggleHelp, which is coordinator's)

-- switchPage, diveToSampler and editTuning/editSwing/closeEditor are reached
-- programmatically (toolbar click, dive, editor exit): label, no keys.

manifest.global = {
  command('play',             'Play'),
  command('playPause',        'Play / pause',        'Space'),
  command('stop',             'Stop',                'F8'),
  command('undo',             'Undo',                'Ctrl+Z'),
  command('redo',             'Redo',                'Ctrl+Shift+Z'),
  command('switchPage',       'Go to page'),
  command('switchToArrange',  'Arrange page',        'F2'),
  command('switchToWiring',   'Wiring page',         'F3'),
  command('switchToTracker',  'Tracker page',        'F4'),
  command('switchToSample',   'Sampler page',        'F9'),
  command('switchToEditor',   'Editor page',         'F10'),
  command('editTuning',       'Edit tuning'),
  command('editSwing',        'Edit swing'),
  command('closeEditor',      'Close editor'),
  command('diveToSampler',    'Dive to sampler'),
  command('togglePage',       'Switch page'),
  command('quit',             'Quit',                'Ctrl+Q'),
  command('beginPrefix',      'Numeric prefix',      'Super+U'),
  command('toggleFxWindows',  'Toggle FX windows',   'F11'),
  command('toggleProfiler',   'Toggle profiler',     'Ctrl+Shift+P'),
  command('toggleHelp',       'This help',           'F1'),
}

----- tracker (bodies in trackerView + trackerRender; editCursor's and clipboard's
----- register onto the same scope, returnToArrange's in continuum's Main)

-- A delete binding carries Backspace beside Delete: on a Mac laptop the bare key
-- is Backspace, and Key_Delete (\xe2\x8c\xa6) needs Fn.

manifest.tracker = {
  command('cursorUp',              'Up',                          { 'Up', 'Super+P' }),
  command('cursorDown',            'Down',                        { 'Down', 'Super+N' }),
  command('cursorLeft',            'Left',                        { 'Left', 'Super+B' }),
  command('cursorRight',           'Right',                       { 'Right', 'Super+F' }),
  command('prevTrack',             'Previous track',              'Alt+Left'),
  command('nextTrack',             'Next track',                  'Alt+Right'),
  command('prevTake',              'Previous take',               'Alt+Comma'),
  command('nextTake',              'Next take',                   'Alt+Period'),
  command('prevInstance',          'Previous instance',           'Alt+Up'),
  command('nextInstance',          'Next instance',               'Alt+Down'),
  command('goTop',                 'Top',                         { 'Home', 'Ctrl+Shift+Comma' }),
  command('goBottom',              'Bottom',                      { 'End', 'Ctrl+Shift+Period' }),
  command('goLeft',                'First column',                'Super+A'),
  command('goRight',               'Last filled column',          'Super+E'),
  command('pageUp',                'Page up',                     { 'PageUp', 'Shift+Super+V' }),
  command('pageDown',              'Page down',                   { 'PageDown', 'Super+V' }),
  command('colLeft',               'Column left',                 'Shift+Tab'),
  command('colRight',              'Column right',                'Tab'),
  command('channelLeft',           'Channel left',                'Ctrl+B'),
  command('channelRight',          'Channel right',               'Ctrl+F'),
  command('noteOff',               'Note off',                    '1'),
  command('shrinkNote',            'Shrink note',                 'Shift+Super+Up'),
  command('growNote',              'Grow note',                   'Shift+Super+Down'),
  command('nudgeBack',             'Push back',                   'Super+Up'),
  command('nudgeForward',          'Push forward',                'Super+Down'),
  command('eventShiftLeft',        'Push left',                   'Super+Left'),
  command('eventShiftRight',       'Push right',                  'Super+Right'),
  command('insertRow',             'Insert row (all columns)',    'Ctrl+Shift+Down'),
  command('insertRowCol',          'Insert row in column',        'Ctrl+Down'),
  command('deleteRowCol',          'Delete row in column',        'Ctrl+Up'),
  command('deleteRow',             'Delete row (all columns)',    'Ctrl+Shift+Up'),
  command('addNoteLane',           'Add note lane',               'Ctrl+Right'),
  command('addTypedCol',           'Add cc/pb/at/pc column',      'Ctrl+Shift+Right'),
  command('hideExtraCol',          'Remove column',               'Ctrl+Left'),
  command('delete',                'Clear cell',                  'Period'),
  command('interpolate',           'Interpolate',                 'Ctrl+I'),
  command('selectUp',              'Select up',                   'Shift+Up'),
  command('selectDown',            'Select down',                 'Shift+Down'),
  command('selectLeft',            'Select left',                 'Shift+Left'),
  command('selectRight',           'Select right',                'Shift+Right'),
  command('cycleBlock',            'Cycle selection H',           'Super+O'),
  command('cycleVBlock',           'Cycle selection V',           'Super+Space'),
  command('swapBlockEnds',         'Swap block ends',             'Ctrl+Grave'),
  command('selectClear',           'Clear selection',             'Super+G'),
  command('selectAll',             'Select all',                  'Ctrl+A'),
  command('cut',                   'Cut',                         { 'Super+W', 'Ctrl+X' }),
  command('copy',                  'Copy',                        { 'Ctrl+W', 'Ctrl+C' }),
  command('paste',                 'Paste',                       { 'Super+Y', 'Ctrl+V' }),
  command('duplicateDown',         'Duplicate',                   'Ctrl+D'),
  command('deleteSel',             'Delete selection',            { 'Delete', 'Backspace' }),
  command('nudgeCoarseUp',         'Nudge val ++',                'Ctrl+Equal'),
  command('nudgeCoarseDown',       'Nudge val --',                'Ctrl+Minus'),
  command('nudgeFineUp',           'Nudge val +',                 'Shift+Equal'),
  command('nudgeFineDown',         'Nudge val -',                 'Shift+Minus'),
  command('scaleHalf',             'Scale \xc3\x97\xc2\xbd',      'Shift+9'),  -- '('
  command('scaleDouble',           'Scale \xc3\x972',             'Shift+0'),  -- ')'
  command('doubleRPB',             'Double',                      'Super+Equal'),
  command('halveRPB',              'Halve',                       'Super+Minus'),
  command('incRPB',                'Rows / beat +1',              'Shift+Super+Equal'),
  command('decRPB',                'Rows / beat -1',              'Shift+Super+Minus'),
  command('setRPB',                'Set',                         'Super+Z'),
  command('takeProperties',        'Take properties',             'Alt+P'),
  command('newTakeBelow',          'New take',                    'Alt+Enter'),
  command('duplicateBelow',        'Duplicate',                   'Shift+Alt+Down'),
  command('deleteInstance',        'Delete instance',             'Shift+Alt+Up'),
  command('prevVariant',           'Previous variant',            'Shift+Alt+Left'),
  command('nextVariant',           'Next variant / vary',         'Shift+Alt+Right'),
  command('deleteBoundSlot',       'Delete take + instances',     { 'Ctrl+Delete', 'Ctrl+Backspace' }),
  command('matchGridToCursor',     'Match',                       'Super+M'),
  command('groupDuplicate',        'Duplicate group',             'Ctrl+Shift+D'),
  command('groupPaste',            'Paste group',                 'Ctrl+Shift+V'),
  command('groupLocalToggle',      'Toggle local',                'Shift+Backslash'),
  command('regionArm',             'Region mode',                 'Backslash'),
  command('groupInstPrev',         'Prev instance',               'LeftBracket'),
  command('groupInstNext',         'Next instance',               'RightBracket'),
  command('inputOctaveUp',         'Octave +',                    'Shift+8'),
  command('inputOctaveDown',       'Octave -',                    'Shift+7'),
  command('inputSampleUp',         'Sample +',                    'Shift+Period'),  -- '>'
  command('inputSampleDown',       'Sample -',                    'Shift+Comma'),  -- '<'
  command('playFromTop',           'Play from top',               'F6'),
  command('playFromCursor',        'Play from cursor',            'F7'),
  command('loopToItemNow',         'Loop to item',                'Super+L'),
  command('toggleLoopToItem',      'Loop to item on each move',   'Ctrl+L'),
  command('toggleFollowPlay',      'Follow play',                 'Ctrl+P'),
  command('clearLoop',             'Clear loop',                  'Escape'),
  command('openTemperPicker',      'Pick tuning',                 'Super+T'),
  command('openSwingPicker',       'Pick swing',                  'Super+S'),
  command('quantize',              'Quantize',                    'Ctrl+K'),
  command('quantizeKeepRealised',  'Quantize (keep realised)',    'Ctrl+Shift+K'),
  command('retune',                'Retune',                      'Ctrl+T'),
  command('editNoteFx',            'Edit note FX',                'Super+X'),
  command('freezeFxRegion',        'Freeze / explode FX',         'Ctrl+E'),
  command('freezeFxGroup',         'Freeze FX to group',          'Ctrl+Shift+E'),
  command('focusParamPalette',     'Focus param palette',         'Super+R'),
  command('pinMap',                'Pin the arrange map',         'Alt+M'),
  command('returnToArrange',       'Back to arrange',             { 'Enter', 'KeypadEnter' }),
}

-- Universal-argument digit prefixes: Ctrl+0..9 arm advBy0..advBy9.
for i = 0, 9 do
  util.add(manifest.tracker, command('advBy' .. i, 'Advance by ' .. i, 'Ctrl+' .. i))
end

----- region (overlay within the tracker page; bodies + springLoaded config on ec)

manifest.region = {
  command('regionExit',         'Leave region mode',               { 'Escape', 'Enter', 'KeypadEnter' }),
  command('regionBail',         'Leave region, clear selection',   'Super+G'),
  command('regionPaintExtend',  'Add column to region',            'Equal'),
  command('regionPaintShrink',  'Drop column from region',         'Minus'),
}

----- arrange (bodies in arrangeView + arrangeRender)

-- Cursor-nav and take-edit commands reuse the tracker scope's keys but not its
-- names: cmgr.commands is flat, so a shared name would clobber the other gate.

manifest.arrange = {
  command('arrangeCursorUp',        'Up',                       'Up'),
  command('arrangeCursorDown',      'Down',                     'Down'),
  command('arrangeCursorLeft',      'Left',                     'Left'),
  command('arrangeCursorRight',     'Right',                    'Right'),
  command('arrangePageUp',          'Page up',                  'PageUp'),
  command('arrangePageDown',        'Page down',                'PageDown'),
  command('arrangeHome',            'Top',                      'Home'),
  command('arrangeEnd',             'End of project',           'End'),
  command('arrangeNextDrop',        'Next take edge',           'Alt+Down'),
  command('arrangePrevDrop',        'Previous take edge',       'Alt+Up'),
  command('arrangeSelectUp',        'Select up',                'Shift+Up'),
  command('arrangeSelectDown',      'Select down',              'Shift+Down'),
  command('arrangeSelectLeft',      'Select left',              'Shift+Left'),
  command('arrangeSelectRight',     'Select right',             'Shift+Right'),
  command('arrangeClearSelection',  'Clear selection',          'Super+G'),
  command('createSlot',             'New slot',                 'Super+Enter'),
  command('deleteSlot',             'Delete slot',              { 'Ctrl+Delete', 'Ctrl+Backspace' }),
  command('arrangeNudgeBack',       'Nudge take back',          'Super+Up'),
  command('arrangeNudgeForward',    'Nudge take forward',       'Super+Down'),
  command('arrangeEdgeUp',          'Move edge up',             'Shift+Super+Up'),
  command('arrangeEdgeDown',        'Move edge down',           'Shift+Super+Down'),
  command('arrangeSplit',           'Split take',               'Ctrl+S'),
  command('arrangeDeleteTake',      'Delete take',              { 'Delete', 'Backspace' }),
  command('arrangeDeleteAdvance',   'Delete take, advance',     'Period'),
  command('arrangeDeleteRetreat',   'Delete take, retreat',     'Shift+Alt+Up'),
  command('arrangeDive',            'Dive to tracker',          'Enter'),
  command('arrangeTakeProperties',  'Take properties',          'Super+Backspace'),
  command('arrangeDuplicateBelow',  'Duplicate take',           { 'Ctrl+D', 'Shift+Alt+Down' }),
  command('arrangePrevVariant',     'Previous variant',         'Shift+Alt+Left'),
  command('arrangeNextVariant',     'Next variant',             'Shift+Alt+Right'),
  -- Shadows the global universal-argument prefix, which no arrange command reads.
  command('arrangeReplaceMode',     'Replace mode',             'Super+U'),
  command('arrangeAdvanceMode',     'Advance by take length',   'Ctrl+Grave'),
  command('arrangeSetLoopStart',    'Set loop start',           'Super+B'),
  command('arrangeSetLoopEnd',      'Set loop end',             'Super+E'),
  command('arrangeLoopToItem',      'Loop to take',             'Super+L'),
  command('arrangeClearLoop',       'Clear loop',               'Escape'),
  command('arrangeFollowPlay',      'Follow play',              'Super+F'),
  command('arrangePlayFromCursor',  'Play from cursor',         'F6'),
  command('arrangeZoomIn',          'Zoom in',                  'Super+Equal'),
  command('arrangeZoomOut',         'Zoom out',                 'Super+Minus'),
}

-- Place-command tokens: 0..9 → digit keys, 10..35 → letters, 36..61 →
-- Shift+letter.
local function placeKey(slotIdx)
  if slotIdx < 10 then return tostring(slotIdx) end
  if slotIdx < 36 then return string.char(65 + slotIdx - 10) end
  return 'Shift+' .. string.char(65 + slotIdx - 36)
end

-- Slot key = util.toBase62(i); matches arrangeView's drop-command registration.
for i = 0, 61 do
  local key = util.toBase62(i)
  util.add(manifest.arrange, command('drop' .. key, 'Place slot ' .. key, placeKey(i)))
end

-- Universal-argument digit prefixes, project-wide rather than tracker's take-tier.
for i = 0, 9 do
  util.add(manifest.arrange,
           command('arrangeAdvanceBy' .. i, 'Advance by ' .. i, 'Ctrl+' .. i))
end

----- sample (bodies + the slot-clamp invariant in sampleRender)

manifest.sample = {
  command('browserUp',       'Up a folder',       'Ctrl+Up'),
  command('browserPreview',  'Open / audition',   'Ctrl+Down'),
  command('browserAssign',   'Load into slot',    'Ctrl+Right'),
  command('slotNext',        'Next slot',         'Shift+Period'),
  command('slotPrev',        'Previous slot',     'Shift+Comma'),
  command('slotRename',      'Rename slot',       { 'Enter', 'KeypadEnter' }),
}

----- wiring (bodies in wiringRender)

manifest.wiring = {
  command('wiringAddFx',           'Add FX',            'N'),
  command('wiringClearSelection',  'Clear selection',   'Escape'),
}

return manifest
