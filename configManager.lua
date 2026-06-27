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
  { 'pbRange',          2     },
  { 'rowPerBeat',       4     },
  { 'overlapOffset',    1/16  },
  { 'defaultVelocity',  100   },
  { 'currentOctave',    4     },
  { 'currentSample',    0     },
  { 'advanceBy',        1     },
  { 'arrangeAdvanceBy', 1     },
  { 'arrangeBeatPerRow', 4    },
  -- New-take dialog length (beats); persisted at project tier, shared by tracker + arrange.
  { 'newTakeBeats',      4    },
  { 'laneStrip.rows',      4    },
  -- boolean
  { 'polyAftertouch',   true  },
  { 'trackerMode',      false },
  { 'previewInPlace',   false },
  { 'advanceOnLoad',    true  },
  { 'arrangeFollowPlay', false },
  { 'laneStrip.visible',   true },

  -- string choice
  { 'noteLayout',       'colemak' },
  { 'temper',           '12EDO'    },

  { 'sampleBrowserRoot', nil },
  -- Project-tier breadcrumb so sampler save-migration survives a
  -- save that happens while Continuum is closed. See docs/sampleManager.md.
  { 'lastProjectPath',   nil },

  -- Tracker selection, decoupled from the arrange cursor: the current track
  -- (project tier) and that track's last-viewed slot (track tier = per-track).
  { 'trackerTrack',      nil },   -- track GUID
  { 'trackerSlot',       nil },   -- slotIdx

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
    } },
  -- Built-in temper catalogue (EDO presets); the personal global library seeds from it.
  { 'tempers',         util.deepClone(tuning.presets) },

  -- User keybinding overrides, global tier. keyBindings[scopeName][cmd] = { token, ... };
  -- overlays code-default keymaps at startup. Tokens are hand-editable ("Ctrl+Z"). See commandManager.
  { 'keyBindings',     {} },

  -- Palette atoms — role-named swatches the colour editor edits; base/alt are
  -- tonal ramps (zoneN at lightness N/10, ends pure black/white).
  { 'palette.base.zone0',  hex('#000000') },  -- base: warm neutral
  { 'palette.base.zone1',  hex('#1e1e15') },
  { 'palette.base.zone2',  hex('#3c3b2a') },
  { 'palette.base.zone3',  hex('#575542') },
  { 'palette.base.zone4',  hex('#716d5b') },
  { 'palette.base.zone5',  hex('#888477') },
  { 'palette.base.zone6',  hex('#a9a389') },
  { 'palette.base.zone7',  hex('#bebba7') },
  { 'palette.base.zone8',  hex('#d5d1c3') },
  { 'palette.base.zone9',  hex('#eae8e1') },
  { 'palette.base.zone10', hex('#faf8f1') },
  { 'palette.alt.zone0',   hex('#000000') },  -- alt: cool blue, OKLCh hue 251° (zone5-anchored), chroma peaks mid
  { 'palette.alt.zone1',   hex('#0b1826') },
  { 'palette.alt.zone2',   hex('#1d3045') },
  { 'palette.alt.zone3',   hex('#324963') },
  { 'palette.alt.zone4',   hex('#496380') },
  { 'palette.alt.zone5',   hex('#647e9b') },
  { 'palette.alt.zone6',   hex('#7a93ae') },
  { 'palette.alt.zone7',   hex('#97acc4') },
  { 'palette.alt.zone8',   hex('#b7c7d8') },
  { 'palette.alt.zone9',   hex('#dee5ee') },
  { 'palette.alt.zone10',  hex('#ffffff') },
  -- Accents — the eight solarized hues plus a salmon (warm-pink hue, lifted
  -- off neutral in both lightness and chroma). Only chromatic atoms.
  { 'palette.yellow',  hex('#b58900') },
  { 'palette.orange',  hex('#cb4b16') },
  { 'palette.red',     hex('#dc322f') },
  { 'palette.magenta', hex('#d33682') },
  { 'palette.violet',  hex('#6c71c4') },
  { 'palette.blue',    hex('#268bd2') },
  { 'palette.cyan',    hex('#2aa198') },
  { 'palette.green',   hex('#859900') },
  { 'palette.salmon',  hex('#c78a7d') },

  ----- global (shared across pages)
  { 'colour.global.bg',          'base.zone8'        },
  { 'colour.global.text',        'base.zone2'        },
  { 'colour.global.rowBeat',     {'base.zone7', 0.4} },
  { 'colour.global.tail',        'alt.zone7'         },  -- loop bracket / corner (was one-off steel)
  { 'colour.global.tailBord',    {'colour.global.tail', 0.4} },  -- blend for corner
  { 'colour.global.separator',   {'base.zone6', 0.3} },
  { 'colour.global.band.fill',   {'blue', 0.22}      },  -- marquee/lasso fill
  { 'colour.global.band.border', {'blue', 0.85}      },  -- marquee/lasso border
  { 'colour.global.error',       'red'               },  -- inline validation-error text (swing/temper editors)

  ----- tracker
  { 'colour.tracker.offGrid',     'green'      },
  { 'colour.tracker.overflow',    'orange'     },
  { 'colour.tracker.negative',    'red'        },
  { 'colour.tracker.inactive',    'base.zone5' },
  { 'colour.tracker.shadowed',    'colour.tracker.inactive' },
  { 'colour.tracker.cursor',      'alt.zone2'  },
  { 'colour.tracker.cursorText',  'alt.zone8'  },
  { 'colour.tracker.rowBarStart', {'base.zone6', 0.4} },
  { 'colour.tracker.selection',   {'base.zone10', 0.5} },
  { 'colour.tracker.accent',      'base.zone6' },
  { 'colour.tracker.mute',        'colour.tracker.negative' },
  { 'colour.tracker.solo',        'yellow'     },
  { 'colour.tracker.chanHeader',  'alt.zone4'  },
  { 'colour.tracker.partHeader',  'base.zone4' },
  { 'colour.tracker.ghost',         {'alt.zone5', 0.9} },
  { 'colour.tracker.ghostNegative', {'salmon',    0.9} },  -- faded warm ghost for negative delay
  { 'colour.tracker.swing.previewBorder', 'base.zone5' },  -- swing editor preview-pane frame
  -- Lane strip (CC/PB/AT envelope visualiser above the tracker grid).
  { 'colour.tracker.laneAxis',         {'base.zone5', 0.6 } },
  { 'colour.tracker.laneRowDivider',   {'base.zone5', 0.15} },
  { 'colour.tracker.laneAnchor',       'colour.global.text'      },
  { 'colour.tracker.laneAnchorActive', 'colour.tracker.negative' },
  { 'colour.tracker.laneEnvelope',     'colour.tracker.accent'   },

  ----- arrange
  { 'colour.arrange.cursorOn',         'base.zone2'           },
  { 'colour.arrange.cursorOff',        'base.zone6'           },
  { 'colour.arrange.itemBorder',       'base.zone5'           },  -- solid neutral box outline (one zone below cursorOff)
  { 'colour.arrange.phrase',           {'colour.global.rowBeat', 1.0} },  -- bar tint at full alpha
  { 'colour.arrange.blockedBorder',    {'red', 0.95}          },  -- drag would overlap a neighbour
  { 'colour.arrange.editCursor',       'base.zone2'           },  -- edit-cursor triangle fill
  { 'colour.arrange.playHead',         'alt.zone5'            },  -- play-head triangle fill
  { 'colour.arrange.cursorTriBorder',  'base.zone6'           },  -- shared border for both gutter triangles
  { 'colour.arrange.ghostFill',        {'base.zone9', 0.35}   },  -- create-preview fill
  { 'colour.arrange.ghostBorder',      {'base.zone3', 0.90}   },  -- create-preview border
  { 'colour.arrange.orphanFill',       {'base.zone5', 0.35}   },  -- slot-less item, neutral
  { 'colour.arrange.orphanFocusFill',  {'base.zone8', 0.55}   },
  { 'colour.arrange.waveform',         {'base.zone2', 0.62}   },  -- audio preview ink over the slot fill
  { 'colour.arrange.midiNoteOn',       'base.zone3'           },  -- note-on cap: low-zone primary (arrangeRender)
  { 'colour.arrange.midiNoteBody',     'base.zone4'           },  -- note body: one zone higher

  ----- sampler (waveform strip in the sample browser)
  { 'colour.sampler.waveBg',   'base.zone1'   },  -- strip background
  { 'colour.sampler.wave',     'base.zone8'   },  -- peak envelope fill
  { 'colour.sampler.waveMid',  'base.zone5'   },  -- silence centre line
  { 'colour.sampler.selFill',  {'blue', 0.13} },  -- selection range wash
  { 'colour.sampler.selStart', 'green'        },  -- selection start marker
  { 'colour.sampler.selEnd',   'orange'       },  -- selection end marker

  -- Wiring page node tints + port marker colours. Category drives node fill; folder = summing
  -- parent (audio.ins>=1 source). Port colours distinguish audio vs MIDI.
  { 'colour.wiring.node.source',    'green'      },
  { 'colour.wiring.node.master',    'base.zone7' },
  { 'colour.wiring.node.generator', 'alt.zone6'  },
  { 'colour.wiring.node.effect',    'salmon'     },
  { 'colour.wiring.node.folder',    'orange'     },  -- summing folder parent; reused later for the folder bar
  { 'colour.wiring.node.selected',  'yellow'     },  -- outline stroke for selected nodes / rubber-band
  { 'colour.wiring.port.audio',     'base.zone2' },
  { 'colour.wiring.port.midi',      'alt.zone5'  },
  { 'colour.wiring.source.label',   'base.zone6' },  -- de-emphasised track-name on a source stub (neutral, not bold)
  { 'colour.wiring.tooltip.bg',     'base.zone9' },  -- matches toolbar; body's dark text reads against it
  { 'colour.wiring.badge.bg',       {'alt.zone9', 0.25} },  -- idle M/B chip: recessed dark, reads on any node tint
  { 'colour.wiring.badge.text',     'base.zone2'          },
  { 'colour.wiring.badge.muted',    'red'                 },  -- active output-mute
  { 'colour.wiring.badge.bypassed', 'alt.zone6'           },  -- active bypass (REAPER-native enable)

  -- Chrome roles — toolbar (top band) and statusBar (bottom band).
  -- Toolbar rides the parchment (base) ramp; statusBar the blue (alt) ramp.
  { 'colour.chrome.toolbar.bg',           'base.zone9'         },
  { 'colour.chrome.toolbar.text',         'base.zone2'         },
  { 'colour.chrome.toolbar.button',       'base.zone10'        },
  { 'colour.chrome.toolbar.buttonActive', 'base.zone8'         },
  { 'colour.chrome.toolbar.buttonBorder', {'base.zone6', 0.35} },
  { 'colour.chrome.toolbar.checkMark',    'base.zone2'         },
  { 'colour.chrome.toolbar.sliderGrab',       'base.zone8'     },  -- slider handle on the chromed track
  { 'colour.chrome.toolbar.sliderGrabActive', 'base.zone7'     },  -- handle while dragging
  { 'colour.chrome.toolbar.meter.bg',    {'base.zone8', 0.6} },  -- master meter trough
  { 'colour.chrome.toolbar.meter.fill',  'green'              },  -- peak fill ≤ 0 dB
  { 'colour.chrome.toolbar.meter.hot',   'red'                },  -- peak fill > 0 dB
  { 'colour.chrome.toolbar.meter.peak',  'green'         },  -- per-channel peak-hold tick
  { 'colour.chrome.toolbar.meter.loud',  'base.zone5'               },  -- mono loudness reference line
  { 'colour.chrome.toolbar.fader.track', 'base.zone6'         },  -- master fader groove
  { 'colour.chrome.toolbar.meter.border','base.zone6'         },  -- meter frame / detent tick / readout box
  { 'colour.chrome.toolbar.popupBg',      'base.zone10'        },
  { 'colour.chrome.toolbar.textSelection', 'alt.zone8'         },  -- text-selection highlight (Col_TextSelectedBg)
  { 'colour.chrome.toolbar.selectedRow',   'alt.zone8'         },  -- Selectable/list-row highlight (Col_Header family)
  { 'colour.chrome.statusBar.bg',         'alt.zone5'          },
  { 'colour.chrome.statusBar.text',       'alt.zone9'          },
  { 'colour.chrome.modal.titleBg',        'alt.zone6'          },  -- modalHost title bar: lift off editor.bg
  -- F1 cheat-sheet overlay (help.lua): blue panel; chips + description ride the
  -- base ramp so the dark shortcut glyphs read on light keycaps.
  { 'colour.chrome.help.box',    'colour.chrome.statusBar.bg' },
  { 'colour.chrome.help.border', 'colour.global.text'         },
  { 'colour.chrome.help.title',  'colour.global.text'         },
  { 'colour.chrome.help.key',    'colour.global.text'         },  -- shortcut glyphs + the '/' separator
  { 'colour.chrome.help.desc',   'base.zone9'                 },  -- command description
  { 'colour.chrome.help.chip',   'base.zone8'                 },  -- keycap fill (alpha at draw)
  { 'colour.chrome.help.remove', 'red'                        },  -- ✕ remove-binding glyph (red)
  { 'colour.chrome.help.add',    'green'                      },  -- + add-binding glyph (green)
  { 'colour.chrome.help.dim',    {'base.zone0', 0.47}         },  -- scrim behind the cheat-sheet overlay
  { 'colour.chrome.help.tag',       'base.zone9'                 },  -- edit-tag box fill (one zone above chips, full alpha)
  { 'colour.chrome.help.tagBorder', 'colour.chrome.help.border' },  -- edit-tag 1px crisp border
  { 'colour.chrome.editor.bg',            'base.zone9' },  -- editor body (snapped from #e9e7df)
  -- Pane-selector pills on the editor body: editor.button a zone below toolbar.button.
  { 'colour.chrome.editor.button',        'base.zone9' },
  { 'colour.chrome.editor.buttonActive',  'base.zone7' },
  { 'colour.chrome.scrollHandle', 'colour.global.text' },
  { 'colour.chrome.scrollBg',     'colour.global.bg'   },
}

-- region.N reuse the eight accents (red last; the old 8th hue was olive).
local ACCENTS = { 'yellow', 'orange', 'magenta', 'violet', 'blue', 'cyan', 'green', 'red' }
for i, hue in ipairs(ACCENTS) do
  util.add(declarations, { 'colour.tracker.region.' .. i .. '.tint',    { hue, 0.22 } })
  util.add(declarations, { 'colour.tracker.region.' .. i .. '.outline', hue })
end

-- overridden is a deviation overlay over the group hue; heavier alpha so it reads against the wash.
local MIRROR = { synced = 'cyan', overridden = 'yellow', conflicted = 'red', ['local'] = 'violet' }
for _, st in ipairs{ 'synced', 'overridden', 'conflicted', 'local' } do
  local hue   = MIRROR[st]
  local alpha = st == 'overridden' and 0.55 or 0.22
  util.add(declarations, { 'colour.tracker.mirror.' .. st .. '.tint',    { hue, alpha } })
  util.add(declarations, { 'colour.tracker.mirror.' .. st .. '.outline', hue })
end

-- Colour contract (see docs/configManager.md § Colour): colour.* roles are refs, not bare
-- RGBA. Bare refs get 'palette.' prepended; page roles resolve via palette.*/global.*/own.
local COLOUR_NS = { global = true, tracker = true, sampler = true,
                    wiring = true, arrange = true, chrome = true }
local function expandRef(ref)
  if ref:match('^colour%.') or ref:match('^palette%.') then return ref end
  return 'palette.' .. ref
end
for _, pair in ipairs(declarations) do
  local key, val = pair[1], pair[2]
  local ns = key:match('^colour%.(%a+)%.')
  if ns then
    assert(COLOUR_NS[ns], 'colour role in unknown namespace: ' .. key)
    if type(val) == 'string' then
      pair[2] = expandRef(val)
    elseif type(val) == 'table' and type(val[1]) == 'string' then
      val[1] = expandRef(val[1])
    else
      error('colour role must reference an atom or role, not a literal: ' .. key)
    end
    local ref   = type(pair[2]) == 'string' and pair[2] or pair[2][1]
    local refNs = ref:match('^colour%.(%a+)%.')
    if refNs then
      assert(refNs == ns or refNs == 'global',
        ('colour role %s references foreign page %s'):format(key, ref))
    end
  end
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

--contract: bound track pointer; nil when context is cleared (track tier resolves off empty)
function cm:boundTrack() return ps:boundTrack() end

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

--contract: non-raising existence test against the schema; true iff key is declared
function cm:isDeclared(key) return declared[key] == true end

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

