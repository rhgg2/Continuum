local t   = require('support')
local DAG = require('DAG')

-- Bracket post-pass: BusRoute CU around a non-bus-aware JSFX (reads/writes bus 0 only).
-- in-park: input→0, -1 silences disconnected recv, parks transit on bus 127; out-park: retores+routes/swallows.

local CU_IDENT = 'JS:Continuum Utility'
local PARK = 127

-- Stage-2 fixture: two source-tracks each midi-sending into trackKey-c, hitting
-- a distinct terminal-consumer JSFX. fxC2 ends up on bus 1 (fxC1 holds bus 0).
local function twoSendersOneTrack(opts)
  opts = opts or {}
  local tracks = {
    ['guid-a'] = {
      trackKind='sourceTrack', trackId='guid-a', fxOrder={},
      mainSend=false, intraConns={},
      outWires={ {from='s_a', to='guid-c', toNode='fxC1', type='midi'} },
    },
    ['guid-b'] = {
      trackKind='sourceTrack', trackId='guid-b', fxOrder={},
      mainSend=false, intraConns={},
      outWires={ {from='s_b', to='guid-c', toNode='fxC2', type='midi'} },
    },
    ['guid-c'] = {
      trackKind='newTrack', fxOrder={'fxC1', 'fxC2'},
      mainSend=false, intraConns={}, outWires={},
    },
  }
  local nodes = {
    fxC1 = { kind='fx', fxIdent='JS:Foo' },
    fxC2 = { kind='fx', fxIdent='JS:Bar', busAware = opts.fxC2BusAware },
  }
  if opts.fxC2NonJsfx then nodes.fxC2.fxIdent = 'VST:Bar' end
  return tracks, nodes
end

return {
  {
    name = 'midi bracket: terminal consumer on bus N≠0 parks on 127 and swallows its out',
    run = function()
      local tracks, nodes = twoSendersOneTrack()
      local out = DAG.allocate(tracks, nodes)
      t.deepEq(out['guid-c'].fxOrder, { 'fxC1', 'bOut:fxC1', 'bIn:fxC2', 'fxC2', 'bOut:fxC2' })
      local brackets = out['guid-c'].bracketNodes
      t.truthy(brackets, 'bracketNodes table emitted')
      t.eq(brackets['bIn:fxC2'].fxIdent, CU_IDENT)
      t.deepEq(brackets['bIn:fxC2'].params,  { mode='busRoute', from=1,    to=PARK, retain=1 })
      t.deepEq(brackets['bOut:fxC2'].params, { mode='busRoute', from=PARK, to=-1,   retain=0 })
      t.eq(brackets['bIn:fxC2'].originNode,  'fxC2')
      t.eq(brackets['bIn:fxC2'].originSide,  'in')
      t.eq(brackets['bOut:fxC2'].originSide, 'out')
    end,
  },
  {
    name = 'midi bracket: bus-0 consumer needs only the out-blocker',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fxC1'},
          mainSend=false,
          intraConns={ {from='s', to='fxC1', type='midi'} },
          outWires={},
        },
      }
      local nodes = { fxC1 = { kind='fx', fxIdent='JS:Foo' } }
      local out = DAG.allocate(tracks, nodes)
      t.deepEq(out['guid-a'].fxOrder, { 'fxC1', 'bOut:fxC1' })
      local brackets = out['guid-a'].bracketNodes
      t.eq(brackets['bIn:fxC1'], nil, 'no in-park: the fx owns bus 0')
      t.deepEq(brackets['bOut:fxC1'].params, { mode='busRoute', from=-1, to=-1, retain=0 })
    end,
  },
  {
    name = 'midi bracket: busAware JSFX is never bracketed (refusal upstream is bypassed here)',
    run = function()
      local tracks, nodes = twoSendersOneTrack{ fxC2BusAware = true }
      local out = DAG.allocate(tracks, nodes)
      local brackets = out['guid-c'].bracketNodes or {}
      t.eq(brackets['bIn:fxC2'],  nil, 'busAware skips the in-park')
      t.eq(brackets['bOut:fxC2'], nil, 'busAware skips the out-park')
    end,
  },
  {
    name = 'midi bracket: non-JSFX fx is never bracketed (VST bus filter is its own slice)',
    run = function()
      local tracks, nodes = twoSendersOneTrack{ fxC2NonJsfx = true }
      local out = DAG.allocate(tracks, nodes)
      local brackets = out['guid-c'].bracketNodes or {}
      t.eq(brackets['bIn:fxC2'],  nil, 'non-JSFX skips the in-park')
      t.eq(brackets['bOut:fxC2'], nil, 'non-JSFX skips the out-park')
    end,
  },
  {
    name = 'midi bracket: consumer-producer JSFX routes its emission to the allocated out bus',
    run = function()
      -- fxC2 has both midi input (from trackKey B's send) AND outgoing midi to trackKey D.
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s_a', to='guid-c', toNode='fxC1', type='midi'} },
        },
        ['guid-b'] = {
          trackKind='sourceTrack', trackId='guid-b', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s_b', to='guid-c', toNode='fxC2', type='midi'} },
        },
        ['guid-c'] = {
          trackKind='newTrack', fxOrder={'fxC1', 'fxC2'},
          mainSend=false, intraConns={},
          outWires={ {from='fxC2', to='guid-d', toNode='fxD', type='midi'} },
        },
        ['guid-d'] = { trackKind='newTrack', fxOrder={'fxD'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local nodes = {
        fxC1 = { kind='fx', fxIdent='JS:Foo' },
        fxC2 = { kind='fx', fxIdent='JS:Bar' },
        fxD  = { kind='fx', fxIdent='JS:Baz' },
      }
      local out = DAG.allocate(tracks, nodes)
      local brackets = out['guid-c'].bracketNodes
      t.deepEq(out['guid-c'].fxOrder, { 'fxC1', 'bOut:fxC1', 'bIn:fxC2', 'fxC2', 'bOut:fxC2' })
      t.deepEq(brackets['bIn:fxC2'].params, { mode='busRoute', from=1, to=PARK, retain=1 })
      local outBus = brackets['bOut:fxC2'].params.to
      t.truthy(outBus >= 0, 'connected midi-out keeps a real bus')
      t.deepEq(brackets['bOut:fxC2'].params, { mode='busRoute', from=PARK, to=outBus, retain=0 })

      -- fxC2's outgoing midi send to trackKey-d carries that same output bus.
      local toD
      for _, s in ipairs(out['guid-c'].sends) do
        if s.to == 'guid-d' and s.type == 'midi' then toD = s end
      end
      t.truthy(toD, 'midi send to guid-d present')
      t.eq(toD.srcChan, outBus, 'send src bus == out-park target bus')
    end,
  },
  {
    name = 'midi bracket: disconnected midi-in JSFX is silenced; bus-0 stream crosses intact',
    run = function()
      -- fxJ sits unwired in front of a native consumer of the source's bus-0 midi.
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fxJ', 'fxN'},
          mainSend=false,
          intraConns={ {from='s', to='fxN', type='midi'} },
          outWires={},
        },
      }
      local nodes = {
        fxJ = { kind='fx', fxIdent='JS:Loose' },
        fxN = { kind='fx', fxIdent='VST:Synth' },
      }
      local out = DAG.allocate(tracks, nodes)
      t.deepEq(out['guid-a'].fxOrder, { 'bIn:fxJ', 'fxJ', 'bOut:fxJ', 'fxN' })
      local brackets = out['guid-a'].bracketNodes
      t.deepEq(brackets['bIn:fxJ'].params,  { mode='busRoute', from=-1,   to=PARK, retain=1 })
      t.deepEq(brackets['bOut:fxJ'].params, { mode='busRoute', from=PARK, to=-1,   retain=0 })
      t.deepEq(out['guid-a'].fxMidiBus['fxN'], { inBus = 0, outBus = 0 },
               'the parked source stream still reaches the native consumer on bus 0')
    end,
  },
  {
    name = 'midi bracket: pure-audio JSFX (scanned midi 0/0) is never bracketed',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fxJ', 'fxN'},
          mainSend=false,
          intraConns={ {from='s', to='fxN', type='midi'} },
          outWires={},
        },
      }
      local nodes = {
        fxJ = { kind='fx', fxIdent='JS:Gain',
                ports = { audio = { ins=1, outs=1 }, midi = { ins=0, outs=0 } } },
        fxN = { kind='fx', fxIdent='VST:Synth' },
      }
      local out = DAG.allocate(tracks, nodes)
      t.eq(out['guid-a'].bracketNodes, nil, 'no midi surface, no brackets')
    end,
  },
  {
    name = 'midi bracket: send-only JSFX parks the crossing stream before taking its out bus',
    run = function()
      -- fxG emits midi to guid-d while the source's bus-0 stream crosses it to reach fxN.
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackId='guid-a', fxOrder={'fxG', 'fxN'},
          mainSend=false,
          intraConns={ {from='s', to='fxN', type='midi'} },
          outWires={ {from='fxG', to='guid-d', toNode='fxD', type='midi'} },
        },
        ['guid-d'] = { trackKind='newTrack', fxOrder={'fxD'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local nodes = {
        fxG = { kind='fx', fxIdent='JS:Gen',
                ports = { audio = { ins=0, outs=1 }, midi = { ins=0, outs=1 } } },
        fxN = { kind='fx', fxIdent='VST:Synth' },
        fxD = { kind='fx', fxIdent='JS:Sink' },
      }
      local out = DAG.allocate(tracks, nodes)
      local brackets = out['guid-a'].bracketNodes
      t.deepEq(brackets['bIn:fxG'].params, { mode='busRoute', from=-1, to=PARK, retain=1 })
      local outBus = brackets['bOut:fxG'].params.to
      t.truthy(outBus > 0, 'emission moved off the occupied bus 0')
      t.deepEq(brackets['bOut:fxG'].params, { mode='busRoute', from=PARK, to=outBus, retain=0 })
      local toD
      for _, s in ipairs(out['guid-a'].sends) do
        if s.to == 'guid-d' and s.type == 'midi' then toD = s end
      end
      t.eq(toD.srcChan, outBus, 'the outgoing send taps the moved emission')
    end,
  },
  {
    name = 'midi bracket: bracket pinMaps pass audio identity on pair 1',
    run = function()
      local tracks, nodes = twoSendersOneTrack()
      local out = DAG.allocate(tracks, nodes)
      local pm = out['guid-c'].pinMaps
      t.deepEq(pm['bIn:fxC2'],  { ins = { [1] = { 1 } }, outs = { [1] = { 1 } } })
      t.deepEq(pm['bOut:fxC2'], { ins = { [1] = { 1 } }, outs = { [1] = { 1 } } })
      t.deepEq(pm['bOut:fxC1'], { ins = { [1] = { 1 } }, outs = { [1] = { 1 } } })
    end,
  },
  {
    name = 'midi bracket: same input → same output (determinism)',
    run = function()
      local tracks, nodes = twoSendersOneTrack()
      local a = DAG.allocate(tracks, nodes)
      local b = DAG.allocate(tracks, nodes)
      t.deepEq(a['guid-c'].fxOrder, b['guid-c'].fxOrder)
      t.deepEq(a['guid-c'].bracketNodes, b['guid-c'].bracketNodes)
    end,
  },
}
