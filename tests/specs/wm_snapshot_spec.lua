local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local wm = util.instantiate('wiringManager', { cm = h.cm })
  return h, wm
end

-- Seed a tagged source track on the project; returns the track + its GUID.
-- guid arg is the literal guid string fakeReaper will report for the track.
local function seedSourceTrack(h, guid)
  local track = { __label = 'src:' .. guid }
  local list  = h.reaper._state.projectTracks
  list[#list+1] = track
  h.reaper._state.trackGuids[track] = guid
  h.cm:writeTrackKey(track, 'wiringHostKind', 'sourceTrack')
  return track
end

local function seedNewTrack(h, guid, classKey)
  local track = { __label = 'new:' .. guid }
  local list  = h.reaper._state.projectTracks
  list[#list+1] = track
  h.reaper._state.trackGuids[track] = guid
  h.cm:writeTrackKey(track, 'wiringHostKind', 'newTrack')
  h.cm:writeTrackKey(track, 'wiringClass',    classKey)
  return track
end

-- Add an fx with a known guid to a track. Returns the fxIdx.
local function seedFx(h, track, ident, fxGuid)
  local idx = h.reaper.TrackFX_AddByName(track, ident, false, -1)
  h.reaper:setFxGuid(track, idx, fxGuid)
  return idx
end

return {
  {
    name = 'empty project: snapshot only carries the scratch entry',
    run = function(harness)
      local _, wm = mkWm(harness)
      wm:load()  -- creates the scratch track
      local snap = wm:snapshot()
      t.truthy(snap['__scratch__'],            'scratch entry present')
      t.eq(snap['__scratch__'].hostKind, 'scratch')
      t.deepEq(snap['__scratch__'].fxOrder, {})
      t.eq(snap['__scratch__'].mainSend, false)
      t.deepEq(snap['__scratch__'].sends, {})
    end,
  },
  {
    name = 'sourceTrack: classKey is the track guid, mainSend defaults true (REAPER parity)',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, 'guid-A')
      local snap  = wm:snapshot()
      t.truthy(snap['guid-A'],            'entry under track-guid classKey')
      t.eq(snap['guid-A'].hostKind, 'sourceTrack')
      t.eq(snap['guid-A'].trackGuid, 'guid-A')
      t.eq(snap['guid-A'].mainSend, true)
      t.deepEq(snap['guid-A'].fxOrder, {})
      t.deepEq(snap['guid-A'].sends, {})
    end,
  },
  {
    name = 'fxOrder only includes FX whose guid is in the user graph',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, 'guid-A')
      seedFx(h, track, 'JS:owned',   '{FX-1}')
      seedFx(h, track, 'JS:foreign', '{FX-foreign}')
      -- Seed user graph with a node carrying fxGuid='{FX-1}' only.
      wm:mutate(function(g)
        g.nodes['s'] = { kind='source', trackGuid='guid-A', pos={x=0,y=0} }
        g.nodes['f'] = { kind='fx', fxIdent='JS:owned', fxGuid='{FX-1}',
                         pos={x=0,y=0}, audio={ins=1, outs=1} }
      end)
      local snap = wm:snapshot()
      t.eq(#snap['guid-A'].fxOrder, 1, 'foreign FX excluded')
      t.eq(snap['guid-A'].fxOrder[1].fxGuid, '{FX-1}')
      t.eq(snap['guid-A'].fxOrder[1].ident,  'JS:owned')
    end,
  },
  {
    name = 'CU instances on a managed track are filtered out of fxOrder',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, 'guid-A')
      seedFx(h, track, 'JS:owned',             '{FX-1}')
      seedFx(h, track, 'JS:Continuum Utility', '{CU-1}')
      wm:mutate(function(g)
        g.nodes['f'] = { kind='fx', fxIdent='JS:owned', fxGuid='{FX-1}',
                         pos={x=0,y=0}, audio={ins=1, outs=1} }
      end)
      local snap = wm:snapshot()
      t.eq(#snap['guid-A'].fxOrder, 1, 'CU excluded even though guid would match')
      t.eq(snap['guid-A'].fxOrder[1].ident, 'JS:owned')
    end,
  },
  {
    name = 'sends to a managed dst surface as {to=classKey, type=audio|midi}; foreign dst dropped',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local src = seedSourceTrack(h, 'guid-A')
      local dst = seedSourceTrack(h, 'guid-B')
      local foreign = { __label = 'foreign' }
      h.reaper._state.projectTracks[#h.reaper._state.projectTracks+1] = foreign
      h.reaper._state.trackGuids[foreign] = 'guid-foreign'
      h.reaper:addSend(src, dst,     { type = 'audio' })
      h.reaper:addSend(src, foreign, { type = 'audio' })
      h.reaper:addSend(src, dst,     { type = 'midi'  })
      local snap = wm:snapshot()
      t.eq(#snap['guid-A'].sends, 2, 'foreign-dst send dropped')
      local kinds = {}
      for _, s in ipairs(snap['guid-A'].sends) do
        t.eq(s.to, 'guid-B')
        kinds[s.type] = true
      end
      t.truthy(kinds.audio and kinds.midi, 'both send types preserved')
    end,
  },
  {
    name = 'newTrack host: classKey comes from wiringClass key (multi-guid)',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      seedNewTrack(h, 'guid-mix', 'guid-A|guid-B')
      local snap = wm:snapshot()
      t.truthy(snap['guid-A|guid-B'],            'entry under multi-guid classKey')
      t.eq(snap['guid-A|guid-B'].hostKind, 'newTrack')
      t.eq(snap['guid-A|guid-B'].trackGuid, 'guid-mix')
    end,
  },
  {
    name = 'B_MAINSEND=0 round-trips as mainSend=false',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, 'guid-A')
      h.reaper.SetMediaTrackInfo_Value(track, 'B_MAINSEND', 0)
      local snap = wm:snapshot()
      t.eq(snap['guid-A'].mainSend, false)
    end,
  },
}
