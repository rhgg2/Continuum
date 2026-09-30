-- wm reads an fx node's midi ports from its plugin's resolved traits
-- (docs/fxCatalogue.md § Traits, docs/DAG.md): midi in gives the node a midi
-- in, midi out a midi out. So a midi out authored absent on a native plugin's
-- catalogue entry leaves its node without one, both at add and on a re-read.
local t    = require('support')
local util = require('util')

local COMP = { name = 'VST3: Comp (Acme)', ident = '/Library/Audio/Plug-Ins/VST3/Comp.vst3',
               key = 'Comp.vst3' }

local function mkWm(harness, entries)
  local h  = harness.mk()
  h.reaper:setInstalledFx({ { name = COMP.name, ident = COMP.ident } })
  h.reaper:setFxIO(COMP.ident, { ins = 2, outs = 2 })
  h.ds:assign('fxCatalogue', { n = 0, entries = entries })
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  wm:load()
  return wm
end

return {
  {
    name = 'a native plugin authored without midi out gets a node with no midi out, at add and on read',
    run = function(harness)
      local wm = mkWm(harness, { [COMP.key] = { traits = { midiOut = false } } })
      local id = wm:addFxNode(0, 0, { name = COMP.name, ident = COMP.ident })
      t.truthy(id, 'precondition: the node is added')
      t.deepEq(wm:graph().nodes[id].ports.midi, { ins = 1, outs = 0 }, 'at add')
      local read = wm:read().nodes[id]
      t.truthy(read, 'precondition: the read surfaces the node')
      t.deepEq(read.ports.midi, { ins = 1, outs = 0 }, 'on read')
    end,
  },
  {
    name = 'the same plugin with nothing authored keeps both midi ports',
    run = function(harness)
      local wm = mkWm(harness, {})
      local id = wm:addFxNode(0, 0, { name = COMP.name, ident = COMP.ident })
      t.deepEq(wm:graph().nodes[id].ports.midi, { ins = 1, outs = 1 })
    end,
  },
}
