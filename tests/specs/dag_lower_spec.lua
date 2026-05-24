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
               audio = { ins  = opts.ins  or { 'L', 'R' },
                         outs = opts.outs or { 'L', 'R' } } }
end

local function master(opts)
  opts = opts or {}
  return 'master', { kind = 'master', pos = { x = 0, y = 0 },
                     audio = { ins = opts.ins or { 'L', 'R' } } }
end

local function mk(nodes, edges)
  if not nodes.master then
    local k, v = master(); nodes[k] = v
  end
  return { nodes = nodes, edges = edges or {}, _nextId = 1 }
end

-- conn predicate sugar: ignore unset fields on the spec side.
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

-- Count CU nodes by mode.
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
    name = 'stereo passthrough: 2 audio conns, no CU nodes',
    run = function()
      local ns = {}
      local k, v   = source('s'); ns[k] = v
      local k2, v2 = fx('f');     ns[k2] = v2
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
      }))
      t.eq(#c.conns, 2)
      t.truthy(hasConn(c.conns, { from = 's', fromCh = 1, to = 'f', toCh = 1 }))
      t.truthy(hasConn(c.conns, { from = 's', fromCh = 2, to = 'f', toCh = 2 }))
      t.eq(cuCount(c.nodes), 0)
    end,
  },
  {
    name = 'gain op materialises a stereo CU gain node',
    run = function()
      local ns = {}
      local k, v   = source('s'); ns[k] = v
      local k2, v2 = fx('f');     ns[k2] = v2
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'f', ops = { gain = 0.5 } },
      }))
      t.eq(cuCount(c.nodes, 'gain'), 1)
      -- find the gain node id
      local gainId
      for id, node in pairs(c.nodes) do
        if node.cuMode == 'gain' then gainId = id end
      end
      t.eq(c.nodes[gainId].cuParams.gain,     0.5)
      t.eq(c.nodes[gainId].cuParams.channels, 2)
      t.eq(#c.conns, 4)  -- src→gain (2) + gain→fx (2)
      t.truthy(hasConn(c.conns, { from = 's',    fromCh = 1, to = gainId, toCh = 1 }))
      t.truthy(hasConn(c.conns, { from = 's',    fromCh = 2, to = gainId, toCh = 2 }))
      t.truthy(hasConn(c.conns, { from = gainId, fromCh = 1, to = 'f',    toCh = 1 }))
      t.truthy(hasConn(c.conns, { from = gainId, fromCh = 2, to = 'f',    toCh = 2 }))
    end,
  },
  {
    name = 'stereo → mono port inserts a monoSum adapter',
    run = function()
      local ns = {}
      local k, v   = source('s');                          ns[k]  = v
      local k2, v2 = fx('f', { ins = { 'L', 'R', 'C' } }); ns[k2] = v2
      -- pair 2 on fx is the mono trailing-odd pair (channel 3).
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'f', toPort = 2 },
      }))
      t.eq(cuCount(c.nodes, 'monoSum'), 1)
      local sumId
      for id, node in pairs(c.nodes) do
        if node.cuMode == 'monoSum' then sumId = id end
      end
      t.eq(#c.conns, 3)
      t.truthy(hasConn(c.conns, { from = 's',   fromCh = 1, to = sumId, toCh = 1 }))
      t.truthy(hasConn(c.conns, { from = 's',   fromCh = 2, to = sumId, toCh = 2 }))
      t.truthy(hasConn(c.conns, { from = sumId, fromCh = 1, to = 'f',   toCh = 3 }))
    end,
  },
  {
    name = 'mono → stereo port inserts a monoReplicate adapter',
    run = function()
      -- source → fx_a (5-channel outs: {L,R,L,R,C}; pair 3 mono) → fx_b (stereo)
      local ns = {}
      local k, v   = source('s'); ns[k] = v
      local k2, v2 = fx('a', { ins = { 'L', 'R' },
                               outs = { 'L', 'R', 'L', 'R', 'C' } }); ns[k2] = v2
      local k3, v3 = fx('b'); ns[k3] = v3
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'a' },
        { type = 'audio', from = 'a', to = 'b', fromPort = 3 },
      }))
      t.eq(cuCount(c.nodes, 'monoReplicate'), 1)
      local repId
      for id, node in pairs(c.nodes) do
        if node.cuMode == 'monoReplicate' then repId = id end
      end
      -- s→a (2) + a→rep (1 from ch 5) + rep→b (2)  = 5
      t.eq(#c.conns, 5)
      t.truthy(hasConn(c.conns, { from = 'a',   fromCh = 5, to = repId, toCh = 1 }))
      t.truthy(hasConn(c.conns, { from = repId, fromCh = 1, to = 'b',   toCh = 1 }))
      t.truthy(hasConn(c.conns, { from = repId, fromCh = 2, to = 'b',   toCh = 2 }))
    end,
  },
  {
    name = 'mono → mono needs no adapter',
    run = function()
      local ns = {}
      local k,  v  = fx('a', { ins = { 'L', 'R' },
                               outs = { 'L', 'R', 'C' } });             ns[k]  = v
      local k2, v2 = fx('b', { ins = { 'L', 'R', 'C' } });              ns[k2] = v2
      local k3, v3 = source('s');                                       ns[k3] = v3
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'a' },
        -- a's pair 2 mono (ch 3) → b's pair 2 mono (ch 3): no adapter.
        { type = 'audio', from = 'a', to = 'b', fromPort = 2, toPort = 2 },
      }))
      t.eq(cuCount(c.nodes), 0)
      t.truthy(hasConn(c.conns, { from = 'a', fromCh = 3, to = 'b', toCh = 3 }))
    end,
  },
  {
    name = 'gain + adapter chain: source → gain CU → monoSum CU → mono fx',
    run = function()
      local ns = {}
      local k,  v  = source('s');                          ns[k]  = v
      local k2, v2 = fx('f', { ins = { 'L', 'R', 'C' } }); ns[k2] = v2
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'f', toPort = 2,
          ops = { gain = 0.25 } },
      }))
      t.eq(cuCount(c.nodes, 'gain'),    1)
      t.eq(cuCount(c.nodes, 'monoSum'), 1)
      -- s→gain (2) + gain→sum (2) + sum→f (1) = 5
      t.eq(#c.conns, 5)
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
      local k,  v  = source('s', 'guid-aaa');         ns[k]  = v
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
    name = 'audio wire to master lowers to channel conns into master',
    run = function()
      local ns = {}
      local k, v = source('s'); ns[k] = v
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'master' },
      }))
      t.eq(#c.conns, 2)
      t.truthy(hasConn(c.conns, { from = 's', fromCh = 1, to = 'master', toCh = 1 }))
      t.truthy(hasConn(c.conns, { from = 's', fromCh = 2, to = 'master', toCh = 2 }))
    end,
  },
}
