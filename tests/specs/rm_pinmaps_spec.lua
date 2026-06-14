-- routingManager Phase 4: pin maps. tracks() nests fx.pinMaps = {ins, outs},
-- each keyed by port → { pair, ... }; disconnected ports (zero mask) are absent.
-- assignFx{pinMaps} is a full per-fx replace. Bit math stays private.
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

return {
  {
    name = 'tracks() nests pinMaps; identity pins decode to port→own pair',
    run = function()
      local reaper, rm = mkRm()
      seedTrack(reaper, 'Synth', { { ident = 'a' } })  -- default IO 2/2 = 1 port each

      local pm = rm:tracks()[1].fx[1].pinMaps
      t.deepEq(pm.ins,  { { 1 } }, 'in port 1 maps to pair 1')
      t.deepEq(pm.outs, { { 1 } }, 'out port 1 maps to pair 1')
    end,
  },
  {
    name = 'a port mapped to two pairs reads both; disconnected ports are absent',
    run = function()
      local reaper, rm = mkRm()
      reaper:setFxIO('fan', { ins = 4, outs = 4 })  -- 2 ports each direction
      seedTrack(reaper, 'Fan', { { ident = 'fan' } })
      local id = rm:tracks()[1].fx[1].id

      rm:assignFx(id, { pinMaps = { ins  = { [1] = { 1 }, [2] = { 2 } },
                                    outs = { [1] = { 1, 2 } } } })

      local pm = rm:tracks()[1].fx[1].pinMaps
      t.deepEq(pm.ins,  { { 1 }, { 2 } }, 'both in ports kept')
      t.deepEq(pm.outs, { [1] = { 1, 2 } }, 'out port 1 fans to two pairs; port 2 absent')
    end,
  },
  {
    name = 'a high pair (channels 64-127, second mapping bank) round-trips',
    run = function()
      local reaper, rm = mkRm()
      seedTrack(reaper, 'Synth', { { ident = 'a' } })  -- default IO 2/2 = 1 port
      local id = rm:tracks()[1].fx[1].id

      rm:assignFx(id, { pinMaps = { ins = { [1] = { 40 } } } })  -- pair 40 = chans 78/79

      local pm = rm:tracks()[1].fx[1].pinMaps
      t.deepEq(pm.ins, { [1] = { 40 } }, 'upper-bank pair round-trips through read/write')
    end,
  },
  {
    name = 'assignFx{pinMaps} is a full replace: omitted ports become disconnected',
    run = function()
      local reaper, rm = mkRm()
      reaper:setFxIO('fan', { ins = 4, outs = 4 })
      seedTrack(reaper, 'Fan', { { ident = 'fan' } })
      local id = rm:tracks()[1].fx[1].id

      rm:assignFx(id, { pinMaps = { ins = { [1] = { 1 }, [2] = { 2 } },
                                    outs = { [1] = { 1 }, [2] = { 2 } } } })
      rm:assignFx(id, { pinMaps = { ins = { [2] = { 1 } } } })  -- drop in port 1, all outs

      local pm = rm:tracks()[1].fx[1].pinMaps
      t.deepEq(pm.ins,  { [2] = { 1 } }, 'in port 1 dropped, port 2 re-routed to pair 1')
      t.deepEq(pm.outs, {}, 'outs omitted entirely → all disconnected')
    end,
  },
}
