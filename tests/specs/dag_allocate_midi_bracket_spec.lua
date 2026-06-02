local t   = require('support')
local DAG = require('DAG')

-- Bracket post-pass: BusRoute CU bridges around a non-bus-aware JSFX on bus N≠0.
-- in-park routes N→0 (parking bus-0 transients on output M); out-park swaps 0↔M. Terminal: M=N.

local CU_IDENT = 'JS:Continuum Utility'

-- Stage-2 fixture: two source-tracks each midi-sending into trackKey-c, hitting
-- a distinct terminal-consumer JSFX. fxC2 ends up on bus 1 (fxC1 holds bus 0).
local function twoSendersOneTrack(opts)
  opts = opts or {}
  local tracks = {
    ['guid-a'] = {
      trackKind='sourceTrack', trackGuid='guid-a', fxOrder={},
      mainSend=false, intraConns={},
      outWires={ {from='s_a', to='guid-c', toNode='fxC1', type='midi'} },
    },
    ['guid-b'] = {
      trackKind='sourceTrack', trackGuid='guid-b', fxOrder={},
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
    name = 'midi bracket: terminal consumer on bus N≠0 gets busRoute CU bridges (from==to==N)',
    run = function()
      local tracks, nodes = twoSendersOneTrack()
      local out = DAG.allocate(tracks, nodes)
      local fxOrder = out['guid-c'].fxOrder
      t.deepEq(fxOrder, { 'fxC1', 'bIn:fxC2', 'fxC2', 'bOut:fxC2' })
      local brackets = out['guid-c'].bracketNodes
      t.truthy(brackets, 'bracketNodes table emitted')
      t.eq(brackets['bIn:fxC2'].fxIdent,       CU_IDENT)
      t.eq(brackets['bIn:fxC2'].params.mode,   'busRoute')
      t.eq(brackets['bIn:fxC2'].params.from,   1)
      t.eq(brackets['bIn:fxC2'].params.to,     1)
      t.eq(brackets['bIn:fxC2'].originNode,    'fxC2')
      t.eq(brackets['bIn:fxC2'].originSide,    'in')
      t.eq(brackets['bOut:fxC2'].params.mode,  'busRoute')
      t.eq(brackets['bOut:fxC2'].params.from,  1)
      t.eq(brackets['bOut:fxC2'].params.to,    1)
      t.eq(brackets['bOut:fxC2'].originSide,   'out')
    end,
  },
  {
    name = 'midi bracket: terminal consumer on bus 0 leaves fxOrder untouched',
    run = function()
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackGuid='guid-a', fxOrder={'fxC1'},
          mainSend=false,
          intraConns={ {from='s', to='fxC1', type='midi'} },
          outWires={},
        },
      }
      local nodes = { fxC1 = { kind='fx', fxIdent='JS:Foo' } }
      local out = DAG.allocate(tracks, nodes)
      t.deepEq(out['guid-a'].fxOrder or {'fxC1'}, {'fxC1'})
      t.eq(out['guid-a'].bracketNodes, nil, 'no bracketNodes for bus-0 consumer')
    end,
  },
  {
    name = 'midi bracket: busAware JSFX is never bracketed (refusal upstream is bypassed here)',
    run = function()
      local tracks, nodes = twoSendersOneTrack{ fxC2BusAware = true }
      local out = DAG.allocate(tracks, nodes)
      t.eq(out['guid-c'].bracketNodes, nil, 'busAware skips bracket')
      t.deepEq(out['guid-c'].fxOrder or {'fxC1','fxC2'}, {'fxC1', 'fxC2'})
    end,
  },
  {
    name = 'midi bracket: non-JSFX fx is never bracketed (VST bus filter is its own slice)',
    run = function()
      local tracks, nodes = twoSendersOneTrack{ fxC2NonJsfx = true }
      local out = DAG.allocate(tracks, nodes)
      t.eq(out['guid-c'].bracketNodes, nil, 'non-JSFX skips bracket')
    end,
  },
  {
    name = 'midi bracket: consumer-producer non-bus-aware JSFX brackets (from→0, 0→to)',
    run = function()
      -- fxC2 has both midi input (from trackKey B's send) AND outgoing midi to trackKey D.
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackGuid='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s_a', to='guid-c', toNode='fxC1', type='midi'} },
        },
        ['guid-b'] = {
          trackKind='sourceTrack', trackGuid='guid-b', fxOrder={},
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
      t.truthy(brackets, 'consumer-producer now brackets')
      t.deepEq(out['guid-c'].fxOrder, { 'fxC1', 'bIn:fxC2', 'fxC2', 'bOut:fxC2' })

      local inBus  = brackets['bIn:fxC2'].params.from
      local outBus = brackets['bIn:fxC2'].params.to
      t.eq(inBus, 1, 'input arrived on bus 1 (fxC1 holds bus 0)')
      t.eq(brackets['bIn:fxC2'].params.mode, 'busRoute')
      -- out-park is the 0↔M swap: from==to==output bus.
      t.eq(brackets['bOut:fxC2'].params.from, outBus)
      t.eq(brackets['bOut:fxC2'].params.to,   outBus)

      -- fxC2's outgoing midi send to trackKey-d carries that same output bus.
      local toD
      for _, s in ipairs(out['guid-c'].sends) do
        if s.to == 'guid-d' and s.type == 'midi' then toD = s end
      end
      t.truthy(toD, 'midi send to guid-d present')
      t.eq(toD.srcChan, outBus, 'send src bus == bracket output bus')
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
