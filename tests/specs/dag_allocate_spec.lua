local t   = require('support')
local DAG = require('DAG')

-- 3c.1 allocator. Per-trackKey live-range register allocation;
-- see DAG.lua's allocatedTracks shape for the model. MIDI stays 0/0.

return {
  {
    name = 'allocate: empty tracks returns empty',
    run = function()
      t.deepEq(DAG.allocate({}), {})
    end,
  },
  {
    name = 'allocate: empty trackKey yields no sends, empty pinMaps, nchan=2, intra/out fields stripped',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.deepEq(out['guid-a'].sends,   {})
      t.deepEq(out['guid-a'].pinMaps, {})
      t.eq(out['guid-a'].nchan,       2)
      t.eq(out['guid-a'].outWires,    nil)
      t.eq(out['guid-a'].intraConns,  nil)
    end,
  },
  {
    name = 'allocate: passes through trackKind / trackId / fxOrder / mainSend / mainSendGain',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a',
          fxOrder={'f1','f2'}, mainSend=true, mainSendGain=0.5,
          intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.eq(out['guid-a'].trackKind,     'sourceTrack')
      t.eq(out['guid-a'].trackId,    'guid-a')
      t.deepEq(out['guid-a'].fxOrder,  { 'f1', 'f2' })
      t.eq(out['guid-a'].mainSend,     true)
      t.eq(out['guid-a'].mainSendGain, 0.5)
    end,
  },
  {
    name = 'allocate: source-from intra seeds fx input pin on pair 1',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1'},
          mainSend=false,
          intraConns={ {from='s', to='fx1', type='audio'} },
          outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.deepEq(out['guid-a'].pinMaps, { fx1 = { ins = { [1] = {1} }, outs = {} } })
      t.eq(out['guid-a'].nchan, 2)
    end,
  },
  {
    name = 'allocate: serial chain fx1->fx2 collapses to pair 1 (in-place reuse)',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1','fx2'},
          mainSend=false,
          intraConns={
            {from='s',   to='fx1', type='audio'},
            {from='fx1', to='fx2', type='audio'},
          },
          outWires={},
        },
      }
      local out = DAG.allocate(tracks)
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
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1','fx2','fx3'},
          mainSend=false,
          intraConns={
            {from='s',   to='fx1', type='audio'},
            {from='fx1', to='fx2', type='audio'},
            {from='fx2', to='fx3', type='audio'},
          },
          outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {1})
      t.deepEq(out['guid-a'].pinMaps.fx2.ins[1],  {1})
      t.deepEq(out['guid-a'].pinMaps.fx2.outs[1], {1})
      t.deepEq(out['guid-a'].pinMaps.fx3.ins[1],  {1})
      t.eq(out['guid-a'].nchan, 2)
    end,
  },
  {
    name = 'allocate: branching producer shares one output pair across both branches',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1','fx2','fx3'},
          mainSend=false,
          intraConns={
            {from='s',   to='fx1', type='audio'},
            {from='fx1', to='fx2', type='audio'},
            {from='fx1', to='fx3', type='audio'},
          },
          outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      -- fx1's single output drives both branches off one pair; each consumer
      -- reads it in place, so nchan stays at 2.
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {1})
      t.deepEq(out['guid-a'].pinMaps.fx2.ins[1],  {1})
      t.deepEq(out['guid-a'].pinMaps.fx3.ins[1],  {1})
      t.eq(out['guid-a'].nchan, 2)
    end,
  },
  {
    name = 'allocate: directed square A->B, A->C, B->D, C->D fits in 2 pairs (nchan=4)',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'A','B','C','D'},
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
      local out = DAG.allocate(tracks)
      -- A's one output pair feeds both B and C in place. B and C run live at
      -- once (pairs 2 and 1), so D sums both at its input; nchan=4.
      t.deepEq(out['guid-a'].pinMaps.A.ins[1],  {1})
      t.deepEq(out['guid-a'].pinMaps.A.outs[1], {1})
      t.deepEq(out['guid-a'].pinMaps.B.ins[1],  {1})
      t.deepEq(out['guid-a'].pinMaps.B.outs[1], {2})
      t.deepEq(out['guid-a'].pinMaps.C.ins[1],  {1})
      t.deepEq(out['guid-a'].pinMaps.C.outs[1], {1})
      t.deepEq(out['guid-a'].pinMaps.D.ins[1],  {1, 2})
      t.eq(out['guid-a'].nchan, 4)
    end,
  },
  {
    name = 'allocate: multi-port intra-conns each claim their own pair',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1','fx2'},
          mainSend=false,
          intraConns={
            {from='s',   to='fx1', type='audio'},
            {from='fx1', fromPort=1, to='fx2', toPort=1, type='audio'},
            {from='fx1', fromPort=2, to='fx2', toPort=2, type='audio'},
          },
          outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      -- port-1 intra takes freed pair 1 in-place; port-2 intra claims pair 2.
      t.deepEq(out['guid-a'].pinMaps.fx1.outs, { [1]={1}, [2]={2} })
      t.deepEq(out['guid-a'].pinMaps.fx2.ins,  { [1]={1}, [2]={2} })
      t.eq(out['guid-a'].nchan, 4)
    end,
  },
  {
    name = 'allocate: source-out outWire anchors srcChan to 0; receiver assigns dstChan',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-b', toNode='fx_b', type='audio'} },
        },
        ['guid-b'] = {
          trackKind='newTrack', fxOrder={'fx_b'},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(tracks)
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
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1'},
          mainSend=false,
          intraConns={ {from='s', to='fx1', type='audio'} },
          outWires={ {from='fx1', to='guid-b', toNode='fx_b', type='audio'} },
        },
        ['guid-b'] = {
          trackKind='newTrack', fxOrder={'fx_b'},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {1})
      t.eq(out['guid-a'].sends[1].srcChan, 0)
      t.eq(out['guid-a'].nchan, 2)
    end,
  },
  {
    name = 'allocate: incoming sends to same receiver get distinct dstChans',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-c', toNode='fx_c', toPort=1, type='audio'} },
        },
        ['guid-b'] = {
          trackKind='sourceTrack', trackId='guid-b', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-c', toNode='fx_c', toPort=2, type='audio'} },
        },
        ['guid-c'] = {
          trackKind='newTrack', fxOrder={'fx_c'},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.eq(out['guid-a'].sends[1].dstChan, 0)
      t.eq(out['guid-b'].sends[1].dstChan, 2)
      t.deepEq(out['guid-c'].pinMaps.fx_c.ins[1], {1})
      t.deepEq(out['guid-c'].pinMaps.fx_c.ins[2], {2})
      t.eq(out['guid-c'].nchan, 4)
    end,
  },
  {
    name = 'allocate: incoming sends to the same input pin coalesce onto one dest pair',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-c', toNode='fx_c', toPort=1, type='audio'} },
        },
        ['guid-b'] = {
          trackKind='sourceTrack', trackId='guid-b', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-c', toNode='fx_c', toPort=1, type='audio'} },
        },
        ['guid-c'] = {
          trackKind='newTrack', fxOrder={'fx_c'},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.eq(out['guid-a'].sends[1].dstChan, 0)
      t.eq(out['guid-b'].sends[1].dstChan, 0)
      t.deepEq(out['guid-c'].pinMaps.fx_c.ins[1], {1})
      t.eq(out['guid-c'].nchan, 2)
    end,
  },
  {
    name = 'allocate: midi conns keep srcChan/dstChan = 0, no audio pin map',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1'},
          mainSend=false,
          intraConns={ {from='s', to='fx1', type='midi'} },
          outWires={ {from='fx1', to='guid-b', toNode='fx_b', type='midi'} },
        },
        ['guid-b'] = {
          trackKind='newTrack', fxOrder={'fx_b'},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.eq(out['guid-a'].sends[1].type,    'midi')
      t.eq(out['guid-a'].sends[1].srcChan, 0)
      t.eq(out['guid-a'].sends[1].dstChan, 0)
      t.deepEq(out['guid-a'].pinMaps,      {})
      t.eq(out['guid-a'].nchan,            2)
    end,
  },
  {
    name = 'allocate: gain on outWire flows through to its send',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-b', toNode='fx_b', type='audio', gain=0.25} },
        },
        ['guid-b'] = {
          trackKind='newTrack', fxOrder={'fx_b'},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.eq(out['guid-a'].sends[1].gain, 0.25)
    end,
  },
  {
    name = 'allocate: sends sorted by (to, type, srcChan, dstChan)',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1'},
          mainSend=false,
          intraConns={ {from='s', to='fx1', type='audio'} },
          outWires={
            {from='fx1', to='guid-c', toNode='fx_c',  type='audio'},
            {from='fx1', to='guid-b', toNode='fx_b',  type='midi'},
            {from='fx1', to='guid-b', toNode='fx_b2', type='audio'},
          },
        },
        ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b','fx_b2'},
                       mainSend=false, intraConns={}, outWires={} },
        ['guid-c'] = { trackKind='newTrack', fxOrder={'fx_c'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local out = DAG.allocate(tracks)
      t.eq(out['guid-a'].sends[1].to,   'guid-b')
      t.eq(out['guid-a'].sends[1].type, 'audio')
      t.eq(out['guid-a'].sends[2].to,   'guid-b')
      t.eq(out['guid-a'].sends[2].type, 'midi')
      t.eq(out['guid-a'].sends[3].to,   'guid-c')
    end,
  },
  {
    name = 'allocate: does not mutate input tracks',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-b', toNode='fx_b', type='audio'} },
        },
        ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      DAG.allocate(tracks)
      t.eq(tracks['guid-a'].outWires[1].to, 'guid-b')
      t.eq(tracks['guid-a'].sends,          nil)
      t.eq(tracks['guid-a'].pinMaps,        nil)
      t.eq(tracks['guid-a'].nchan,          nil)
    end,
  },
  {
    name = 'allocate: master-to intra (master-hosted trackKey) anchors fx output to pair 1',
    run = function()
      local tracks = {
        ['__master__'] = {
          trackKind='master', fxOrder={'mix'},
          mainSend=false,
          intraConns={ {from='mix', to='master', type='audio'} },
          outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.deepEq(out['__master__'].pinMaps.mix.outs[1], {1})
      t.eq(out['__master__'].nchan, 2)
    end,
  },
  {
    name = 'mainSendOffs: mainSend=true with no parentFeed defaults to 0',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={},
          mainSend=true, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.eq(out['guid-a'].mainSendOffs, 0)
      t.eq(out['guid-a'].nchan,        2)
    end,
  },
  {
    name = 'mainSendOffs: parentFeed from source (not in fxSet) stays at 0, no pin',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={},
          mainSend=true, parentFeed={from='s', sink='__master__'},
          intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.eq(out['guid-a'].mainSendOffs, 0)
      t.deepEq(out['guid-a'].pinMaps,  {})
    end,
  },
  {
    name = 'mainSendOffs: parentFeed reuses fx input pair in-place (offs=0)',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1'},
          mainSend=true, parentFeed={from='fx1', sink='__master__'},
          intraConns={ {from='s', to='fx1', type='audio'} },
          outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.deepEq(out['guid-a'].pinMaps.fx1.ins[1],  {1})
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {1})
      t.eq(out['guid-a'].mainSendOffs, 0)
      t.eq(out['guid-a'].nchan,        2)
    end,
  },
  {
    name = 'mainSendOffs: chain ending in parentFeed collapses to one pair',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1','fx2','fx3'},
          mainSend=true, parentFeed={from='fx3', sink='__master__'},
          intraConns={
            {from='s',   to='fx1', type='audio'},
            {from='fx1', to='fx2', type='audio'},
            {from='fx2', to='fx3', type='audio'},
          },
          outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.deepEq(out['guid-a'].pinMaps.fx3.outs[1], {1})
      t.eq(out['guid-a'].mainSendOffs, 0)
      t.eq(out['guid-a'].nchan,        2)
    end,
  },
  {
    name = 'mainSendOffs: parentFeed shares its pair with the outgoing send (split-share)',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1'},
          mainSend=true, parentFeed={from='fx1', sink='__master__'},
          intraConns={ {from='s', to='fx1', type='audio'} },
          outWires={ {from='fx1', to='guid-b', toNode='fx_b', type='audio'} },
        },
        ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local out = DAG.allocate(tracks)
      -- fx1's one output pair feeds both readers: send (srcChan=0) and
      -- parentFeed (mainSendOffs=0) read it in place, no replica.
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {1})
      t.eq(out['guid-a'].sends[1].srcChan, 0)
      t.eq(out['guid-a'].mainSendOffs,     0)
      t.eq(out['guid-a'].nchan,            2)
    end,
  },
  {
    name = 'split-share: fx output feeding an intra consumer and a send shares one pair',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1','fx2'},
          mainSend=false,
          intraConns={
            {from='s',   to='fx1', type='audio'},
            {from='fx1', to='fx2', type='audio'},
          },
          outWires={ {from='fx1', to='guid-b', toNode='fx_b', type='audio'} },
        },
        ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local out = DAG.allocate(tracks)
      -- fx1's output pair is read by fx2's input and the send alike.
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {1})
      t.deepEq(out['guid-a'].pinMaps.fx2.ins[1],  {1})
      t.eq(out['guid-a'].sends[1].srcChan, 0)
      t.eq(out['guid-a'].nchan,            2)
    end,
  },
  {
    name = 'mainSendOffs: absent on master-hosted trackKey (mainSend=false)',
    run = function()
      local tracks = {
        ['__master__'] = {
          trackKind='master', fxOrder={'mix'},
          mainSend=false,
          intraConns={ {from='mix', to='master', type='audio'} },
          outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.eq(out['__master__'].mainSendOffs, nil)
    end,
  },
  {
    name = 'mainSendOffs: absent on hosts with mainSend=false',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={},
          mainSend=false, intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.eq(out['guid-a'].mainSendOffs, nil)
    end,
  },
  {
    name = 'preFx: source-out send taps raw input, coexists with fx master feed',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1'},
          mainSend=true, parentFeed={from='fx1', toNode='master', toPort=1, sink='__master__'},
          intraConns={ {from='s', to='fx1', type='audio'} },
          outWires={ {from='s', to='guid-b', toNode='fx_b', type='audio'} },
        },
        ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local out = DAG.allocate(tracks)
      t.deepEq(out['guid-a'].pinMaps.fx1.outs[1], {1})  -- master feed in place on pair 1
      t.eq(out['guid-a'].mainSendOffs, 0)
      t.eq(out['guid-a'].sends[1].srcChan, 0)            -- raw input, tapped pre-fx
      t.eq(out['guid-a'].sends[1].preFx,   true)
    end,
  },
  {
    name = 'preFx: fx-origin send stays post-fx (no preFx flag)',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1'},
          mainSend=false,
          intraConns={ {from='s', to='fx1', type='audio'} },
          outWires={ {from='fx1', to='guid-b', toNode='fx_b', type='audio'} },
        },
        ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local out = DAG.allocate(tracks)
      t.eq(out['guid-a'].sends[1].preFx, nil)
    end,
  },
  {
    name = 'mainSendOffs: master-hosted fx, parent-send OFFS = receiver dest pair (sidechain)',
    run = function()
      local tracks = {
        ['__master__'] = {
          trackKind='master', fxOrder={'comp'},
          mainSend=false,
          intraConns={ {from='comp', to='master', type='audio'} },
          outWires={},
        },
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={},
          mainSend=true, parentFeed={from='sa', toNode='comp', toPort=1, sink='__master__'},
          intraConns={}, outWires={},
        },
        ['guid-b'] = {
          trackKind='sourceTrack', trackId='guid-b', fxOrder={},
          mainSend=true, parentFeed={from='sb', toNode='comp', toPort=2, sink='__master__'},
          intraConns={}, outWires={},
        },
      }
      local out = DAG.allocate(tracks)
      t.deepEq(out['__master__'].pinMaps.comp.ins[1], {1})
      t.deepEq(out['__master__'].pinMaps.comp.ins[2], {2})
      t.eq(out['guid-a'].mainSendOffs, 0)  -- main input → master pair 1
      t.eq(out['guid-b'].mainSendOffs, 2)  -- sidechain → master pair 2
    end,
  },
  {
    name = 'allocate: same input -> same output (determinism)',
    run = function()
      local mk = function()
        return {
          ['guid-a'] = {
            trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1','fx2'},
            mainSend=false,
            intraConns={
              {from='s',   to='fx1', type='audio'},
              {from='fx1', to='fx2', type='audio'},
            },
            outWires={ {from='fx2', to='guid-b', toNode='fx_b', type='audio'} },
          },
          ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b'},
                         mainSend=false, intraConns={}, outWires={} },
        }
      end
      t.deepEq(DAG.allocate(mk()), DAG.allocate(mk()))
    end,
  },
}
