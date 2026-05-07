-- Pin tests for slot persistence and the gmem mailbox protocol on
-- sampleManager. cm is real; fileOps is a call-recording stub so we
-- can verify side-effects without disk I/O. gmem calls are captured by
-- fakeReaper. Tracks are opaque tokens; the harness puts the sampler
-- FX on each so getInstanceId resolves cleanly.

local t = require('support')
require('fs')
require('sampleManager')

local MAGIC = 1717658484  -- 'CTML' as 32-bit ASCII; mirrors sampleManager constant

-- gmem layout — kept in sync with sampleManager.lua and the JSFX.
local LOAD_BASE     = 0
local PREVIEW_BASE  = 1024
local PREFIX_BASE   = 2048
local TRIM_BASE     = 3072

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

-- Plant a sampler FX on track and register it with the project so
-- listTracks/getInstanceId can find it.
local function bindSamplerTrack(h, track)
  h.reaper:setTrackFX(track, { 'Continuum Sampler' })
  h.reaper:setProjectTracks({ track })
end

return {
  {
    name = 'slotEntries default is an empty table per call',
    run = function(harness)
      local h = harness.mk()
      local a = h.cm:get('slotEntries')
      a[0] = { path = 'leak' }
      local b = h.cm:get('slotEntries')
      t.eq(b[0], nil, 'mutation of returned table does not pollute cm')
    end,
  },
  {
    name = 'slotEntries round-trips through track ext-state',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('track', 'slotEntries', { [3] = { path = 'Continuum/k.wav' } })
      local cm2 = newConfigManager()
      cm2:setContext('take1')
      t.eq(cm2:get('slotEntries')[3].path, 'Continuum/k.wav', 'rehydrated from track P_EXT')
    end,
  },
  {
    name = 'getInstanceId assigns next-free, persists P_EXT, pushes slider',
    run = function(harness)
      local h  = harness.mk()
      bindSamplerTrack(h, 't1')
      local sm = newSampleManager(mkOps())
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
      local sm = newSampleManager(mkOps())
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
      local sm = newSampleManager(mkOps())
      t.eq(sm:getInstanceId('t2'), 1, 'next-free id around taken=0')
    end,
  },
  {
    name = 'getInstanceId returns nil for tracks lacking the sampler FX',
    run = function(harness)
      local h  = harness.mk()
      h.reaper:setTrackFX('t1', { 'SomeOther' })
      local sm = newSampleManager(mkOps())
      t.eq(sm:getInstanceId('t1'), nil, 'no FX → no id')
    end,
  },
  {
    name = 'assign copies, writes cm, arms the gmem load mailbox with target_id',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      local ops = mkOps()
      local sm  = newSampleManager(ops)

      local ok = sm:assign('t1', 5, '/disk/kick.wav', '/proj', h.cm)
      t.truthy(ok, 'returns true on success')

      t.eq(#ops.mkdirs, 1, 'one mkdir')
      t.eq(ops.mkdirs[1], '/proj/Continuum', 'mkdir targets Continuum subdir')

      t.eq(#ops.copies, 1, 'one copy')
      t.eq(ops.copies[1][1], '/disk/kick.wav', 'copy src is the source path')
      t.truthy(ops.copies[1][2]:match('^/proj/Continuum/kick%-%x+%.wav$'),
        'copy dst is /proj/Continuum/kick-<rand>.wav, got ' .. ops.copies[1][2])

      local entry = h.cm:get('slotEntries')[5]
      t.truthy(entry, 'cm has slot 5')
      t.truthy(entry.path:match('^Continuum/kick%-%x+%.wav$'),
        'cm path is project-relative, got ' .. tostring(entry.path))

      t.eq(h.reaper.gmem_read(LOAD_BASE),     MAGIC, 'load mailbox armed')
      t.eq(h.reaper.gmem_read(LOAD_BASE + 1), 0,     'target_id at [+1] = 0')
      t.eq(h.reaper.gmem_read(LOAD_BASE + 2), 5,     'slot index at [+2]')
      t.truthy(h.reaper:gmemString(LOAD_BASE + 3):match('^Continuum/kick%-%x+%.wav$'),
        'rel path at [+3..]')
    end,
  },
  {
    name = 'assign returns false on copy failure, leaves cm and gmem untouched',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      local ops = mkOps()
      ops.copyResult = false
      local sm = newSampleManager(ops)

      t.eq(sm:assign('t1', 2, '/disk/missing.wav', '/proj', h.cm), false, 'returns false')
      t.eq(h.cm:get('slotEntries')[2], nil, 'no cm entry written')
      t.eq(h.reaper.gmem_read(LOAD_BASE), 0, 'mailbox not armed')
    end,
  },
  {
    name = 'assign preserves other slot fields when overwriting path',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.cm:set('track', 'slotEntries',
        { [4] = { path = 'Continuum/old.wav', shStart = 100 } })
      local sm = newSampleManager(mkOps())

      sm:assign('t1', 4, '/disk/new.wav', '/proj', h.cm)
      local entry = h.cm:get('slotEntries')[4]
      t.eq(entry.shStart, 100, 'shStart survived re-assign')
      t.truthy(entry.path:match('^Continuum/new%-'), 'path was overwritten')
    end,
  },
  {
    name = 'stageInto copies + arms mailbox, returns rel, but does not touch cm',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      local ops = mkOps()
      local sm  = newSampleManager(ops)

      local rel = sm:stageInto('t1', 7, '/disk/snare.wav', '/proj')
      t.truthy(rel and rel:match('^Continuum/snare%-%x+%.wav$'),
        'returned rel path, got ' .. tostring(rel))
      t.eq(#ops.copies, 1, 'one copy issued')
      t.eq(h.reaper.gmem_read(LOAD_BASE),     MAGIC, 'load mailbox armed')
      t.eq(h.reaper.gmem_read(LOAD_BASE + 1), 0,     'target_id stamped')
      t.eq(h.reaper.gmem_read(LOAD_BASE + 2), 7,     'slot index written')
      t.eq(h.cm:get('slotEntries')[7], nil, 'cm slotEntries untouched')
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
      local sm = newSampleManager(ops)
      t.eq(sm:stageInto('t1', 2, '/disk/x.wav', '/proj'), nil, 'returned nil')
      t.eq(h.reaper.gmem_read(LOAD_BASE), 0, 'mailbox not armed')
    end,
  },
  {
    name = 'unloadSlot writes the empty-path sentinel without touching cm',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.cm:set('track', 'slotEntries', { [3] = { path = 'Continuum/k.wav' } })
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps())

      t.eq(sm:unloadSlot('t1', 3), true, 'returns true')
      t.eq(h.reaper.gmem_read(LOAD_BASE),     MAGIC, 'mailbox armed')
      t.eq(h.reaper.gmem_read(LOAD_BASE + 1), 0,     'target_id at [+1]')
      t.eq(h.reaper.gmem_read(LOAD_BASE + 2), 3,     'slot at [+2]')
      t.eq(h.reaper.gmem_read(LOAD_BASE + 3), 0,     'path byte 0 = sentinel')
      t.eq(h.cm:get('slotEntries')[3].path, 'Continuum/k.wav',
           'cm slotEntries untouched by unloadSlot')
    end,
  },
  {
    name = 'previewSlot stamps target_id alongside slot and bounds',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps())
      t.eq(sm:previewSlot('t1', 9, 1), true)
      t.eq(h.reaper.gmem_read(PREVIEW_BASE),     MAGIC)
      t.eq(h.reaper.gmem_read(PREVIEW_BASE + 1), 0, 'target_id at [+1]')
      t.eq(h.reaper.gmem_read(PREVIEW_BASE + 2), 9, 'slot at [+2]')
      t.eq(h.reaper.gmem_read(PREVIEW_BASE + 3), 1, 'bounds at [+3]')
    end,
  },
  {
    name = 'setTrim stamps target_id and writes seq/slot/start/end',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      local sm = newSampleManager(mkOps())
      t.eq(sm:setTrim('t1', 4, 100, 200), true)
      t.truthy(h.reaper.gmem_read(TRIM_BASE) > 0, 'seq monotonic, > 0')
      t.eq(h.reaper.gmem_read(TRIM_BASE + 1), 0,   'target_id at [+1]')
      t.eq(h.reaper.gmem_read(TRIM_BASE + 2), 4,   'slot at [+2]')
      t.eq(h.reaper.gmem_read(TRIM_BASE + 3), 100, 'start at [+3]')
      t.eq(h.reaper.gmem_read(TRIM_BASE + 4), 200, 'end at [+4]')
    end,
  },
  {
    name = 'sweep replays every entry through the gmem load mailbox',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.cm:set('track', 'slotEntries', {
        [0] = { path = 'Continuum/a.wav' },
        [3] = { path = 'Continuum/b.wav' },
      })
      local sm = newSampleManager(mkOps())

      -- sweep fires loadSlot twice; the second call overwrites the mailbox.
      -- We can only inspect the final state, so just verify it was armed.
      sm:sweep('t1', h.cm)
      t.eq(h.reaper.gmem_read(LOAD_BASE), MAGIC, 'mailbox armed after sweep')
    end,
  },
  {
    name = 'sweep skips entries with no path',
    run = function(harness)
      local h = harness.mk()
      bindSamplerTrack(h, 't1')
      h.reaper:clearGmem()
      h.cm:set('track', 'slotEntries', { [1] = { shStart = 50 } })
      newSampleManager(mkOps()):sweep('t1', h.cm)
      t.eq(h.reaper.gmem_read(LOAD_BASE), 0, 'mailbox not armed for pathless entry')
    end,
  },
  {
    name = 'migrate moves bytes when project path changes',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('track', 'slotEntries', {
        [0] = { path = 'Continuum/k.wav' },
        [1] = { path = 'Continuum/s.wav' },
      })
      local ops = mkOps()
      local moved = newSampleManager(ops):migrate('/new', '/old', h.cm)
      t.eq(moved, true, 'migrate reports work was done')
      t.eq(#ops.moves, 2, 'one move per entry')
      local seen = {}
      for _, m in ipairs(ops.moves) do seen[m[1]] = m[2] end
      t.eq(seen['/old/Continuum/k.wav'], '/new/Continuum/k.wav', 'slot 0 moved')
      t.eq(seen['/old/Continuum/s.wav'], '/new/Continuum/s.wav', 'slot 1 moved')

      local entries = h.cm:get('slotEntries')
      t.eq(entries[0].path, 'Continuum/k.wav', 'cm path unchanged (still relative)')
    end,
  },
  {
    name = 'migrate is a no-op when paths match or oldPath is nil',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('track', 'slotEntries', { [0] = { path = 'Continuum/k.wav' } })
      local ops = mkOps()
      local sm  = newSampleManager(ops)

      t.eq(sm:migrate('/proj', nil,    h.cm), false, 'nil oldPath = no-op')
      t.eq(sm:migrate('/proj', '/proj', h.cm), false, 'same path = no-op')
      t.eq(#ops.moves, 0, 'no moves issued')
    end,
  },
}
