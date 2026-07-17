-- See docs/sampleManager.md for the model.
-- @noindex

--invariant: ds is sole authority for slot state ({path,start,end,name}); JSFX is a pure consumer
--invariant: ds holds project-relative paths; sm prepends currentPrefix so JSFX needs no prefix
--invariant: gmem layout mirrors Continuum_Sampler.jsfx; SLOT_BASE/BOOT_BASE constants must stay in lockstep with the JSFX side
--invariant: per-instance bundled mailbox at SLOT_BASE+id*SLOT_STRIDE; preview retains its own legacy magic-gated mailbox at PREVIEW_BASE
--invariant: at most one slot drained per track per tick — keeps last-write-wins consolidation simple
--invariant: instance ids are persisted via track P_EXT (PEXT_KEY) and mirrored into JSFX slider2 every getInstanceId call
--invariant: boot-token watcher (BOOT_BASE+id) detects fresh JSFX mem[] (project reload, recompile) and triggers full rehydrate
--invariant: JSFX user-string slot cap is 1023; PATH_MAX (1019) + SLOT_STRIDE bookkeeping must not push slot string writes past that ceiling
--shape: slotEntry      = { path=string?, name=string?, start=number, ['end']=number }   -- ds-stored, path is project-relative
--shape: pendingEntry   = { slot=number, op=0|1, path=string?, name=string?, start=number?, ['end']=number? }  -- mailbox queue entry; op=1 is clear
--shape: trackState     = { fxGuid=string?, instanceId=number?, lastBootToken=number, slotSeq=number, pending={byOrder={int,...}, bySlot={[slot]=pendingEntry}} }
--shape: mailboxHeader  = [seq, seq_ack, slot, op, start, end, pathLen, nameLen, <pathBytes...>, <nameBytes...>]   -- gmem words at SLOT_BASE+id*SLOT_STRIDE
local fs   = require 'fs'

local SAMPLER_FX            = 'Continuum Sampler'
local GMEM_NS               = 'Continuum_sampler'
local MAGIC                 = 1717658484   -- 'CTML' as 32-bit ASCII
local MAX_INSTANCES         = 128
local N_SAMPLES             = 64

local PATH_MAX              = 1019
local NAME_MAX              = 64
local SLOT_STRIDE           = 8 + PATH_MAX + NAME_MAX                    -- 1091

local PREVIEW_BASE          = 1024
-- Numbers mirror Continuum_Sampler.jsfx; intermediate strides are no
-- longer derivable Lua-side.
local SLOT_BASE             = 561152
local BOOT_BASE             = SLOT_BASE + MAX_INSTANCES * SLOT_STRIDE    -- 700800

local PREVIEW_SLOT_IDX      = N_SAMPLES
local SLIDER_INSTANCE_ID    = 1            -- slider2 in JSFX = param index 1 (0-based)
local PEXT_KEY              = 'P_EXT:samplerInstanceId'

--contract: writePath emits NUL-terminated bytes; caller must ensure base+#path is within the addressable string region
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

-- Force anticipative FX off (I_PERFFLAGS bit 1): sampler must not render ahead
-- of the play cursor. Applied once per track; re-applied when its FX GUID changes.
local function forceAnticipativeFxOff(track)
  local pf = reaper.GetMediaTrackInfo_Value(track, 'I_PERFFLAGS')
  if (pf & 2) == 0 then
    reaper.SetMediaTrackInfo_Value(track, 'I_PERFFLAGS', pf | 2)
  end
end

--contract: readInstanceId validates the P_EXT value into [0, MAX_INSTANCES); returns nil for missing/out-of-range/non-numeric
local function readInstanceId(track)
  local _, val = reaper.GetSetMediaTrackInfo_String(track, PEXT_KEY, '', false)
  local id = tonumber(val)
  if id and id >= 0 and id < MAX_INSTANCES then return math.floor(id) end
  return nil
end

--contract: gatherTakenIds skips skipTrack so a re-assignment of the same track doesn't see its own id as taken
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

local fileOps, cm, ds = (...).fileOps, (...).cm, (...).ds

local sm = {}

local trackStates = {}
local currentPrefix = nil

local function absFor(rel)
  if not rel or rel == '' then return rel end
  if not currentPrefix or currentPrefix == '' then return rel end
  return currentPrefix .. '/' .. rel
end
local function ensureTrackState(track)
  local s = trackStates[track]
  if not s then
    s = { fxGuid = nil, instanceId = nil, lastBootToken = 0,
          slotSeq = 0,
          pending = { byOrder = {}, bySlot = {} } }
    trackStates[track] = s
  end
  return s
end

local function relForSrc(srcBase, hash)
  local stem, ext = srcBase:match('^(.*)%.([^.]+)$')
  stem = stem or srcBase
  return ext
    and 'Continuum/' .. stem .. '-' .. hash .. '.' .. ext
    or  'Continuum/' .. stem .. '-' .. hash
end

local function setEntry(idx, fields)
  local entries = ds:get('slotEntries') or {}
  entries[idx] = entries[idx] or {}
  for k, v in pairs(fields) do entries[idx][k] = v end
  ds:assign('slotEntries', entries)
end

local function clearEntry(idx)
  local entries = ds:get('slotEntries') or {}
  entries[idx] = nil
  ds:assign('slotEntries', entries)
end

--contract: pushSlot merges into the existing pendingEntry for slot; op=1 (clear) wipes path/name/start/end; op=0 only overrides explicitly-passed fields
--contract: byOrder records first-seen slot only (no duplicate enqueue); merges into the existing bySlot entry to preserve drain ordering
local function pushSlot(state, slot, opts)
  local entry = state.pending.bySlot[slot]
  if not entry then
    entry = { slot = slot, op = 0 }
    state.pending.bySlot[slot] = entry
    state.pending.byOrder[#state.pending.byOrder + 1] = slot
  end
  if opts.op == 1 then
    entry.op     = 1
    entry.path   = nil
    entry.name   = nil
    entry.start  = 0
    entry['end'] = 0
  else
    entry.op = 0
    if opts.path   ~= nil then entry.path   = opts.path  end
    if opts.name   ~= nil then entry.name   = opts.name  end
    if opts.start  ~= nil then entry.start  = opts.start end
    if opts['end'] ~= nil then entry['end'] = opts['end'] end
  end
end

--contract: drain writes header words in order [slot, op, start, end, pathLen, nameLen, body...] then bumps seq last so JSFX only fires once the body is in
--contract: drain gates on seq == seq_ack at addr/addr+1 — JSFX must have consumed the prior write before the next one can land
--contract: drain is no-op while instanceId is nil (track lacks the FX) or queue is empty
local function drain(state)
  local order = state.pending.byOrder
  if #order == 0 or not state.instanceId then return end
  local addr = SLOT_BASE + state.instanceId * SLOT_STRIDE
  if reaper.gmem_read(addr) ~= reaper.gmem_read(addr + 1) then return end

  local slot  = table.remove(order, 1)
  local entry = state.pending.bySlot[slot]
  state.pending.bySlot[slot] = nil

  local pathBytes = entry.path
  local nameBytes = entry.name
  local pathLen   = pathBytes and #pathBytes or 0
  local nameLen   = nameBytes and #nameBytes or 0

  reaper.gmem_write(addr + 2, slot)
  reaper.gmem_write(addr + 3, entry.op)
  reaper.gmem_write(addr + 4, entry.start  or 0)
  reaper.gmem_write(addr + 5, entry['end'] or 0)
  reaper.gmem_write(addr + 6, pathLen)
  reaper.gmem_write(addr + 7, nameLen)
  for i = 1, pathLen do
    reaper.gmem_write(addr + 7 + i, pathBytes:byte(i))
  end
  for i = 1, nameLen do
    reaper.gmem_write(addr + 7 + pathLen + i, nameBytes:byte(i))
  end

  state.slotSeq = state.slotSeq + 1
  reaper.gmem_write(addr, state.slotSeq)
end

function sm:isLive(track)
  return findSamplerFx(track) ~= nil
end

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

function sm:rehydrateTrack(track)
  local state   = ensureTrackState(track)
  local entries = ds:getAt(track, 'slotEntries') or {}
  for slot = 0, N_SAMPLES - 1 do
    local e = entries[slot]
    if e and e.path then
      pushSlot(state, slot, {
        path  = absFor(e.path),
        name  = e.name,
        start = e.start  or 0,
        ['end'] = e['end'] or 0,
      })
    end
  end
end

function sm:syncSlot(track, slot)
  local state = ensureTrackState(track)
  local e     = (ds:get('slotEntries') or {})[slot]
  if not e or not e.path then
    pushSlot(state, slot, { op = 1 })
  else
    pushSlot(state, slot, {
      path  = absFor(e.path),
      name  = e.name,
      start = e.start  or 0,
      ['end'] = e['end'] or 0,
    })
  end
end

--contract: tick is the only caller of gmem_attach for the bundled mailbox path; coordinator must invoke per frame
--contract: tick reaps trackStates entries for tracks whose sampler FX has been removed (else closed-over state leaks)
--contract: first-sight FX-GUID binding does NOT reset state (lastBootToken=0 still triggers rehydrate via the boot-token branch)
function sm:tick()
  reaper.gmem_attach(GMEM_NS)
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local fxIdx = findSamplerFx(track)
    if fxIdx then
      local state = ensureTrackState(track)
      local guid  = reaper.TrackFX_GetFXGUID(track, fxIdx)
      if state.fxGuid == nil then
        state.fxGuid = guid     -- first sight: bind, don't reset
        forceAnticipativeFxOff(track)
      elseif state.fxGuid ~= guid then
        state.fxGuid        = guid
        state.lastBootToken = 0
        state.slotSeq       = 0
        state.pending       = { byOrder = {}, bySlot = {} }
        forceAnticipativeFxOff(track)
      end
      state.instanceId = self:getInstanceId(track)
      if state.instanceId then
        local token = reaper.gmem_read(BOOT_BASE + state.instanceId)
        if token ~= 0 and token ~= state.lastBootToken then
          state.lastBootToken = token
          self:rehydrateTrack(track)
        end
        drain(state)
      end
    else
      trackStates[track] = nil
    end
  end
end

----- cm-authoritative slot operations

--contract: assign hashes srcPath, copies into projectPath/Continuum/<stem>-<hash>.<ext> if missing, writes cm rel path, queues mailbox push; returns false if hash or copy fails
function sm:assign(track, idx, srcPath)
  local projectPath = reaper.GetProjectPath(0)
  local hash = fileOps.hash(srcPath)
  if not hash then return false end
  local rel  = relForSrc(fs.basename(srcPath), hash)
  local abs  = projectPath .. '/' .. rel
  fileOps.mkdir(projectPath .. '/Continuum')
  if not fileOps.exists(abs) and not fileOps.copy(srcPath, abs) then return false end
  local name    = fs.basename(srcPath)
  -- A fresh sample replaces the slot's source — trim from the previous
  -- sample no longer applies. Clear start/end (other fields, e.g.
  -- shStart, are unrelated and survive).
  local entries = ds:get('slotEntries') or {}
  entries[idx] = entries[idx] or {}
  entries[idx].path,  entries[idx].name   = rel, name
  entries[idx].start, entries[idx]['end'] = nil, nil
  ds:assign('slotEntries', entries)
  pushSlot(ensureTrackState(track), idx, {
    path = absFor(rel), name = name, start = 0, ['end'] = 0,
  })
  return true
end

function sm:loadSlot(track, slot, relPath)
  pushSlot(ensureTrackState(track), slot, {
    path = absFor(relPath), start = 0, ['end'] = 0,
  })
  return true
end

function sm:clearSlot(track, slot)
  clearEntry(slot)
  pushSlot(ensureTrackState(track), slot, { op = 1 })
  return true
end

--contract: setTrim sends start/end without path/name; pathLen=0/nameLen=0 in the wire payload means "leave alone" on the JSFX side
function sm:setTrim(track, slot, startFrames, endFrames)
  setEntry(slot, { start = startFrames, ['end'] = endFrames })
  pushSlot(ensureTrackState(track), slot, {
    start = startFrames, ['end'] = endFrames,
  })
  return true
end

function sm:setName(track, slot, name)
  setEntry(slot, { name = name })
  pushSlot(ensureTrackState(track), slot, { name = name })
  return true
end

function sm:stageInto(track, idx, srcPath)
  local projectPath = reaper.GetProjectPath(0)
  local hash = fileOps.hash(srcPath)
  if not hash then return nil end
  local rel = relForSrc(fs.basename(srcPath), hash)
  local abs = projectPath .. '/' .. rel
  fileOps.mkdir(projectPath .. '/Continuum')
  if not fileOps.exists(abs) and not fileOps.copy(srcPath, abs) then return nil end
  self:loadSlot(track, idx, rel)
  return rel
end

----- Preview + prefix

function sm:setPrefix(prefix)
  currentPrefix = prefix
  return true
end

--contract: preview writes are silently dropped if the magic word at PREVIEW_BASE is non-zero (JSFX hasn't consumed the prior preview command)
--contract: preview header order: payload words first, magic last — JSFX dispatches on the MAGIC write
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

--contract: stopPreview encodes "stop" as slot=-1 in the same preview mailbox; same magic-gate as previewSlot
function sm:stopPreview(track)
  local id = self:getInstanceId(track); if not id then return false end
  reaper.gmem_attach(GMEM_NS)
  if reaper.gmem_read(PREVIEW_BASE) ~= 0 then return false end
  reaper.gmem_write(PREVIEW_BASE + 2, -1)
  reaper.gmem_write(PREVIEW_BASE + 1, id)
  reaper.gmem_write(PREVIEW_BASE, MAGIC)
  return true
end

--contract: previewPath uses the dedicated PREVIEW_SLOT_IDX (=N_SAMPLES) so the JSFX side knows to load from the inline path bytes rather than a slot
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

----- Track surface

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

--contract: migrate iterates every sampler track via ds:getAt so non-bound tracks migrate too
--contract: ds rel paths are preserved across migrate; only file bytes move
--contract: migrate is a no-op if oldProjectPath is missing or unchanged
function sm:migrate(projectPath, oldProjectPath)
  if not oldProjectPath or oldProjectPath == projectPath then return false end
  local anyMoved = false
  for _, entry in ipairs(self:listTracks()) do
    local entries = ds:getAt(entry.track, 'slotEntries') or {}
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
  end
  return anyMoved
end

--contract: watchPath calls setPrefix every call (idempotent)
--contract: migrate + cm.lastProjectPath write only on GetProjectPath change
--contract: cm.lastProjectPath persists at project-tier so close-during-save is caught next open
function sm:watchPath()
  local pp = reaper.GetProjectPath(0)
  if not pp or pp == '' then return end
  self:setPrefix(pp)
  local last = cm:get('lastProjectPath')
  if last == pp then return end
  if last then self:migrate(pp, last) end
  cm:set('project', 'lastProjectPath', pp)
end

return sm

