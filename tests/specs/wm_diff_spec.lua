local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local wm = util.instantiate('wiringManager', { cm = h.cm })
  return h, wm
end

-- Sort ops by op-name so spec assertions don't depend on insertion order
-- within a logical phase (creates/mutates/deletes still grouped though).
local function byOp(ops)
  local out = {}
  for _, op in ipairs(ops) do
    out[op.op] = out[op.op] or {}
    table.insert(out[op.op], op)
  end
  return out
end

return {
  ----- targetState

  {
    name = 'targetState on fresh graph: only scratch (master is implicit)',
    run = function(harness)
      local _, wm = mkWm(harness)
      wm:load()
      local target = wm:targetState()
      -- Empty graph + master only → DAG.targetPlan yields the empty plan
      -- (master implicit on REAPER master), nothing scratch-worthy.
      t.eq(next(target), nil, 'no entries for fresh graph')
    end,
  },
  {
    name = 'targetState carries fxGuid from user-graph nodes through to fxOrder',
    run = function(harness)
      local _, wm = mkWm(harness)
      wm:load()
      wm:mutate(function(g)
        g.nodes['s'] = { kind='source', trackGuid='guid-A', pos={x=0,y=0} }
        g.nodes['f'] = { kind='fx', fxIdent='JS:foo', fxGuid='{FX-1}',
                         pos={x=0,y=0}, audio={ins=1, outs=1} }
        util.add(g.edges, { type='audio', from='s', to='f' })
        util.add(g.edges, { type='audio', from='f', to='master' })
      end)
      local target = wm:targetState()
      t.truthy(target['guid-A'], 'source class present')
      t.eq(#target['guid-A'].fxOrder, 1)
      t.eq(target['guid-A'].fxOrder[1].fxGuid, '{FX-1}')
      t.eq(target['guid-A'].fxOrder[1].ident,  'JS:foo')
      t.eq(target['guid-A'].mainSend, true)
    end,
  },
  {
    name = 'targetState fxGuid is nil for unmaterialised fx nodes',
    run = function(harness)
      local _, wm = mkWm(harness)
      wm:load()
      wm:mutate(function(g)
        g.nodes['s'] = { kind='source', trackGuid='guid-A', pos={x=0,y=0} }
        g.nodes['f'] = { kind='fx', fxIdent='JS:foo',
                         pos={x=0,y=0}, audio={ins=1, outs=1} }
        util.add(g.edges, { type='audio', from='s', to='f' })
      end)
      local target = wm:targetState()
      t.eq(target['guid-A'].fxOrder[1].fxGuid, nil)
      t.eq(target['guid-A'].fxOrder[1].ident,  'JS:foo')
    end,
  },

  {
    name = 'targetState: edge ops materialise as CU entries in fxOrder (lower-uniform)',
    run = function(harness)
      local _, wm = mkWm(harness)
      wm:load()
      wm:mutate(function(g)
        g.nodes['s'] = { kind='source', trackGuid='guid-A', pos={x=0,y=0} }
        g.nodes['f'] = { kind='fx', fxIdent='JS:foo', fxGuid='{FX-1}',
                         pos={x=0,y=0}, audio={ins=1, outs=1} }
        util.add(g.edges, { type='audio', from='s', to='f',
                            ops={gain=0.5}, _opFxGuid='{CU-7}' })
        util.add(g.edges, { type='audio', from='f', to='master' })
      end)
      local target = wm:targetState()
      local order = target['guid-A'].fxOrder
      t.eq(#order, 2, 'CU and fx both surface')
      -- CU comes first (it sits upstream of fx_a on the source track).
      t.eq(order[1].ident,  'JS:Continuum Utility')
      t.eq(order[1].fxGuid, '{CU-7}')
      t.eq(order[1].params.mode, 'gain')
      t.eq(order[1].params.gain, 0.5)
      t.eq(order[2].ident,  'JS:foo')
      t.eq(order[2].fxGuid, '{FX-1}')
    end,
  },
  {
    name = 'diff: params change triggers setFXChain (full-replace)',
    run = function(harness)
      local _, wm = mkWm(harness)
      local mk = function(gain) return {
        ['guid-A'] = { hostKind='sourceTrack', trackGuid='guid-A',
                       fxOrder = { { fxGuid='{CU-1}', ident='JS:Continuum Utility',
                                     params={ mode='gain', gain = gain } } },
                       mainSend = true, sends = {} },
      } end
      local ops = wm:diff(mk(0.7), mk(0.5))
      t.truthy(#ops > 0, 'param drift produces ops')
      local kinds = {}
      for _, op in ipairs(ops) do kinds[op.op] = true end
      t.truthy(kinds.setFXChain, 'setFXChain emitted for params change')
    end,
  },
  {
    name = 'diff: identical params → no op',
    run = function(harness)
      local _, wm = mkWm(harness)
      local both = {
        ['guid-A'] = { hostKind='sourceTrack', trackGuid='guid-A',
                       fxOrder = { { fxGuid='{CU-1}', ident='JS:Continuum Utility',
                                     params={ mode='gain', gain = 0.5 } } },
                       mainSend = true, sends = {} },
      }
      t.eq(#wm:diff(both, both), 0)
    end,
  },

  ----- diff: empty in, empty out

  {
    name = 'diff: empty target vs empty snap → no ops',
    run = function(harness)
      local _, wm = mkWm(harness)
      t.eq(#wm:diff({}, {}), 0)
    end,
  },
  {
    name = 'diff: identical target and snap → no ops',
    run = function(harness)
      local _, wm = mkWm(harness)
      local both = {
        ['guid-A'] = { hostKind='sourceTrack', trackGuid='guid-A',
                       fxOrder = { { fxGuid='{FX-1}', ident='JS:foo' } },
                       mainSend = true, sends = {} },
      }
      t.eq(#wm:diff(both, both), 0)
    end,
  },

  ----- diff: creation path

  {
    name = "diff: target-only newTrack host emits createTrack + setFXChain + setSends + setExtState writes",
    run = function(harness)
      local _, wm = mkWm(harness)
      local target = {
        ['guid-A|guid-B'] = {
          hostKind='newTrack', trackGuid=nil,
          fxOrder = { { fxGuid=nil, ident='JS:mix' } },
          mainSend = false,
          sends    = { { to='guid-X', type='audio' } },
        },
      }
      local ops = byOp(wm:diff(target, {}))
      t.eq(#ops.createTrack, 1)
      t.eq(ops.createTrack[1].classKey, 'guid-A|guid-B')
      t.eq(ops.createTrack[1].hostKind, 'newTrack')
      t.eq(#ops.setFXChain, 1)
      t.eq(ops.setFXChain[1].fxOrder[1].ident, 'JS:mix')
      t.eq(ops.setFXChain[1].fxOrder[1].fxGuid, nil, 'unmaterialised → nil guid')
      t.eq(#ops.setSends, 1)
      t.eq(ops.setSends[1].sends[1].to, 'guid-X')
      -- setExtState: wiringHostKind + wiringClass (newTrack writes both).
      local extKeys = {}
      for _, op in ipairs(ops.setExtState or {}) do extKeys[op.key] = op.value end
      t.eq(extKeys.wiringHostKind, 'newTrack')
      t.eq(extKeys.wiringClass,    'guid-A|guid-B')
    end,
  },
  {
    name = "diff: target-only sourceTrack host writes only wiringHostKind (classKey ≡ trackGuid)",
    run = function(harness)
      local _, wm = mkWm(harness)
      local target = {
        ['guid-A'] = { hostKind='sourceTrack', trackGuid='guid-A',
                       fxOrder = {}, mainSend = true, sends = {} },
      }
      local ops = byOp(wm:diff(target, {}))
      t.eq(ops.createTrack, nil, 'source tracks pre-exist; no createTrack')
      local extKeys = {}
      for _, op in ipairs(ops.setExtState or {}) do extKeys[op.key] = op.value end
      t.eq(extKeys.wiringHostKind, 'sourceTrack')
      t.eq(extKeys.wiringClass,    nil,           'no redundant wiringClass write')
    end,
  },
  {
    name = "diff: mainSend transitions emit setMainSend",
    run = function(harness)
      local _, wm = mkWm(harness)
      local target = { ['guid-A'] = { hostKind='sourceTrack', trackGuid='guid-A',
                                      fxOrder={}, mainSend=true, sends={} } }
      local snap   = { ['guid-A'] = { hostKind='sourceTrack', trackGuid='guid-A',
                                      fxOrder={}, mainSend=false, sends={} } }
      local ops = byOp(wm:diff(target, snap))
      t.eq(#ops.setMainSend, 1)
      t.eq(ops.setMainSend[1].value, true)
    end,
  },
  {
    name = "diff: fxOrder reorder emits setFXChain",
    run = function(harness)
      local _, wm = mkWm(harness)
      local entry = function(order) return { hostKind='sourceTrack', trackGuid='guid-A',
                                              fxOrder=order, mainSend=true, sends={} } end
      local target = { ['guid-A'] = entry({ { fxGuid='1', ident='a' },
                                            { fxGuid='2', ident='b' } }) }
      local snap   = { ['guid-A'] = entry({ { fxGuid='2', ident='b' },
                                            { fxGuid='1', ident='a' } }) }
      local ops = byOp(wm:diff(target, snap))
      t.eq(#ops.setFXChain, 1)
    end,
  },
  {
    name = "diff: sends are order-insensitive (rearranged sends → no op)",
    run = function(harness)
      local _, wm = mkWm(harness)
      local mk = function(sends) return { hostKind='sourceTrack', trackGuid='guid-A',
                                          fxOrder={}, mainSend=true, sends=sends } end
      local target = { ['guid-A'] = mk({ { to='X', type='audio' },
                                         { to='Y', type='midi'  } }) }
      local snap   = { ['guid-A'] = mk({ { to='Y', type='midi'  },
                                         { to='X', type='audio' } }) }
      t.eq(#wm:diff(target, snap), 0)
    end,
  },
  {
    name = "diff: snap-only newTrack host emits deleteTrack",
    run = function(harness)
      local _, wm = mkWm(harness)
      local snap = {
        ['guid-A|guid-B'] = { hostKind='newTrack', trackGuid='guid-mix',
                              fxOrder={}, mainSend=false, sends={} },
      }
      local ops = byOp(wm:diff({}, snap))
      t.eq(#ops.deleteTrack, 1)
      t.eq(ops.deleteTrack[1].trackGuid, 'guid-mix')
    end,
  },
  {
    name = "diff: snap-only sourceTrack is NOT deleted (user owns it)",
    run = function(harness)
      local _, wm = mkWm(harness)
      local snap = {
        ['guid-A'] = { hostKind='sourceTrack', trackGuid='guid-A',
                       fxOrder={}, mainSend=true, sends={} },
      }
      local ops = byOp(wm:diff({}, snap))
      t.eq(ops.deleteTrack, nil, 'source tracks survive removal from graph')
    end,
  },
  {
    name = "diff: snap-only scratch is NOT deleted",
    run = function(harness)
      local _, wm = mkWm(harness)
      local snap = {
        ['__scratch__'] = { hostKind='scratch', trackGuid='guid-scratch',
                            fxOrder={}, mainSend=false, sends={} },
      }
      local ops = byOp(wm:diff({}, snap))
      t.eq(ops.deleteTrack, nil)
    end,
  },

  ----- round-trip integration: targetState + snapshot agree after seeding

  {
    name = 'integration: snapshot of a seeded source track matches targetState',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      -- Seed REAPER state: one source track + one fx with matching guid.
      local track = { __label = 'src' }
      h.reaper._state.projectTracks[#h.reaper._state.projectTracks+1] = track
      h.reaper._state.trackGuids[track] = 'guid-A'
      h.cm:writeTrackKey(track, 'wiringHostKind', 'sourceTrack')
      local fxIdx = h.reaper.TrackFX_AddByName(track, 'JS:foo', false, -1)
      h.reaper:setFxGuid(track, fxIdx, '{FX-1}')
      -- Seed user graph to match.
      wm:mutate(function(g)
        g.nodes['s'] = { kind='source', trackGuid='guid-A', pos={x=0,y=0} }
        g.nodes['f'] = { kind='fx', fxIdent='JS:foo', fxGuid='{FX-1}',
                         pos={x=0,y=0}, audio={ins=1, outs=1} }
        util.add(g.edges, { type='audio', from='s', to='f' })
        util.add(g.edges, { type='audio', from='f', to='master' })
      end)
      local target = wm:targetState()
      local snap   = wm:snapshot()
      local ops    = wm:diff(target, snap)
      -- The scratch track exists in snap but not in target's plan; it's a
      -- snap-only entry with hostKind='scratch' → no delete, no other ops.
      t.eq(#ops, 0, 'steady state: no ops needed')
    end,
  },
}
