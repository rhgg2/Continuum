local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
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
      -- Empty graph + master only → DAG.targetTracks yields the empty tracks
      -- (master implicit on REAPER master), nothing scratch-worthy.
      t.eq(next(target), nil, 'no entries for fresh graph')
    end,
  },
  {
    name = 'targetState carries fxId from user-graph nodes through to fx',
    run = function(harness)
      local _, wm = mkWm(harness)
      wm:load()
      wm:mutate(function(g)
        g.nodes['s'] = { kind='source', trackId='guid-A', pos={x=0,y=0}, ports={audio={ins=0,outs=1},midi={ins=0,outs=1}} }
        g.nodes['f'] = { kind='fx', fxIdent='JS:foo', fxId='{FX-1}',
                         pos={x=0,y=0}, ports={audio={ins=1,outs=1},midi={ins=1,outs=1}} }
        util.add(g.edges, { type='audio', from='s', to='f' })
        util.add(g.edges, { type='audio', from='f', to='master' })
      end)
      local target = wm:targetState()
      t.truthy(target['guid-A'], 'source class present')
      t.eq(#target['guid-A'].fx, 1)
      t.eq(target['guid-A'].fx[1].id,    '{FX-1}')
      t.eq(target['guid-A'].fx[1].ident, 'JS:foo')
      t.eq(target['guid-A'].mainSend.on, true)
    end,
  },
  {
    name = 'targetState fx id is nil for unmaterialised fx nodes',
    run = function(harness)
      local _, wm = mkWm(harness)
      wm:load()
      wm:mutate(function(g)
        g.nodes['s'] = { kind='source', trackId='guid-A', pos={x=0,y=0}, ports={audio={ins=0,outs=1},midi={ins=0,outs=1}} }
        g.nodes['f'] = { kind='fx', fxIdent='JS:foo',
                         pos={x=0,y=0}, ports={audio={ins=1,outs=1},midi={ins=1,outs=1}} }
        util.add(g.edges, { type='audio', from='s', to='f' })
      end)
      local target = wm:targetState()
      t.eq(target['guid-A'].fx[1].id,    nil)
      t.eq(target['guid-A'].fx[1].ident, 'JS:foo')
    end,
  },

  {
    name = 'targetState: intra gain materialises as a per-consumer merge CU in fx',
    run = function(harness)
      local _, wm = mkWm(harness)
      wm:load()
      wm:mutate(function(g)
        g.nodes['s'] = { kind='source', trackId='guid-A', pos={x=0,y=0}, ports={audio={ins=0,outs=1},midi={ins=0,outs=1}} }
        g.nodes['f'] = { kind='fx', fxIdent='JS:foo', fxId='{FX-1}',
                         mergeGuids = { ['guid-A'] = '{CU-7}' },
                         pos={x=0,y=0}, ports={audio={ins=1,outs=1},midi={ins=1,outs=1}} }
        util.add(g.edges, { type='audio', from='s', to='f', ops={gain=0.5} })
        util.add(g.edges, { type='audio', from='f', to='master' })
      end)
      local target = wm:targetState()
      local order = target['guid-A'].fx
      t.eq(#order, 2, 'CU and fx both surface')
      -- CU comes first (it sits upstream of fx on the source track).
      t.eq(order[1].ident, 'JS:Continuum Utility')
      t.eq(order[1].id,    '{CU-7}', 'guid resolved from consumer.mergeGuids[trackKey]')
      t.eq(order[1].params.mode,   1, 'merge mode flattened to its slider float')
      t.eq(order[1].params.nPairs, 1)
      t.eq(order[1].params.gain1,  0.5, 'gain bank flattened to gain1..N')
      t.eq(order[2].ident, 'JS:foo')
      t.eq(order[2].id,    '{FX-1}')
    end,
  },
  {
    name = 'diff: params change triggers setFXChain (full-replace)',
    run = function(harness)
      local _, wm = mkWm(harness)
      local mk = function(gain) return {
        ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                       fx = { { id='{CU-1}', ident='JS:Continuum Utility',
                               params={ mode='gain', gain = gain } } },
                       mainSend = {on=true}, sends = {} },
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
        ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                       fx = { { id='{CU-1}', ident='JS:Continuum Utility',
                               params={ mode='gain', gain = 0.5 } } },
                       mainSend = {on=true}, sends = {} },
      }
      t.eq(#wm:diff(both, both), 0)
    end,
  },

  {
    name = 'diff: midi change triggers setFXChain',
    run = function(harness)
      local _, wm = mkWm(harness)
      local mk = function(inBus) return {
        ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                       fx = { { id='{FX-1}', ident='VST:Foo',
                               midi={ inBus=inBus, outBus=0, outDisabled=false } } },
                       mainSend = {on=true}, sends = {} },
      } end
      local kinds = {}
      for _, op in ipairs(wm:diff(mk(1), mk(0))) do kinds[op.op] = true end
      t.truthy(kinds.setFXChain, 'inBus drift produces setFXChain')
    end,
  },
  {
    name = 'diff: identical midi → no op',
    run = function(harness)
      local _, wm = mkWm(harness)
      local both = {
        ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                       fx = { { id='{FX-1}', ident='VST:Foo',
                               midi={ inBus=1, outBus=2, outDisabled=true } } },
                       mainSend = {on=true}, sends = {} },
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
        ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                       fx = { { id='{FX-1}', ident='JS:foo' } },
                       mainSend = {on=true}, sends = {} },
      }
      t.eq(#wm:diff(both, both), 0)
    end,
  },

  ----- diff: creation path

  {
    name = "diff: target-only newTrack trackKey emits createTrack + setFXChain + setSends (id lives in wiringTracks)",
    run = function(harness)
      local _, wm = mkWm(harness)
      local target = {
        ['guid-A|guid-B'] = {
          trackKind='newTrack', id=nil,
          fx = { { id=nil, ident='JS:mix' } },
          mainSend = {on=false},
          sends    = { { to='guid-X', kind='audio', srcChan=0, dstChan=0 } },
        },
      }
      local ops = byOp(wm:diff(target, {}))
      t.eq(#ops.createTrack, 1)
      t.eq(ops.createTrack[1].trackKey, 'guid-A|guid-B')
      t.eq(ops.createTrack[1].trackKind, 'newTrack')
      t.eq(#ops.setFXChain, 1)
      t.eq(ops.setFXChain[1].fx[1].ident, 'JS:mix')
      t.eq(ops.setFXChain[1].fx[1].id, nil, 'unmaterialised → nil id')
      t.eq(#ops.setSends, 1)
      t.eq(ops.setSends[1].sends[1].to, 'guid-X')
      t.eq(ops.setExtState, nil, 'no ext-state op — addressing is the wiringTracks map')
    end,
  },
  {
    name = "diff: target-only sourceTrack trackKey emits no createTrack and no ext-state op (trackKey ≡ id)",
    run = function(harness)
      local _, wm = mkWm(harness)
      local target = {
        ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                       fx = {}, mainSend = {on=true}, sends = {} },
      }
      local ops = byOp(wm:diff(target, {}))
      t.eq(ops.createTrack, nil, 'source tracks pre-exist; no createTrack')
      t.eq(ops.setExtState, nil, 'source identity is its own id; no marker op')
    end,
  },
  {
    name = "diff: mainSend transitions emit setMainSend",
    run = function(harness)
      local _, wm = mkWm(harness)
      local target = { ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                                      fx={}, mainSend={on=true}, sends={} } }
      local snap   = { ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                                      fx={}, mainSend={on=false}, sends={} } }
      local ops = byOp(wm:diff(target, snap))
      t.eq(#ops.setMainSend, 1)
      t.eq(ops.setMainSend[1].value, true)
    end,
  },
  {
    name = "diff: fx reorder emits setFXChain",
    run = function(harness)
      local _, wm = mkWm(harness)
      local entry = function(order) return { trackKind='sourceTrack', id='guid-A',
                                              fx=order, mainSend={on=true}, sends={} } end
      local target = { ['guid-A'] = entry({ { id='1', ident='a' },
                                            { id='2', ident='b' } }) }
      local snap   = { ['guid-A'] = entry({ { id='2', ident='b' },
                                            { id='1', ident='a' } }) }
      local ops = byOp(wm:diff(target, snap))
      t.eq(#ops.setFXChain, 1)
    end,
  },
  {
    name = "diff: sends are order-insensitive (rearranged sends → no op)",
    run = function(harness)
      local _, wm = mkWm(harness)
      local mk = function(sends) return { trackKind='sourceTrack', id='guid-A',
                                          fx={}, mainSend={on=true}, sends=sends } end
      local target = { ['guid-A'] = mk({ { to='X', kind='audio', srcChan=0, dstChan=0 },
                                         { to='Y', kind='midi',  srcChan=0, dstChan=0 } }) }
      local snap   = { ['guid-A'] = mk({ { to='Y', kind='midi',  srcChan=0, dstChan=0 },
                                         { to='X', kind='audio', srcChan=0, dstChan=0 } }) }
      t.eq(#wm:diff(target, snap), 0)
    end,
  },
  {
    name = "diff: snap-only newTrack trackKey emits deleteTrack",
    run = function(harness)
      local _, wm = mkWm(harness)
      local snap = {
        ['guid-A|guid-B'] = { trackKind='newTrack', id='guid-mix',
                              fx={}, mainSend={on=false}, sends={} },
      }
      local ops = byOp(wm:diff({}, snap))
      t.eq(#ops.deleteTrack, 1)
      t.eq(ops.deleteTrack[1].trackId, 'guid-mix')
    end,
  },
  {
    name = "diff: snap-only sourceTrack is NOT deleted (user owns it)",
    run = function(harness)
      local _, wm = mkWm(harness)
      local snap = {
        ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                       fx={}, mainSend={on=true}, sends={} },
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
        ['__scratch__'] = { trackKind='scratch', id='guid-scratch',
                            fx={}, mainSend={on=false}, sends={} },
      }
      local ops = byOp(wm:diff({}, snap))
      t.eq(ops.deleteTrack, nil)
    end,
  },

  ----- trackKey transitions

  {
    name = "diff: field ops carry trackKind so applier can resolve master without a class tag",
    run = function(harness)
      local _, wm = mkWm(harness)
      local target = { ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                                      fx={}, mainSend={on=true}, sends={} } }
      local snap   = { ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                                      fx={}, mainSend={on=false}, sends={} } }
      local ops = byOp(wm:diff(target, snap))
      t.eq(ops.setMainSend[1].trackKind, 'sourceTrack')
    end,
  },
  {
    name = "diff: newTrack → master transition deletes the old newTrack and installs on master",
    run = function(harness)
      local _, wm = mkWm(harness)
      local target = { ['__master__'] = { trackKind='master', id=nil,
                                          fx = { { id='{FX-1}', ident='JS:mix' } },
                                          mainSend={on=false}, sends={} } }
      local snap   = { ['guid-A|guid-B'] = { trackKind='newTrack', id='guid-mix',
                                              fx = { { id='{FX-1}', ident='JS:mix' } },
                                              mainSend={on=false}, sends={} } }
      local ops = byOp(wm:diff(target, snap))
      t.eq(ops.createTrack, nil, 'no newTrack to create — target is master')
      t.eq(#ops.setFXChain, 1, 'install on master (snap newTrack drains via deleteTrack)')
      t.eq(ops.setFXChain[1].trackKind, 'master')
      t.eq(#ops.deleteTrack, 1, 'old newTrack deleted')
      t.eq(ops.deleteTrack[1].trackId, 'guid-mix')
    end,
  },
  {
    name = "diff: master → newTrack transition drains master, creates a newTrack, installs there",
    run = function(harness)
      local _, wm = mkWm(harness)
      local target = { ['guid-A|guid-B'] = { trackKind='newTrack', id=nil,
                                              fx = { { id='{FX-1}', ident='JS:mix' } },
                                              mainSend={on=false}, sends={} } }
      local snap   = { ['__master__'] = { trackKind='master', id=nil,
                                          fx = { { id='{FX-1}', ident='JS:mix' } },
                                          mainSend={on=false}, sends={} } }
      local ops = byOp(wm:diff(target, snap))
      t.eq(#ops.createTrack, 1)
      t.eq(ops.createTrack[1].trackKey, 'guid-A|guid-B')
      local installs, drains = 0, 0
      for _, op in ipairs(ops.setFXChain or {}) do
        if op.trackKind == 'master' and #op.fx == 0 then drains   = drains   + 1 end
        if op.trackKind == 'newTrack'                     then installs = installs + 1 end
      end
      t.eq(drains,   1, 'master drained')
      t.eq(installs, 1, 'newTrack populated')
      t.eq(ops.deleteTrack, nil, 'master is not deletable')
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
      h.reaper.SetMediaTrackInfo_Value(track, 'C_MAINSEND_NCH', 2)  -- Continuum-managed parent send
      local fxIdx = h.reaper.TrackFX_AddByName(track, 'JS:foo', false, -1)
      h.reaper:setFxGuid(track, fxIdx, '{FX-1}')
      -- Seed user graph to match.
      wm:mutate(function(g)
        g.nodes['s'] = { kind='source', trackId='guid-A', pos={x=0,y=0}, ports={audio={ins=0,outs=1},midi={ins=0,outs=1}} }
        g.nodes['f'] = { kind='fx', fxIdent='JS:foo', fxId='{FX-1}',
                         pos={x=0,y=0}, ports={audio={ins=1,outs=1},midi={ins=1,outs=1}} }
        util.add(g.edges, { type='audio', from='s', to='f' })
        util.add(g.edges, { type='audio', from='f', to='master' })
      end)
      local target = wm:targetState()
      local snap   = wm:snapshot()
      local ops    = wm:diff(target, snap)
      -- The scratch track exists in snap but not in target's tracks; it's a
      -- snap-only entry with trackKind='scratch' → no delete, no other ops.
      t.eq(#ops, 0, 'steady state: no ops needed')
    end,
  },

  ----- send / master gain

  {
    name = 'diff: send gain drift drives setSends',
    run = function(harness)
      local _, wm = mkWm(harness)
      local mk = function(g) return {
        ['guid-A'] = { trackKind='sourceTrack', id='guid-A', fx={},
                       mainSend={on=false},
                       sends={ { to='guid-X', kind='audio', gain=g, srcChan=0, dstChan=0 } } },
      } end
      local ops = byOp(wm:diff(mk(0.5), mk(1.0)))
      t.eq(#ops.setSends, 1, 'gain change emits setSends')
      t.eq(ops.setSends[1].sends[1].gain, 0.5)
    end,
  },
  {
    name = 'diff: identical send gain → no op',
    run = function(harness)
      local _, wm = mkWm(harness)
      local mk = function() return {
        ['guid-A'] = { trackKind='sourceTrack', id='guid-A', fx={},
                       mainSend={on=false},
                       sends={ { to='guid-X', kind='audio', gain=0.5, srcChan=0, dstChan=0 } } },
      } end
      t.eq(#wm:diff(mk(), mk()), 0)
    end,
  },
  {
    name = 'diff: mainSend.gain drift drives setMainSend carrying the gain',
    run = function(harness)
      local _, wm = mkWm(harness)
      local entry = function(g) return { trackKind='sourceTrack', id='guid-A',
                                         fx={}, mainSend={on=true, gain=g}, sends={} } end
      local ops = byOp(wm:diff({ ['guid-A']=entry(0.25) }, { ['guid-A']=entry(1.0) }))
      t.eq(#ops.setMainSend, 1)
      t.eq(ops.setMainSend[1].value, true)
      t.eq(ops.setMainSend[1].gain, 0.25)
    end,
  },

  ----- nchan / pinMaps / mainSend.tgtOffset

  {
    name = 'diff: nchan drift drives setNchan',
    run = function(harness)
      local _, wm = mkWm(harness)
      local mk = function(n) return { ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                                                      fx={}, mainSend={on=true}, nchan=n, sends={} } } end
      local ops = byOp(wm:diff(mk(6), mk(2)))
      t.eq(#ops.setNchan, 1)
      t.eq(ops.setNchan[1].value, 6)
      t.eq(ops.setNchan[1].trackKind, 'sourceTrack')
    end,
  },
  {
    name = 'diff: identical nchan → no setNchan',
    run = function(harness)
      local _, wm = mkWm(harness)
      local both = { ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                                    fx={}, mainSend={on=true}, nchan=4, sends={} } }
      t.eq(byOp(wm:diff(both, both)).setNchan, nil)
    end,
  },
  {
    name = 'diff: target nchan=2 vs snap with no nchan → no op (REAPER default)',
    run = function(harness)
      local _, wm = mkWm(harness)
      local target = { ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                                      fx={}, mainSend={on=true}, nchan=2, sends={} } }
      local snap   = { ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                                      fx={}, mainSend={on=true}, sends={} } }
      t.eq(byOp(wm:diff(target, snap)).setNchan, nil)
    end,
  },
  {
    name = 'diff: pinMaps drift drives setPinMaps (fxId-keyed)',
    run = function(harness)
      local _, wm = mkWm(harness)
      local mk = function(pm) return { ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                                                      fx={ { id='{FX-1}', ident='JS:foo', pinMaps=pm } },
                                                      mainSend={on=true}, sends={} } } end
      local target = mk({ ins={[1]={2}}, outs={} })
      local snap   = mk(nil)
      local ops = byOp(wm:diff(target, snap))
      t.eq(#ops.setPinMaps, 1)
      t.deepEq(ops.setPinMaps[1].fx[1].pinMaps.ins[1], {2})
      t.eq(ops.setPinMaps[1].fx[1].id, '{FX-1}')
      t.eq(ops.setPinMaps[1].trackKind, 'sourceTrack')
    end,
  },
  {
    name = 'diff: identical pinMaps → no setPinMaps',
    run = function(harness)
      local _, wm = mkWm(harness)
      local both = { ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                                    fx={ { id='{FX-1}', ident='JS:foo',
                                           pinMaps={ ins={[1]={2}}, outs={} } } },
                                    mainSend={on=true}, sends={} } }
      t.eq(byOp(wm:diff(both, both)).setPinMaps, nil)
    end,
  },
  {
    name = 'diff: unmaterialised target pinMaps (no id) always drives setPinMaps',
    run = function(harness)
      local _, wm = mkWm(harness)
      local target = { ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                                      fx={ { id=nil, ident='JS:foo',
                                             origin={kind='node', id='f'},
                                             pinMaps={ ins={[1]={2}}, outs={} } } },
                                      mainSend={on=true}, sends={} } }
      local snap   = { ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                                      fx={}, mainSend={on=true}, sends={} } }
      local ops = byOp(wm:diff(target, snap))
      t.truthy(ops.setPinMaps and #ops.setPinMaps >= 1, 'setPinMaps emitted')
      t.eq(ops.setPinMaps[1].fx[1].id, nil, 'unmaterialised entry carries no id')
      t.eq(ops.setPinMaps[1].fx[1].origin.id, 'f', 'resolves through its origin')
      t.deepEq(ops.setPinMaps[1].fx[1].pinMaps.ins[1], {2})
    end,
  },
  {
    name = 'diff: mainSend.tgtOffset drift drives setMainSend carrying offs',
    run = function(harness)
      local _, wm = mkWm(harness)
      local entry = function(o) return { trackKind='sourceTrack', id='guid-A',
                                         fx={}, mainSend={on=true, tgtOffset=o}, sends={} } end
      local ops = byOp(wm:diff({ ['guid-A']=entry(4) }, { ['guid-A']=entry(0) }))
      t.eq(#ops.setMainSend, 1)
      t.eq(ops.setMainSend[1].value, true)
      t.eq(ops.setMainSend[1].offs, 4)
    end,
  },
  {
    name = 'diff: mainSend.nchan drift drives setMainSend carrying nch',
    run = function(harness)
      local _, wm = mkWm(harness)
      local entry = function(n) return { trackKind='sourceTrack', id='guid-A',
                                         fx={}, mainSend={on=true, nchan=n}, sends={} } end
      local ops = byOp(wm:diff({ ['guid-A']=entry(2) }, { ['guid-A']=entry(0) }))
      t.eq(#ops.setMainSend, 1)
      t.eq(ops.setMainSend[1].value, true)
      t.eq(ops.setMainSend[1].nch, 2)
    end,
  },
  {
    name = 'diff: fresh class setMainSend carries offs (defaults to 0)',
    run = function(harness)
      local _, wm = mkWm(harness)
      local target = { ['guid-A'] = { trackKind='sourceTrack', id='guid-A',
                                      fx={}, mainSend={on=true}, sends={} } }
      local ops = byOp(wm:diff(target, {}))
      t.eq(#ops.setMainSend, 1)
      t.eq(ops.setMainSend[1].offs, 0)
    end,
  },
}
