local t   = require('support')
local DAG = require('DAG')

-- 3c.1 allocator. Per-host live-range register allocation;
-- see DAG.lua's allocatedPlan shape for the model. MIDI stays 0/0.

return {
  {
    name = 'allocate: empty plan returns empty',
    run = function()
      t.deepEq(DAG.allocate({}), {})
    end,
  },
  {
    name = 'allocate: empty host yields no sends, empty pinMaps, nchan=2, intra/out fields stripped',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.deepEq(out['guid-a'].sends,   {})
      t.deepEq(out['guid-a'].pinMaps, {})
      t.eq(out['guid-a'].nchan,       2)
      t.eq(out['guid-a'].outWires,    nil)
      t.eq(out['guid-a'].intraConns,  nil)
    end,
  },
  {
    name = 'allocate: passes through hostKind / trackGuid / fxOrder / mainSend / mainSendGain',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a',
          fxOrder={'f1','f2'}, mainSend=true, mainSendGain=0.5,
          intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.eq(out['guid-a'].hostKind,     'sourceTrack')
      t.eq(out['guid-a'].trackGuid,    'guid-a')
      t.deepEq(out['guid-a'].fxOrder,  { 'f1', 'f2' })
      t.eq(out['guid-a'].mainSend,     true)
      t.eq(out['guid-a'].mainSendGain, 0.5)
    end,
  },
  {
    name = 'allocate: source-from intra seeds fx input pin on pair 1',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'fx1'},
          mainSend=false,
          intraConns={ {from='s', to='fx1', type='audio'} },
          outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.deepEq(out['guid-a'].pinMaps, { fx1 = { ins = { [1] = {1} }, outs = {} } })
      t.eq(out['guid-a'].nchan, 2)
    end,
  },
  {
    name = 'allocate: serial chain fx1->fx2 collapses to pair 1 (in-place reuse)',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'fx1','fx2'},
          mainSend=false,
          intraConns={
            {from='s',   to='fx1', type='audio'},
            {from='fx1', to='fx2', type='audio'},
          },
          outWires={},
        },
      }
      local out = DAG.allocate(plan)
      -- source-from value (pair 1) freed at fx1's slot, claimed back for fx1's own output.
      t.deepEq(out['guid-a'].pinMaps, {
        fx1 = { ins = { [1] = {1} }, outs = { [1] = {1} } },
        fx2 = { ins = { [1] = {1} }, outs = {} },
      })
      t.eq(out['guid-a'].nchan, 2)
    end,
  },
  {
    name = 'allocate: serial chain s->fx1->fx2->fx3 collapses to one pair, nchan=2',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'fx1','fx2','fx3'},
          mainSend=false,
          intraConns={
            {from='s',   to='fx1', type='audio'},
            {from='fx1', to='fx2', type='audio'},
            {from='fx2', to='fx3', type='audio'},
          },
          outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {1})
      t.deepEq(out['guid-a'].pinMaps.fx2.ins[1],  {1})
      t.deepEq(out['guid-a'].pinMaps.fx2.outs[1], {1})
      t.deepEq(out['guid-a'].pinMaps.fx3.ins[1],  {1})
      t.eq(out['guid-a'].nchan, 2)
    end,
  },
  {
    name = 'allocate: branching producer reuses freed input pair for one branch, claims fresh for the other',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'fx1','fx2','fx3'},
          mainSend=false,
          intraConns={
            {from='s',   to='fx1', type='audio'},
            {from='fx1', to='fx2', type='audio'},
            {from='fx1', to='fx3', type='audio'},
          },
          outWires={},
        },
      }
      local out = DAG.allocate(plan)
      -- shorter-range branch (fx1->fx2, dies at slot 2) takes the freed pair 1;
      -- longer-range branch (fx1->fx3, dies at slot 3) claims fresh pair 2.
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {1, 2})
      t.deepEq(out['guid-a'].pinMaps.fx2.ins[1],  {1})
      t.deepEq(out['guid-a'].pinMaps.fx3.ins[1],  {2})
      t.eq(out['guid-a'].nchan, 4)
    end,
  },
  {
    name = 'allocate: directed square A->B, A->C, B->D, C->D fits in 2 pairs (nchan=4)',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'A','B','C','D'},
          mainSend=false,
          intraConns={
            {from='s', to='A', type='audio'},
            {from='A', to='B', type='audio'},
            {from='A', to='C', type='audio'},
            {from='B', to='D', type='audio'},
            {from='C', to='D', type='audio'},
          },
          outWires={},
        },
      }
      local out = DAG.allocate(plan)
      -- Source seeds pair 1 (A reads), freed at A then split into A->B (pair 1)
      -- and A->C (pair 2). Each branch reuses its own input pair through to D.
      t.deepEq(out['guid-a'].pinMaps.A.ins[1],  {1})
      t.deepEq(out['guid-a'].pinMaps.A.outs[1], {1, 2})
      t.deepEq(out['guid-a'].pinMaps.B.ins[1],  {1})
      t.deepEq(out['guid-a'].pinMaps.B.outs[1], {1})
      t.deepEq(out['guid-a'].pinMaps.C.ins[1],  {2})
      t.deepEq(out['guid-a'].pinMaps.C.outs[1], {2})
      t.deepEq(out['guid-a'].pinMaps.D.ins[1],  {1, 2})
      t.eq(out['guid-a'].nchan, 4)
    end,
  },
  {
    name = 'allocate: multi-port intra-conns each claim their own pair',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'fx1','fx2'},
          mainSend=false,
          intraConns={
            {from='s',   to='fx1', type='audio'},
            {from='fx1', fromPort=1, to='fx2', toPort=1, type='audio'},
            {from='fx1', fromPort=2, to='fx2', toPort=2, type='audio'},
          },
          outWires={},
        },
      }
      local out = DAG.allocate(plan)
      -- port-1 intra takes freed pair 1 in-place; port-2 intra claims pair 2.
      t.deepEq(out['guid-a'].pinMaps.fx1.outs, { [1]={1}, [2]={2} })
      t.deepEq(out['guid-a'].pinMaps.fx2.ins,  { [1]={1}, [2]={2} })
      t.eq(out['guid-a'].nchan, 4)
    end,
  },
  {
    name = 'allocate: source-out outWire anchors srcChan to 0; receiver assigns dstChan',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-b', toNode='fx_b', type='audio'} },
        },
        ['guid-b'] = {
          hostKind='newTrack', fxOrder={'fx_b'},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.eq(#out['guid-a'].sends,           1)
      t.eq(out['guid-a'].sends[1].to,      'guid-b')
      t.eq(out['guid-a'].sends[1].srcChan, 0)
      t.eq(out['guid-a'].sends[1].dstChan, 0)
      t.deepEq(out['guid-b'].pinMaps.fx_b.ins[1], {1})
    end,
  },
  {
    name = 'allocate: fx-out outWire reuses fx input pair in-place (srcChan=0)',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'fx1'},
          mainSend=false,
          intraConns={ {from='s', to='fx1', type='audio'} },
          outWires={ {from='fx1', to='guid-b', toNode='fx_b', type='audio'} },
        },
        ['guid-b'] = {
          hostKind='newTrack', fxOrder={'fx_b'},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {1})
      t.eq(out['guid-a'].sends[1].srcChan, 0)
      t.eq(out['guid-a'].nchan, 2)
    end,
  },
  {
    name = 'allocate: incoming sends to same receiver get distinct dstChans',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-c', toNode='fx_c', toPort=1, type='audio'} },
        },
        ['guid-b'] = {
          hostKind='sourceTrack', trackGuid='guid-b', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-c', toNode='fx_c', toPort=2, type='audio'} },
        },
        ['guid-c'] = {
          hostKind='newTrack', fxOrder={'fx_c'},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.eq(out['guid-a'].sends[1].dstChan, 0)
      t.eq(out['guid-b'].sends[1].dstChan, 2)
      t.deepEq(out['guid-c'].pinMaps.fx_c.ins[1], {1})
      t.deepEq(out['guid-c'].pinMaps.fx_c.ins[2], {2})
      t.eq(out['guid-c'].nchan, 4)
    end,
  },
  {
    name = 'allocate: midi conns keep srcChan/dstChan = 0, no audio pin map',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'fx1'},
          mainSend=false,
          intraConns={ {from='s', to='fx1', type='midi'} },
          outWires={ {from='fx1', to='guid-b', toNode='fx_b', type='midi'} },
        },
        ['guid-b'] = {
          hostKind='newTrack', fxOrder={'fx_b'},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.eq(out['guid-a'].sends[1].type,    'midi')
      t.eq(out['guid-a'].sends[1].srcChan, 0)
      t.eq(out['guid-a'].sends[1].dstChan, 0)
      t.deepEq(out['guid-a'].pinMaps,      {})
      t.eq(out['guid-a'].nchan,            2)
    end,
  },
  {
    name = 'allocate: midi sends to same dest dedup on 4-tuple (all 0/0 until 3c.3)',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'fx1'},
          mainSend=false,
          intraConns={ {from='s', to='fx1', type='midi'} },
          outWires={
            {from='fx1', to='guid-b', toNode='fx_b', type='midi'},
            {from='fx1', to='guid-b', toNode='fx_b', type='midi'},
          },
        },
        ['guid-b'] = {
          hostKind='newTrack', fxOrder={'fx_b'},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.eq(#out['guid-a'].sends, 1)
    end,
  },
  {
    name = 'allocate: gain on outWire flows through to its send',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-b', toNode='fx_b', type='audio', gain=0.25} },
        },
        ['guid-b'] = {
          hostKind='newTrack', fxOrder={'fx_b'},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.eq(out['guid-a'].sends[1].gain, 0.25)
    end,
  },
  {
    name = 'allocate: sends sorted by (to, type, srcChan, dstChan)',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'fx1'},
          mainSend=false,
          intraConns={ {from='s', to='fx1', type='audio'} },
          outWires={
            {from='fx1', to='guid-c', toNode='fx_c',  type='audio'},
            {from='fx1', to='guid-b', toNode='fx_b',  type='midi'},
            {from='fx1', to='guid-b', toNode='fx_b2', type='audio'},
          },
        },
        ['guid-b'] = { hostKind='newTrack', fxOrder={'fx_b','fx_b2'},
                       mainSend=false, intraConns={}, outWires={} },
        ['guid-c'] = { hostKind='newTrack', fxOrder={'fx_c'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local out = DAG.allocate(plan)
      t.eq(out['guid-a'].sends[1].to,   'guid-b')
      t.eq(out['guid-a'].sends[1].type, 'audio')
      t.eq(out['guid-a'].sends[2].to,   'guid-b')
      t.eq(out['guid-a'].sends[2].type, 'midi')
      t.eq(out['guid-a'].sends[3].to,   'guid-c')
    end,
  },
  {
    name = 'allocate: does not mutate input plan',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-b', toNode='fx_b', type='audio'} },
        },
        ['guid-b'] = { hostKind='newTrack', fxOrder={'fx_b'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      DAG.allocate(plan)
      t.eq(plan['guid-a'].outWires[1].to, 'guid-b')
      t.eq(plan['guid-a'].sends,          nil)
      t.eq(plan['guid-a'].pinMaps,        nil)
      t.eq(plan['guid-a'].nchan,          nil)
    end,
  },
  {
    name = 'allocate: master-to intra (master-hosted host) anchors fx output to pair 1',
    run = function()
      local plan = {
        ['__master__'] = {
          hostKind='master', fxOrder={'mix'},
          mainSend=false,
          intraConns={ {from='mix', to='master', type='audio'} },
          outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.deepEq(out['__master__'].pinMaps.mix.outs[1], {1})
      t.eq(out['__master__'].nchan, 2)
    end,
  },
  {
    name = 'mainSendOffs: mainSend=true with no masterFeed defaults to 0',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={},
          mainSend=true, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.eq(out['guid-a'].mainSendOffs, 0)
      t.eq(out['guid-a'].nchan,        2)
    end,
  },
  {
    name = 'mainSendOffs: masterFeed from source (not in fxSet) stays at 0, no pin',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={},
          mainSend=true, masterFeed={from='s'},
          intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.eq(out['guid-a'].mainSendOffs, 0)
      t.deepEq(out['guid-a'].pinMaps,  {})
    end,
  },
  {
    name = 'mainSendOffs: masterFeed reuses fx input pair in-place (offs=0)',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'fx1'},
          mainSend=true, masterFeed={from='fx1'},
          intraConns={ {from='s', to='fx1', type='audio'} },
          outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.deepEq(out['guid-a'].pinMaps.fx1.ins[1],  {1})
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {1})
      t.eq(out['guid-a'].mainSendOffs, 0)
      t.eq(out['guid-a'].nchan,        2)
    end,
  },
  {
    name = 'mainSendOffs: chain ending in masterFeed collapses to one pair',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'fx1','fx2','fx3'},
          mainSend=true, masterFeed={from='fx3'},
          intraConns={
            {from='s',   to='fx1', type='audio'},
            {from='fx1', to='fx2', type='audio'},
            {from='fx2', to='fx3', type='audio'},
          },
          outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.deepEq(out['guid-a'].pinMaps.fx3.outs[1], {1})
      t.eq(out['guid-a'].mainSendOffs, 0)
      t.eq(out['guid-a'].nchan,        2)
    end,
  },
  {
    name = 'mainSendOffs: masterFeed coexists with outgoing send (pair counting)',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'fx1'},
          mainSend=true, masterFeed={from='fx1'},
          intraConns={ {from='s', to='fx1', type='audio'} },
          outWires={ {from='fx1', to='guid-b', toNode='fx_b', type='audio'} },
        },
        ['guid-b'] = { hostKind='newTrack', fxOrder={'fx_b'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local out = DAG.allocate(plan)
      -- Two outputs from fx1 contend for pair 1 (freed at fx1's slot). Outgoing
      -- send takes it (srcChan=0); masterFeed claims pair 2 (mainSendOffs=2).
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {1, 2})
      t.eq(out['guid-a'].sends[1].srcChan, 0)
      t.eq(out['guid-a'].mainSendOffs,     2)
      t.eq(out['guid-a'].nchan,            4)
    end,
  },
  {
    name = 'mainSendOffs: absent on master-hosted host (mainSend=false)',
    run = function()
      local plan = {
        ['__master__'] = {
          hostKind='master', fxOrder={'mix'},
          mainSend=false,
          intraConns={ {from='mix', to='master', type='audio'} },
          outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.eq(out['__master__'].mainSendOffs, nil)
    end,
  },
  {
    name = 'mainSendOffs: absent on hosts with mainSend=false',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(plan)
      t.eq(out['guid-a'].mainSendOffs, nil)
    end,
  },
  {
    name = 'allocate: same input -> same output (determinism)',
    run = function()
      local mk = function()
        return {
          ['guid-a'] = {
            hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'fx1','fx2'},
            mainSend=false,
            intraConns={
              {from='s',   to='fx1', type='audio'},
              {from='fx1', to='fx2', type='audio'},
            },
            outWires={ {from='fx2', to='guid-b', toNode='fx_b', type='audio'} },
          },
          ['guid-b'] = { hostKind='newTrack', fxOrder={'fx_b'},
                         mainSend=false, intraConns={}, outWires={} },
        }
      end
      t.deepEq(DAG.allocate(mk()), DAG.allocate(mk()))
    end,
  },
}
