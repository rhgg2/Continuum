local t   = require('support')
local DAG = require('DAG')

local function source(id, guid)
  return id, { kind = 'source', trackId = guid or 'guid-' .. id,
               pos = { x = 0, y = 0 },
               ports = { audio = { ins = 0, outs = 1 },
                         midi  = { ins = 0, outs = 1 } } }
end

local function fx(id, opts)
  opts = opts or {}
  return id, { kind = 'fx', pos = { x = 0, y = 0 },
               fxIdent   = opts.ident   or 'JS:test',
               fxDisplay = opts.display or 'FX',
               split     = opts.split or nil,
               ports = { audio = { ins  = opts.ins  or 1,
                                   outs = opts.outs or 1 },
                         midi  = { ins = 1, outs = 1 } } }
end

local function master(opts)
  opts = opts or {}
  return 'master', { kind = 'master', pos = { x = 0, y = 0 },
                     ports = { audio = { ins = opts.ins or 1, outs = 0 },
                               midi  = { ins = 0, outs = 0 } } }
end

local function mk(nodes, edges)
  if not nodes.master then
    local k, v = master(); nodes[k] = v
  end
  return { nodes = nodes, edges = edges or {}, nextId = 1 }
end

-- s1 -> a -> b -> master, s2 -> master. Two sources, so master's class
-- differs from the {s1} chain: marking b evicts it cleanly.
local function twoSourceChain(splitB)
  local ns = {}
  local k,  v  = source('s1', 'g1');         ns[k]  = v
  local k2, v2 = source('s2', 'g2');         ns[k2] = v2
  local k3, v3 = fx('a');                    ns[k3] = v3
  local k4, v4 = fx('b', { split = splitB }); ns[k4] = v4
  return mk(ns, {
    { type = 'audio', from = 's1', to = 'a' },
    { type = 'audio', from = 'a',  to = 'b' },
    { type = 'audio', from = 'b',  to = 'master' },
    { type = 'audio', from = 's2', to = 'master' },
  })
end

local function hasOutWire(entry, to, from)
  for _, w in ipairs(entry.outWires) do
    if w.to == to and w.from == from then return true end
  end
  return false
end

local function inList(list, id)
  for _, x in ipairs(list) do if x == id then return true end end
  return false
end

return {
  {
    name = 'unmarked: chain stays one class',
    run = function()
      local cls = DAG.compile(twoSourceChain(false)):classOf()
      t.eq(cls['a'], 'g1')
      t.eq(cls['b'], 'g1')
    end,
  },
  {
    name = 'split tag evicts the node into its own class',
    run = function()
      local cx  = DAG.compile(twoSourceChain(true))
      local cls = cx:classOf()
      t.eq(cls['a'], 'g1')
      t.eq(cls['b'], t.key('g1', 'split:b'))
    end,
  },
  {
    name = 'split-tagged class never absorbs into its single audio parent',
    run = function()
      -- b has exactly one audio parent (a); absent the guard it would auto-absorb
      -- back onto a's trackKey, undoing the split. classTrackKey unchanged → hosts itself.
      local rh = DAG.compile(twoSourceChain(true)):classTrackKey(t.key('g1', 'split:b'))
      t.eq(rh, t.key('g1', 'split:b'))
    end,
  },
  {
    name = 'targetTracks: cut edge is a send, cone is its own newTrack',
    run = function()
      local tracks = DAG.targetTracks(DAG.compile(twoSourceChain(true)))
      t.eq(tracks[t.key('g1', 'split:b')].trackKind, 'newTrack')
      t.truthy(hasOutWire(tracks['g1'], t.key('g1', 'split:b'), 'a'))
      t.truthy(tracks[t.key('g1', 'split:b')].mainSend)
    end,
  },
  {
    name = 'unmarked: a->b is intra-trackKey, no eviction',
    run = function()
      local tracks = DAG.targetTracks(DAG.compile(twoSourceChain(false)))
      t.falsy(tracks[t.key('g1', 'split:b')])
      local intra = false
      for _, c in ipairs(tracks['g1'].intraConns) do
        if c.from == 'a' and c.to == 'b' then intra = true end
      end
      t.truthy(intra)
    end,
  },
  {
    name = 'sole contributor to master re-merges (no eviction)',
    run = function()
      -- s -> a -> master, a marked. a's cone is master's only feed, so
      -- a and master share class 'g1|split:a'; a hosts on the master.
      local ns = {}
      local k,  v  = source('s', 'g1');          ns[k]  = v
      local k2, v2 = fx('a', { split = true });   ns[k2] = v2
      local cx  = DAG.compile(mk(ns, {
        { type = 'audio', from = 's', to = 'a' },
        { type = 'audio', from = 'a', to = 'master' },
      }))
      local cls = cx:classOf()
      t.eq(cls['a'], cls['master'])
      t.truthy(inList(DAG.targetTracks(cx)['__master__'].fxOrder, 'a'))
    end,
  },
  {
    name = 'validate rejects split on a source node',
    run = function()
      local ns = {}
      local k, v = source('s', 'g1'); ns[k] = v
      ns['s'].split = true
      t.eq(DAG.validate(mk(ns, {})).code, 'split_non_fx')
    end,
  },
  {
    name = 'validate rejects split on the master node',
    run = function()
      local ns = {}
      local k, v = source('s', 'g1'); ns[k] = v
      local g = mk(ns, {})
      g.nodes.master.split = true
      t.eq(DAG.validate(g).code, 'split_non_fx')
    end,
  },

  ----- master minimization (3c.4.3b)
  {
    name = 'multi-class sidechain stays on master (two ports, two hosts)',
    run = function()
      -- a (g1) -> f.p1, b (g2) -> f.p2, f -> master. Two different upstream
      -- hosts feed two ports — one pair each, no violation.
      local ns = {}
      local k, v
      k, v = source('s1', 'g1');   ns[k] = v
      k, v = source('s2', 'g2');   ns[k] = v
      k, v = fx('a');              ns[k] = v
      k, v = fx('b');              ns[k] = v
      k, v = fx('f', { ins = 2 }); ns[k] = v
      local cx = DAG.compile(mk(ns, {
        { type = 'audio', from = 's1', to = 'a' },
        { type = 'audio', from = 's2', to = 'b' },
        { type = 'audio', from = 'a',  to = 'f', toPort = 1 },
        { type = 'audio', from = 'b',  to = 'f', toPort = 2 },
        { type = 'audio', from = 'f',  to = 'master' },
      }))
      t.eq(cx:classOf()['f'], cx:classOf()['master'])
    end,
  },
  {
    name = 'same-trackKey two ports: split at the post-dominator below the violator',
    run = function()
      -- u (g1) feeds f.p1 and f.p2 (violation); s2 (g2) feeds f.p3 so f and master both see {g1,g2}.
      -- f->g->master so f's ipdom is g — the cut lands just below f.
      local ns = {}
      local k, v
      k, v = source('s1', 'g1');   ns[k] = v
      k, v = source('s2', 'g2');   ns[k] = v
      k, v = fx('u');              ns[k] = v
      k, v = fx('f', { ins = 3 }); ns[k] = v
      k, v = fx('g');              ns[k] = v
      local cx = DAG.compile(mk(ns, {
        { type = 'audio', from = 's1', to = 'u' },
        { type = 'audio', from = 'u',  to = 'f', toPort = 1 },
        { type = 'audio', from = 'u',  to = 'f', toPort = 2 },
        { type = 'audio', from = 's2', to = 'f', toPort = 3 },
        { type = 'audio', from = 'f',  to = 'g' },
        { type = 'audio', from = 'g',  to = 'master' },
      }))
      t.eq(cx:classOf()['g'], cx:classOf()['master'])
      t.truthy(cx:classOf()['f'] ~= cx:classOf()['master'])
      t.eq(DAG.targetTracks(cx)[cx:classOf()['f']].trackKind, 'newTrack')
    end,
  },
  {
    name = 'disjoint paths to master: marker lands on the master node',
    run = function()
      -- f violates (u feeds p1,p2); two disjoint paths f->x->master and f->y->master
      -- so the post-dominator is master itself and the master class collapses to {master}.
      local ns = {}
      local k, v
      k, v = source('s1', 'g1');   ns[k] = v
      k, v = source('s2', 'g2');   ns[k] = v
      k, v = fx('u');              ns[k] = v
      k, v = fx('f', { ins = 3 }); ns[k] = v
      k, v = fx('x');              ns[k] = v
      k, v = fx('y');              ns[k] = v
      local cx = DAG.compile(mk(ns, {
        { type = 'audio', from = 's1', to = 'u' },
        { type = 'audio', from = 'u',  to = 'f', toPort = 1 },
        { type = 'audio', from = 'u',  to = 'f', toPort = 2 },
        { type = 'audio', from = 's2', to = 'f', toPort = 3 },
        { type = 'audio', from = 'f',  to = 'x' },
        { type = 'audio', from = 'f',  to = 'y' },
        { type = 'audio', from = 'x',  to = 'master' },
        { type = 'audio', from = 'y',  to = 'master' },
      }))
      t.eq(cx:classOf()['master'], t.key('g1', 'g2', 'split:master'))
    end,
  },
  {
    name = 'dead-end violator off the cone lands on its own track',
    run = function()
      -- f violates (u feeds p1,p2), is master-hosted, but feeds nothing. The cut
      -- rides master's dominator z; f, off the cone, peels onto its own 'g1|g2' track.
      local ns = {}
      local k, v
      k, v = source('s1', 'g1');            ns[k] = v
      k, v = source('s2', 'g2');            ns[k] = v
      k, v = fx('u');                       ns[k] = v
      k, v = fx('f', { ins = 3, outs = 0 }); ns[k] = v
      k, v = fx('z', { ins = 2 });          ns[k] = v
      local cx = DAG.compile(mk(ns, {
        { type = 'audio', from = 's1', to = 'u' },
        { type = 'audio', from = 'u',  to = 'f', toPort = 1 },
        { type = 'audio', from = 'u',  to = 'f', toPort = 2 },
        { type = 'audio', from = 's2', to = 'f', toPort = 3 },
        { type = 'audio', from = 's1', to = 'z', toPort = 1 },
        { type = 'audio', from = 's2', to = 'z', toPort = 2 },
        { type = 'audio', from = 'z',  to = 'master' },
      }))
      t.eq(cx:classOf()['f'], t.key('g1', 'g2'))
      t.truthy(cx:classOf()['f'] ~= cx:classOf()['master'])
    end,
  },
  {
    name = 'off-cone parallel mixer is evicted (not a single-entry cone)',
    run = function()
      -- s1,s2 feed master directly AND via y; neither path crosses y, so master
      -- has no fx dominator. y shares master's srcSet yet peels onto its own track.
      local ns = {}
      local k, v
      k, v = source('s1', 'g1');   ns[k] = v
      k, v = source('s2', 'g2');   ns[k] = v
      k, v = fx('y', { ins = 2 }); ns[k] = v
      local cx = DAG.compile(mk(ns, {
        { type = 'audio', from = 's1', to = 'master' },
        { type = 'audio', from = 's2', to = 'master' },
        { type = 'audio', from = 's1', to = 'y', toPort = 1 },
        { type = 'audio', from = 's2', to = 'y', toPort = 2 },
        { type = 'audio', from = 'y',  to = 'master' },
      }))
      t.eq(cx:classOf()['master'], t.key('g1', 'g2', 'split:master'))
      t.truthy(cx:classOf()['y'] ~= cx:classOf()['master'])
      t.eq(DAG.targetTracks(cx)[cx:classOf()['y']].trackKind, 'newTrack')
    end,
  },
}
