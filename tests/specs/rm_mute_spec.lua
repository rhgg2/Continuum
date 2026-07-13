-- rm mute primitive: a muted fx has the live pins on its *silencing side* cleared
-- but keeps reporting the real pinout there, so readGraph never loses the wire.
-- A processor silences its INPUT (it then overwrites its outputs with silence); a
-- generator, which ignores input, silences its OUTPUT. Writes to the cleared side
-- divert to the stash; unmute restores it; state persists in fx-meta across reload.
local t       = require('support')
local harness = require('harness')
local util    = require('util')

local function mkRm()
  local h = harness.mk()
  return h.reaper, util.instantiate('routingManager', { ds = h.ds }), h
end

local function seedFx(reaper, rm, io, pinMaps)
  reaper:setFxIO('fx', io)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', 'Fx', true)
  reaper:setTrackFX(track, { { ident = 'fx' } })
  local id = rm:tracks()[1].fx[1].id
  rm:assignFx(id, { pinMaps = pinMaps })
  return track, id
end

-- A stereo-in/stereo-out processor wired 1,2 -> fx -> 1,2.
local function seedProcessor(reaper, rm)
  return seedFx(reaper, rm, { ins = 4, outs = 4 },
    { ins = { [1] = { 1 }, [2] = { 2 } }, outs = { [1] = { 1 }, [2] = { 2 } } })
end

-- An instrument: no audio inputs, stereo out on 1,2.
local function seedGenerator(reaper, rm)
  return seedFx(reaper, rm, { ins = 0, outs = 4 },
    { ins = {}, outs = { [1] = { 1 }, [2] = { 2 } } })
end

local function liveCleared(reaper, track, isoutput)
  for pin = 0, 3 do  -- 4 pins (2 ports) per direction
    local lo, hi = reaper.TrackFX_GetPinMappings(track, 0, isoutput, pin)
    if (lo or 0) ~= 0 or (hi or 0) ~= 0 then return false end
  end
  return true
end

local function reported(rm) return rm:tracks()[1].fx[1].pinMaps end

return {
  {
    name = 'processor mute clears live INPUT pins yet reports the stashed inputs',
    run = function()
      local reaper, rm = mkRm()
      local track, id  = seedProcessor(reaper, rm)

      rm:setMuted(id, true)

      t.eq(rm:muted(id), true, 'reads back as muted')
      t.eq(liveCleared(reaper, track, 0), true, 'live input pins cleared → fx overwrites outs with silence')
      t.eq(liveCleared(reaper, track, 1), false, 'outputs stay live so the fx can overwrite the dry')
      t.deepEq(reported(rm).ins, { [1] = { 1 }, [2] = { 2 } },
               'report still shows the real inputs — the wire survives')
      t.deepEq(reported(rm).outs, { [1] = { 1 }, [2] = { 2 } }, 'outputs untouched by mute')
    end,
  },
  {
    name = 'generator mute clears live OUTPUT pins yet reports the stashed outputs',
    run = function()
      local reaper, rm = mkRm()
      local track, id  = seedGenerator(reaper, rm)

      rm:setMuted(id, true)

      t.eq(rm:muted(id), true, 'reads back as muted')
      t.eq(liveCleared(reaper, track, 1), true, 'live output pins cleared → instrument goes dark')
      t.deepEq(reported(rm).outs, { [1] = { 1 }, [2] = { 2 } },
               'report still shows the real outputs — the wire survives')
    end,
  },
  {
    name = 'a write while muted diverts to the stash; the cleared side stays cleared',
    run = function()
      local reaper, rm = mkRm()
      local track, id  = seedProcessor(reaper, rm)
      rm:setMuted(id, true)

      rm:assignFx(id, { pinMaps = { ins  = { [1] = { 3 } },              -- rewire input while muted
                                    outs = { [1] = { 1 }, [2] = { 2 } } } })

      t.eq(liveCleared(reaper, track, 0), true, 'live input pins still cleared')
      t.deepEq(reported(rm).ins, { [1] = { 3 } }, 'stash updated → report shows the new inputs')
    end,
  },
  {
    name = 'unmute restores the live input pins from the stash',
    run = function()
      local reaper, rm = mkRm()
      local track, id  = seedProcessor(reaper, rm)
      rm:setMuted(id, true)
      rm:setMuted(id, false)

      t.eq(rm:muted(id), false, 'no longer muted')
      t.eq(liveCleared(reaper, track, 0), false, 'live input pins repopulated')
      t.deepEq(reported(rm).ins, { [1] = { 1 }, [2] = { 2 } }, 'real inputs back on the live fx')
    end,
  },
  {
    name = 'unmute after a diverted write restores the latest (diverted) inputs',
    run = function()
      local reaper, rm = mkRm()
      local _, id = seedProcessor(reaper, rm)
      rm:setMuted(id, true)
      rm:assignFx(id, { pinMaps = { ins  = { [1] = { 3 } },
                                    outs = { [1] = { 1 }, [2] = { 2 } } } })
      rm:setMuted(id, false)

      t.deepEq(reported(rm).ins, { [1] = { 3 } }, 'unmute lands the diverted inputs, not the pre-mute ones')
    end,
  },
  {
    name = 'mute persists: a fresh rm still reads muted and reports the wire',
    run = function()
      local reaper, rm, h = mkRm()
      local _, id = seedProcessor(reaper, rm)
      rm:setMuted(id, true)

      -- Fresh ds over the same engine, so the read round-trips through storage
      -- rather than hitting the first ds's cache.
      local rm2 = util.instantiate('routingManager',
        { ds = util.instantiate('dataStore', { ps = h.ps }) })
      t.eq(rm2:muted(id), true, 'a fresh rm still sees the mute (persisted fx-meta)')
      t.deepEq(rm2:tracks()[1].fx[1].pinMaps.ins, { [1] = { 1 }, [2] = { 2 } },
               'wire still reported after the reload')
    end,
  },
}
