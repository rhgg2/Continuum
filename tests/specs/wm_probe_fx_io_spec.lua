local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  return h, wm
end

return {
  {
    name = 'instantiateFxOnScratch returns stereo-port counts (pins/2)',
    run = function(harness)
      local _, wm = mkWm(harness)
      reaper:setFxIO('VST3:Quad', { ins = 4, outs = 2 })
      local io = wm:instantiateFxOnScratch('VST3:Quad')
      t.eq(io.ins,  2, 'two stereo input ports from 4 pins')
      t.eq(io.outs, 1, 'one stereo output port from 2 pins')
    end,
  },
  {
    name = 'instantiateFxOnScratch reads in_pin_X / out_pin_X via TrackFX_GetNamedConfigParm',
    run = function(harness)
      local _, wm = mkWm(harness)
      reaper:setFxIO('VST3:Comp', {
        ins  = 4, outs = 2,
        inPinNames  = { 'Main L', 'Main R', 'Sidechain L', 'Sidechain R' },
        outPinNames = { 'Out L',  'Out R' },
      })
      local io = wm:instantiateFxOnScratch('VST3:Comp')
      t.deepEq(io.inNames,  { 'Main', 'Sidechain' }, 'L/R suffix stripped per stereo pair')
      t.deepEq(io.outNames, { 'Out' })
    end,
  },
  {
    name = 'instantiateFxOnScratch returns the live fxId (matches TrackFX_GetFXGUID on scratch)',
    run = function(harness)
      local _, wm = mkWm(harness)
      reaper:setFxIO('JS:thing', { ins = 2, outs = 2 })
      local io = wm:instantiateFxOnScratch('JS:thing')
      local scratch = reaper.GetTrack(0, 0)
      t.eq(io.fxId, reaper.TrackFX_GetFXGUID(scratch, 0), 'returned guid matches the live instance')
    end,
  },
  {
    name = 'instantiateFxOnScratch KEEPS the instance (no TrackFX_Delete; count stays at 1)',
    run = function(harness)
      local _, wm = mkWm(harness)
      reaper:setFxIO('JS:keep', { ins = 2, outs = 2 })
      wm:instantiateFxOnScratch('JS:keep')
      local scratch = reaper.GetTrack(0, 0)
      t.eq(reaper.TrackFX_GetCount(scratch), 1, 'instance persists on scratch')
    end,
  },
  {
    name = 'instantiateFxOnScratch does not cache: each call mints a fresh instance',
    run = function(harness)
      local _, wm = mkWm(harness)
      reaper:setFxIO('JS:thing', { ins = 2, outs = 2 })
      local io1 = wm:instantiateFxOnScratch('JS:thing')
      local io2 = wm:instantiateFxOnScratch('JS:thing')
      local scratch = reaper.GetTrack(0, 0)
      t.eq(reaper.TrackFX_GetCount(scratch), 2, 'two distinct instances on scratch')
      t.truthy(io1.fxId ~= io2.fxId, 'distinct fxGuids')
    end,
  },
  {
    name = 'instantiateFxOnScratch on unknown ident (AddByName returns -1) gives fxId=nil, ins=outs=0',
    run = function(harness)
      local _, wm = mkWm(harness)
      reaper.TrackFX_AddByName = function() return -1 end
      local io = wm:instantiateFxOnScratch('VST3:Missing')
      t.eq(io.fxId, nil)
      t.eq(io.ins,  0)
      t.eq(io.outs, 0)
      t.deepEq(io.inNames,  {})
      t.deepEq(io.outNames, {})
    end,
  },
  {
    name = 'instantiateFxOnScratch triggers scratch creation lazily when load was skipped',
    run = function(harness)
      local _, wm = mkWm(harness)
      reaper:setFxIO('JS:lazy', { ins = 2, outs = 2 })
      t.eq(reaper.CountTracks(0), 0)
      wm:instantiateFxOnScratch('JS:lazy')
      t.eq(reaper.CountTracks(0), 1, 'instantiate created the scratch on demand')
    end,
  },
  {
    name = 'addFx writes probed ins/outs + per-port names onto the node',
    run = function(harness)
      local h = harness.mk()
      local rm = util.instantiate('routingManager', { ds = h.ds })
      local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
      local wv = util.instantiate('wiringView', { cm = h.cm, wm = wm })
      reaper:setFxIO('VST3:Comp', {
        ins  = 4, outs = 2,
        inPinNames  = { 'Main L', 'Main R', 'Sidechain L', 'Sidechain R' },
        outPinNames = { 'Out L',  'Out R' },
      })
      local id = wv:addFx(0, 0, { name = 'Comp', ident = 'VST3:Comp' })
      local n = wv:graph().nodes[id]
      t.eq(n.ports.audio.ins,  2)
      t.eq(n.ports.audio.outs, 1)
      t.deepEq(n.ports.audio.inNames,  { 'Main', 'Sidechain' })
      t.deepEq(n.ports.audio.outNames, { 'Out' })
    end,
  },
  {
    name = 'addFxNode records one use of the plugin, with its ports, in the catalogue',
    run = function(harness)
      local h, wm = mkWm(harness)
      local ident = '/Library/Audio/Plug-Ins/VST3/Effects/EQ/Canvas Audio - 8K.vst3'
      reaper:setInstalledFx({ { name = 'VST3: 8K (Canvas Audio)', ident = ident } })
      reaper:setFxIO(ident, { ins = 4, outs = 2 })
      local id = wm:addFxNode(0, 0, { name = 'VST3: 8K (Canvas Audio)', ident = ident })
      t.truthy(id, 'precondition: the fx was added')
      local catalogue = h.ds:get('fxCatalogue')
      t.truthy(catalogue, 'the add wrote the catalogue')
      t.eq(catalogue.n, 1, 'one bump per add')
      local entry = catalogue.entries['Canvas_Audio___8K.vst3']
      t.deepEq(entry.ports, { ins = 2, outs = 1 }, 'stereo ports, pins/2')
      t.deepEq(entry.usage, { s = 1, n0 = 1 })
    end,
  },
}
