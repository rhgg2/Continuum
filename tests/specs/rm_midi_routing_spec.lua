-- routingManager Phase 5: per-FX MIDI routing. tracks() nests fx.midi =
-- { inBus, outBus, outDisabled } for non-JS fx (nil for JS fx). assignFx{midi}
-- drives the in/out bus + out-passthrough bits via state-chunk surgery, which
-- stays private. The chunk addresses FX blocks by non-JS index, so the write
-- must skip JS fx when locating the target block.
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
    name = 'tracks() nests midi for non-JS fx with passthrough defaults',
    run = function()
      local reaper, rm = mkRm()
      seedTrack(reaper, 'Synth', { { ident = 'a' } })

      local midi = rm:tracks()[1].fx[1].midi
      t.deepEq(midi, { inBus = 0, outBus = 0, inDisabled = false, outDisabled = false },
               'default routing: bus 0/0, in/out passthrough on')
    end,
  },
  {
    name = 'JS fx carries no midi record',
    run = function()
      local reaper, rm = mkRm()
      seedTrack(reaper, 'JS', { { ident = 'JS:wat' } })

      t.eq(rm:tracks()[1].fx[1].midi, nil, 'midi nil for JS fx')
    end,
  },
  {
    name = 'assignFx{midi} sets in/out bus; read reflects it',
    run = function()
      local reaper, rm = mkRm()
      seedTrack(reaper, 'Synth', { { ident = 'a' } })
      local id = rm:tracks()[1].fx[1].id

      rm:assignFx(id, { midi = { inBus = 2, outBus = 3 } })

      local midi = rm:tracks()[1].fx[1].midi
      t.eq(midi.inBus,  2, 'in bus written')
      t.eq(midi.outBus, 3, 'out bus written')
    end,
  },
  {
    name = 'assignFx{midi} toggles output passthrough off',
    run = function()
      local reaper, rm = mkRm()
      seedTrack(reaper, 'Synth', { { ident = 'a' } })
      local id = rm:tracks()[1].fx[1].id

      rm:assignFx(id, { midi = { outDisabled = true } })

      t.eq(rm:tracks()[1].fx[1].midi.outDisabled, true, 'output disabled')
    end,
  },
  {
    name = 'midi block index skips JS fx: write lands on the right non-JS fx',
    run = function()
      local reaper, rm = mkRm()
      seedTrack(reaper, 'Mixed', { { ident = 'a' }, { ident = 'JS:mid' }, { ident = 'b' } })
      local fx = rm:tracks()[1].fx
      local idA, idB = fx[1].id, fx[3].id

      rm:assignFx(idB, { midi = { inBus = 5 } })

      local after = rm:tracks()[1].fx
      t.eq(after[1].midi.inBus, 0, 'first non-JS fx untouched')
      t.eq(after[2].midi,       nil, 'JS fx still has no midi')
      t.eq(after[3].midi.inBus, 5, 'second non-JS fx got the bus')
    end,
  },
  {
    name = 'midi block index skips a bare-ident JS fx (real fx_ident has no JS: prefix)',
    run = function()
      local reaper, rm = mkRm()
      -- Real REAPER returns a bare path for a JSFX's fx_ident and fx_type='JS'
      -- (e.g. the stock 'utility/volume' gain insert), never a 'JS:' prefix. It
      -- carries no routing block, so it must not consume a routing-index slot.
      seedTrack(reaper, 'Mixed', {
        { ident = 'utility/volume', fxType = 'JS' },
        { ident = 'b',              fxType = 'VST3' },
      })
      local fx = rm:tracks()[1].fx
      t.eq(fx[1].midi, nil, 'bare-ident JS fx decodes no midi routing')
      local idVst = fx[2].id

      rm:assignFx(idVst, { midi = { outDisabled = true } })

      t.eq(rm:tracks()[1].fx[2].midi.outDisabled, true,
           'routing write lands on the VST, not shifted off the chain end by the JS')
    end,
  },
  {
    name = 'reads routing from the stream tail past a preset name',
    run = function()
      local reaper, rm = mkRm()
      seedTrack(reaper, 'Synth', { { ident = 'a', preset = 'Program 0',
                                     routingBytes = { flag = 0, inBus = 2, outBus = 3 } } })

      local midi = rm:tracks()[1].fx[1].midi
      t.eq(midi.inBus,  2, 'in bus read from the last 4 bytes, not the preset name')
      t.eq(midi.outBus, 3, 'out bus read from the last 4 bytes')
    end,
  },
  {
    name = 'routing write on a preset-bearing fx targets the record, not the name',
    run = function()
      local reaper, rm = mkRm()
      seedTrack(reaper, 'Synth', { { ident = 'a', preset = 'Program 0',
                                     routingBytes = { flag = 0, inBus = 0, outBus = 0 } } })
      local id = rm:tracks()[1].fx[1].id

      rm:assignFx(id, { midi = { inBus = 4 } })

      local midi = rm:tracks()[1].fx[1].midi
      t.eq(midi.inBus,      4,     'in bus written into the record')
      t.eq(midi.outBus,     0,     'out bus untouched')
      t.eq(midi.inDisabled, false, 'flags untouched')
    end,
  },
}
