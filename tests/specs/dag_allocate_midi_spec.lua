local t   = require('support')
local DAG = require('DAG')

-- 3c.3a.1 MIDI bus allocator. Per-trackKey live-range allocation on a parallel
-- bus register file (bus 0 = boundary). One value per producer stream
-- (source-midi / per-fx / per-incoming-send); fan-out from one producer shares
-- one bus, distinct producers with overlapping lifetimes get distinct buses.

return {
  {
    name = 'midi: source-midi outgoing send anchored to bus 0',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-b', toNode='fx_b', type='midi'} },
        },
        ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local out = DAG.allocate(tracks)
      t.eq(#out['guid-a'].sends,           1)
      t.eq(out['guid-a'].sends[1].type,    'midi')
      t.eq(out['guid-a'].sends[1].srcChan, 0)
      t.eq(out['guid-a'].sends[1].dstChan, 0)
    end,
  },
  {
    name = 'midi: fx-midi outgoing send reuses bus 0 after source-midi releases',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1'},
          mainSend=false,
          intraConns={ {from='s', to='fx1', type='midi'} },
          outWires={ {from='fx1', to='guid-b', toNode='fx_b', type='midi'} },
        },
        ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local out = DAG.allocate(tracks)
      -- source-midi value [0..1] releases at slot 1; fx1-midi reclaims bus 0.
      t.eq(out['guid-a'].sends[1].srcChan, 0)
    end,
  },
  {
    name = 'midi: source-midi-out keeps boundary live; fx-midi claims fresh bus',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1'},
          mainSend=false,
          intraConns={ {from='s', to='fx1', type='midi'} },
          outWires={
            {from='s',   to='guid-b', toNode='fx_b', type='midi'},
            {from='fx1', to='guid-c', toNode='fx_c', type='midi'},
          },
        },
        ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b'},
                       mainSend=false, intraConns={}, outWires={} },
        ['guid-c'] = { trackKind='newTrack', fxOrder={'fx_c'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local out = DAG.allocate(tracks)
      local toB, toC
      for _, s in ipairs(out['guid-a'].sends) do
        if s.to == 'guid-b' then toB = s end
        if s.to == 'guid-c' then toC = s end
      end
      t.eq(toB.srcChan, 0, 'source on boundary bus 0')
      t.eq(toC.srcChan, 1, 'fx1-midi claims fresh bus 1 (overlapping lifetime)')
    end,
  },
  {
    name = 'midi: per-fx producer fans intra + outgoing onto one bus',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1','fx2'},
          mainSend=false,
          intraConns={
            {from='s',   to='fx1', type='midi'},
            {from='fx1', to='fx2', type='midi'},
          },
          outWires={ {from='fx1', to='guid-b', toNode='fx_b', type='midi'} },
        },
        ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local out = DAG.allocate(tracks)
      -- fx1 emits on one bus; fx2 (intra) and guid-b (out) both consume it.
      t.eq(out['guid-a'].sends[1].srcChan, 0)
    end,
  },
  {
    name = 'midi: branching one producer to two dests shares one src bus',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1'},
          mainSend=false,
          intraConns={ {from='s', to='fx1', type='midi'} },
          outWires={
            {from='fx1', to='guid-b', toNode='fx_b', type='midi'},
            {from='fx1', to='guid-c', toNode='fx_c', type='midi'},
          },
        },
        ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b'},
                       mainSend=false, intraConns={}, outWires={} },
        ['guid-c'] = { trackKind='newTrack', fxOrder={'fx_c'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local out = DAG.allocate(tracks)
      for _, s in ipairs(out['guid-a'].sends) do
        t.eq(s.srcChan, 0, 'shared producer bus')
        t.eq(s.dstChan, 0, 'each receiver allocates alone')
      end
    end,
  },
  {
    name = 'midi: incoming sends to the same receiver node coalesce onto one bus',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-c', toNode='fx_c', type='midi'} },
        },
        ['guid-b'] = {
          trackKind='sourceTrack', trackId='guid-b', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s', to='guid-c', toNode='fx_c', type='midi'} },
        },
        ['guid-c'] = { trackKind='newTrack', fxOrder={'fx_c'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local out = DAG.allocate(tracks)
      t.eq(out['guid-a'].sends[1].dstChan, 0)
      t.eq(out['guid-b'].sends[1].dstChan, 0)
    end,
  },
  {
    name = 'midi: pure midi chain leaves audio side untouched (nchan=2, no pinMaps)',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1'},
          mainSend=false,
          intraConns={ {from='s', to='fx1', type='midi'} },
          outWires={ {from='fx1', to='guid-b', toNode='fx_b', type='midi'} },
        },
        ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local out = DAG.allocate(tracks)
      t.eq(out['guid-a'].nchan, 2)
      t.deepEq(out['guid-a'].pinMaps, {})
    end,
  },
  {
    name = 'midi: same input -> same output (determinism)',
    run = function()
      local mk = function()
        return {
          ['guid-a'] = {
            trackKind='sourceTrack', trackId='guid-a', fxOrder={'fx1','fx2'},
            mainSend=false,
            intraConns={
              {from='s',   to='fx1', type='midi'},
              {from='fx1', to='fx2', type='midi'},
            },
            outWires={ {from='fx2', to='guid-b', toNode='fx_b', type='midi'} },
          },
          ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b'},
                         mainSend=false, intraConns={}, outWires={} },
        }
      end
      t.deepEq(DAG.allocate(mk()), DAG.allocate(mk()))
    end,
  },
}
