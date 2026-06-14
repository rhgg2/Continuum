local t    = require('support')
local util = require('util')
local DAG  = require('DAG')

-- Family-level capacity bisection (design/archive/wiring-folders.md § Bus domains, step 4): a folder
-- family is ONE midi bus domain (the identity pipe is n->n). When its distinct child->parent-fx
-- crossings exceed 126 buses, the family cannot live as one domain, so `allocate` evicts segments
-- to top-level tracks (crossings re-expressed as explicit sends) until it fits. Two shapes:
--   * many single-fx children  -> whole-member eviction (no internal gap to cut)
--   * one deep-chain child      -> within-chain out-of-family bisection
-- Graph preservation under both is pinned by wm_roundtrip_spec; here we pin termination,
-- that eviction actually happens, and determinism.

local function source(guid, opts)
  opts = opts or {}
  return { kind = 'source', trackId = guid, parent = opts.parent, pos = { x = 0, y = 0 },
           ports = { audio = { ins = opts.ins or 0, outs = 1 },
                     midi  = { ins = opts.midiIns or 0, outs = 1 } } }
end

local function fx(ident)
  return { kind = 'fx', fxIdent = ident, fxDisplay = 'FX', pos = { x = 0, y = 0 },
           ports = { audio = { ins = 1, outs = 1 }, midi = { ins = 1, outs = 1 } } }
end

local function master()
  return { kind = 'master', pos = { x = 0, y = 0 },
           ports = { audio = { ins = 1, outs = 0 }, midi = { ins = 0, outs = 0 } } }
end

-- n single-fx children of one parent, each threading a distinct crossing gen_i -> cons_i through
-- the pipe. The cons_i form one linear fx chain ON the parent (so every crossing lands on a family
-- member); all n stay live into the parent block, so n past 126 overflows the one family domain.
local function nChildFamily(n)
  local g = { nextId = 1, nodes = { p = source('guid-P', { ins = 1 }), master = master() }, edges = {} }
  local prevCons = 'p'
  for i = 1, n do
    local sa, gen, cons = 'sa' .. i, 'gen' .. i, 'cons' .. i
    g.nodes[sa]   = source('guid-A' .. i, { parent = 'p' })
    g.nodes[gen]  = fx('VST:Gen' .. i)
    g.nodes[cons] = fx('VST:Cons' .. i)
    util.add(g.edges, { type = 'audio', from = sa,       to = gen })
    util.add(g.edges, { type = 'midi',  from = sa,       to = gen })
    util.add(g.edges, { type = 'audio', from = gen,      to = 'p' })    -- conduit
    util.add(g.edges, { type = 'midi',  from = gen,      to = cons })   -- distinct crossing
    util.add(g.edges, { type = 'audio', from = prevCons, to = cons })   -- parent fx chain
    prevCons = cons
  end
  util.add(g.edges, { type = 'audio', from = prevCons, to = 'master' })
  return g
end

-- One child whose fx chain taps a distinct parent fx at every stage: n stages live at once.
local function deepChildFamily(n)
  local g = { nextId = 1, nodes = {
    p  = source('guid-P', { ins = 1 }),
    sa = source('guid-A', { parent = 'p' }),
    master = master(),
  }, edges = {} }
  util.add(g.edges, { type = 'audio', from = 'p', to = 'master' })
  local prev = 'sa'
  for i = 1, n do
    local gen, cons = 'gen' .. i, 'cons' .. i
    g.nodes[gen]  = fx('VST:Gen' .. i)
    g.nodes[cons] = fx('VST:Cons' .. i)
    util.add(g.edges, { type = 'audio', from = prev, to = gen })
    util.add(g.edges, { type = 'midi',  from = prev, to = gen })
    util.add(g.edges, { type = 'midi',  from = gen,  to = cons })   -- distinct tap
    util.add(g.edges, { type = 'audio', from = 'p',  to = cons })
    util.add(g.edges, { type = 'audio', from = cons, to = 'master' })
    prev = gen
  end
  util.add(g.edges, { type = 'audio', from = prev, to = 'p' })      -- conduit: chain tail to parent
  return g
end

local function allocOf(g) return DAG.allocate(DAG.targetTracks(DAG.compile(g)), g.nodes) end

local function trackCount(out)
  local n = 0
  for _ in pairs(out) do n = n + 1 end
  return n
end

return {
  {
    name = 'folder capacity: 130 single-fx children overflow one family, eviction resolves it',
    run = function()
      local g = nChildFamily(130)
      local base = trackCount(DAG.targetTracks(DAG.compile(g)))
      local out  = allocOf(g)
      t.truthy(trackCount(out) > base, 'family overflow forced out-of-family eviction (extra tracks)')
    end,
  },
  {
    name = 'folder capacity: a deep-chain child overflows and bisects out of the family',
    run = function()
      local g = deepChildFamily(130)
      local base = trackCount(DAG.targetTracks(DAG.compile(g)))
      local out  = allocOf(g)
      t.truthy(trackCount(out) > base, 'family overflow forced a within-chain out-of-family cut')
    end,
  },
  {
    name = 'folder capacity: family eviction is deterministic',
    run = function()
      t.deepEq(allocOf(nChildFamily(130)), allocOf(nChildFamily(130)))
      t.deepEq(allocOf(deepChildFamily(130)), allocOf(deepChildFamily(130)))
    end,
  },
}
