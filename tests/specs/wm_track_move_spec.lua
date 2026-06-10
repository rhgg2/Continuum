-- Pins the no-delete-on-trackKey-move invariant: addFxNode parks on scratch, then
-- CopyToTrack(is_move=true) relocates. Node delete is the one TrackFX_Delete trigger.
local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  -- 'JS:plain' scans as audio-only so the move tests stay bracket-free.
  wm.readJSFXContent = function() return 'desc:plain\n@sample\nspl0 *= 1;\n' end
  wm:load()
  return h, wm
end

local function seedSource(h, guid)
  local track = { __label = 'src-' .. guid }
  table.insert(h.reaper._state.projectTracks, track)
  h.reaper._state.trackGuids[track] = guid
  return track
end

local function instrumentAddByName()
  local calls = 0
  local original = reaper.TrackFX_AddByName
  reaper.TrackFX_AddByName = function(...)
    calls = calls + 1
    return original(...)
  end
  return function() return calls end
end

local function sourceNode(guid)
  return { kind = 'source', trackId = guid, pos = { x = 0, y = 0 },
           ports = { audio = { ins = 0, outs = 1 }, midi = { ins = 0, outs = 1 } } }
end

return {
  {
    name = 'addFxNode parks the FX on scratch with its fxId stamped into the node',
    run = function(harness)
      local h, wm = mkWm(harness)
      reaper:setFxIO('JS:plain', { ins = 2, outs = 2 })  -- 1 stereo port each (pins)
      wm:enableLive()
      local fxId = wm:addFxNode(0, 0, { name = 'Plain', ident = 'JS:plain' })
      local scratch = reaper.GetTrack(0, 0)
      t.eq(reaper.TrackFX_GetCount(scratch), 1, 'fx parked on scratch')
      local fxNode = wm:graph().nodes[fxId]
      t.eq(fxNode.fxId, reaper.TrackFX_GetFXGUID(scratch, 0),
           'node fxId matches the live scratch instance')
    end,
  },
  {
    name = 'wiring source->fx MOVES the live instance; fxId stable, AddByName fires once total',
    run = function(harness)
      local h, wm = mkWm(harness)
      reaper:setFxIO('JS:plain', { ins = 2, outs = 2 })  -- 1 stereo port each (pins)
      local sourceTrack = seedSource(h, 'guid-A')
      local countCalls  = instrumentAddByName()

      wm:enableLive()
      local fxId = wm:addFxNode(0, 0, { name = 'Plain', ident = 'JS:plain' })
      local originalGuid = wm:graph().nodes[fxId].fxId
      t.eq(countCalls(), 1, 'addFxNode mints exactly one instance')

      wm:mutate(function(g)
        g.nodes.src = sourceNode('guid-A')
        util.add(g.edges, { type = 'audio', from = 'src', to = fxId,
                            fromPort = 1, toPort = 1 })
      end)

      -- After seeding the source track, scratch may sit at a different project
      -- index. Locate it by its persisted id (wm:scratchId), not position.
      local scratch
      for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        if wm:isScratchTrack(tr) then scratch = tr; break end
      end
      t.eq(reaper.TrackFX_GetCount(scratch),     0, 'scratch drained — instance moved off')
      t.eq(reaper.TrackFX_GetCount(sourceTrack), 1, 'source track now hosts the fx')
      t.eq(reaper.TrackFX_GetFXGUID(sourceTrack, 0), originalGuid,
           'same fxId — instance was moved, not re-instantiated')
      t.eq(countCalls(), 1, 'no second AddByName; CopyToTrack(is_move=true) did the work')
    end,
  },
  {
    name = 'removing the fx-node from the graph deletes the instance (the one legit delete)',
    run = function(harness)
      local h, wm = mkWm(harness)
      reaper:setFxIO('JS:plain', { ins = 2, outs = 2 })  -- 1 stereo port each (pins)
      wm:enableLive()
      local fxId = wm:addFxNode(0, 0, { name = 'Plain', ident = 'JS:plain' })
      local scratch = reaper.GetTrack(0, 0)
      t.eq(reaper.TrackFX_GetCount(scratch), 1, 'fx on scratch pre-delete')

      wm:mutate(function(g) g.nodes[fxId] = nil end)

      t.eq(reaper.TrackFX_GetCount(scratch), 0,
           'node removed → applier deletes the orphaned instance')
    end,
  },
}
