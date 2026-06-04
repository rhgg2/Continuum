local t    = require('support')
local util = require('util')

local function mkWv(harness)
  local h  = harness.mk()
  local wv = util.instantiate('wiringView', { cm = h.cm })
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
      t.truthy(wv:addFx(0, 0, { name = 'ReaEQ', ident = 'VST3:ReaEQ (Cockos)' }))
      t.eq(viewById(wv, 'n1').activate, 'fx', 'plain fx is float-its-window')
    end,
  },
  {
    name = 'nodeView.activate = "sampler" when fxDisplay names the Continuum Sampler',
    run = function(harness)
      local _, wv = mkWv(harness)
      t.truthy(wv:addFx(0, 0, { name = 'Continuum Sampler', ident = 'VST3:Continuum Sampler' }))
      t.eq(viewById(wv, 'n1').activate, 'sampler', 'sampler dives to the sample page')
    end,
  },
  {
    name = 'master and source nodes are inert (activate = nil)',
    run = function(harness)
      local h, wv = mkWv(harness)
      h.reaper:setFxIO('VST3:Massive', { ins = 0, outs = 2 })  -- generator → auto-spawns a source
      t.truthy(wv:addFx(0, 0, { name = 'Massive', ident = 'VST3:Massive' }))
      t.eq(viewById(wv, 'master').activate, nil, 'master has nothing to activate')
      t.eq(viewById(wv, 'n2').activate,     nil, 'source has nothing to activate')
    end,
  },
}
