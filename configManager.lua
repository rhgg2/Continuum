-- See docs/configManager.md for the model.

--@map:invariant cm is the sole source of truth for valid keys; in-code reads/writes raise on unknown keys, persistence-loaded unknowns are silently pruned
--@map:invariant cm owns its cache tables: every read deep-clones on the way out, every write deep-clones on the way in (callers never alias cm state)
--@map:invariant 5-tier merge order: global → project → track → take → transient; most-specific cache holding the key wins, falling through to schema defaults
--@map:invariant transient tier never persists (saver is a no-op) and resets to {} on every refreshCache
--@map:invariant declarations is an ordered array-of-pairs so declared-but-nil keys (e.g. temper, swing) coexist with non-nil defaults without ambiguity
--@map:invariant track and take tiers require the corresponding REAPER context; without it their loaders return {} and savers print an error

--@map:shape configChangedPayload.targeted = { key = string, level = string }   -- set / remove
--@map:shape configChangedPayload.bulk     = { level = string }                  -- assign (keyless)
--@map:shape configChangedPayload.reload   = {}                                  -- setContext / clearTake / setTrack

loadModule('util')

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

  -- boolean
  { 'polyAftertouch',  true  },
  { 'trackerMode',     false },
  { 'previewInPlace',  false },
  { 'advanceOnLoad',   true  },

  -- string choice
  { 'noteLayout',      'colemak' },

  -- null-defaulted (declared, no initial value)
  { 'temper',          nil   },
  { 'swing',           nil   },
  { 'sampleBrowserRoot', nil },

  -- table-valued
  { 'colSwing',        {}    },
  { 'swings',          {}    },
  { 'tempers',         {}    },
  { 'mutedChannels',   {}    },
  { 'soloedChannels',  {}    },
  { 'extraColumns',    {}    },
  { 'noteDelay',       {}    },
  { 'slotEntries',     {}    },

  -- Atoms — parchment palette
  { 'palette.bg',        hex('#dad6c9') },  -- cream paper
  { 'palette.shade',     hex('#303021') },  -- dark ink
  { 'palette.mid',       hex('#9f9373') },  -- warm tan (accents, separators, bar markers)
  { 'palette.highlight', hex('#b5b39e') },  -- lighter tan (beat-row tone)
  { 'palette.inactive',  hex('#8a8679') },  -- muted olive-grey
  { 'palette.danger',    hex('#da3021') },
  { 'palette.caution',   hex('#d25a23') },
  { 'palette.positive',  hex('#568a40') },
  { 'palette.amber',     hex('#dcb432') },
  { 'palette.steel',     hex('#6482a0') },
  { 'palette.pale',      hex('#f7f7f4') },
  { 'palette.night',     hex('#252936') },
  { 'palette.nightText', hex('#cfcfde') },

  -- Atoms — chrome palette
  { 'chrome.bg',        hex('#79829f') },              -- slate
  { 'chrome.shade',     hex('#5e6678') },              -- deeper slate
  { 'chrome.highlight', hex('#d6d9df') },              -- warm fog on slate

  -- Grid roles
  { 'colour.bg',               'palette.bg'                       },
  { 'colour.text',             'palette.shade'                    },
  { 'colour.offGrid',          'palette.positive'                 },
  { 'colour.overflow',         'palette.caution'                  },
  { 'colour.negative',         'palette.danger'                   },
  { 'colour.inactive',         'palette.inactive'                 },
  { 'colour.shadowed',         'colour.inactive'                  },
  { 'colour.cursor',           'palette.night'                    },
  { 'colour.cursorText',       'palette.nightText'                },
  { 'colour.rowNormal',        {'palette.bg',         0   }       },
  { 'colour.rowBeat',          {'palette.highlight',  0.4 }       },
  { 'colour.rowBarStart',      {'palette.mid',        0.4 }       },
  { 'colour.editCursor',       hex('#ffff00')                     },  -- one-off yellow
  { 'colour.selection',        {'palette.pale',       0.5 }       },
  { 'colour.scrollHandle',     'colour.text'                      },
  { 'colour.scrollBg',         'colour.bg'                        },
  { 'colour.accent',           'palette.mid'                      },
  { 'colour.mute',             'colour.negative'                  },
  { 'colour.solo',             'palette.amber'                    },
  { 'colour.separator',        {'palette.mid',        0.3 }       },
  { 'colour.tail',             {'palette.steel',      0.15}       },
  { 'colour.tailBord',         hex('#8caac8')                     },  -- one-off lighter steel
  { 'colour.ghost',            {'palette.steel',      0.9 }       },
  { 'colour.ghostNegative',    hex('#da8278', 0.9)                },  -- one-off faded red
  -- Lane strip (CC/PB/AT envelope visualiser above the tracker grid).
  { 'colour.laneAxis',         {'palette.inactive',   0.6 }       },
  { 'colour.laneRowDivider',   {'palette.inactive',   0.15}       },
  { 'colour.laneAnchor',       'colour.text'                      },
  { 'colour.laneAnchorActive', 'colour.negative'                  },
  { 'colour.laneEnvelope',     'colour.accent'                    },

  -- Chrome roles — toolbar (top band) and statusBar (bottom band).
  -- They share the chrome palette today; split aliases let either diverge.
  { 'colour.toolbar.bg',           {'palette.pale', 0.5}          },
  { 'colour.toolbar.text',         'palette.shade'                 },
  { 'colour.toolbar.button',       'palette.pale',                 },
  { 'colour.toolbar.buttonHover',  {'palette.pale',  0.42 }       },
  { 'colour.toolbar.buttonActive', {'palette.pale',  0.62 }       },
  { 'colour.toolbar.buttonBorder', {'palette.mid',    0.35  }       },
  { 'colour.toolbar.checkMark',    'palette.shade'                 },
  { 'colour.toolbar.popupBg',      'palette.pale'                  },
  { 'colour.statusBar.bg',         'chrome.bg'                    },
  { 'colour.statusBar.text',       'chrome.highlight'             },
  -- Pre-blended `0.5*pale + 0.5*bg`; a literal alias would render translucent over a different parent.
  { 'colour.editor.bg',            hex('#e9e7df')                 },
  { 'laneStrip.rows',      4    },
  { 'laneStrip.visible',   true },
}

local declared, defaults = {}, {}
for _, pair in ipairs(declarations) do
  declared[pair[1]] = true
  if pair[2] ~= nil then defaults[pair[1]] = pair[2] end
end

local function copy(v)
  if type(v) == 'table' then return util.deepClone(v) end
  return v
end

--@map:contract caches are lazy: first getter call triggers refreshCache; setContext/setTrack refresh eagerly
--@map:contract no take context means track context is also dropped (track derived from take in setContext)
function newConfigManager()

  ---------- PRIVATE DATA

  local CONFIG_PREFIX = 'ctm_'
  local SCRIPT_PATH = debug.getinfo(1,'S').source:match[[^@?(.*[\/])[^\/]-$]]
  local CONFIG_GLOBAL_PATH = SCRIPT_PATH .. 'ctm_cfg.txt'

  local take      = nil
  local track     = nil
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

  --@map:contract parse failures (bad text or non-table result) fall through to {}; never raises
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
    reaper.GetSetMediaTrackInfo_String(
      track, 'P_EXT:' .. CONFIG_PREFIX .. 'config', util.serialise(tbl), true)
  end

  local function loadTake()
    if not take then return {} end
    local ok, val = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_config', '', false)
    return ok and parse(val)
  end

  local function saveTake(tbl)
    if not take then
      print('Error! No take context for config storage')
      return
    end
    reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_config', util.serialise(tbl), true)
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

  ---------- CACHE MANAGEMENT

  local function refreshCache()
    for _, level in ipairs(levels) do
      cache[level] = loaders[level]()
    end
  end

  local function ensureCache()
    if not cache.global then refreshCache() end
  end

  --@map:contract starts from schema defaults, then overlays each level's cache in `levels` order so later (more-specific) tiers win
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

  --@map:contract setContext(nil) clears both take and track; setContext(take) derives track via GetMediaItemTrack
  --@map:contract refreshes all four persisted caches (transient resets to {}) and fires configChanged with empty payload
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
    --@map:emits configChanged -- configChangedPayload.reload
    fire('configChanged', {})
  end

  function cm:clearTake()
    take = nil
    cache.take = {}
    --@map:emits configChanged -- configChangedPayload.reload
    fire('configChanged', {})
  end

  function cm:setTrack(newTrack)
    track = newTrack
    cache.track = loaders.track()
    --@map:emits configChanged -- configChangedPayload.reload
    fire('configChanged', {})
  end

  ----- Reading

  --@map:contract returns deep copy of merged value (defaults overlaid by all five tiers); raises on unknown key
  function cm:get(key)
    checkKey(key)
    return copy(mergedTable()[key])
  end

  --@map:contract reads single tier only (no merge, no defaults); key omitted returns whole-cache deep clone; raises on unknown level/key
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

  --@map:contract bypasses cache and active context; reads otherTrack's P_EXT directly without firing configChanged or disturbing the bound track's cache
  function cm:readTrackKey(otherTrack, key)
    checkKey(key)
    if not otherTrack then return nil end
    local ok, val = reaper.GetSetMediaTrackInfo_String(
      otherTrack, 'P_EXT:' .. CONFIG_PREFIX .. 'config', '', false)
    if not ok or not val or val == '' then return nil end
    local parsed = parse(val)
    return copy(parsed[key])
  end

  --@map:contract walks tiers most-specific to least, returning the first level whose cache defines the key (matches merge resolution); nil if no tier sets it
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

  --@map:contract deep-copies value into the target tier's cache, persists that tier, fires targeted configChanged
  function cm:set(level, key, value)
    checkLevel(level)
    checkKey(key)
    ensureCache()

    cache[level] = cache[level] or {}
    cache[level][key] = copy(value)
    savers[level](cache[level])
    --@map:emits configChanged -- configChangedPayload.targeted
    fire('configChanged', { key = key, level = level })
  end

  --@map:contract removes key from the named tier only; no-op (and no signal) if that tier's cache is unloaded
  function cm:remove(level, key)
    checkLevel(level)
    checkKey(key)
    ensureCache()

    if cache[level] then
      cache[level][key] = nil
      savers[level](cache[level])
      --@map:emits configChanged -- configChangedPayload.targeted
      fire('configChanged', { key = key, level = level })
    end
  end

  --@map:contract validates every key in updates before any write (all-or-nothing); util.REMOVE sentinel deletes that key; fires keyless configChanged
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
    --@map:emits configChanged -- configChangedPayload.bulk
    fire('configChanged', { level = level })
  end

  return cm
end
