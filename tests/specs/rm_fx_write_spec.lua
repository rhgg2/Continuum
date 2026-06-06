-- routingManager Phase 3: fx write. addFx/deleteFx/assignFx, addressed by the
-- opaque fx id (guid). Covers append, the append-then-CopyToTrack reorder,
-- cross-track move, param push by name, and delete.
local t       = require('support')
local harness = require('harness')
local util    = require('util')

local function mkRm()
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
  return h.reaper, rm
end

local function seedTrack(reaper, name, fx)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', name, true)
  if fx then reaper:setTrackFX(track, fx) end
  return track, reaper.GetTrackGUID(track)
end

local function fxById(rm, id)
  for _, tr in ipairs(rm:tracks()) do
    for _, fx in ipairs(tr.fx) do if fx.id == id then return fx, tr end end
  end
end

local function chainIdents(rm, name)
  for _, tr in ipairs(rm:tracks()) do
    if tr.name == name then
      local idents = {}
      for _, fx in ipairs(tr.fx) do util.add(idents, fx.ident) end
      return idents
    end
  end
end

return {
  {
    name = 'addFx appends and returns an id that resolves to the new fx',
    run = function()
      local reaper, rm = mkRm()
      local _, tid = seedTrack(reaper, 'Synth', { { ident = 'a' } })

      local id = rm:addFx(tid, { ident = 'b' })
      t.deepEq(chainIdents(rm, 'Synth'), { 'a', 'b' }, 'appended after existing fx')

      local fx, tr = fxById(rm, id)
      t.truthy(fx, 'returned id resolves')
      t.eq(fx.ident, 'b')
      t.eq(tr.name, 'Synth')
    end,
  },
  {
    name = 'addFx with index inserts at position via the append-then-move reorder',
    run = function()
      local reaper, rm = mkRm()
      local _, tid = seedTrack(reaper, 'Chain', { { ident = 'a' }, { ident = 'c' } })

      local id = rm:addFx(tid, { ident = 'b', index = 1 })
      t.deepEq(chainIdents(rm, 'Chain'), { 'a', 'b', 'c' }, 'b landed between a and c')
      t.eq(fxById(rm, id).ident, 'b', 'id tracks the moved fx')
    end,
  },
  {
    name = 'addFx pushes params by name',
    run = function()
      local reaper, rm = mkRm()
      reaper:setFxParamNames('FX:comp', { 'thresh', 'gain' })
      local track, tid = seedTrack(reaper, 'Bus')

      rm:addFx(tid, { ident = 'FX:comp', params = { gain = 0.75 } })
      t.eq(reaper.TrackFX_GetParam(track, 0, 1), 0.75, 'gain set at its slider index')
    end,
  },
  {
    name = 'deleteFx removes the addressed fx',
    run = function()
      local reaper, rm = mkRm()
      local _, tid = seedTrack(reaper, 'Synth', { { ident = 'a' }, { ident = 'b' } })
      local id = rm:addFx(tid, { ident = 'c' })

      rm:deleteFx(id)
      t.deepEq(chainIdents(rm, 'Synth'), { 'a', 'b' }, 'c gone')
      t.falsy(fxById(rm, id), 'deleted id no longer resolves')
    end,
  },
  {
    name = 'assignFx{index} reorders within the track',
    run = function()
      local reaper, rm = mkRm()
      seedTrack(reaper, 'Chain', { { ident = 'a' }, { ident = 'b' }, { ident = 'c' } })
      local idOf = function(ident)
        for _, fx in ipairs(rm:tracks()[1].fx) do if fx.ident == ident then return fx.id end end
      end

      rm:assignFx(idOf('b'), { index = 0 })
      t.deepEq(chainIdents(rm, 'Chain'), { 'b', 'a', 'c' }, 'b moved to the front')
    end,
  },
  {
    name = 'assignFx{track} moves the fx across tracks, id preserved',
    run = function()
      local reaper, rm = mkRm()
      local _, srcId = seedTrack(reaper, 'Src', { { ident = 'x' } })
      local _, dstId = seedTrack(reaper, 'Dst', { { ident = 'y' } })
      local id = rm:tracks()[1].fx[1].id

      rm:assignFx(id, { track = dstId })
      t.deepEq(chainIdents(rm, 'Src'), {}, 'src emptied')
      t.deepEq(chainIdents(rm, 'Dst'), { 'y', 'x' }, 'x appended to dst')

      local fx, tr = fxById(rm, id)
      t.truthy(fx, 'id still resolves after the move')
      t.eq(tr.name, 'Dst')
    end,
  },
  {
    name = 'assignFx{params} sets params on the addressed fx; unknown name raises',
    run = function()
      local reaper, rm = mkRm()
      reaper:setFxParamNames('FX:comp', { 'thresh', 'gain' })
      local track = seedTrack(reaper, 'Bus', { { ident = 'FX:comp' } })
      local id = rm:tracks()[1].fx[1].id

      rm:assignFx(id, { params = { thresh = 0.3 } })
      t.eq(reaper.TrackFX_GetParam(track, 0, 0), 0.3)

      local ok = pcall(function() rm:assignFx(id, { params = { nope = 1 } }) end)
      t.falsy(ok, 'unknown param name raises')
    end,
  },
  {
    name = 'param-name resolution is memoised per ident across instances',
    run = function()
      local reaper, rm = mkRm()
      reaper:setFxParamNames('FX:comp', { 'thresh', 'gain' })
      seedTrack(reaper, 'A', { { ident = 'FX:comp' } })
      seedTrack(reaper, 'B', { { ident = 'FX:comp' } })

      local scans = 0
      local realGetParamName = reaper.TrackFX_GetParamName
      reaper.TrackFX_GetParamName = function(track, fxIdx, p)
        if p == 0 then scans = scans + 1 end
        return realGetParamName(track, fxIdx, p)
      end

      local id1 = rm:tracks()[1].fx[1].id
      local id2 = rm:tracks()[2].fx[1].id
      rm:assignFx(id1, { params = { gain = 0.5 } })
      rm:assignFx(id2, { params = { gain = 0.6 } })

      t.eq(scans, 1, 'param layout scanned once, reused for the second instance')
    end,
  },
}
