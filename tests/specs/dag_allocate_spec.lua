local t   = require('support')
local DAG = require('DAG')

-- 3c.1 allocator. Audio claims a stereo pair per intra/outgoing/incoming send;
-- pair 1 anchors source-from / master-to / source-out. MIDI stays 0/0.

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
    name = 'allocate: source-from intra anchors fx input pin to pair 1',
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
    name = 'allocate: fx -> fx intra claims fresh pair, stamps both pin maps',
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
      t.deepEq(out['guid-a'].pinMaps, {
        fx1 = { ins = { [1] = {1} }, outs = { [1] = {2} } },
        fx2 = { ins = { [1] = {2} }, outs = {} },
      })
      t.eq(out['guid-a'].nchan, 4)
    end,
  },
  {
    name = 'allocate: branching producer pins multiple pairs on one out port',
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
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {2, 3})
      t.deepEq(out['guid-a'].pinMaps.fx2.ins[1],  {2})
      t.deepEq(out['guid-a'].pinMaps.fx3.ins[1],  {3})
      t.eq(out['guid-a'].nchan, 6)
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
      t.deepEq(out['guid-a'].pinMaps.fx1.outs, { [1]={2}, [2]={3} })
      t.deepEq(out['guid-a'].pinMaps.fx2.ins,  { [1]={2}, [2]={3} })
      t.eq(out['guid-a'].nchan, 6)
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
    name = 'allocate: fx-out outWire claims fresh srcChan pair on sender',
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
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {2})
      t.eq(out['guid-a'].sends[1].srcChan, 2)
      t.eq(out['guid-a'].nchan, 4)
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
    name = 'mainSendOffs: masterFeed from fx claims fresh pair, pins fx output',
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
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {2})
      t.eq(out['guid-a'].mainSendOffs, 2)
      t.eq(out['guid-a'].nchan,        4)
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
      -- fx_order walk claims pair 2 for the outWire; stage 1b claims pair 3 for
      -- the master feed. fx1.outs[1] holds both pairs, sorted.
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {2, 3})
      t.eq(out['guid-a'].sends[1].srcChan, 2)
      t.eq(out['guid-a'].mainSendOffs,     4)
      t.eq(out['guid-a'].nchan,            6)
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
