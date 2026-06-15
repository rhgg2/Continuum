-- See docs/configManager.md for the model.

--invariant: cm is the sole source of truth for valid keys; in-code reads/writes raise on unknown keys, persistence-loaded unknowns are silently pruned
--invariant: cm owns its cache tables: every read deep-clones on the way out, every write deep-clones on the way in (callers never alias cm state)
--invariant: 5-tier merge order: global → project → track → take → transient; most-specific cache holding the key wins, falling through to schema defaults
--invariant: transient tier never persists (saver is a no-op) and resets to {} on every refreshCache
--invariant: declarations is an ordered array-of-pairs so declared-but-nil keys (e.g. sampleBrowserRoot) coexist with non-nil defaults without ambiguity
--invariant: track and take tiers require the corresponding REAPER context; without it their loaders return {} and savers print an error
--shape: configChangedPayload.targeted = { key = string, level = string, track? = MediaTrack }   -- set / remove; track set only by writeTrackKey for foreign-track writes
--shape: configChangedPayload.bulk     = { level = string }                  -- assign (keyless)
--shape: configChangedPayload.reload   = {}                                  -- setContext / clearTake / setTrack
local util = require 'util'

local function print(...)
  return util.print(...)
end

local function hex(s, alpha)
  s = s:gsub('^#', '')
  local r = tonumber(s:sub(1,2), 16) / 255
  local g = tonumber(s:sub(3,4), 16) / 255
  local b = tonumber(s:sub(5,6), 16) / 255
  return {r, g, b, alpha or 1}
end

local declarations = {
  -- numeric
  { 'pbRange',         2     },
  { 'rowPerBeat',      4     },
  { 'overlapOffset',   1/16  },
  { 'defaultVelocity', 100   },
  { 'currentOctave',   2     },
  { 'currentSample',   0     },
  { 'advanceBy',       1     },
  { 'arrangeAdvanceBy', 1     },

  -- boolean
  { 'polyAftertouch',  true  },
  { 'trackerMode',     false },
  { 'previewInPlace',  false },
  { 'advanceOnLoad',   true  },

  -- string choice
  { 'noteLayout',      'colemak' },
  -- Slot keys: take-tier so each take can carry its own swing/temper
  -- without rewriting siblings. Defaults are explicit no-op sentinels,
  -- not nil. '12EDO' resolves via tuning.presets; 'identity' resolves
  -- via the swings library. The sentinel blocks the bind-time seed --
  -- an explicit "Off" pick must stick across rebinds.
  { 'temper',          '12EDO'    },
  { 'swing',           'identity' },
  -- Project-tier seeds for first-encounter takes. Pickers mirror the
  -- chosen value into 'last*Used' at project tier; tp:bind copies the
  -- seed into the take tier on bind when the take has no value of its
  -- own (created in REAPER outside Continuum, or pre-existing). Pickers
  -- used to mirror 'swing'/'temper' themselves at project tier as the
  -- cross-take seed, but SetProjExtState lives outside REAPER's undo,
  -- so a Ctrl-Z over a pick left the project mirror at the new value
  -- while the lower tier was rewound -- picker desync.
  { 'lastSwingUsed',   'identity' },
  { 'lastTemperUsed',  '12EDO'    },

  -- null-defaulted (declared, no initial value)
  { 'sampleBrowserRoot', nil },
  -- Project-tier breadcrumb so sampler save-migration survives a
  -- save that happens while Continuum is closed. See docs/sampleManager.md.
  { 'lastProjectPath',   nil },

  -- table-valued
  { 'colSwing',        {}    },
  -- The swings default is the system preset library: built-in
  -- compositions visible in every project until either the global
  -- tier (user-saved presets) or the project tier (project-local
  -- swings) overlays them per-name. Read with mergeTiers=true to
  -- get the union.
  { 'swings',          {
      ['identity']   = {},
      ['classic-55'] = { factors = { { atom = 'classic', shift = 0.05, period = 1 } } },
      ['classic-58'] = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } },
      ['classic-62'] = { factors = { { atom = 'classic', shift = 0.12, period = 1 } } },
      ['classic-67'] = { factors = { { atom = 'classic', shift = 0.17, period = 1 } } },
      -- Identity-shift = pure delay.
      ['delay+15']   = { factors = { { atom = 'id', shift =  1/16, period = 1 } } },
      ['delay+30']   = { factors = { { atom = 'id', shift =  1/8,  period = 1 } } },
      ['delay-15']   = { factors = { { atom = 'id', shift = -1/16, period = 1 } } },
      ['delay-30']   = { factors = { { atom = 'id', shift = -1/8,  period = 1 } } },
    } },
  { 'usedSwings',      {}    },
  { 'tempers',         {}    },
  { 'mutedChannels',   {}    },
  { 'soloedChannels',  {}    },
  { 'extraColumns',    {}    },
  -- Param-automation bindings, take tier: [chan][lane] = binding.
  -- See design/cv.md § simple layer for the binding shape.
  { 'paramAutomation', {}    },
  -- Param-palette frecency, global tier. Decays per plugin-use (the
  -- ident's n counter), not per day; see paramAutomation.lua.
  { 'paramFrecency',   {}    },
  { 'noteDelay',       {}    },
  { 'slotEntries',     {}    },
  -- Mirror groups, persisted at the take tier. See docs/groupManager.md.
  { 'groups',    {}    },
  -- Arrange-page slot palette, per track. Indexed 0..61; entry shape
  -- { kind = 'midi'|'audio', id = <pool-guid-or-source-path> }. See
  -- docs/arrangeManager.md.
  { 'arrangeSlots', {} },
  -- Arrange-page grid density. Row/col addressing mirrors the tracker
  -- view; cursor and scroll live in arrangeView module-locals (in-memory,
  -- not persisted) the same way trackerView and editCursor handle them.
  -- Only the density preference earns a persisted slot. Typical values
  -- 4, 8, 16 beats per row (one bar to four bars per row in 4/4).
  { 'arrangeBeatPerRow', 4 },
  -- Arrange-take natural length in QN: the ceiling the item regrows
  -- toward when neighbours move out of the way. Persisted per-take via
  -- writeTakeKey (P_EXT). Default (nil at storage) reads as util.OPEN —
  -- the source's length is the effective cap. See docs/arrangeManager.md.
  { 'arrangeNaturalLenQN', nil },
  -- Arrange palette colour, project-wide, { [takeId] = colourIdx }.
  -- See docs/arrangeManager.md.
  { 'arrangeColours', {} },

  -- Palette atoms — role-named swatches the colour editor edits; base/alt are
  -- tonal ramps (zoneN at lightness N/10, ends pure black/white).
  { 'palette.base.zone0',  hex('#000000') },  -- base: warm neutral (paper / ink)
  { 'palette.base.zone1',  hex('#1e1e15') },
  { 'palette.base.zone2',  hex('#3c3b2a') },
  { 'palette.base.zone3',  hex('#575542') },
  { 'palette.base.zone4',  hex('#716d5b') },
  { 'palette.base.zone5',  hex('#888477') },
  { 'palette.base.zone6',  hex('#a9a389') },
  { 'palette.base.zone7',  hex('#bebba7') },
  { 'palette.base.zone8',  hex('#d5d1c3') },
  { 'palette.base.zone9',  hex('#eae8e1') },
  { 'palette.base.zone10', hex('#ffffff') },
  { 'palette.alt.zone0',   hex('#000000') },  -- alt: cool blue (cursor / chrome / wiring)
  { 'palette.alt.zone1',   hex('#15171e') },
  { 'palette.alt.zone2',   hex('#2a2e3c') },
  { 'palette.alt.zone3',   hex('#414758') },
  { 'palette.alt.zone4',   hex('#596173') },
  { 'palette.alt.zone5',   hex('#637e9c') },
  { 'palette.alt.zone6',   hex('#888faa') },
  { 'palette.alt.zone7',   hex('#a5a8c0') },
  { 'palette.alt.zone8',   hex('#c3c3d5') },
  { 'palette.alt.zone9',   hex('#e2e4e9') },
  { 'palette.alt.zone10',  hex('#ffffff') },
  -- single-swatch roles
  { 'palette.alt2',     hex('#e89282') },  -- warm pink (wiring effect node)
  { 'palette.mark',     hex('#dcb432') },  -- amber attention marker (solo, selected node)
  { 'palette.alert',    hex('#da3021') },
  { 'palette.caution',  hex('#d25a23') },
  { 'palette.positive', hex('#568a40') },

  -- Grid roles
  { 'colour.bg',               'palette.base.zone8'               },
  { 'colour.text',             'palette.base.zone2'               },
  { 'colour.offGrid',          'palette.positive'                 },
  { 'colour.overflow',         'palette.caution'                  },
  { 'colour.negative',         'palette.alert'                    },
  { 'colour.inactive',         'palette.base.zone5'               },
  { 'colour.shadowed',         'colour.inactive'                  },
  { 'colour.cursor',           'palette.alt.zone2'                },
  { 'colour.cursorText',       'palette.alt.zone8'                },
  -- Arrange page: cursor caret, blocked-drag outline, transport rules,
  -- double-click-drag ghost, and orphan (slot-less item) fills. The 62
  -- generated slot hues stay computed (golden-ratio rotation); these are the
  -- fixed colours, named so they live in the palette like every other chrome
  -- colour rather than as inline ints.
  { 'colour.arrange.cursorOn',     'palette.base.zone2'      },
  { 'colour.arrange.cursorOff',     'palette.base.zone6'    },
  { 'colour.arrange.itemBorder',       'palette.base.zone5'      },  -- solid neutral box outline (one zone below cursorOff)
  { 'colour.arrange.phrase',           {'colour.rowBeat', 1.0}   },  -- bar tint at full alpha
  { 'colour.arrange.blockedBorder',    {0.80, 0.16, 0.16, 0.95}  },  -- drag would overlap a neighbour
  { 'colour.arrange.editCursor',       'palette.base.zone2'      },  -- edit-cursor triangle fill
  { 'colour.arrange.playHead',         'palette.alt.zone5'       },  -- play-head triangle fill
  { 'colour.arrange.cursorTriBorder',  'palette.base.zone6'      },  -- shared border for both gutter triangles
  { 'colour.arrange.ghostFill',        {0.95, 0.93, 0.80, 0.35}  },  -- create-preview fill
  { 'colour.arrange.ghostBorder',      {0.45, 0.42, 0.30, 0.90}  },  -- create-preview border
  { 'colour.arrange.orphanFill',       {0.50, 0.50, 0.50, 0.35}  },  -- slot-less item, neutral grey
  { 'colour.arrange.orphanFocusFill',  {0.85, 0.85, 0.85, 0.55}  },
  { 'colour.arrange.waveform',         {0.13, 0.13, 0.16, 0.62}  },  -- audio preview ink over the slot fill
  { 'colour.rowNormal',        {'palette.base.zone8',  0   }      },
  { 'colour.rowBeat',          {'palette.base.zone7',  0.4 }      },
  { 'colour.rowBarStart',      {'palette.base.zone6',  0.4 }      },
  { 'colour.editCursor',       hex('#ffff00')                     },  -- one-off yellow
  { 'colour.selection',        {'palette.base.zone10', 0.5 }      },
  { 'colour.scrollHandle',     'colour.text'                      },
  { 'colour.scrollBg',         'colour.bg'                        },
  { 'colour.accent',           'palette.base.zone6'               },
  { 'colour.mute',             'colour.negative'                  },
  { 'colour.solo',             'palette.mark'                     },
  { 'colour.separator',        {'palette.base.zone6',  0.3 }      },
  -- Tracker grid headers: chanHeader rides the blue (alt) ramp; partHeader the
  -- base ramp. Both zone4 so they sit a couple of steps darker than accent.
  { 'colour.tracker.chanHeader', 'palette.alt.zone4'              },
  { 'colour.tracker.partHeader', 'palette.base.zone4'             },
--  { 'colour.tail',             {'palette.steel',      0.3}       },
  { 'colour.tail',             hex('#8caac8')                     },  -- one-off lighter steel
  { 'colour.tailBord',         {'colour.tail', 0.4}               },  -- blend for corner
  { 'colour.ghost',            {'palette.alt.zone5',   0.9 }      },
  { 'colour.ghostNegative',    hex('#da8278', 0.9)                },  -- one-off faded red
  { 'colour.alias',            {'palette.alt.zone5',   0.22}      },  -- materialised-alias cell tint
  { 'colour.aliasFocus',       {'palette.alt.zone5',   0.40}      },  -- transient family-highlight tint (alias-nav cursor)
  -- Region palette: 8 muted hues. tint = pale wash; outline = full-sat border on the active region.
  { 'palette.region.1', hex('#d2a52a') },
  { 'palette.region.2', hex('#d27158') },
  { 'palette.region.3', hex('#c25c8c') },
  { 'palette.region.4', hex('#8a6bb1') },
  { 'palette.region.5', hex('#5489c2') },
  { 'palette.region.6', hex('#4ea99c') },
  { 'palette.region.7', hex('#6ba35a') },
  { 'palette.region.8', hex('#a39342') },
  -- Mirror-region state palette. tint = wash behind a synced/diverged
  -- cell; fade = the same hue dimmed for a non-focused (inactive)
  -- group; outline = the active group's border. Conflicted is loud.
  { 'palette.mirror.synced',     hex('#4ea99c') },  -- calm teal
  { 'palette.mirror.overridden', hex('#d2a52a') },  -- amber: locally diverged, coherent
  { 'palette.mirror.conflicted', hex('#d83a3a') },  -- alarming red
  { 'palette.mirror.local',      hex('#8a6bb1') },  -- violet: instance-only stream
  -- Lane strip (CC/PB/AT envelope visualiser above the tracker grid).
  { 'colour.laneAxis',         {'palette.base.zone5',  0.6 }      },
  { 'colour.laneRowDivider',   {'palette.base.zone5',  0.15}      },
  { 'colour.laneAnchor',       'colour.text'                      },
  { 'colour.laneAnchorActive', 'colour.negative'                  },
  { 'colour.laneEnvelope',     'colour.accent'                    },

  -- Wiring page node tints + port marker colours. Category drives node fill; folder = summing
  -- parent (audio.ins>=1 source). Port colours distinguish audio vs MIDI.
  { 'colour.wiring.node.source',    'palette.positive' },
  { 'colour.wiring.node.master',    'palette.base.zone6' },
  { 'colour.wiring.node.generator', 'palette.alt.zone5'  },
  { 'colour.wiring.node.effect',    'palette.alt2'       },
  { 'colour.wiring.node.folder',    'palette.caution'    },  -- summing folder parent; reused later for the folder bar
  { 'colour.wiring.node.selected',  'palette.mark'       },  -- outline stroke for selected nodes / rubber-band
  { 'colour.wiring.port.audio',     'palette.base.zone2' },
  { 'colour.wiring.port.midi',      'palette.alt.zone5'  },
  { 'colour.wiring.source.label',   'palette.base.zone6' },  -- de-emphasised track-name on a source stub (neutral, not bold)
  { 'colour.wiring.tooltip.bg',     'palette.base.zone9' },  -- matches toolbar; body's dark text reads against it

  -- Chrome roles — toolbar (top band) and statusBar (bottom band).
  -- Toolbar rides the parchment (base) ramp; statusBar the blue (alt) ramp.
  { 'colour.toolbar.bg',           'palette.base.zone9'            },
  { 'colour.toolbar.text',         'palette.base.zone2'            },
  { 'colour.toolbar.button',       'palette.base.zone10',          },
  { 'colour.toolbar.buttonHover',  'palette.base.zone9'            },
  { 'colour.toolbar.buttonActive', 'palette.base.zone8',           },
  { 'colour.toolbar.buttonBorder', {'palette.base.zone6', 0.35 }    },
  { 'colour.toolbar.checkMark',    'palette.base.zone2'            },
  { 'colour.toolbar.popupBg',      'palette.base.zone10'           },
  { 'colour.statusBar.bg',         'palette.alt.zone5'            },
  { 'colour.statusBar.text',       'palette.alt.zone9'            },
  -- Pre-blended `0.5*pale + 0.5*bg`; a literal alias would render translucent over a different parent.
  { 'colour.editor.bg',            hex('#e9e7df')                 },
  { 'laneStrip.rows',      4    },
  { 'laneStrip.visible',   true },
}

for i = 1, 8 do
  local base = 'palette.region.' .. i
  util.add(declarations, { 'colour.region.' .. i .. '.tint',    { base, 0.22 } })
  util.add(declarations, { 'colour.region.' .. i .. '.outline', base })
end

-- overridden is a per-cell deviation overlay painted over the group
-- hue, so it carries a heavier alpha than a plain membership wash to
-- read clearly against it.
for _, st in ipairs{ 'synced', 'overridden', 'conflicted', 'local' } do
  local base  = 'palette.mirror.' .. st
  local alpha = st == 'overridden' and 0.55 or 0.22
  util.add(declarations, { 'colour.mirror.' .. st .. '.tint',    { base, alpha } })
  util.add(declarations, { 'colour.mirror.' .. st .. '.fade',    { base, 0.08 } })
  util.add(declarations, { 'colour.mirror.' .. st .. '.outline', base })
end

local declared, defaults = {}, {}
for _, pair in ipairs(declarations) do
  declared[pair[1]] = true
  if pair[2] ~= nil then defaults[pair[1]] = pair[2] end
end

local function copy(v)
  if type(v) == 'table' then return util.deepClone(v) end
  return v
end

--contract: caches are lazy: first getter call triggers refreshCache; setContext/setTrack refresh eagerly
--contract: no take context means track context is also dropped (track derived from take in setContext)
---------- PRIVATE DATA

local CONFIG_PREFIX = 'ctm_'
local SCRIPT_PATH = debug.getinfo(1,'S').source:match[[^@?(.*[\/])[^\/]-$]]
local CONFIG_GLOBAL_PATH = SCRIPT_PATH .. 'ctm_cfg.txt'

local take      = nil
local track     = nil
local fire  -- installed below, once cm exists

-- External-mutation watcher. REAPER undo / redo (and any third-party
-- script) can rewrite the take + track P_EXT strings without telling
-- us, so cm's cache would stay stale until the next setContext.
-- pollUndo() compares the project state count once a frame; on a tick
-- it re-reads the bound take + track P_EXT and refreshes if either
-- differs from what we last wrote. Project + global tiers live outside
-- REAPER's undo system (SetProjExtState / disk file) and stay
-- unreversed -- a known gap, not a bug.
local lastStateCount = -1
local lastTakeRaw    = ''
local lastTrackRaw   = ''

local cache = {
  global    = nil,
  project   = nil,
  track     = nil,
  take      = nil,
  transient = nil,
}

local levels = { 'global', 'project', 'track', 'take', 'transient' }

local levelSet = {}
for _, l in ipairs(levels) do levelSet[l] = true end

---------- STORAGE BACKENDS

-- Tolerant on load: stale keys from a rename shouldn't error.
local function pruneUnknown(tbl)
  for k in pairs(tbl) do
    if not declared[k] then tbl[k] = nil end
  end
  return tbl
end

--contract: parse failures (bad text or non-table result) fall through to {}; never raises
local function parse(text)
  if not text or text == '' then return {} end
  local ok, result = pcall(util.unserialise, text)
  if ok and type(result) == 'table' then return pruneUnknown(result) end
  return {}
end

local function loadGlobal()
  local f = io.open(CONFIG_GLOBAL_PATH, 'r')
  if not f then return {} end
  local content = f:read('*a')
  f:close()
  return parse(content)
end

local function saveGlobal(tbl)
  local f = io.open(CONFIG_GLOBAL_PATH, 'w')
  if not f then
    print('Error! Could not write global config to ' .. CONFIG_GLOBAL_PATH)
    return
  end
  f:write(util.serialise(tbl))
  f:close()
end

local function loadProject()
  local ok, val = reaper.GetProjExtState(0, 'rdm', 'config')
  return ok and parse(val)
end

local function saveProject(tbl)
  reaper.SetProjExtState(0, 'rdm', 'config', util.serialise(tbl))
end

local function loadTrack()
  if not track then return {} end
  local ok, val = reaper.GetSetMediaTrackInfo_String(
    track, 'P_EXT:' .. CONFIG_PREFIX .. 'config', '', false)
  return ok and parse(val)
end

local function saveTrack(tbl)
  if not track then
    print('Error! No track context for config storage')
    return
  end
  lastTrackRaw = util.serialise(tbl)
  reaper.GetSetMediaTrackInfo_String(
    track, 'P_EXT:' .. CONFIG_PREFIX .. 'config', lastTrackRaw, true)
end

local function loadTake()
  if not take then return {} end
  local ok, val = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_config', '', false)
  return ok and parse(val)
end

local function saveTake(tbl)
  -- No bound take: the dormant seam after bindTake(nil). Take-tier
  -- config is wholly derived state (usedSwings/extraColumns/groups,
  -- recomputed on the next take-changed rebuild); a real lost user
  -- edit is impossible since editing requires a bound take. So a
  -- no-take take-tier write is always benign -- drop it silently.
  if not take then return end
  lastTakeRaw = util.serialise(tbl)
  reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_config', lastTakeRaw, true)
end

local loaders = {
  global    = loadGlobal,
  project   = loadProject,
  track     = loadTrack,
  take      = loadTake,
  transient = function() return {} end,
}

local savers = {
  global    = saveGlobal,
  project   = saveProject,
  track     = saveTrack,
  take      = saveTake,
  transient = function() end,
}

local function readTakeRaw()
  if not take then return '' end
  local _, val = reaper.GetSetMediaItemTakeInfo_String(
    take, 'P_EXT:ctm_config', '', false)
  return val or ''
end

local function readTrackRaw()
  if not track then return '' end
  local _, val = reaper.GetSetMediaTrackInfo_String(
    track, 'P_EXT:' .. CONFIG_PREFIX .. 'config', '', false)
  return val or ''
end

-- Called after every context-changing path so pollUndo's next compare
-- is against the just-bound state, not whatever the previous take held.
local function snapshotBaseline()
  lastStateCount = reaper.GetProjectStateChangeCount
                   and reaper.GetProjectStateChangeCount(0) or -1
  lastTakeRaw    = readTakeRaw()
  lastTrackRaw   = readTrackRaw()
end

---------- CACHE MANAGEMENT

local function refreshCache()
  for _, level in ipairs(levels) do
    cache[level] = loaders[level]()
  end
end

local function ensureCache()
  if not cache.global then refreshCache() end
end

--contract: starts from schema defaults, then overlays each level's cache in `levels` order so later (more-specific) tiers win
local function mergedTable()
  ensureCache()
  local merged = {}
  for k, v in pairs(defaults) do merged[k] = v end
  for _, level in ipairs(levels) do
    if cache[level] then
      util.assign(merged, cache[level])
    end
  end
  return merged
end

local function checkLevel(level)
  if not levelSet[level] then
    error('Unknown config level: ' .. tostring(level), 3)
  end
end

local function checkKey(key)
  if not declared[key] then
    error('Unknown config key: ' .. tostring(key), 3)
  end
end

---------- PUBLIC INTERFACE

local cm = {}
fire = util.installHooks(cm)

--contract: setContext(nil) clears both take and track; setContext(take) derives track via GetMediaItemTrack
--contract: refreshes all four persisted caches (transient resets to {}) and fires configChanged with empty payload
function cm:setContext(newTake)
  take = newTake
  track = nil

  if take then
    local item = reaper.GetMediaItemTake_Item(take)
    if item then
      track = reaper.GetMediaItemTrack(item)
    end
  end

  refreshCache()
  snapshotBaseline()
  --emits: configChanged -- configChangedPayload.reload
  fire('configChanged', {})
end

function cm:clearTake()
  take = nil
  cache.take = {}
  snapshotBaseline()
  --emits: configChanged -- configChangedPayload.reload
  fire('configChanged', {})
end

--contract: bound take pointer; nil when context is cleared (take/track tiers resolve off empty)
function cm:boundTake() return take end

function cm:setTrack(newTrack)
  track = newTrack
  cache.track = loaders.track()
  snapshotBaseline()
  --emits: configChanged -- configChangedPayload.reload
  fire('configChanged', {})
end

--invariant: poll REAPER's project state count once per frame; on a tick, re-read the bound take + track P_EXT strings and refresh the cache + fire reload if either differs from what cm last wrote. Catches REAPER undo / redo, which rewinds P_EXT without notifying us. Project + global tiers live outside REAPER's undo and stay unreversed.
--contract: no-op when reaper.GetProjectStateChangeCount is absent (test harness without state-count fake); cheap poll otherwise -- one int compare per frame, two string reads + compares only on a state-count tick
--contract: dead take/track ptrs are dropped before any P_EXT read; tick() drives propagation
--emits: configChanged -- configChangedPayload.reload (only when an external diff is observed)
function cm:pollUndo()
  if not reaper.GetProjectStateChangeCount then return end
  local count = reaper.GetProjectStateChangeCount(0)
  if count == lastStateCount then return end
  lastStateCount = count
  if take and reaper.ValidatePtr2
     and not reaper.ValidatePtr2(0, take, 'MediaItem_Take*') then
    take, lastTakeRaw = nil, ''
  end
  if track and reaper.ValidatePtr2
     and not reaper.ValidatePtr2(0, track, 'MediaTrack*') then
    track, lastTrackRaw = nil, ''
  end
  local changed = false
  if take then
    local raw = readTakeRaw()
    if raw ~= lastTakeRaw then
      lastTakeRaw = raw
      cache.take  = loaders.take() or {}
      changed = true
    end
  end
  if track then
    local raw = readTrackRaw()
    if raw ~= lastTrackRaw then
      lastTrackRaw = raw
      cache.track  = loaders.track() or {}
      changed = true
    end
  end
  if changed then fire('configChanged', {}) end
end

----- Reading

-- Per-subkey union of a single key's tables across defaults→tiers,
-- most-specific tier wins on name collision. Non-table contributions
-- (including a scalar default) are skipped, so the result is always
-- a table.
local function mergedKey(key)
  ensureCache()
  local out = {}
  local function overlay(src)
    if type(src) == 'table' then
      for k, v in pairs(src) do out[k] = v end
    end
  end
  overlay(defaults[key])
  for _, level in ipairs(levels) do
    if cache[level] then overlay(cache[level][key]) end
  end
  return out
end

--contract: returns deep copy of merged value (defaults overlaid by all five tiers); raises on unknown key
--contract: opts.mergeTiers=true switches to per-subkey union across defaults+tiers (most-specific wins on collision) — only meaningful for table-valued keys
function cm:get(key, opts)
  checkKey(key)
  if opts and opts.mergeTiers then return copy(mergedKey(key)) end
  return copy(mergedTable()[key])
end

--contract: reads single tier only (no merge, no defaults); key omitted returns whole-cache deep clone; raises on unknown level/key
function cm:getAt(level, key)
  checkLevel(level)
  ensureCache()
  local tbl = cache[level] or {}
  if key ~= nil then
    checkKey(key)
    return copy(tbl[key])
  end
  return util.deepClone(tbl)
end

--contract: returns the raw cm-P_EXT blob string on otherTrack (or nil/empty if unset). Stable byte-for-byte across reads — callers can compare against a previously-captured raw to detect external rewrites (REAPER undo/redo), where re-serialising a parsed copy would diverge due to Lua pairs ordering.
function cm:readTrackRaw(otherTrack)
  if not otherTrack then return nil end
  local _, raw = reaper.GetSetMediaTrackInfo_String(
    otherTrack, 'P_EXT:' .. CONFIG_PREFIX .. 'config', '', false)
  return raw
end

--contract: bypasses cache and active context; reads otherTrack's P_EXT directly without firing configChanged or disturbing the bound track's cache
function cm:readTrackKey(otherTrack, key)
  checkKey(key)
  if not otherTrack then return nil end
  local ok, val = reaper.GetSetMediaTrackInfo_String(
    otherTrack, 'P_EXT:' .. CONFIG_PREFIX .. 'config', '', false)
  if not ok or not val or val == '' then return nil end
  local parsed = parse(val)
  return copy(parsed[key])
end

--contract: bypasses cache and active context; updates a single key on otherTrack's P_EXT (read-modify-write the parsed table). Fires targeted configChanged with .track set so subscribers of the bound track can ignore foreign-track edits.
function cm:writeTrackKey(otherTrack, key, value)
  checkKey(key)
  if not otherTrack then return end
  local ok, val = reaper.GetSetMediaTrackInfo_String(
    otherTrack, 'P_EXT:' .. CONFIG_PREFIX .. 'config', '', false)
  local parsed = (ok and val and val ~= '') and parse(val) or {}
  if value == util.REMOVE then parsed[key] = nil
  else                         parsed[key] = copy(value) end
  reaper.GetSetMediaTrackInfo_String(
    otherTrack, 'P_EXT:' .. CONFIG_PREFIX .. 'config', util.serialise(parsed), true)
  -- If the foreign track happens to be the bound one, refresh its cache so the next get sees the write.
  if otherTrack == track then cache.track = loaders.track() end
  --emits: configChanged -- configChangedPayload.targeted (with .track for cross-track writes)
  fire('configChanged', { key = key, level = 'track', track = otherTrack })
end

--contract: bypasses cache and active context; reads otherTake's P_EXT directly without firing configChanged or disturbing the bound take's cache
function cm:readTakeKey(otherTake, key)
  checkKey(key)
  if not otherTake then return nil end
  local ok, val = reaper.GetSetMediaItemTakeInfo_String(
    otherTake, 'P_EXT:' .. CONFIG_PREFIX .. 'config', '', false)
  if not ok or not val or val == '' then return nil end
  local parsed = parse(val)
  return copy(parsed[key])
end

--contract: bypasses cache and active context; updates a single key on otherTake's P_EXT (read-modify-write). util.REMOVE clears. No signal fired — read/write helpers are silent seams for foreign-take state.
function cm:writeTakeKey(otherTake, key, value)
  checkKey(key)
  if not otherTake then return end
  local ok, val = reaper.GetSetMediaItemTakeInfo_String(
    otherTake, 'P_EXT:' .. CONFIG_PREFIX .. 'config', '', false)
  local parsed = (ok and val and val ~= '') and parse(val) or {}
  if value == util.REMOVE then parsed[key] = nil
  else                         parsed[key] = copy(value) end
  reaper.GetSetMediaItemTakeInfo_String(
    otherTake, 'P_EXT:' .. CONFIG_PREFIX .. 'config', util.serialise(parsed), true)
  if otherTake == take then cache.take = loaders.take() end
end

--contract: walks tiers most-specific to least, returning the first level whose cache defines the key (matches merge resolution); nil if no tier sets it
function cm:getLevel(key)
  checkKey(key)
  ensureCache()
  for i = #levels, 1, -1 do
    local level = levels[i]
    if cache[level] and cache[level][key] ~= nil then
      return level
    end
  end
  return
end

----- Writing

--contract: deep-copies value into the target tier's cache, persists that tier, fires targeted configChanged
function cm:set(level, key, value)
  checkLevel(level)
  checkKey(key)
  ensureCache()

  cache[level] = cache[level] or {}
  cache[level][key] = copy(value)
  savers[level](cache[level])
  --emits: configChanged -- configChangedPayload.targeted
  fire('configChanged', { key = key, level = level })
end

--contract: removes key from the named tier only; no-op (and no signal) if that tier's cache is unloaded
function cm:remove(level, key)
  checkLevel(level)
  checkKey(key)
  ensureCache()

  if cache[level] then
    cache[level][key] = nil
    savers[level](cache[level])
    --emits: configChanged -- configChangedPayload.targeted
    fire('configChanged', { key = key, level = level })
  end
end

--contract: validates every key in updates before any write (all-or-nothing); util.REMOVE sentinel deletes that key; fires keyless configChanged
function cm:assign(level, updates)
  if type(updates) ~= 'table' then return end
  checkLevel(level)
  for k in pairs(updates) do checkKey(k) end
  ensureCache()

  cache[level] = cache[level] or {}
  for k, v in pairs(updates) do
    if v == util.REMOVE then cache[level][k] = nil
    else                     cache[level][k] = copy(v) end
  end
  savers[level](cache[level])
  --emits: configChanged -- configChangedPayload.bulk
  fire('configChanged', { level = level })
end

return cm

