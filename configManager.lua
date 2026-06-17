-- See docs/configManager.md for the model.

--invariant: sole truth for valid keys; in-code access raises on unknowns, loaded unknowns pruned
--invariant: owns cache: reads deep-clone out, writes deep-clone in; callers never alias cm state
--invariant: 5-tier merge: global→project→track→take→transient; most-specific wins, else defaults
--invariant: transient tier never persists (saver is a no-op) and resets to {} on every refreshCache
--invariant: declarations is ordered array-of-pairs; nil-default keys coexist with non-nil defaults
--invariant: track/take tiers require REAPER context; without it loaders return {}, savers error
--shape: configChangedPayload.targeted = { key = string, level = string }   -- set / remove
--shape: configChangedPayload.bulk     = { level = string }                  -- assign (keyless)
--shape: configChangedPayload.reload   = {}                                  -- setContext / clearTake / setTrack
local util   = require 'util'
local tuning = require 'tuning'

local deps = ...
local ps   = assert(deps and deps.ps, 'configManager requires a pextStore dep { ps = ... }')

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
  -- temper is a view-only lens (never realised). A pick writes all three tiers: the
  -- take freezes that take's choice, track/project carry the default for unpicked takes.
  { 'temper',          '12EDO'    },

  -- null-defaulted (declared, no initial value)
  { 'sampleBrowserRoot', nil },
  -- Project-tier breadcrumb so sampler save-migration survives a
  -- save that happens while Continuum is closed. See docs/sampleManager.md.
  { 'lastProjectPath',   nil },

  -- table-valued
  -- defaultSwing: seed for a take's swing map on first bind; never read at realisation.
  { 'defaultSwing',    { global = 'identity' } },
  -- Default is the system preset library; global (user-saved) and project (local) tiers overlay per-name.
  -- Read with mergeTiers=true to get the union.
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
  -- Built-in temper catalogue (EDO presets); the personal global library seeds from it.
  { 'tempers',         util.deepClone(tuning.presets) },
  -- Arrange-page grid density preference (persisted). Cursor/scroll stay in arrangeView module-locals.
  -- Typical values: 4, 8, 16 beats per row (one to four bars per row in 4/4).
  { 'arrangeBeatPerRow', 4 },
  -- Arrange viewport follows the play head while the transport runs
  -- (boundary-scroll). Toolbar checkbox / Super+F; global tier.
  { 'arrangeFollowPlay', false },

  -- User keybinding overrides, global tier. keyBindings[scopeName][cmd] = { token, ... };
  -- overlays code-default keymaps at startup. Tokens are hand-editable ("Ctrl+Z"). See commandManager.
  { 'keyBindings',     {} },

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
  { 'colour.band.fill',        {0.55, 0.70, 0.95, 0.22}           },  -- marquee/lasso fill (shared)
  { 'colour.band.border',      {0.45, 0.60, 0.90, 0.85}           },  -- marquee/lasso border (shared)
  -- Arrange-page fixed colours: cursor, blocked-drag, ghost, and orphan fills. The 62 slot hues stay
  -- computed (golden-ratio rotation) and are not declared here.
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
  { 'colour.arrange.midiNoteOn',       'palette.base.zone3'      },  -- note-on cap: low-zone primary (arrangeRender)
  { 'colour.arrange.midiNoteBody',     'palette.base.zone4'      },  -- note body: one zone higher
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
  -- Mirror-region state palette. tint = cell wash; fade = inactive-group dim; outline = active border.
  -- Conflicted is loud.
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
  -- F1 cheat-sheet overlay (help.lua): blue panel; chips + description ride the
  -- base ramp so the dark shortcut glyphs read on light keycaps.
  { 'colour.help.box',    'colour.statusBar.bg' },
  { 'colour.help.border', 'colour.text'         },
  { 'colour.help.title',  'colour.text'         },
  { 'colour.help.key',    'colour.text'         },  -- shortcut glyphs + the '/' separator
  { 'colour.help.desc',   'palette.base.zone9'  },  -- command description
  { 'colour.help.chip',   'palette.base.zone8'  },  -- keycap fill (alpha at draw)
  { 'colour.help.remove', 'palette.alert'       },  -- ✕ remove-binding glyph (red)
  { 'colour.help.add',    'palette.positive'    },  -- + add-binding glyph (green)
  { 'colour.help.tag',       'palette.base.zone9'  },  -- edit-tag box fill (one zone above chips, full alpha)
  { 'colour.help.tagBorder', 'colour.help.border'  },  -- edit-tag 1px crisp border
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

-- overridden is a deviation overlay over the group hue; heavier alpha so it reads against the wash.
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

--contract: caches lazy: first getter triggers refreshCache; setContext/setTrack refresh eagerly
--contract: no take context drops track too (track derived from take in setContext)
---------- PRIVATE DATA

-- Storage, bound context, and the undo watcher all live in pextStore now;
-- cm is the schema face that prunes, merges tiers, and validates keys.
local fire  -- installed below, once cm exists

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

local function asTable(v) return type(v) == 'table' and v or {} end

-- Each tier is a pextStore blob (take/track→'ctm_config', project→'config', global→disk).
-- Engine decodes; cm prunes unknown keys so a renamed key in a stale file can't raise.
local loaders = {
  global    = function() return pruneUnknown(asTable(ps:get('global',  'config'))) end,
  project   = function() return pruneUnknown(asTable(ps:get('project', 'config'))) end,
  track     = function() return pruneUnknown(asTable(ps:get('track',   'ctm_config'))) end,
  take      = function() return pruneUnknown(asTable(ps:get('take',    'ctm_config'))) end,
  transient = function() return {} end,
}

local savers = {
  global    = function(tbl) ps:assign('global',  'config', tbl) end,
  project   = function(tbl) ps:assign('project', 'config', tbl) end,
  track     = function(tbl)
    if not ps:boundTrack() then print('Error! No track context for config storage'); return end
    ps:assign('track', 'ctm_config', tbl)
  end,
  -- No bound take: take-tier config is derived state (recomputed on next rebuild), so a write
  -- here can't lose real user edits — drop silently.
  take      = function(tbl) if ps:boundTake() then ps:assign('take', 'ctm_config', tbl) end end,
  transient = function() end,
}

---------- CACHE MANAGEMENT

local function refreshCache()
  for _, level in ipairs(levels) do
    cache[level] = loaders[level]()
  end
end

local function ensureCache()
  if not cache.global then refreshCache() end
end

--contract: overlays levels[] in order onto schema defaults; later (more-specific) tiers win
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

-- cm's two P_EXT tiers as one watcher group: the engine fires this callback
-- once per undo tick that rewinds either blob, and we reload the diverged tiers.
ps:watch({ { scope = 'take', slot = 'ctm_config' }, { scope = 'track', slot = 'ctm_config' } },
  function(diverged)
    for _, blob in ipairs(diverged) do cache[blob.scope] = loaders[blob.scope]() end
    --emits: configChanged -- configChangedPayload.reload (external diff observed)
    fire('configChanged', {})
  end)

--contract: setContext(nil) clears take+track; setContext(take) derives track via GetMediaItemTrack
--contract: refreshes all persisted caches (transient resets to {}) and fires configChanged {}
function cm:setContext(newTake)
  ps:setTake(newTake)
  refreshCache()
  --emits: configChanged -- configChangedPayload.reload
  fire('configChanged', {})
end

function cm:clearTake()
  ps:clearTake()
  cache.take = {}
  --emits: configChanged -- configChangedPayload.reload
  fire('configChanged', {})
end

--contract: bound take pointer; nil when context is cleared (take/track tiers resolve off empty)
function cm:boundTake() return ps:boundTake() end

function cm:setTrack(newTrack)
  ps:setTrack(newTrack)
  cache.track = loaders.track()
  --emits: configChanged -- configChangedPayload.reload
  fire('configChanged', {})
end

--contract: delegates to the engine watcher; cm's watch group reloads tiers and fires configChanged
function cm:pollUndo() ps:pollUndo() end

----- Reading

-- Per-subkey union of a single key's tables across defaults→tiers; most-specific tier wins.
-- Non-table contributions are skipped, so the result is always a table.
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

--contract: returns deep-copy of merged value (defaults + all tiers); raises on unknown key
--contract: opts.mergeTiers=true → per-subkey union across defaults+tiers; table-valued keys only
function cm:get(key, opts)
  checkKey(key)
  if opts and opts.mergeTiers then return copy(mergedKey(key)) end
  return copy(mergedTable()[key])
end

--contract: reads single tier only (no merge, no defaults); key nil → whole-cache clone
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

--contract: seeds global tier for key from its default catalogue when empty; excluded names omitted
function cm:seedGlobalFromDefault(key, exclude)
  checkKey(key)
  ensureCache()
  if next(cm:getAt('global', key) or {}) ~= nil then return end
  local seed = copy(defaults[key]) or {}
  if exclude then for name in pairs(exclude) do seed[name] = nil end end
  if next(seed) == nil then return end
  cm:set('global', key, seed)
end

----- Writing

--contract: deep-copies value into tier cache, persists, fires targeted configChanged
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

--contract: removes key from named tier; no-op (no signal) if that tier's cache is unloaded
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

--contract: validates all keys before any write (all-or-nothing); REMOVE deletes; fires signal
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

