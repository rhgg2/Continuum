-- Wire-protocol bridge to the Continuum Sampler JSFX. Owns the gmem
-- mailbox layout (load, preview, prefix, trim, names slab, trims slab)
-- and the instance-id multiplex. Each sampler-bearing track carries a
-- P_EXT 'samplerInstanceId' (0..127); Continuum tags every mailbox write
-- with target_id, JSFX consumes only when slider2==target_id. Names and
-- trims slabs stride per-instance. Single point of truth for the
-- JSFX-side contract.

loadModule('util')
loadModule('fs')

local SAMPLER_FX            = 'Continuum Sampler'
local GMEM_NS               = 'Continuum_sampler'
local MAGIC                 = 1717658484   -- 'CTML' as 32-bit ASCII
local MAX_INSTANCES         = 128
local N_SAMPLES             = 64
local NAME_STRIDE           = 64
local TRIMS_STRIDE          = 4
local INSTANCE_NAMES_STRIDE = N_SAMPLES * NAME_STRIDE             -- 4096
local INSTANCE_TRIMS_STRIDE = N_SAMPLES * TRIMS_STRIDE            -- 256

local LOAD_BASE             = 0
local PREVIEW_BASE          = 1024
local PREFIX_BASE           = 2048
local TRIM_BASE             = 3072
local NAMES_BASE            = 4096
local TRIMS_BASE            = NAMES_BASE + MAX_INSTANCES * INSTANCE_NAMES_STRIDE  -- 528384

local PREVIEW_SLOT_IDX      = N_SAMPLES
local SLIDER_INSTANCE_ID    = 1            -- slider2 in JSFX = param index 1 (0-based)
local PEXT_KEY              = 'P_EXT:samplerInstanceId'

local function writePath(base, path)
  for i = 1, #path do reaper.gmem_write(base + i - 1, path:byte(i)) end
  reaper.gmem_write(base + #path, 0)
end

local function findSamplerFx(track)
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i, '')
    if name:find(SAMPLER_FX, 1, true) then return i end
  end
  return nil
end

local function readInstanceId(track)
  local _, val = reaper.GetSetMediaTrackInfo_String(track, PEXT_KEY, '', false)
  local id = tonumber(val)
  if id and id >= 0 and id < MAX_INSTANCES then return math.floor(id) end
  return nil
end

local function gatherTakenIds(skipTrack)
  local taken = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    if t ~= skipTrack and findSamplerFx(t) then
      local id = readInstanceId(t)
      if id then taken[id] = true end
    end
  end
  return taken
end

local function nextFreeId(taken)
  for i = 0, MAX_INSTANCES - 1 do
    if not taken[i] then return i end
  end
  return nil
end

function newSampleManager(fileOps)
  local sm = {}
  local trimSeq = 0

  -- Continuum/<stem>-<8 hex>[.ext]. Hex tail is a content fingerprint
  -- (fs.hashFile), so re-loading the same audio resolves to the same
  -- destination filename and the copy can be skipped.
  local function relForSrc(srcBase, hash)
    local stem, ext = srcBase:match('^(.*)%.([^.]+)$')
    stem = stem or srcBase
    return ext
      and 'Continuum/' .. stem .. '-' .. hash .. '.' .. ext
      or  'Continuum/' .. stem .. '-' .. hash
  end

  -- Strip the 8-hex suffix that relForSrc adds, before either the
  -- extension or end-of-string. Applied at the point of publishing into
  -- cm so every consumer sees the clean name.
  local function stripHash(name)
    local s = (name:gsub('%-(%x%x%x%x%x%x%x%x)(%.[^.]+)$', '%2'))
    return (s:gsub('%-(%x%x%x%x%x%x%x%x)$', ''))
  end

  local function setEntry(cm, idx, fields)
    local entries = cm:get('slotEntries')
    entries[idx] = entries[idx] or {}
    for k, v in pairs(fields) do entries[idx][k] = v end
    cm:set('track', 'slotEntries', entries)
  end

  -- Resolve track → instance id, assigning + persisting on first sight.
  -- Always pushes the value back into JSFX slider2 so a drifted slider
  -- (manual reset, fresh FX before @serialize) can never silently swallow
  -- our writes. Returns nil if the track lacks the sampler FX entirely.
  function sm:getInstanceId(track)
    local fxIdx = findSamplerFx(track)
    if not fxIdx then return nil end
    local id = readInstanceId(track)
    if not id then
      id = nextFreeId(gatherTakenIds(track))
      if not id then return nil end
      reaper.GetSetMediaTrackInfo_String(track, PEXT_KEY, tostring(id), true)
    end
    reaper.TrackFX_SetParam(track, fxIdx, SLIDER_INSTANCE_ID, id)
    return id
  end

  -- JSFX-only unload (path=0 sentinel). cm-side bookkeeping lives in
  -- clearSlot; preview-in-place uses unloadSlot directly to revert without
  -- touching the persistent slot list.
  function sm:unloadSlot(track, slot)
    local id = self:getInstanceId(track); if not id then return false end
    reaper.gmem_attach(GMEM_NS)
    if reaper.gmem_read(LOAD_BASE) ~= 0 then return false end
    reaper.gmem_write(LOAD_BASE + 3, 0)
    reaper.gmem_write(LOAD_BASE + 2, slot)
    reaper.gmem_write(LOAD_BASE + 1, id)
    reaper.gmem_write(LOAD_BASE, MAGIC)
    return true
  end

  function sm:clearSlot(track, slot, cm)
    local entries = cm:get('slotEntries')
    entries[slot] = nil
    cm:set('track', 'slotEntries', entries)
    local names = cm:get('samplerNames')
    if names[slot] then
      names[slot] = nil
      cm:set('transient', 'samplerNames', names)
    end
    return self:unloadSlot(track, slot)
  end

  function sm:loadSlot(track, slot, relPath)
    local id = self:getInstanceId(track); if not id then return false end
    reaper.gmem_attach(GMEM_NS)
    if reaper.gmem_read(LOAD_BASE) ~= 0 then return false end
    writePath(LOAD_BASE + 3, relPath)
    reaper.gmem_write(LOAD_BASE + 2, slot)
    reaper.gmem_write(LOAD_BASE + 1, id)
    reaper.gmem_write(LOAD_BASE, MAGIC)
    return true
  end

  -- Push the project root to all sampler instances so they can compose
  -- abs paths from rel-path loads and persist the prefix in @serialize.
  -- Project-wide; not instance-tagged.
  function sm:setPrefix(prefix)
    reaper.gmem_attach(GMEM_NS)
    if reaper.gmem_read(PREFIX_BASE) ~= 0 then return false end
    writePath(PREFIX_BASE + 1, prefix)
    reaper.gmem_write(PREFIX_BASE, MAGIC)
    return true
  end

  function sm:previewSlot(track, slot, bounds)
    local id = self:getInstanceId(track); if not id then return false end
    reaper.gmem_attach(GMEM_NS)
    if reaper.gmem_read(PREVIEW_BASE) ~= 0 then return false end
    reaper.gmem_write(PREVIEW_BASE + 2, slot)
    reaper.gmem_write(PREVIEW_BASE + 3, bounds)
    reaper.gmem_write(PREVIEW_BASE + 1, id)
    reaper.gmem_write(PREVIEW_BASE, MAGIC)
    return true
  end

  function sm:stopPreview(track)
    local id = self:getInstanceId(track); if not id then return false end
    reaper.gmem_attach(GMEM_NS)
    if reaper.gmem_read(PREVIEW_BASE) ~= 0 then return false end
    reaper.gmem_write(PREVIEW_BASE + 2, -1)   -- sentinel: release all preview voices
    reaper.gmem_write(PREVIEW_BASE + 1, id)
    reaper.gmem_write(PREVIEW_BASE, MAGIC)
    return true
  end

  function sm:previewPath(track, path)
    local id = self:getInstanceId(track); if not id then return false end
    reaper.gmem_attach(GMEM_NS)
    if reaper.gmem_read(PREVIEW_BASE) ~= 0 then return false end
    writePath(PREVIEW_BASE + 4, path)
    reaper.gmem_write(PREVIEW_BASE + 2, PREVIEW_SLOT_IDX)
    reaper.gmem_write(PREVIEW_BASE + 3, 0)
    reaper.gmem_write(PREVIEW_BASE + 1, id)
    reaper.gmem_write(PREVIEW_BASE, MAGIC)
    return true
  end

  -- Seq-gated (no magic): a slider drag at frame rate must not drop
  -- writes behind a still-pending clear. JSFX caches last-seen seq and
  -- applies on change. end==0 routes through the JSFX default
  -- (frames-2); pass -1 to mean "leave untouched" by re-reading current.
  function sm:setTrim(track, slot, startFrames, endFrames)
    local id = self:getInstanceId(track); if not id then return false end
    reaper.gmem_attach(GMEM_NS)
    trimSeq = trimSeq + 1
    reaper.gmem_write(TRIM_BASE + 1, id)
    reaper.gmem_write(TRIM_BASE + 2, slot)
    reaper.gmem_write(TRIM_BASE + 3, startFrames)
    reaper.gmem_write(TRIM_BASE + 4, endFrames)
    reaper.gmem_write(TRIM_BASE,     trimSeq)
    return true
  end

  -- Pulls the per-slot publish slab for the given track's instance.
  -- Returns a fresh table keyed by 0-indexed slot, only entries with
  -- fs > 0 (loaded). Caller passes its cached table; an all-empty read
  -- on a previously populated cache is treated as a transient gap and
  -- the cache is returned untouched, mirroring readNames.
  function sm:readTrims(track, prev)
    local id = self:getInstanceId(track); if not id then return prev or {} end
    reaper.gmem_attach(GMEM_NS)
    local instBase = TRIMS_BASE + id * INSTANCE_TRIMS_STRIDE
    local out = {}
    for idx = 0, N_SAMPLES - 1 do
      local base = instBase + idx * TRIMS_STRIDE
      local fs = reaper.gmem_read(base)
      if fs and fs > 0 then
        out[idx] = {
          fs     = fs,
          frames = reaper.gmem_read(base + 1),
          start  = reaper.gmem_read(base + 2),
          ['end']= reaper.gmem_read(base + 3),
        }
      end
    end
    if next(out) == nil and prev and next(prev) ~= nil then return prev end
    return out
  end

  -- Pull sample names from the gmem names slab for the given track's
  -- instance; only write back to cm when they actually change so
  -- configChanged doesn't fire every frame.
  function sm:readNames(track, cm)
    local id = self:getInstanceId(track); if not id then return end
    reaper.gmem_attach(GMEM_NS)
    local instBase = NAMES_BASE + id * INSTANCE_NAMES_STRIDE
    local fresh = {}
    for idx = 0, N_SAMPLES - 1 do
      local base, chars = instBase + idx * NAME_STRIDE, {}
      for j = 0, NAME_STRIDE - 1 do
        local b = reaper.gmem_read(base + j)
        if not b or b == 0 then break end
        chars[#chars + 1] = string.char(math.floor(b))
      end
      if #chars > 0 then fresh[idx] = stripHash(table.concat(chars)) end
    end
    local cur = cm:get('samplerNames')
    -- Empty fresh on a tick where JSFX briefly hasn't republished
    -- (transport gating, race with @serialize) would otherwise blank
    -- cur and the slot list flickers '(empty)'. JSFX wiping all 64
    -- names in one go isn't a real workflow — prefer stickiness.
    if next(fresh) == nil and next(cur) ~= nil then return end
    for k, v in pairs(fresh) do
      if cur[k] ~= v then cm:set('transient', 'samplerNames', fresh); return end
    end
    for k, v in pairs(cur) do
      if fresh[k] ~= v then cm:set('transient', 'samplerNames', fresh); return end
    end
  end

  -- Walks all tracks and returns those carrying the Continuum Sampler FX.
  -- Returned shape: { { track, name, instanceId }, ... } — instance ids
  -- are assigned + persisted in the same pass.
  function sm:listTracks()
    local out = {}
    for i = 0, reaper.CountTracks(0) - 1 do
      local t = reaper.GetTrack(0, i)
      if findSamplerFx(t) then
        local _, trackName = reaper.GetTrackName(t)
        out[#out + 1] = { track      = t,
                          name       = trackName ~= '' and trackName or '(unnamed)',
                          instanceId = self:getInstanceId(t) }
      end
    end
    return out
  end

  -- Detect whether the take's track carries the sampler; mirror the
  -- result into cm:trackerMode and ensure the instance id is assigned.
  -- Anticipative FX puts the sampler to sleep when idle and preview
  -- wake-up takes 200–500 ms; I_PERFFLAGS bit 2 disables it on this
  -- track only. Persistent (saved with the project), set once.
  function sm:probeMode(take, cm)
    local track = reaper.GetMediaItemTake_Track(take)
    local detected = findSamplerFx(track) ~= nil
    if cm:get('trackerMode') ~= detected then
      cm:set('transient', 'trackerMode', detected)
    end
    if detected then
      self:getInstanceId(track)
      local pf = reaper.GetMediaTrackInfo_Value(track, 'I_PERFFLAGS')
      if (pf & 2) == 0 then
        reaper.SetMediaTrackInfo_Value(track, 'I_PERFFLAGS', pf | 2)
      end
    end
  end

  ----- Slot persistence

  -- Copy src into the project's Continuum/ folder (skipped if the
  -- hashed name already exists) and push the rel path into JSFX.
  -- Returns the rel path on success, nil on failure. Does not touch
  -- cm — caller decides whether the load is persistent (assign) or
  -- transient (preview-in-place).
  function sm:stageInto(track, idx, srcPath, projectPath)
    local hash = fileOps.hash(srcPath)
    if not hash then return nil end
    local rel = relForSrc(fs.basename(srcPath), hash)
    local abs = projectPath .. '/' .. rel
    fileOps.mkdir(projectPath .. '/Continuum')
    if not fileOps.exists(abs) and not fileOps.copy(srcPath, abs) then return nil end
    self:loadSlot(track, idx, rel)
    return rel
  end

  function sm:assign(track, idx, srcPath, projectPath, cm)
    local rel = self:stageInto(track, idx, srcPath, projectPath)
    if not rel then return false end
    setEntry(cm, idx, { path = rel })
    return true
  end

  function sm:sweep(track, cm)
    local entries = cm:get('slotEntries')
    for idx, e in pairs(entries) do
      if e.path then sm:loadSlot(track, idx, e.path) end
    end
  end

  -- Move slot files when the project's media folder changes (typically
  -- the empty→saved transition). cm paths are relative so they survive
  -- the move untouched; only the bytes need to follow.
  function sm:migrate(projectPath, oldProjectPath, cm)
    if not oldProjectPath or oldProjectPath == projectPath then return false end
    local entries = cm:get('slotEntries')
    local anyMoved = false
    for _, e in pairs(entries) do
      if e.path then
        local oldAbs = oldProjectPath .. '/' .. e.path
        local newAbs = projectPath    .. '/' .. e.path
        if oldAbs ~= newAbs then
          fileOps.mkdir(projectPath .. '/Continuum')
          if fileOps.move(oldAbs, newAbs) then anyMoved = true end
        end
      end
    end
    return anyMoved
  end

  return sm
end
