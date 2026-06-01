local t   = require('support')
local DAG = require('DAG')

-- 3c.3a.2 bracket post-pass: park N→0 before a non-bus-aware JSFX terminal
-- consumer whose input arrived on bus N≠0, restore 0→N after. Consumer-
-- producers (hasMidiOut) are skipped until the input==output bus rule lands.

local CU_IDENT = 'JS:Continuum Utility'

-- Stage-2 fixture: two source-tracks each midi-sending into host-c, hitting
-- a distinct terminal-consumer JSFX. fxC2 ends up on bus 1 (fxC1 holds bus 0).
local function twoSendersOneHost(opts)
  opts = opts or {}
  local plan = {
    ['guid-a'] = {
      hostKind='sourceTrack', trackGuid='guid-a', fxOrder={},
      mainSend=false, intraConns={},
      outWires={ {from='s_a', to='guid-c', toNode='fxC1', type='midi'} },
    },
    ['guid-b'] = {
      hostKind='sourceTrack', trackGuid='guid-b', fxOrder={},
      mainSend=false, intraConns={},
      outWires={ {from='s_b', to='guid-c', toNode='fxC2', type='midi'} },
    },
    ['guid-c'] = {
      hostKind='newTrack', fxOrder={'fxC1', 'fxC2'},
      mainSend=false, intraConns={}, outWires={},
    },
  }
  local nodes = {
    fxC1 = { kind='fx', fxIdent='JS:Foo' },
    fxC2 = { kind='fx', fxIdent='JS:Bar', busAware = opts.fxC2BusAware },
  }
  if opts.fxC2NonJsfx then nodes.fxC2.fxIdent = 'VST:Bar' end
  return plan, nodes
end

return {
  {
    name = 'midi bracket: terminal consumer on bus N≠0 gets busSwap CU bridges',
    run = function()
      local plan, nodes = twoSendersOneHost()
      local out = DAG.allocate(plan, nodes)
      local fxOrder = out['guid-c'].fxOrder
      t.deepEq(fxOrder, { 'fxC1', 'bIn:fxC2', 'fxC2', 'bOut:fxC2' })
      local brackets = out['guid-c'].bracketNodes
      t.truthy(brackets, 'bracketNodes table emitted')
      t.eq(brackets['bIn:fxC2'].fxIdent,       CU_IDENT)
      t.eq(brackets['bIn:fxC2'].params.mode,   'busSwap')
      t.eq(brackets['bIn:fxC2'].params.bus,    1)
      t.eq(brackets['bIn:fxC2'].originNode,    'fxC2')
      t.eq(brackets['bIn:fxC2'].originSide,    'in')
      t.eq(brackets['bOut:fxC2'].params.mode,  'busSwap')
      t.eq(brackets['bOut:fxC2'].params.bus,   1)
      t.eq(brackets['bOut:fxC2'].originSide,   'out')
    end,
  },
  {
    name = 'midi bracket: terminal consumer on bus 0 leaves fxOrder untouched',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={'fxC1'},
          mainSend=false,
          intraConns={ {from='s', to='fxC1', type='midi'} },
          outWires={},
        },
      }
      local nodes = { fxC1 = { kind='fx', fxIdent='JS:Foo' } }
      local out = DAG.allocate(plan, nodes)
      t.deepEq(out['guid-a'].fxOrder or {'fxC1'}, {'fxC1'})
      t.eq(out['guid-a'].bracketNodes, nil, 'no bracketNodes for bus-0 consumer')
    end,
  },
  {
    name = 'midi bracket: busAware JSFX is never bracketed (refusal upstream is bypassed here)',
    run = function()
      local plan, nodes = twoSendersOneHost{ fxC2BusAware = true }
      local out = DAG.allocate(plan, nodes)
      t.eq(out['guid-c'].bracketNodes, nil, 'busAware skips bracket')
      t.deepEq(out['guid-c'].fxOrder or {'fxC1','fxC2'}, {'fxC1', 'fxC2'})
    end,
  },
  {
    name = 'midi bracket: non-JSFX fx is never bracketed (VST bus filter is its own slice)',
    run = function()
      local plan, nodes = twoSendersOneHost{ fxC2NonJsfx = true }
      local out = DAG.allocate(plan, nodes)
      t.eq(out['guid-c'].bracketNodes, nil, 'non-JSFX skips bracket')
    end,
  },
  {
    name = 'midi bracket: consumer-producer (hasMidiOut) skips bracket in this slice',
    run = function()
      -- fxC2 has both midi input (from host B's send) AND outgoing midi to host D.
      local plan = {
        ['guid-a'] = {
          hostKind='sourceTrack', trackGuid='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s_a', to='guid-c', toNode='fxC1', type='midi'} },
        },
        ['guid-b'] = {
          hostKind='sourceTrack', trackGuid='guid-b', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s_b', to='guid-c', toNode='fxC2', type='midi'} },
        },
        ['guid-c'] = {
          hostKind='newTrack', fxOrder={'fxC1', 'fxC2'},
          mainSend=false, intraConns={},
          outWires={ {from='fxC2', to='guid-d', toNode='fxD', type='midi'} },
        },
        ['guid-d'] = { hostKind='newTrack', fxOrder={'fxD'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local nodes = {
        fxC1 = { kind='fx', fxIdent='JS:Foo' },
        fxC2 = { kind='fx', fxIdent='JS:Bar' },
        fxD  = { kind='fx', fxIdent='JS:Baz' },
      }
      local out = DAG.allocate(plan, nodes)
      t.eq(out['guid-c'].bracketNodes, nil, 'consumer-producer skipped')
    end,
  },
  {
    name = 'midi bracket: bracket pinMaps pass audio identity on pair 1',
    run = function()
      local plan, nodes = twoSendersOneHost()
      local out = DAG.allocate(plan, nodes)
      local pm = out['guid-c'].pinMaps
      t.deepEq(pm['bIn:fxC2'],  { ins = { [1] = { 1 } }, outs = { [1] = { 1 } } })
      t.deepEq(pm['bOut:fxC2'], { ins = { [1] = { 1 } }, outs = { [1] = { 1 } } })
    end,
  },
  {
    name = 'midi bracket: same input → same output (determinism)',
    run = function()
      local plan, nodes = twoSendersOneHost()
      local a = DAG.allocate(plan, nodes)
      local b = DAG.allocate(plan, nodes)
      t.deepEq(a['guid-c'].fxOrder, b['guid-c'].fxOrder)
      t.deepEq(a['guid-c'].bracketNodes, b['guid-c'].bracketNodes)
    end,
  },
}
