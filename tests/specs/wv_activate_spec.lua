local t    = require('support')
local util = require('util')

local function mkWv(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  local wv = util.instantiate('wiringView', { cm = h.cm, wm = wm })
  return h, wv
end

local function viewById(wv, id)
  for _, nv in ipairs(wv:nodeViews()) do
    if nv.id == id then return nv end
  end
end

return {
  {
    name = 'nodeView.activate = "fx" for a materialised plain fx node',
    run = function(harness)
      local _, wv = mkWv(harness)
      local id = wv:addFx(0, 0, { name = 'ReaEQ', ident = 'VST3:ReaEQ (Cockos)' })
      t.truthy(id)
      t.eq(viewById(wv, id).activate, 'fx', 'plain fx is float-its-window')
    end,
  },
  {
    name = 'nodeView.activate = "sampler" when fxDisplay names the Continuum Sampler',
    run = function(harness)
      local _, wv = mkWv(harness)
      local id = wv:addFx(0, 0, { name = 'Continuum Sampler', ident = 'VST3:Continuum Sampler' })
      t.truthy(id)
      t.eq(viewById(wv, id).activate, 'sampler', 'sampler dives to the sample page')
    end,
  },
  {
    name = 'master and source nodes are inert (activate = nil)',
    run = function(harness)
      local h, wv = mkWv(harness)
      h.reaper:setFxIO('VST3:Massive', { ins = 0, outs = 2 })  -- generator → auto-spawns a source
      t.truthy(wv:addFx(0, 0, { name = 'Massive', ident = 'VST3:Massive' }))
      local sourceId
      for id, n in pairs(wv:graph().nodes) do if n.kind == 'source' then sourceId = id end end
      t.eq(viewById(wv, 'master').activate, nil, 'master has nothing to activate')
      t.eq(viewById(wv, sourceId).activate, nil, 'source has nothing to activate')
    end,
  },
}
