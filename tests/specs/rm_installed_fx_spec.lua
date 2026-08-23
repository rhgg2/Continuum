-- routingManager Phase 7: installedFx + showFx. Static plugin enumeration
-- (memoised) and floating the window for a live fx id.
local t       = require('support')
local harness = require('harness')
local util    = require('util')

local function mkRm()
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
  return h.reaper, rm
end

local function seedTrack(reaper, name)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', name, true)
  return track
end

return {
  {
    name = 'installedFx enumerates the installed plugins as {ident, name}',
    run = function()
      local reaper, rm = mkRm()
      -- Production shape: EnumInstalledFX hands JS rows a bare path under Effects/.
      -- Every other format's ident is already canonical — VST/VST3 an absolute path,
      -- AU 'Vendor: Name', CLAP the plugin id.
      reaper:setInstalledFx({
        { name = 'VST3: ReaEQ (Cockos)',           ident = '/Library/Audio/Plug-Ins/VST3/ReaEQ.vst3' },
        { name = 'JS: Volume Adjustment',          ident = 'utility/volume' },
        { name = 'AU: BitShiftGain (Airwindows)',  ident = 'Airwindows: BitShiftGain' },
        { name = 'CLAPi: Aeolus (Arthur Benilov)', ident = 'com.ArthurBenilov.Aeolus' },
      })
      local fx = rm:installedFx()
      t.eq(#fx, 4, 'every plugin enumerated')
      t.eq(fx[1].ident, '/Library/Audio/Plug-Ins/VST3/ReaEQ.vst3', 'VST3 path ident untouched')
      t.eq(fx[1].name,  'VST3: ReaEQ (Cockos)')
      t.eq(fx[2].ident, 'JS:utility/volume', "JS ident canonicalised to the 'JS:' form")
      t.eq(fx[3].ident, 'Airwindows: BitShiftGain', 'AU ident untouched')
      t.eq(fx[4].ident, 'com.ArthurBenilov.Aeolus', 'CLAP plugin id untouched')
    end,
  },
  {
    name = 'installedFx memoises the runtime-fixed list',
    run = function()
      local reaper, rm = mkRm()
      reaper:setInstalledFx({ { name = 'A', ident = 'a' } })
      local first = rm:installedFx()
      t.eq(first, rm:installedFx(), 'second call returns the cached table')
    end,
  },
  {
    name = 'showFx floats the window for a live fx id',
    run = function()
      local reaper, rm = mkRm()
      local track = seedTrack(reaper, 'Synth')
      reaper:setTrackFX(track, { { ident = 'VST3:ReaEQ' } })
      reaper:setFxGuid(track, 0, '{FX-eq}')

      t.truthy(rm:showFx('{FX-eq}'))
      local shown
      for _, c in ipairs(reaper._state.calls) do
        if c.fn == 'TrackFX_Show' then shown = c end
      end
      t.truthy(shown, 'TrackFX_Show invoked')
      t.eq(shown.fxIdx,    0)
      t.eq(shown.showFlag, 3, 'floating window')
    end,
  },
  {
    name = 'showFx returns false for an unknown id',
    run = function()
      local _, rm = mkRm()
      t.eq(rm:showFx('{nope}'), false)
    end,
  },
}
