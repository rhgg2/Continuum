local t   = require('support')
local DAG = require('DAG')

-- 3c.0 stub allocator: outWires → sends, default 0/0, 4-tuple dedup.
-- Hand-crafted plan inputs cover the contract surface 3c.1 must preserve.

return {
  {
    name = 'allocate: empty plan returns empty',
    run = function()
      t.deepEq(DAG.allocate({}), {})
    end,
  },
  {
    name = 'allocate: passes through hostKind / trackGuid / fxOrder / mainSend / mainSendGain',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind = 'sourceTrack', trackGuid = 'guid-a',
          fxOrder  = { 'f1', 'f2' },
          mainSend = true, mainSendGain = 0.5,
          outWires = {},
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
    name = 'allocate: outWires consumed; sends emitted with srcChan=0, dstChan=0',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind = 'sourceTrack', fxOrder = {}, mainSend = false,
          outWires = { { to = 'guid-b', type = 'audio' } },
        },
        ['guid-b'] = {
          hostKind = 'sourceTrack', fxOrder = {}, mainSend = false,
          outWires = {},
        },
      }
      local out = DAG.allocate(plan)
      t.eq(out['guid-a'].outWires, nil, 'outWires stripped')
      t.deepEq(out['guid-a'].sends,
               { { to = 'guid-b', type = 'audio', srcChan = 0, dstChan = 0 } })
      t.deepEq(out['guid-b'].sends, {})
    end,
  },
  {
    name = 'allocate: two outWires sharing (to, type) collapse to one send (stub default 0/0)',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind = 'sourceTrack', fxOrder = {}, mainSend = false,
          outWires = {
            { to = 'guid-b', type = 'audio' },
            { to = 'guid-b', type = 'audio' },
          },
        },
      }
      local out = DAG.allocate(plan)
      t.eq(#out['guid-a'].sends, 1, 'collision at (to, type, 0, 0)')
      t.eq(out['guid-a'].sends[1].srcChan, 0)
      t.eq(out['guid-a'].sends[1].dstChan, 0)
    end,
  },
  {
    name = 'allocate: distinct (to, type) survive — one send each',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind = 'sourceTrack', fxOrder = {}, mainSend = false,
          outWires = {
            { to = 'guid-b', type = 'audio' },
            { to = 'guid-b', type = 'midi'  },
            { to = 'guid-c', type = 'audio' },
          },
        },
      }
      local out = DAG.allocate(plan)
      t.eq(#out['guid-a'].sends, 3)
    end,
  },
  {
    name = 'allocate: gain on outWire flows through to its send',
    run = function()
      local plan = {
        ['guid-a'] = {
          hostKind = 'sourceTrack', fxOrder = {}, mainSend = false,
          outWires = { { to = 'guid-b', type = 'audio', gain = 0.25 } },
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
          hostKind = 'sourceTrack', fxOrder = {}, mainSend = false,
          outWires = {
            { to = 'guid-c', type = 'audio' },
            { to = 'guid-b', type = 'midi'  },
            { to = 'guid-b', type = 'audio' },
          },
        },
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
          hostKind = 'sourceTrack', fxOrder = {}, mainSend = false,
          outWires = { { to = 'guid-b', type = 'audio' } },
        },
      }
      DAG.allocate(plan)
      t.eq(plan['guid-a'].outWires[1].to, 'guid-b', 'input outWires preserved')
      t.eq(plan['guid-a'].sends,          nil,       'input has no sends field')
    end,
  },
}
