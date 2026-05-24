local t   = require('support')
local DAG = require('DAG')

local function source(id, guid)
  return id, { kind = 'source', trackGuid = guid or 'guid-' .. id,
               pos = { x = 0, y = 0 } }
end

local function fx(id, opts)
  opts = opts or {}
  return id, { kind = 'fx', pos = { x = 0, y = 0 },
               fxIdent   = opts.ident   or 'JS:test',
               fxDisplay = opts.display or 'FX',
               audio = { ins  = opts.ins  or 1,
                         outs = opts.outs or 1 } }
end

local function master(opts)
  opts = opts or {}
  return 'master', { kind = 'master', pos = { x = 0, y = 0 },
                     audio = { ins = opts.ins or 1 } }
end

local function mk(nodes, edges)
  if not nodes.master then
    local k, v = master(); nodes[k] = v
  end
  return { nodes = nodes, edges = edges or {}, _nextId = 1 }
end

local function hasConn(conns, want)
  for _, c in ipairs(conns) do
    local match = true
    for k, v in pairs(want) do
      if c[k] ~= v then match = false; break end
    end
    if match then return true end
  end
  return false
end

local function cuCount(nodes, mode)
  local n = 0
  for _, node in pairs(nodes) do
    if node.kind == 'cu' and (mode == nil or node.cuMode == mode) then
      n = n + 1
    end
  end
  return n
end

return {
  {
    name = 'empty graph lowers to empty conns',
    run = function()
      local c = DAG.lower(mk({}))
      t.eq(#c.conns, 0)
      t.truthy(c.nodes.master, 'master preserved')
    end,
  },
  {
    name = 'audio passthrough: one port-to-port conn, no CU nodes',
    run = function()
      local ns = {}
      local k, v   = source('s'); ns[k] = v
      local k2, v2 = fx('f');     ns[k2] = v2
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
      }))
      t.eq(#c.conns, 1)
      t.truthy(hasConn(c.conns, { from = 's', fromPort = 1, to = 'f', toPort = 1 }))
      t.eq(cuCount(c.nodes), 0)
    end,
  },
  {
    name = 'gain op materialises a CU gain node spliced into the wire',
    run = function()
      local ns = {}
      local k, v   = source('s'); ns[k] = v
      local k2, v2 = fx('f');     ns[k2] = v2
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'f', ops = { gain = 0.5 } },
      }))
      t.eq(cuCount(c.nodes, 'gain'), 1)
      local gainId
      for id, node in pairs(c.nodes) do
        if node.cuMode == 'gain' then gainId = id end
      end
      t.eq(c.nodes[gainId].cuParams.gain, 0.5)
      t.eq(#c.conns, 2)
      t.truthy(hasConn(c.conns, { from = 's',    fromPort = 1, to = gainId, toPort = 1 }))
      t.truthy(hasConn(c.conns, { from = gainId, fromPort = 1, to = 'f',    toPort = 1 }))
    end,
  },
  {
    name = 'gain op preserves toPort routing on a multi-port-in fx',
    run = function()
      local ns = {}
      local k, v   = source('s');                  ns[k]  = v
      local k2, v2 = fx('f', { ins = 2 });         ns[k2] = v2
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'f', toPort = 2,
          ops = { gain = 0.25 } },
      }))
      t.eq(cuCount(c.nodes, 'gain'), 1)
      local gainId
      for id, node in pairs(c.nodes) do
        if node.cuMode == 'gain' then gainId = id end
      end
      t.eq(#c.conns, 2)
      t.truthy(hasConn(c.conns, { from = gainId, fromPort = 1, to = 'f', toPort = 2 }))
    end,
  },
  {
    name = 'midi passthrough: 1 midi conn, no CU',
    run = function()
      local ns = {}
      local k,  v  = source('s'); ns[k]  = v
      local k2, v2 = fx('f');     ns[k2] = v2
      local c = DAG.lower(mk(ns, {
        { type = 'midi', from = 's', to = 'f' },
      }))
      t.eq(#c.conns, 1)
      t.eq(c.conns[1].type, 'midi')
      t.eq(c.conns[1].from, 's')
      t.eq(c.conns[1].to,   'f')
      t.eq(cuCount(c.nodes), 0)
    end,
  },
  {
    name = 'channelMap op materialises a channelRemap CU on the MIDI wire',
    run = function()
      local ns = {}
      local k,  v  = source('s'); ns[k]  = v
      local k2, v2 = fx('f');     ns[k2] = v2
      local map = { [1] = 3, [2] = 4 }
      local c = DAG.lower(mk(ns, {
        { type = 'midi', from = 's', to = 'f', ops = { channelMap = map } },
      }))
      t.eq(cuCount(c.nodes, 'channelRemap'), 1)
      local remapId
      for id, node in pairs(c.nodes) do
        if node.cuMode == 'channelRemap' then remapId = id end
      end
      t.eq(c.nodes[remapId].cuParams.map, map)
      t.eq(#c.conns, 2)
      t.truthy(hasConn(c.conns, { type = 'midi', from = 's',     to = remapId }))
      t.truthy(hasConn(c.conns, { type = 'midi', from = remapId, to = 'f'     }))
    end,
  },
  {
    name = 'user nodes preserved (source trackGuid + fxIdent + master)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-aaa');          ns[k]  = v
      local k2, v2 = fx('f', { ident = 'VST:thing' }); ns[k2] = v2
      local c = DAG.lower(mk(ns, {}))
      t.eq(c.nodes.s.kind,      'source')
      t.eq(c.nodes.s.trackGuid, 'guid-aaa')
      t.eq(c.nodes.f.kind,      'fx')
      t.eq(c.nodes.f.fxIdent,   'VST:thing')
      t.eq(c.nodes.master.kind, 'master')
    end,
  },
  {
    name = 'audio wire to master lowers to one port-to-port conn',
    run = function()
      local ns = {}
      local k, v = source('s'); ns[k] = v
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'master' },
      }))
      t.eq(#c.conns, 1)
      t.truthy(hasConn(c.conns, { from = 's', fromPort = 1, to = 'master', toPort = 1 }))
    end,
  },
}
