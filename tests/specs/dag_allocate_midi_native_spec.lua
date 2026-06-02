local t   = require('support')
local DAG = require('DAG')

-- 3c.3b.1: the allocator surfaces per-trackKey fxMidiBus[fxId] = {inBus, outBus}
-- for native (non-JS) fx only. inBus is the consumer's resolved input bus,
-- outBus its producer emit bus; both default 0. JSFX (bracket path) and merge
-- CUs (synthNodes) are excluded — 3c.3b.2 reads these for native chunk surgery.

local CU_IDENT = 'JS:Continuum Utility'

return {
  {
    name = 'native: VST consumer surfaces its resolved input bus (JS sibling excluded)',
    run = function()
      -- Two senders into one trackKey; fxC1 (JS) holds bus 0, so fxC2 (VST) lands on 1.
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
        fxC1 = { kind='fx', fxIdent='JS:Foo'  },
        fxC2 = { kind='fx', fxIdent='VST:Bar' },
      }
      local out = DAG.allocate(tracks, nodes)
      t.deepEq(out['guid-c'].fxMidiBus['fxC2'], { inBus = 1, outBus = 0 })
      t.eq(out['guid-c'].fxMidiBus['fxC1'], nil, 'JS fx excluded from fxMidiBus')
      t.eq(out['guid-c'].bracketNodes, nil, 'VST is not bracketed')
    end,
  },
  {
    name = 'native: VST producer outBus matches downstream VST consumer inBus',
    run = function()
      -- source-midi out keeps bus 0 live, so fxP claims bus 1; fxC inherits it.
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackGuid='guid-a', fxOrder={'fxP', 'fxC'},
          mainSend=false,
          intraConns={
            {from='s',   to='fxP', type='midi'},
            {from='fxP', to='fxC', type='midi'},
          },
          outWires={ {from='s', to='guid-b', toNode='fx_b', type='midi'} },
        },
        ['guid-b'] = { trackKind='newTrack', fxOrder={'fx_b'},
                       mainSend=false, intraConns={}, outWires={} },
      }
      local nodes = {
        fxP = { kind='fx', fxIdent='VST:Prod' },
        fxC = { kind='fx', fxIdent='VST:Cons' },
      }
      local out = DAG.allocate(tracks, nodes)
      local fmb = out['guid-a'].fxMidiBus
      t.deepEq(fmb['fxP'], { inBus = 0, outBus = 1 })
      t.deepEq(fmb['fxC'], { inBus = 1, outBus = 0 })
      t.eq(fmb['fxP'].outBus, fmb['fxC'].inBus, 'producer out == consumer in')
    end,
  },
  {
    name = 'native: mixed merge-CU + VST trackKey — synthNode CU excluded, VST present',
    run = function()
      -- Two sources merge through a CU into a native consumer on one trackKey.
      local tracks = {
        ['guid-a'] = {
          trackKind='sourceTrack', trackGuid='guid-a', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s_a', to='guid-c', toNode='cu', type='midi'} },
        },
        ['guid-b'] = {
          trackKind='sourceTrack', trackGuid='guid-b', fxOrder={},
          mainSend=false, intraConns={},
          outWires={ {from='s_b', to='guid-c', toNode='cu', type='midi'} },
        },
        ['guid-c'] = {
          trackKind='newTrack', fxOrder={'cu', 'vstFx'},
          mainSend=false,
          intraConns={ {from='cu', to='vstFx', type='midi'} },
          synthNodes={ cu = { kind='fx', fxIdent=CU_IDENT, params={ mode='merge' } } },
          outWires={},
        },
      }
      local nodes = { vstFx = { kind='fx', fxIdent='VST:Bar' } }
      local out = DAG.allocate(tracks, nodes)
      t.eq(out['guid-c'].fxMidiBus['cu'], nil, 'merge CU excluded from fxMidiBus')
      t.truthy(out['guid-c'].fxMidiBus['vstFx'], 'native consumer present')
    end,
  },
}
