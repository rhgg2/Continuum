local t   = require('support')
local DAG = require('DAG')

-- Stage 3c.5 — multi-audio-parent absorption, end to end (compile →
-- targetTracks → allocate). The pure :absorption() map is covered in
-- dag_absorption_spec; here a primary-elected parent hosts the absorbed
-- FX while every other audio parent feeds in as a channel-allocated send.
-- This is the path absorption opens only once channels exist: the absorbed
-- FX's primary input reads the trackKey's intra signal, the rest arrive on
-- distinct destination pairs.

local function source(id, guid)
  return id, { kind = 'source', trackId = guid or 'guid-' .. id,
               pos = { x = 0, y = 0 },
               ports = { audio = { ins = 0, outs = 1 },
                         midi  = { ins = 0, outs = 1 } } }
end

local function fx(id, opts)
  opts = opts or {}
  return id, { kind = 'fx', pos = { x = 0, y = 0 },
               fxIdent   = 'JS:test', fxDisplay = 'FX',
               ports = { audio = { ins  = opts.ins  or 1,
                                   outs = opts.outs or 1 },
                         midi  = { ins = 0, outs = 0 } } }
end

local function master(opts)
  opts = opts or {}
  return 'master', { kind = 'master', pos = { x = 0, y = 0 },
                     ports = { audio = { ins = opts.ins or 1, outs = 0 },
                               midi  = { ins = 0, outs = 0 } } }
end

local function mk(nodes, edges)
  if not nodes.master then local k, v = master(); nodes[k] = v end
  return { nodes = nodes, edges = edges or {}, nextId = 1 }
end

-- The whole compile pipeline a live recompile runs: tracks + channel alloc.
local function allocOf(g)
  local g0  = mk(g.nodes, g.edges)
  local ctx = DAG.compile(g0)
  return DAG.allocate(DAG.targetTracks(ctx), g0.nodes)
end

return {
  {
    name = 'two audio parents + primary: send lands on the absorbed FX second pin',
    run = function()
      local ns = {}
      local k1, v1 = source('s1', 'guid-s1'); ns[k1] = v1
      local k2, v2 = source('s2', 'guid-s2'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2, outs = 0 }); ns[k3] = v3
      local out = allocOf({ nodes = ns, edges = {
        { type = 'audio', from = 's1', to = 'mix', toPort = 1, primary = true },
        { type = 'audio', from = 's2', to = 'mix', toPort = 2 },
      } })
      -- mix hosts on guid-s1: primary pin reads the trackKey's track pair,
      -- the non-primary parent arrives as a send on a fresh pair.
      t.deepEq(out['guid-s1'].pinMaps.mix.ins, { [1] = {1}, [2] = {2} })
      t.eq(out['guid-s1'].nchan, 4)
      t.eq(out['guid-s1'].mainSend, false)
      -- The non-primary parent has no absorbed-class entry; it sends in.
      t.eq(out['guid-s1|guid-s2'], nil)
      t.eq(#out['guid-s2'].sends, 1)
      t.eq(out['guid-s2'].sends[1].to,      'guid-s1')
      t.eq(out['guid-s2'].sends[1].srcChan, 0)
      t.eq(out['guid-s2'].sends[1].dstChan, 2, 'lands on mix pin 2 (pair 2)')
      t.eq(out['guid-s2'].nchan, 2)
    end,
  },
  {
    name = 'three audio parents + primary: two sends claim distinct dest pairs',
    run = function()
      local ns = {}
      local k1, v1 = source('s1', 'guid-s1'); ns[k1] = v1
      local k2, v2 = source('s2', 'guid-s2'); ns[k2] = v2
      local k3, v3 = source('s3', 'guid-s3'); ns[k3] = v3
      local k4, v4 = fx('mix', { ins = 3, outs = 0 }); ns[k4] = v4
      local out = allocOf({ nodes = ns, edges = {
        { type = 'audio', from = 's1', to = 'mix', toPort = 1, primary = true },
        { type = 'audio', from = 's2', to = 'mix', toPort = 2 },
        { type = 'audio', from = 's3', to = 'mix', toPort = 3 },
      } })
      t.deepEq(out['guid-s1'].pinMaps.mix.ins, { [1] = {1}, [2] = {2}, [3] = {3} })
      t.eq(out['guid-s1'].nchan, 6)
      t.eq(out['guid-s2'].sends[1].dstChan, 2)
      t.eq(out['guid-s3'].sends[1].dstChan, 4)
    end,
  },
  {
    name = 'absorbed node feeds master: parentFeed on trackKey, non-primary parent sends in',
    run = function()
      -- s3 → master keeps master's class a strict superset of mix's, so mix
      -- stays newTrack-eligible and absorbs into guid-s1 rather than going
      -- master-hosted.
      local ns = {}
      local k1, v1 = source('s1', 'guid-s1'); ns[k1] = v1
      local k2, v2 = source('s2', 'guid-s2'); ns[k2] = v2
      local k3, v3 = source('s3', 'guid-s3'); ns[k3] = v3
      local k4, v4 = fx('mix', { ins = 2, outs = 1 }); ns[k4] = v4
      local out = allocOf({ nodes = ns, edges = {
        { type = 'audio', from = 's1',  to = 'mix', toPort = 1, primary = true },
        { type = 'audio', from = 's2',  to = 'mix', toPort = 2 },
        { type = 'audio', from = 'mix', to = 'master' },
        { type = 'audio', from = 's3',  to = 'master' },
      } })
      -- mix's output drives the parent send in place (offs 0, pair 1).
      t.deepEq(out['guid-s1'].pinMaps.mix.ins,  { [1] = {1}, [2] = {2} })
      t.deepEq(out['guid-s1'].pinMaps.mix.outs, { [1] = {1} })
      t.eq(out['guid-s1'].mainSend,     true)
      t.eq(out['guid-s1'].mainSendOffs, 0)
      t.eq(out['guid-s1'].parentFeed.from, 'mix')
      -- Non-primary audio parent still arrives as a send on pin 2.
      t.eq(out['guid-s2'].sends[1].to,      'guid-s1')
      t.eq(out['guid-s2'].sends[1].dstChan, 2)
      -- The unrelated source goes straight to master via its own parent send.
      t.eq(out['guid-s3'].mainSend, true)
      t.deepEq(out['guid-s3'].sends, {})
    end,
  },
  {
    name = 'gain on a non-primary parent folds onto the send (D_VOL), no trackKey CU',
    run = function()
      local ns = {}
      local k1, v1 = source('s1', 'guid-s1'); ns[k1] = v1
      local k2, v2 = source('s2', 'guid-s2'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2, outs = 0 }); ns[k3] = v3
      local out = allocOf({ nodes = ns, edges = {
        { type = 'audio', from = 's1', to = 'mix', toPort = 1, primary = true },
        { type = 'audio', from = 's2', to = 'mix', toPort = 2, ops = { gain = 0.5 } },
      } })
      t.eq(out['guid-s2'].sends[1].gain, 0.5, 'gain rides the send, not a CU')
      t.deepEq(out['guid-s1'].fxOrder, { 'mix' }, 'no merge CU on the trackKey chain')
    end,
  },
  {
    name = 'two-hop primary chain: both FX collapse to the terminal trackKey, sends retarget',
    run = function()
      -- s primary into mixA, t the non-primary; mixA primary into mixB, u the
      -- non-primary. Both hops absorb, so mixA+mixB land on guid-s and t/u
      -- retarget their sends to it.
      local ns = {}
      local k1, v1 = source('s', 'guid-s'); ns[k1] = v1
      local k2, v2 = source('t', 'guid-t'); ns[k2] = v2
      local k3, v3 = source('u', 'guid-u'); ns[k3] = v3
      local k4, v4 = fx('mixA', { ins = 2, outs = 1 }); ns[k4] = v4
      local k5, v5 = fx('mixB', { ins = 2, outs = 0 }); ns[k5] = v5
      local out = allocOf({ nodes = ns, edges = {
        { type = 'audio', from = 's',    to = 'mixA', toPort = 1, primary = true },
        { type = 'audio', from = 't',    to = 'mixA', toPort = 2 },
        { type = 'audio', from = 'mixA', to = 'mixB', toPort = 1, primary = true },
        { type = 'audio', from = 'u',    to = 'mixB', toPort = 2 },
      } })
      t.deepEq(out['guid-s'].fxOrder, { 'mixA', 'mixB' })
      -- mixA's output feeds mixB's primary pin in place (pair 1).
      t.deepEq(out['guid-s'].pinMaps.mixA.outs, { [1] = {1} })
      t.deepEq(out['guid-s'].pinMaps.mixB.ins[1], {1})
      -- The two non-primary parents arrive on separate pairs.
      t.eq(out['guid-t'].sends[1].to,      'guid-s')
      t.eq(out['guid-u'].sends[1].to,      'guid-s')
      t.eq(out['guid-t'].sends[1].dstChan, 2)
      t.eq(out['guid-u'].sends[1].dstChan, 4)
      t.eq(out['guid-u'].sends[1].dstChan ~= out['guid-t'].sends[1].dstChan, true)
    end,
  },
}
