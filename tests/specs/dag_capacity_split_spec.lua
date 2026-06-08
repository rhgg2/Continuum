-- Capacity bisection (design/wiring-implicit-graph.md § Capacity, step 3): a class whose
-- allocated stream exceeds a REAPER ceiling is split across tracks until each fits. These
-- drive the split directly with a hand-built over-cap partition; the read-side bijection
-- on a *compiled* overflow is pinned by wm_roundtrip_spec.
local t   = require('support')
local DAG = require('DAG')

-- One over-cap track: n fx, each producing one stream value that leaves via a send to a
-- distinct dest, so all n stay live to chain-end (no cascade compression). n past the
-- ceiling forces a bisection. A single FX never exceeds a ceiling, so this is the
-- minimal shape that actually overflows.
local function overCapTracks(kind, n)
  local nodes = {}
  local src = { trackKind = 'sourceTrack', trackId = 'guid-s', fxOrder = {},
                mainSend = false, intraConns = {}, outWires = {} }
  local tracks = { ['guid-s'] = src }
  for i = 1, n do
    local fxId, gId, destKey = 'f' .. i, 'g' .. i, 'd' .. i
    nodes[fxId] = { kind = 'fx', fxIdent = 'VST:x',
                    ports = { audio = { ins = 1, outs = 1 }, midi = { ins = 1, outs = 1 } } }
    nodes[gId]  = { kind = 'fx', fxIdent = 'VST:y',
                    ports = { audio = { ins = 1, outs = 1 }, midi = { ins = 1, outs = 1 } } }
    src.fxOrder[i]  = fxId
    src.outWires[i] = { from = fxId, fromPort = 1, to = destKey, toNode = gId, toPort = 1, type = kind }
    tracks[destKey] = { trackKind = 'newTrack', fxOrder = { gId },
                        mainSend = false, intraConns = {}, outWires = {} }
  end
  return tracks, nodes
end

local CAP_NCHAN = 128 -- REAPER's per-track channel max (64 stereo pairs)

local function trackCount(out)
  local count = 0
  for _ in pairs(out) do count = count + 1 end
  return count
end

return {
  {
    name = 'capacity: 65 audio producers over the ceiling bisect until every track fits',
    run = function()
      local out = DAG.allocate(overCapTracks('audio', 65))
      for _, entry in pairs(out) do
        t.truthy((entry.nchan or 2) <= CAP_NCHAN, 'track within REAPER channel ceiling')
      end
      t.truthy(trackCount(out) > 1 + 65, 'overflow forced a split')
    end,
  },
  {
    name = 'capacity: midi bus overflow bisects too (130 producers past 128 buses)',
    run = function()
      -- midi buses do not raise nchan, so the witness of a resolved overflow is the
      -- extra split tracks (the only pressure here is midi).
      local out = DAG.allocate(overCapTracks('midi', 130))
      t.truthy(trackCount(out) > 1 + 130, 'midi overflow forced a split')
    end,
  },
  {
    name = 'capacity: bisection is deterministic',
    run = function()
      t.deepEq(DAG.allocate(overCapTracks('audio', 65)),
               DAG.allocate(overCapTracks('audio', 65)))
    end,
  },
}
