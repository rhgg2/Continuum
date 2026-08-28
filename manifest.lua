-- Every command declared once, in the order it reads: label, keys, menu path and cheat-sheet group.
-- see docs/commandManager.md §§ Manifest, Menu tree

--shape: { scope = { group = { entry, ... } } }
--shape: entry = { name, label = 'Play / pause', keys = { 'Ctrl+Z', ... }?, path?, letter?, family?, base? }
--shape: family = { label = 'Place slot', members = { entry, ... } } -- one cheat-sheet row

local util = require 'util'

local manifest = {}

-- Keys are the binding tokens of docs/commandManager.md § Binding tokens, and
-- installManifest turns them into keyspecs. A single chord needs no list.

-- The path's last segment titles the command in the menu; letter overrides it.
local function command(name, label, keys, path, letter)
  return { name = name, label = label, path = path, letter = letter,
           keys = type(keys) == 'string' and { keys } or keys }
end

-- One member of a generated family: the family table is shared, and `base` is the
-- member's unmasked token, which a family rebind re-masks. See docs/commandManager.md § Manifest.
local function member(family, name, label, mask, base)
  local entry = command(name, label, mask .. base)
  entry.family, entry.base = family, base
  util.add(family.members, entry)
  return entry
end

-- One menu group: its title, the letter that reaches it (derived from the title
-- where absent), the line shown while it is highlighted, and its child groups.
local function item(name, letter, desc, ...)
  return { name = name, letter = letter, desc = desc, children = { ... } }
end

----- global (bodies in continuum's Main, except toggleHelp, which is coordinator's)

manifest.global = {
  Transport = {
    command('playPause',        'Play / pause',        'Space'),
    command('stop',             'Stop',                'F8'),
  },
  Pages = {
    command('switchToArrange',  'Arrange page',        'F2',  'Jump/Arrange'),
    command('switchToWiring',   'Wiring page',         'F3',  'Jump/Wiring'),
    command('switchToTracker',  'Tracker page',        'F4',  'Jump/Tracker'),
    command('switchToSample',   'Sampler page',        'F9',  'Jump/Sampler'),
    command('switchToEditor',   'Editor page',         'F10', 'Jump/Editor'),
  },
  -- Both reached from their toolbar segment, which is where the sheet pins them.
  Tuning = { command('editTuning', 'Edit tuning', nil, 'Tuning/Edit') },
  Swing  = { command('editSwing',  'Edit swing',  nil, 'Grid/Swing/Edit') },
  Global = {
    command('undo',             'Undo',                'Ctrl+Z',       'Edit/Undo'),
    command('redo',             'Redo',                'Ctrl+Shift+Z', 'Edit/Redo'),
    command('quit',             'Quit',                'Ctrl+Q',       'File/Quit'),
    command('beginPrefix',      'Numeric prefix',      'Super+U'),
    command('toggleFxWindows',  'Toggle FX windows',   'F11',          'View/FX'),
    command('toggleProfiler',   'Toggle profiler',     'Ctrl+Shift+P', 'File/Profiler'),
    command('toggleHelp',       'This help',           'F1',           'Help'),
  },
  -- Reached programmatically — a toolbar click, a dive, the editor's exit — so
  -- they carry a label and no keys, and no page places this group.
  Programmatic = {
    command('play',             'Play'),
    command('switchPage',       'Go to page'),
    command('closeEditor',      'Close editor'),
    command('diveToSampler',    'Dive to sampler'),
  },
}

----- tracker (bodies in trackerView + trackerRender; editCursor's and clipboard's
----- register onto the same scope, returnToArrange's in continuum's Main)

-- A delete binding carries Backspace beside Delete: on a Mac laptop the bare key
-- is Backspace, and Key_Delete (\xe2\x8c\xa6) needs Fn.

manifest.tracker = {
  Movement = {
    command('cursorUp',              'Up',                          { 'Up', 'Super+P' }),
    command('cursorDown',            'Down',                        { 'Down', 'Super+N' }),
    command('cursorLeft',            'Left',                        { 'Left', 'Super+B' }),
    command('cursorRight',           'Right',                       { 'Right', 'Super+F' }),
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
  },
  Track = {
    command('prevTrack',             'Previous track',              'Alt+Left'),
    command('nextTrack',             'Next track',                  'Alt+Right'),
  },
  Take = {
    command('prevTake',              'Previous take',               'Alt+Comma'),
    command('nextTake',              'Next take',                   'Alt+Period'),
  },
  ['Take management'] = {
    command('prevInstance',          'Previous instance',           'Alt+Up'),
    command('nextInstance',          'Next instance',               'Alt+Down'),
    command('takeProperties',        'Take properties',             'Alt+P',            'Take/Properties'),
    command('newTakeBelow',          'New take',                    'Alt+Enter',        'Take/New'),
    command('duplicateBelow',        'Duplicate',                   'Shift+Alt+Down',   'Take/Duplicate'),
    command('deleteInstance',        'Delete instance',             'Shift+Alt+Up',     'Take/Remove/Instance'),
    command('prevVariant',           'Previous variant',            'Shift+Alt+Left',   'Take/Variant/Previous'),
    command('nextVariant',           'Next variant / vary',         'Shift+Alt+Right',  'Take/Variant/Next'),
    command('deleteBoundSlot',       'Delete take + instances',     { 'Ctrl+Delete', 'Ctrl+Backspace' },
                                                                                        'Take/Remove/Take + instances'),
    command('pinMap',                'Pin the arrange map',         'Alt+M',            'View/Map'),
  },
  Editing = {
    command('noteOff',               'Note off',                    '1'),
    command('shrinkNote',            'Shrink note',                 'Shift+Super+Up'),
    command('growNote',              'Grow note',                   'Shift+Super+Down'),
    command('nudgeBack',             'Push back',                   'Super+Up'),
    command('nudgeForward',          'Push forward',                'Super+Down'),
    command('eventShiftLeft',        'Push left',                   'Super+Left'),
    command('eventShiftRight',       'Push right',                  'Super+Right'),
    command('delete',                'Clear cell',                  'Period'),
    command('deleteSel',             'Delete selection',            { 'Delete', 'Backspace' }),
    command('interpolate',           'Interpolate',                 'Ctrl+I',           'Edit/Interpolate'),
    command('nudgeCoarseUp',         'Nudge val ++',                'Ctrl+Equal'),
    command('nudgeCoarseDown',       'Nudge val --',                'Ctrl+Minus'),
    command('nudgeFineUp',           'Nudge val +',                 'Shift+Equal'),
    command('nudgeFineDown',         'Nudge val -',                 'Shift+Minus'),
    command('scaleHalf',             'Scale \xc3\x97\xc2\xbd',      'Shift+9',          'Grid/Scale/Halve'),   -- '('
    command('scaleDouble',           'Scale \xc3\x972',             'Shift+0',          'Grid/Scale/Double'),  -- ')'
    command('quantize',              'Quantize',                    'Ctrl+K',           'Grid/Quantize'),
    command('quantizeKeepRealised',  'Quantize (keep realised)',    'Ctrl+Shift+K',     'Grid/Keep'),
    command('retune',                'Retune',                      'Ctrl+T',           'Tuning/Retune'),
  },
  Selection = {
    command('selectUp',              'Select up',                   'Shift+Up'),
    command('selectDown',            'Select down',                 'Shift+Down'),
    command('selectLeft',            'Select left',                 'Shift+Left'),
    command('selectRight',           'Select right',                'Shift+Right'),
    command('cycleBlock',            'Cycle selection H',           'Super+O'),
    command('cycleVBlock',           'Cycle selection V',           'Super+Space'),
    command('swapBlockEnds',         'Swap block ends',             'Ctrl+Grave'),
    command('selectClear',           'Clear selection',             'Super+G'),
    command('selectAll',             'Select all',                  'Ctrl+A',           'Edit/All'),
    command('cut',                   'Cut',                         { 'Super+W', 'Ctrl+X' }, 'Edit/Cut', 'X'),
    command('copy',                  'Copy',                        { 'Ctrl+W', 'Ctrl+C' },  'Edit/Copy'),
    command('paste',                 'Paste',                       { 'Super+Y', 'Ctrl+V' }, 'Edit/Paste'),
    command('duplicateDown',         'Duplicate',                   'Ctrl+D',           'Edit/Duplicate'),
  },
  ['Columns & rows'] = {
    command('insertRow',             'Insert row (all columns)',    'Ctrl+Shift+Down',  'Row/Global/Insert'),
    command('insertRowCol',          'Insert row in column',        'Ctrl+Down',        'Row/Insert'),
    command('deleteRowCol',          'Delete row in column',        'Ctrl+Up',          'Row/Delete'),
    command('deleteRow',             'Delete row (all columns)',    'Ctrl+Shift+Up',    'Row/Global/Delete'),
    command('addNoteLane',           'Add note lane',               'Ctrl+Right',       'Column/Note'),
    command('addTypedCol',           'Add cc/pb/at/pc column',      'Ctrl+Shift+Right', 'Column/Continuous'),
    command('hideExtraCol',          'Remove column',               'Ctrl+Left',        'Column/Delete'),
  },
  ['Rows / beat'] = {
    command('doubleRPB',             'Double',                      'Super+Equal',      'View/Rows/Double', '='),
    command('halveRPB',              'Halve',                       'Super+Minus',      'View/Rows/Halve',  '-'),
    command('incRPB',                'Rows / beat +1',              'Shift+Super+Equal'),
    command('decRPB',                'Rows / beat -1',              'Shift+Super+Minus'),
    command('setRPB',                'Set',                         'Super+Z',          'View/Rows/Set'),
    command('matchGridToCursor',     'Match',                       'Super+M',          'View/Rows/Match'),
  },
  ['Groups & region'] = {
    command('groupDuplicate',        'Duplicate group',             'Ctrl+Shift+D',     'Mirror/Duplicate'),
    command('groupPaste',            'Paste group',                 'Ctrl+Shift+V',     'Mirror/Paste'),
    command('groupLocalToggle',      'Toggle local',                'Shift+Backslash',  'Mirror/Local'),
    command('regionArm',             'Region mode',                 'Backslash',        'Mirror/Region'),
    command('groupInstPrev',         'Prev instance',               'LeftBracket'),
    command('groupInstNext',         'Next instance',               'RightBracket'),
  },
  FX = {
    command('editNoteFx',            'Edit note FX',                'Super+X',          'FX/Editor'),
    command('freezeFxRegion',        'Freeze / explode FX',         'Ctrl+E',           'FX/Freeze'),
    command('freezeFxGroup',         'Freeze FX to group',          'Ctrl+Shift+E',     'FX/Group'),
    command('focusParamPalette',     'Focus param palette',         'Super+R',          'View/Parameters'),
  },
  Input = {
    command('inputOctaveUp',         'Octave +',                    'Shift+8'),
    command('inputOctaveDown',       'Octave -',                    'Shift+7'),
  },
  Sample = {
    command('inputSampleUp',         'Sample +',                    'Shift+Period'),  -- '>'
    command('inputSampleDown',       'Sample -',                    'Shift+Comma'),  -- '<'
  },
  Transport = {
    command('playFromTop',           'Play from top',               'F6',               'Play/Item'),
    command('playFromCursor',        'Play from cursor',            'F7',               'Play/Cursor'),
  },
  Loop = {
    command('loopToItemNow',         'Loop to item',                'Super+L',          'Play/Loop/Item'),
    command('toggleLoopToItem',      'Loop to item on each move',   'Ctrl+L',           'Play/Loop/Always'),
    command('toggleFollowPlay',      'Follow play',                 'Ctrl+P',           'Play/Follow'),
    command('clearLoop',             'Clear loop',                  'Escape',           'Play/Loop/Clear'),
  },
  Tuning = { command('openTemperPicker', 'Pick tuning',             'Super+T',          'Tuning/Pick') },
  Swing  = { command('openSwingPicker',  'Pick swing',              'Super+S',          'Grid/Swing/Pick') },
  Global = { command('returnToArrange',  'Back to arrange',         { 'Enter', 'KeypadEnter' }) },
  Advance = {},
}

-- Universal-argument digit prefixes: Ctrl+0..9 arm advBy0..advBy9. The ten read as
-- one cheat-sheet row and rebind together from one captured chord's mask.
local trackerAdvance = { label = 'Advance by 0-9', members = {} }
for i = 0, 9 do
  util.add(manifest.tracker.Advance,
           member(trackerAdvance, 'advBy' .. i, 'Advance by ' .. i, 'Ctrl+', tostring(i)))
end

----- region (overlay within the tracker page; bodies + springLoaded config on ec)

manifest.region = {
  Region = {
    command('regionExit',         'Leave region mode',               { 'Escape', 'Enter', 'KeypadEnter' }),
    command('regionBail',         'Leave region, clear selection',   'Super+G'),
    command('regionPaintExtend',  'Add column to region',            'Equal'),
    command('regionPaintShrink',  'Drop column from region',         'Minus'),
  },
}

----- arrange (bodies in arrangeView + arrangeRender)

-- Cursor-nav and take-edit commands reuse the tracker scope's keys but not its
-- names: cmgr.commands is flat, so a shared name would clobber the other gate.

manifest.arrange = {
  Movement = {
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
  },
  Selection = {
    command('arrangeSelectUp',        'Select up',                'Shift+Up'),
    command('arrangeSelectDown',      'Select down',              'Shift+Down'),
    command('arrangeSelectLeft',      'Select left',              'Shift+Left'),
    command('arrangeSelectRight',     'Select right',             'Shift+Right'),
    command('arrangeClearSelection',  'Clear selection',          'Super+G'),
  },
  Takes = {
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
  },
  Modes = {
    -- Shadows the global universal-argument prefix, which no arrange command reads.
    command('arrangeReplaceMode',     'Replace mode',             'Super+U'),
    command('arrangeAdvanceMode',     'Advance by take length',   'Ctrl+Grave'),
    command('arrangeFollowPlay',      'Follow play',              'Super+F'),
  },
  Loop = {
    command('arrangeSetLoopStart',    'Set loop start',           'Super+B'),
    command('arrangeSetLoopEnd',      'Set loop end',             'Super+E'),
    command('arrangeLoopToItem',      'Loop to take',             'Super+L'),
    command('arrangeClearLoop',       'Clear loop',               'Escape'),
  },
  Transport = {
    command('arrangePlayFromCursor',  'Play from cursor',         'F6'),
  },
  View = {
    command('arrangeZoomIn',          'Zoom in',                  'Super+Equal'),
    command('arrangeZoomOut',         'Zoom out',                 'Super+Minus'),
  },
  Slots   = {},
  Advance = {},
}

-- Place-command tokens: 0..9 → digit keys, 10..35 → letters, 36..61 →
-- Shift+letter.
local function placeKey(slotIdx)
  if slotIdx < 10 then return tostring(slotIdx) end
  if slotIdx < 36 then return string.char(65 + slotIdx - 10) end
  return 'Shift+' .. string.char(65 + slotIdx - 36)
end

-- Slot key = util.toBase62(i); matches arrangeView's drop-command registration. The
-- sixty-two are unmasked, so a captured mask lands over the place keys as declared.
local slotFamily = { label = 'Place slot', members = {} }
for i = 0, 61 do
  local key = util.toBase62(i)
  util.add(manifest.arrange.Slots,
           member(slotFamily, 'drop' .. key, 'Place slot ' .. key, '', placeKey(i)))
end

-- Universal-argument digit prefixes, project-wide rather than tracker's take-tier.
local arrangeAdvance = { label = 'Advance by 0-9', members = {} }
for i = 0, 9 do
  util.add(manifest.arrange.Advance,
           member(arrangeAdvance, 'arrangeAdvanceBy' .. i, 'Advance by ' .. i, 'Ctrl+', tostring(i)))
end

----- sample (bodies + the slot-clamp invariant in sampleRender)

manifest.sample = {
  Browser = {
    command('browserUp',       'Up a folder',       'Ctrl+Up'),
    command('browserPreview',  'Open / audition',   'Ctrl+Down'),
    command('browserAssign',   'Load into slot',    'Ctrl+Right'),
  },
  Slots = {
    command('slotNext',        'Next slot',         'Shift+Period'),
    command('slotPrev',        'Previous slot',     'Shift+Comma'),
    command('slotRename',      'Rename slot',       { 'Enter', 'KeypadEnter' }),
  },
}

----- wiring (bodies in wiringRender)

manifest.wiring = {
  Wiring = {
    command('wiringAddFx',           'Add FX',            'N'),
    command('wiringClearSelection',  'Clear selection',   'Escape'),
  },
}

----- menu tree (the groups a path walks; see docs/commandManager.md § Menu tree)

manifest.tree = {
  item('File',   nil, 'REAPER project actions, and leaving Continuum'),
  item('Edit',   nil, 'The block and the clipboard'),
  item('View',   nil, 'Panels, the arrange map, rows per beat',
       item('Rows',    nil, 'How many rows a beat holds')),
  item('Play',   nil, 'Playing, following, and the loop',
       item('Loop',    nil, 'The loop and what clears it')),
  item('Column', nil, 'Adding and removing columns'),
  item('Row',    nil, 'Inserting and deleting rows',
       item('Global',  nil, 'Rows across every column at once')),
  item('Grid',   nil, 'Quantize, scale and swing',
       item('Scale',   nil, 'Stretch the block in time'),
       item('Swing',   'W', 'The swing the take is played with')),
  item('Tuning', nil, 'Tuning and retune'),
  item('Take',   'K', 'Take lifecycle and variants',
       item('Variant', nil, 'Step through a take\'s variants'),
       item('Remove',  nil, 'Delete a take or one instance')),
  item('Mirror', nil, 'Mirror groups and freezing'),
  item('FX',     'X', 'Note FX and the param palette'),
  item('Jump',   nil, 'Travel to a page'),
}

return manifest
