local t   = require('support')
local DAG = require('DAG')

-- Folder-parent MIDI conduit (compile side): a foldered child sending audio + midi to
-- its parent rides B_MAINSEND atomically. The midi must NOT become a second explicit
-- send (it would collide with the un-gateable identity pipe). See design/wiring-folders.md § 3b.

local function source(guid, opts)
  opts = opts or {}
  return { kind = 'source', trackId = guid, parent = opts.parent, pos = { x = 0, y = 0 },
           ports = { audio = { ins = opts.ins or 0, outs = 1 },
                     midi  = { ins = opts.midiIns or 0, outs = 1 } } }
end

local function fx(opts)
  opts = opts or {}
  return { kind = 'fx', fxIdent = opts.ident or 'JS:test', fxDisplay = 'FX', pos = { x = 0, y = 0 },
           ports = { audio = { ins = opts.ins or 1, outs = opts.outs or 1 },
                     midi  = { ins = 1, outs = 1 } } }
end

local function master()
  return { kind = 'master', pos = { x = 0, y = 0 },
           ports = { audio = { ins = 1, outs = 0 }, midi = { ins = 0, outs = 0 } } }
end

local function tracksOf(g) return DAG.targetTracks(DAG.compile(g)) end
local function allocOf(g) return DAG.allocate(DAG.targetTracks(DAG.compile(g)), g.nodes) end

local function midiOutWires(entry)
  local out = {}
  for _, w in ipairs(entry.outWires or {}) do
    if w.type == 'midi' then table.insert(out, w) end
  end
  return out
end

return {
  {
    -- The child audio-sums into the parent (conduit) and its midi hits a parent-resident fx.
    -- Both ride the one B_MAINSEND: the midi is pipe traffic, not an explicit send.
    name = 'folder midi: child audio+midi to parent rides the pipe, no explicit midi send',
    run = function()
      local g = { nextId = 1, nodes = {
        sa  = source('guid-A', { parent = 'p' }),
        p   = source('guid-P', { ins = 1, midiIns = 1 }),
        arp = fx({ ident = 'VST:Arp' }),
        master = master(),
      }, edges = {
        { type = 'audio', from = 'sa',  to = 'p'      },
        { type = 'midi',  from = 'sa',  to = 'arp'    },
        { type = 'audio', from = 'p',   to = 'arp'    },
        { type = 'audio', from = 'arp', to = 'master' },
      } }
      local tracks = tracksOf(g)
      local child = tracks['guid-A']
      t.eq(child.mainSend, true, 'child audio rides B_MAINSEND to the parent')
      t.deepEq(midiOutWires(child), {}, 'child midi rides the pipe, not a second send')
      t.deepEq(child.pipeMidi, { { from = 'sa', consumer = 'arp' } },
        'distinct crossing recorded for the family allocator (consumer is the parent fx)')
    end,
  },
  {
    -- The child's tail midi merges into the parent's bus-0 aggregate (native folder merge): the
    -- edge targets the parent source node, so it drops to no send and records as a merge crossing.
    name = 'folder midi: child midi into the parent node is a bus-0 merge, no send',
    run = function()
      local g = { nextId = 1, nodes = {
        sa = source('guid-A', { parent = 'p' }),
        p  = source('guid-P', { ins = 1, midiIns = 1 }),
        eq = fx({ ident = 'VST:EQ' }),
        master = master(),
      }, edges = {
        { type = 'audio', from = 'sa', to = 'p'      },
        { type = 'midi',  from = 'sa', to = 'p'      },
        { type = 'audio', from = 'p',  to = 'eq'     },
        { type = 'audio', from = 'eq', to = 'master' },
      } }
      local tracks = tracksOf(g)
      local child = tracks['guid-A']
      t.deepEq(midiOutWires(child), {}, 'merge rides the pipe onto bus 0, not a send')
      t.deepEq(child.pipeMidi, { { from = 'sa', consumer = 'p' } },
        'merge crossing recorded (consumer is the parent source node)')
    end,
  },

  ----- allocator: the family is one MIDI bus domain (the identity pipe is n->n, un-gateable).
  {
    -- A child fx emits midi to a parent fx through the pipe. They must agree on one family-unique
    -- bus >= 1 (off the bus-0 aggregate): the child emits on it, the parent reads it, n->n for free.
    name = 'folder alloc: distinct child->parent-fx crossing shares one family bus >= 1',
    run = function()
      -- `tail` also reads the child take, so bus 0 stays occupied past `gen` and the distinct
      -- stream is forced off the aggregate — making the shared bus observably >= 1.
      local g = { nextId = 1, nodes = {
        sa   = source('guid-A', { parent = 'p' }),
        gen  = fx({ ident = 'VST:Gen' }),
        tail = fx({ ident = 'VST:Tail' }),
        p    = source('guid-P', { ins = 1, midiIns = 1 }),
        cons = fx({ ident = 'VST:Cons' }),
        master = master(),
      }, edges = {
        { type = 'audio', from = 'sa',   to = 'gen'    },
        { type = 'midi',  from = 'sa',   to = 'gen'    },
        { type = 'audio', from = 'gen',  to = 'tail'   },
        { type = 'midi',  from = 'sa',   to = 'tail'   },  -- keeps the take alive on bus 0 past gen
        { type = 'audio', from = 'tail', to = 'p'      },  -- conduit: child tail rides B_MAINSEND
        { type = 'midi',  from = 'gen',  to = 'cons'   },  -- distinct crossing through the pipe
        { type = 'audio', from = 'p',    to = 'cons'   },
        { type = 'audio', from = 'cons', to = 'master' },
      } }
      local out = allocOf(g)
      local emit = out['guid-A'].fxMidiBus.gen.outBus
      local read = out['guid-P'].fxMidiBus.cons.inBus
      t.eq(emit, read, 'child emits on the same bus the parent reads (identity pipe)')
      t.truthy(emit >= 1, 'distinct stream sits off the bus-0 aggregate')
    end,
  },
  {
    -- A child take merges into the parent's bus-0 aggregate natively (the adoption no-op): a parent
    -- fx reads it on bus 0. The merge holds bus 0 across the parent, so a distinct stream from the
    -- same child is forced onto a family-unique bus >= 1.
    name = 'folder alloc: merge rides bus 0 and forces a co-resident distinct stream off it',
    run = function()
      local g = { nextId = 1, nodes = {
        sa   = source('guid-A', { parent = 'p' }),
        gen  = fx({ ident = 'VST:Gen' }),
        p    = source('guid-P', { ins = 1, midiIns = 1 }),
        cons = fx({ ident = 'VST:Cons' }),
        mix  = fx({ ident = 'VST:Mix' }),
        master = master(),
      }, edges = {
        { type = 'audio', from = 'sa',   to = 'gen'    },
        { type = 'midi',  from = 'sa',   to = 'gen'    },
        { type = 'audio', from = 'gen',  to = 'p'      },  -- conduit
        { type = 'midi',  from = 'sa',   to = 'p'      },  -- merge: child take -> parent bus 0
        { type = 'midi',  from = 'gen',  to = 'cons'   },  -- distinct crossing
        { type = 'midi',  from = 'p',    to = 'mix'    },  -- parent reads the merged bus-0 aggregate
        { type = 'audio', from = 'p',    to = 'cons'   },
        { type = 'audio', from = 'p',    to = 'mix'    },
        { type = 'audio', from = 'cons', to = 'master' },
        { type = 'audio', from = 'mix',  to = 'master' },
      } }
      local out = allocOf(g)
      t.eq(out['guid-P'].fxMidiBus.mix.inBus, 0, 'parent fx reads the merged take on bus 0')
      local emit = out['guid-A'].fxMidiBus.gen.outBus
      t.eq(emit, out['guid-P'].fxMidiBus.cons.inBus, 'distinct crossing agrees end to end')
      t.truthy(emit >= 1, 'merge holding bus 0 forces the distinct stream off the aggregate')
    end,
  },
  {
    -- Bus-0 leak guard: take releases bus 0 at gen's slot, so without minReg=1 gen reclaims it
    -- and read mis-merges the distinct stream. A distinct crossing must never sit on bus 0.
    name = 'folder alloc: a distinct crossing never reclaims a just-freed bus 0',
    run = function()
      local g = { nextId = 1, nodes = {
        sa   = source('guid-A', { parent = 'p' }),
        gen  = fx({ ident = 'VST:Gen' }),
        p    = source('guid-P', { ins = 1, midiIns = 1 }),
        cons = fx({ ident = 'VST:Cons' }),
        master = master(),
      }, edges = {
        { type = 'audio', from = 'sa',   to = 'gen'    },
        { type = 'midi',  from = 'sa',   to = 'gen'    },  -- take feeds gen, then releases bus 0
        { type = 'audio', from = 'gen',  to = 'p'      },  -- conduit
        { type = 'midi',  from = 'gen',  to = 'cons'   },  -- distinct crossing through the pipe
        { type = 'audio', from = 'p',    to = 'cons'   },
        { type = 'audio', from = 'cons', to = 'master' },
      } }
      local out = allocOf(g)
      local emit = out['guid-A'].fxMidiBus.gen.outBus
      local read = out['guid-P'].fxMidiBus.cons.inBus
      t.eq(emit, read, 'child emits on the same bus the parent reads')
      t.truthy(emit >= 1, 'the distinct crossing stays off bus 0 (no spurious merge on read)')
    end,
  },
  {
    -- Every fx producer on a pipe-riding member is floored off bus 0 — not just diverted crossings.
    -- Here `gen` midi-sends off-track (plain send, not a crossing); still must not sit on bus 0.
    name = 'folder alloc: a child generator sending off-track is floored off the pipe bus 0',
    run = function()
      local g = { nextId = 1, nodes = {
        sa   = source('guid-A', { parent = 'p' }),
        gen  = fx({ ident = 'VST:Gen' }),
        p    = source('guid-P', { ins = 1 }),
        cons = fx({ ident = 'VST:Cons' }),
        master = master(),
      }, edges = {
        { type = 'audio', from = 'sa',   to = 'gen'    },
        { type = 'audio', from = 'gen',  to = 'p'      },  -- conduit: A rides B_MAINSEND to P
        { type = 'midi',  from = 'gen',  to = 'cons'   },  -- plain cross-track send to a sibling fx
        { type = 'audio', from = 'cons', to = 'master' },
        { type = 'audio', from = 'p',    to = 'master' },
      } }
      local out = allocOf(g)
      t.truthy(out['guid-A'].fxMidiBus.gen.outBus >= 1,
        'the generator stays off bus 0 so it cannot phantom-merge into the parent via the pipe')
    end,
  },
}
