-- Pin tests for slot persistence and the ds-authoritative bundled mailbox protocol on sampleManager.
-- ds is real; fileOps is a call-recording stub; gmem via fakeReaper; tracks are opaque tokens.

local t = require('support')
local fs = require('fs')
local util = require('util')

local function newSampleManager(fileOps, cm, ds)
  return util.instantiate('sampleManager', { fileOps = fileOps, cm = cm, ds = ds })
end

local MAGIC        = 1717658484  -- 'CTML' as 32-bit ASCII; mirrors sampleManager
local PREVIEW_BASE = 1024
local SLOT_BASE    = 561152
local PATH_MAX     = 1019
local NAME_MAX     = 64
local SLOT_STRIDE  = 8 + PATH_MAX + NAME_MAX                    -- 1091
local BOOT_BASE    = SLOT_BASE + 128 * SLOT_STRIDE              -- 700800

local function mkOps()
  local ops = {
    copies = {}, moves = {}, mkdirs = {},
    copyResult = true,
    moveResult = true,
  }
  ops.copy   = function(src, dst) ops.copies[#ops.copies+1] = { src, dst }; return ops.copyResult end
  ops.move   = function(src, dst) ops.moves [#ops.moves +1] = { src, dst }; return ops.moveResult end
  ops.mkdir  = function(dir)      ops.mkdirs[#ops.mkdirs+1] = dir          end
  ops.exists = function()         return false end
  ops.hash   = function()         return 'deadbeef' end
  return ops
end

-- Plant a sampler FX on track, register it with the project, and bind cm
-- to the same track so cm-side reads/writes match what sm:tick will see.
-- Default GUID per-track is supplied by fakeReaper; pass guidOverride to
-- control it.
local function bindSamplerTrack(h, track, guidOverride)
  h.reaper:setTrackFX(track, { 'Continuum Sampler' })
  h.reaper:setProjectTracks({ track })
  if guidOverride then h.reaper:setFxGuid(track, guidOverride) end
  h.cm:setTrack(track)
end

-- Read N bytes from gmem starting at base, dropping at 0 or N exhaust.
-- The mailbox packs path then name with no separator; gmemString would
-- run past path into name, so length-bounded reads are mandatory.
local function gmemSpan(h, base, len)
  local chars = {}
  for i = 0, len - 1 do
    local b = h.reaper.gmem_read(base + i)
    if b == 0 then break end
    chars[#chars + 1] = string.char(math.floor(b))
  end
  return table.concat(chars)
end

-- Read the bundled mailbox header for instance_id at SLOT_BASE.
local function readMailbox(h, instanceId)
  local addr    = SLOT_BASE + instanceId * SLOT_STRIDE
  local pathLen = h.reaper.gmem_read(addr + 6)
  local nameLen = h.reaper.gmem_read(addr + 7)
  return {
    seq      = h.reaper.gmem_read(addr),
    seqAck   = h.reaper.gmem_read(addr + 1),
    slot     = h.reaper.gmem_read(addr + 2),
    op       = h.reaper.gmem_read(addr + 3),
    startF   = h.reaper.gmem_read(addr + 4),
    endF     = h.reaper.gmem_read(addr + 5),
    pathLen  = pathLen,
    nameLen  = nameLen,
    path     = gmemSpan(h, addr + 8, pathLen),
    name     = gmemSpan(h, addr + 8 + pathLen, nameLen),
  }
end

-- JSFX echoes [0] into [1] after consuming. Tests fake that ack so the
-- channel-clear gate lets the next sm:tick drain another queued slot.
local function ackMailbox(h, instanceId)
  local addr = SLOT_BASE + instanceId * SLOT_STRIDE
  h.reaper.gmem_write(addr + 1, h.reaper.gmem_read(addr))
end

-- Seed a nonzero boot-token so the first sm:tick triggers rehydrate.
local function plantBootToken(h, instanceId, token)
  h.reaper.gmem_write(BOOT_BASE + instanceId, token)
end

return {
  {
    name = 'reads deep-clone out; a mutated slotEntries read does not pollute ds',
    run = function(harness)
      local h = harness.mk()
      h.ds:assign('slotEntries', { [0] = { path = 'seed' } })
      local a = h.ds:get('slotEntries')
      a[0].path = 'leak'
      t.eq(h.ds:get('slotEntries')[0].path, 'seed', 'mutation of returned table does not pollute ds')
    end,
  },
  {
    name = 'slotEntries round-trips through track ext-state',
    run = function(harness)
      local h = harness.mk()
      h.ds:assign('slotEntries', { [3] = { path = 'Continuum/k.wav' } })
      local ps2 = util.instantiate('pextStore'); ps2:setTake('take1')
      local ds2 = util.instantiate('dataStore', { ps = ps2 })
      t.eq(ds2:get('slotEntries')[3].path, 'Continuum/k.wav', 'rehydrated from track P_EXT')
    end,
  },
  {
    name = 'ds:getAt reads a track scope without changing context',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      bindSamplerTrack(h, 't2')
      h.reaper:setProjectTracks({ 't1', 't2' })
      h.cm:setTrack('t2')
      h.ds:assign('slotEntries', { [0] = { path = 'Continuum/two.wav' } })
      h.cm:setTrack('t1')
      h.ds:assign('slotEntries', { [0] = { path = 'Continuum/one.wav' } })

      local fromOne = h.ds:getAt('t1', 'slotEntries')
      local fromTwo = h.ds:getAt('t2', 'slotEntries')
      t.eq(fromOne[0].path, 'Continuum/one.wav', 't1 read direct')
      t.eq(fromTwo[0].path, 'Continuum/two.wav', 't2 read direct')
      t.eq((h.ds:get('slotEntries') or {})[0].path, 'Continuum/one.wav',
           'cm context (t1) untouched after foreign reads')
    end,
  },
  {
    name = 'getInstanceId assigns next-free, persists P_EXT, pushes slider',
    run = function(harness)
      local h  = harness.mk()
      bindSamplerTrack(h, 't1')
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      local id = sm:getInstanceId('t1')
      t.eq(id, 0, 'first sampler track gets id 0')
      local _, persisted = h.reaper.GetSetMediaTrackInfo_String('t1',
        'P_EXT:samplerInstanceId', '', false)
      t.eq(persisted, '0', 'P_EXT carries the assigned id')
      local lastSetParam
      for _, c in ipairs(h.reaper._state.calls) do
        if c.fn == 'TrackFX_SetParam' then lastSetParam = c end
      end
      t.truthy(lastSetParam, 'TrackFX_SetParam invoked')
      t.eq(lastSetParam.paramIdx, 1,    'pushed to slider2 (param idx 1)')
      t.eq(lastSetParam.value,    0,    'value matches assigned id')
    end,
  },
  {
    name = 'getInstanceId reads existing P_EXT without reassigning',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper.GetSetMediaTrackInfo_String('t1', 'P_EXT:samplerInstanceId', '7', true)
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      t.eq(sm:getInstanceId('t1'), 7, 'returns persisted id')
    end,
  },
  {
    name = 'getInstanceId skips taken ids when assigning a new track',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setTrackFX('t1', { 'Continuum Sampler' })
      h.reaper:setTrackFX('t2', { 'Continuum Sampler' })
      h.reaper:setProjectTracks({ 't1', 't2' })
      h.reaper.GetSetMediaTrackInfo_String('t1', 'P_EXT:samplerInstanceId', '0', true)
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      t.eq(sm:getInstanceId('t2'), 1, 'next-free id around taken=0')
    end,
  },
  {
    name = 'isLive reflects sampler FX presence',
    run = function(harness)
      local h  = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:setTrackFX('t2', { 'SomeOther' })
      h.reaper:setProjectTracks({ 't1', 't2' })
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      t.truthy(sm:isLive('t1'),  't1 has the sampler FX')
      t.falsy (sm:isLive('t2'),  't2 lacks the sampler FX')
      t.eq    (sm:getInstanceId('t2'), nil, 'no FX → no id')
    end,
  },
  {
    name = 'watchPath sets the prefix on reopen even when the breadcrumb already matches',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      h.reaper:setProjectPath('/proj')
      -- Reopen: breadcrumb already matches, so watchPath's change-branch is a no-op.
      -- Prefix must still be set or slot paths reach JSFX relative and load_sample_from_file silently fails.
      h.cm:set('project', 'lastProjectPath', '/proj')

      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      sm:watchPath()
      sm:assign('t1', 5, '/disk/kick.wav')
      sm:tick()

      local mb = readMailbox(h, 0)
      t.truthy(mb.path:match('^/proj/Continuum/kick%-%x+%.wav$'),
        'slot path reaches JSFX absolute despite an unchanged project path, got ' .. mb.path)
    end,
  },
  {
    name = 'assign copies, writes cm rel path, queues abs in mailbox after tick',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      local ops = mkOps()
      local sm  = newSampleManager(ops, h.cm, h.ds)
      sm:setPrefix('/proj')
      h.reaper:setProjectPath('/proj')

      local ok = sm:assign('t1', 5, '/disk/kick.wav')
      t.truthy(ok, 'returns true on success')

      t.eq(#ops.mkdirs, 1, 'one mkdir')
      t.eq(ops.mkdirs[1], '/proj/Continuum', 'mkdir targets Continuum subdir')
      t.eq(#ops.copies, 1, 'one copy')
      t.eq(ops.copies[1][1], '/disk/kick.wav', 'copy src is the source path')
      t.truthy(ops.copies[1][2]:match('^/proj/Continuum/kick%-%x+%.wav$'),
        'copy dst is /proj/Continuum/kick-<hash>.wav, got ' .. ops.copies[1][2])

      local entry = (h.ds:get('slotEntries') or {})[5]
      t.truthy(entry, 'cm has slot 5')
      t.truthy(entry.path:match('^Continuum/kick%-%x+%.wav$'),
        'cm path is project-relative, got ' .. tostring(entry.path))
      t.eq(entry.name, 'kick.wav', 'cm name seeded from src basename')

      sm:tick()   -- one drain pop emits the queued slot
      local mb = readMailbox(h, 0)
      t.eq(mb.seq,    1, 'first drain bumped seq to 1')
      t.eq(mb.slot,   5, 'slot index in payload')
      t.eq(mb.op,     0, 'op=0 (set/update)')
      t.eq(mb.startF, 0, 'start=0 on assign')
      t.eq(mb.endF,   0, 'end=0 on assign')
      t.truthy(mb.path:match('^/proj/Continuum/kick%-%x+%.wav$'),
        'mailbox path is absolute (rel composed against /proj), got ' .. mb.path)
      t.eq(mb.name, 'kick.wav', 'name bytes follow path bytes')
    end,
  },
  {
    name = 'assign returns false on copy failure, leaves cm and mailbox untouched',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      local ops = mkOps()
      ops.copyResult = false
      local sm = newSampleManager(ops, h.cm, h.ds)
      sm:setPrefix('/proj')

      t.eq(sm:assign('t1', 2, '/disk/missing.wav'), false, 'returns false')
      t.eq((h.ds:get('slotEntries') or {})[2], nil, 'no cm entry written')
      sm:tick()
      t.eq(readMailbox(h, 0).seq, 0, 'mailbox not bumped')
    end,
  },
  {
    name = 'assign preserves other slot fields when overwriting path',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.ds:assign('slotEntries',
        { [4] = { path = 'Continuum/old.wav', shStart = 100 } })
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      sm:setPrefix('/proj')

      sm:assign('t1', 4, '/disk/new.wav')
      local entry = (h.ds:get('slotEntries') or {})[4]
      t.eq(entry.shStart, 100, 'shStart survived re-assign')
      t.truthy(entry.path:match('^Continuum/new%-'), 'path was overwritten')
    end,
  },
  {
    name = 'assign clears start/end so the new sample plays full by default',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.ds:assign('slotEntries',
        { [4] = { path    = 'Continuum/old.wav',
                  start   = 1000, ['end'] = 5000,
                  shStart = 100 } })
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      sm:setPrefix('/proj')

      sm:assign('t1', 4, '/disk/new.wav')
      local entry = (h.ds:get('slotEntries') or {})[4]
      t.eq(entry.start,   nil, 'start cleared')
      t.eq(entry['end'],  nil, 'end cleared')
      t.eq(entry.shStart, 100, 'unrelated field preserved')
    end,
  },
  {
    name = 'stageInto copies + queues mailbox, returns rel, leaves cm alone',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      local ops = mkOps()
      local sm  = newSampleManager(ops, h.cm, h.ds)
      sm:setPrefix('/proj')
      h.reaper:setProjectPath('/proj')

      local rel = sm:stageInto('t1', 7, '/disk/snare.wav')
      t.truthy(rel and rel:match('^Continuum/snare%-%x+%.wav$'),
        'returned rel path, got ' .. tostring(rel))
      t.eq(#ops.copies, 1, 'one copy issued')
      t.eq((h.ds:get('slotEntries') or {})[7], nil, 'cm slotEntries untouched')

      sm:tick()
      local mb = readMailbox(h, 0)
      t.eq(mb.seq,  1, 'mailbox seq bumped')
      t.eq(mb.slot, 7, 'slot index in payload')
      t.truthy(mb.path:match('^/proj/Continuum/snare%-%x+%.wav$'),
        'abs path composed against prefix')
    end,
  },
  {
    name = 'stageInto returns nil on copy failure, leaves mailbox quiet',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      local ops = mkOps()
      ops.copyResult = false
      local sm = newSampleManager(ops, h.cm, h.ds)
      sm:setPrefix('/proj')
      t.eq(sm:stageInto('t1', 2, '/disk/x.wav'), nil, 'returned nil')
      sm:tick()
      t.eq(readMailbox(h, 0).seq, 0, 'mailbox not bumped')
    end,
  },
  {
    name = 'clearSlot zeros cm entry and queues op=1 in mailbox',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.ds:assign('slotEntries', { [3] = { path = 'Continuum/k.wav', name = 'k' } })
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      sm:setPrefix('/proj')

      t.eq(sm:clearSlot('t1', 3), true, 'returns true')
      t.eq((h.ds:get('slotEntries') or {})[3], nil, 'cm entry removed')
      sm:tick()
      local mb = readMailbox(h, 0)
      t.eq(mb.seq,  1, 'mailbox seq bumped')
      t.eq(mb.slot, 3, 'slot at [+2]')
      t.eq(mb.op,   1, 'op=1 (clear)')
    end,
  },
  {
    name = 'previewSlot stamps target_id alongside slot and bounds',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      t.eq(sm:previewSlot('t1', 9, 1), true)
      t.eq(h.reaper.gmem_read(PREVIEW_BASE),     MAGIC)
      t.eq(h.reaper.gmem_read(PREVIEW_BASE + 1), 0, 'target_id at [+1]')
      t.eq(h.reaper.gmem_read(PREVIEW_BASE + 2), 9, 'slot at [+2]')
      t.eq(h.reaper.gmem_read(PREVIEW_BASE + 3), 1, 'bounds at [+3]')
    end,
  },
  {
    name = 'setTrim mirrors start/end onto cm and queues a mailbox update',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.ds:assign('slotEntries', { [4] = { path = 'Continuum/k.wav' } })
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      sm:setPrefix('/proj')

      t.eq(sm:setTrim('t1', 4, 100, 200), true)
      local entry = (h.ds:get('slotEntries') or {})[4]
      t.eq(entry.start,  100,                'start written to cm')
      t.eq(entry['end'], 200,                'end written to cm')
      t.eq(entry.path,   'Continuum/k.wav',  'path preserved')

      sm:tick()
      local mb = readMailbox(h, 0)
      t.eq(mb.seq,     1,   'seq bumped')
      t.eq(mb.slot,    4,   'slot in payload')
      t.eq(mb.startF,  100, 'start in payload')
      t.eq(mb.endF,    200, 'end in payload')
      t.eq(mb.pathLen, 0,   'no path in payload (trim-only)')
    end,
  },
  {
    name = 'setName writes name onto cm and queues a name-only mailbox update',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.ds:assign('slotEntries', { [2] = { path = 'Continuum/snare.wav' } })
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      sm:setPrefix('/proj')

      sm:setName('t1', 2, 'Snare top')
      local entry = (h.ds:get('slotEntries') or {})[2]
      t.eq(entry.name, 'Snare top',           'name written')
      t.eq(entry.path, 'Continuum/snare.wav', 'path preserved')

      sm:tick()
      local mb = readMailbox(h, 0)
      t.eq(mb.seq,     1, 'seq bumped')
      t.eq(mb.pathLen, 0, 'no path in payload')
      t.eq(mb.nameLen, 9, '"Snare top" has 9 bytes')
      t.eq(mb.name,    'Snare top', 'name follows the (zero-length) path')
    end,
  },
  {
    name = 'tick rehydrates a track when boot-token first appears',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.ds:assign('slotEntries', {
        [0] = { path = 'Continuum/a.wav', name = 'a' },
        [3] = { path = 'Continuum/b.wav', name = 'b' },
      })
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      sm:setPrefix('/proj')

      plantBootToken(h, 0, 12345)
      sm:tick()
      local mb = readMailbox(h, 0)
      t.eq(mb.seq,  1, 'first drain after rehydrate')
      t.eq(mb.slot, 0, 'slot 0 first by byOrder')
      t.eq(mb.path, '/proj/Continuum/a.wav', 'abs path emitted')

      ackMailbox(h, 0)
      sm:tick()
      mb = readMailbox(h, 0)
      t.eq(mb.seq,  2, 'second drain')
      t.eq(mb.slot, 3, 'slot 3 next')
      t.eq(mb.path, '/proj/Continuum/b.wav', 'abs path emitted')

      ackMailbox(h, 0)
      sm:tick()
      t.eq(readMailbox(h, 0).seq, 2, 'no further drains; queue empty')
    end,
  },
  {
    name = 'tick rehydrates a non-active track via ds:getAt',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      bindSamplerTrack(h, 't2')
      h.reaper:setProjectTracks({ 't1', 't2' })
      h.cm:setTrack('t2')
      h.ds:assign('slotEntries', { [0] = { path = 'Continuum/two.wav', name = 'two' } })
      h.cm:setTrack('t1')   -- bound to t1, but t2 is the one we're rehydrating
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      sm:setPrefix('/proj')

      -- t2 takes instance id 1 (t1 takes 0 first via bindSamplerTrack order)
      h.reaper.GetSetMediaTrackInfo_String('t1', 'P_EXT:samplerInstanceId', '0', true)
      h.reaper.GetSetMediaTrackInfo_String('t2', 'P_EXT:samplerInstanceId', '1', true)
      plantBootToken(h, 1, 7777)

      sm:tick()
      local mb = readMailbox(h, 1)
      t.eq(mb.seq,  1,   't2 mailbox bumped')
      t.eq(mb.slot, 0,   't2 slot 0')
      t.eq(mb.path, '/proj/Continuum/two.wav', 't2 own entries pushed (not t1\'s)')
    end,
  },
  {
    name = 'tick refires rehydrate when boot-token changes',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.ds:assign('slotEntries', { [0] = { path = 'Continuum/a.wav' } })
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      sm:setPrefix('/proj')

      plantBootToken(h, 0, 1)
      sm:tick(); ackMailbox(h, 0)
      t.eq(readMailbox(h, 0).seq, 1, 'first rehydrate consumed')

      sm:tick(); ackMailbox(h, 0)
      t.eq(readMailbox(h, 0).seq, 1, 'no rehydrate on stable token')

      plantBootToken(h, 0, 2)   -- fresh-mem detected
      sm:tick(); ackMailbox(h, 0)
      t.eq(readMailbox(h, 0).seq, 2, 'rehydrate refired on token change')
    end,
  },
  {
    name = 'tick resets per-track state and refires rehydrate on FX-GUID change',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1', 'guid-old')
      h.ds:assign('slotEntries', { [0] = { path = 'Continuum/a.wav' } })
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      sm:setPrefix('/proj')

      plantBootToken(h, 0, 100)
      sm:tick(); ackMailbox(h, 0)
      t.eq(readMailbox(h, 0).path, '/proj/Continuum/a.wav',
           'first rehydrate emitted slot 0')

      -- Mutate cm so the second push is observably different. GUID change
      -- forces a reset of state.lastBootToken to 0 — so the still-nonzero
      -- token reads as new and rehydrate fires again.
      h.ds:assign('slotEntries', { [0] = { path = 'Continuum/b.wav' } })
      h.reaper:setFxGuid('t1', 'guid-new')
      sm:tick(); ackMailbox(h, 0)
      t.eq(readMailbox(h, 0).path, '/proj/Continuum/b.wav',
           'rehydrate refired with cm\'s new content after GUID change')
    end,
  },
  {
    name = 'syncSlot pushes cm truth back through the mailbox',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.ds:assign('slotEntries', {
        [3] = { path = 'Continuum/k.wav', name = 'k', start = 50, ['end'] = 99 },
      })
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      sm:setPrefix('/proj')

      sm:syncSlot('t1', 3)
      sm:tick()
      local mb = readMailbox(h, 0)
      t.eq(mb.slot,   3,                       'slot 3')
      t.eq(mb.op,     0,                       'op=0 (set)')
      t.eq(mb.startF, 50,                      'start from cm')
      t.eq(mb.endF,   99,                      'end from cm')
      t.eq(mb.path,   '/proj/Continuum/k.wav', 'abs path emitted')
    end,
  },
  {
    name = 'syncSlot of an empty cm slot queues a clear',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      sm:setPrefix('/proj')

      sm:syncSlot('t1', 5)
      sm:tick()
      local mb = readMailbox(h, 0)
      t.eq(mb.slot, 5, 'slot 5')
      t.eq(mb.op,   1, 'op=1 (clear)')
    end,
  },
  {
    name = 'tick drains at most one slot per call',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      sm:setPrefix('/proj')

      sm:setName('t1', 0, 'a')
      sm:setName('t1', 1, 'b')
      sm:setName('t1', 2, 'c')

      sm:tick(); local seq1 = readMailbox(h, 0).seq
      ackMailbox(h, 0)
      sm:tick(); local seq2 = readMailbox(h, 0).seq
      ackMailbox(h, 0)
      sm:tick(); local seq3 = readMailbox(h, 0).seq
      t.eq(seq1, 1, 'first drain bumps to 1')
      t.eq(seq2, 2, 'second drain bumps to 2')
      t.eq(seq3, 3, 'third drain bumps to 3 — one slot per tick')
    end,
  },
  {
    name = 'tick blocks a drain until the previous write is acked',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps(), h.cm, h.ds)
      sm:setPrefix('/proj')

      sm:setName('t1', 0, 'a')
      sm:setName('t1', 1, 'b')

      sm:tick()
      t.eq(readMailbox(h, 0).seq, 1, 'first drain')
      sm:tick()
      t.eq(readMailbox(h, 0).seq, 1, 'second drain blocked: seq != ack')
      ackMailbox(h, 0)
      sm:tick()
      t.eq(readMailbox(h, 0).seq, 2, 'second drain proceeds after ack')
    end,
  },
  {
    name = 'setPrefix updates abs composition for subsequent pushes',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps(), h.cm, h.ds)

      sm:setPrefix('/old')
      sm:loadSlot('t1', 0, 'Continuum/x.wav')
      sm:tick()
      t.eq(readMailbox(h, 0).path, '/old/Continuum/x.wav', 'composed against /old')

      ackMailbox(h, 0)
      sm:setPrefix('/new')
      sm:loadSlot('t1', 1, 'Continuum/y.wav')
      sm:tick()
      t.eq(readMailbox(h, 0).path, '/new/Continuum/y.wav', 'composed against /new')
    end,
  },
  {
    name = 'migrate moves bytes when project path changes',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.ds:assign('slotEntries', {
        [0] = { path = 'Continuum/k.wav' },
        [1] = { path = 'Continuum/s.wav' },
      })
      local ops = mkOps()
      local moved = newSampleManager(ops, h.cm, h.ds):migrate('/new', '/old')
      t.eq(moved, true, 'migrate reports work was done')
      t.eq(#ops.moves, 2, 'one move per entry')
      local seen = {}
      for _, m in ipairs(ops.moves) do seen[m[1]] = m[2] end
      t.eq(seen['/old/Continuum/k.wav'], '/new/Continuum/k.wav', 'slot 0 moved')
      t.eq(seen['/old/Continuum/s.wav'], '/new/Continuum/s.wav', 'slot 1 moved')
      t.eq((h.ds:get('slotEntries') or {})[0].path, 'Continuum/k.wav',
           'cm path unchanged (still relative)')
    end,
  },
  {
    name = 'migrate is a no-op when paths match or oldPath is nil',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.ds:assign('slotEntries', { [0] = { path = 'Continuum/k.wav' } })
      local ops = mkOps()
      local sm  = newSampleManager(ops, h.cm, h.ds)
      t.eq(sm:migrate('/proj', nil,    h.cm), false, 'nil oldPath = no-op')
      t.eq(sm:migrate('/proj', '/proj'), false, 'same path = no-op')
      t.eq(#ops.moves, 0, 'no moves issued')
    end,
  },
  {
    name = 'migrate walks every sampler track, not just the bound one',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setTrackFX('t1', { 'Continuum Sampler' })
      h.reaper:setTrackFX('t2', { 'Continuum Sampler' })
      h.reaper:setProjectTracks({ 't1', 't2' })
      h.cm:setTrack('t1')
      h.ds:assign('slotEntries', { [0] = { path = 'Continuum/a.wav' } })
      h.cm:setTrack('t2')
      h.ds:assign('slotEntries', { [0] = { path = 'Continuum/b.wav' } })
      local ops = mkOps()
      local moved = newSampleManager(ops, h.cm, h.ds):migrate('/new', '/old')
      t.eq(moved, true, 'work happened')
      t.eq(#ops.moves, 2, 'one move per sampler track')
      local seen = {}
      for _, m in ipairs(ops.moves) do seen[m[1]] = m[2] end
      t.truthy(seen['/old/Continuum/a.wav'], 't1 slot moved')
      t.truthy(seen['/old/Continuum/b.wav'], 't2 slot moved')
    end,
  },
  {
    name = 'watchPath sets prefix, writes breadcrumb, fires migrate on change',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.ds:assign('slotEntries', { [0] = { path = 'Continuum/k.wav' } })
      h.reaper:setProjectPath('/old')
      local ops = mkOps()
      local sm  = newSampleManager(ops, h.cm, h.ds)

      sm:watchPath()
      t.eq(h.cm:get('lastProjectPath'), '/old', 'breadcrumb stored on first run')
      t.eq(#ops.moves, 0, 'no prior breadcrumb → no migrate')

      h.reaper:setProjectPath('/new')
      sm:watchPath()
      t.eq(h.cm:get('lastProjectPath'), '/new', 'breadcrumb updated')
      t.eq(#ops.moves, 1, 'migrate fired on project-path change')
      t.eq(ops.moves[1][1], '/old/Continuum/k.wav', 'src is old root')
      t.eq(ops.moves[1][2], '/new/Continuum/k.wav', 'dst is new root')
    end,
  },
}
