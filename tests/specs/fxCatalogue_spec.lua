-- fxCatalogue: the catalogue key and the installed-plugin walk. A VST-family
-- key is the ident's last path part with every byte outside [%w.<] spelt '_'
-- (REAPER's own reaper-vstplugins key), so it survives an update that moves
-- the plugin's files; any other format keys on the ident as reported. Rows
-- carry REAPER's raw ident, and the set is walked afresh on every call.
local t           = require('support')
local harness     = require('harness')
local fxCatalogue = require('fxCatalogue')

-- Real EnumInstalledFX (name, ident) pairs, with REAPER's own key for each.
local ROWS = {
  { name = 'VST: ReaComp (Cockos)',
    ident = '/Applications/REAPER.app/Contents/Plugins/FX/reacomp.vst.dylib',
    format = 'VST', key = 'reacomp.vst.dylib' },
  { name = 'VST3: 8K (Canvas Audio)',
    ident = '/Library/Audio/Plug-Ins/VST3/Effects/EQ/Canvas Audio - 8K.vst3',
    format = 'VST3', key = 'Canvas_Audio___8K.vst3' },
  { name = 'VST3i: Aeolus (Arthur Benilov)',
    ident = '/Library/Audio/Plug-Ins/VST3/Generators/Keys/Aeolus.vst3',
    format = 'VST3i', key = 'Aeolus.vst3' },
  { name = 'JS: Volume Adjustment', ident = 'utility/volume',
    format = 'JS', key = 'utility/volume' },
  { name = 'AU: BitShiftGain (x64) (Airwindows)', ident = 'Airwindows: BitShiftGain',
    format = 'AU', key = 'Airwindows: BitShiftGain' },
  { name = 'CLAPi: Aeolus (Arthur Benilov)', ident = 'com.ArthurBenilov.Aeolus',
    format = 'CLAPi', key = 'com.ArthurBenilov.Aeolus' },
  { name = 'Container', ident = 'Container', format = '', key = 'Container' },
}

local function seed(rows)
  local reaper = harness.mk().reaper
  local list = {}
  for i, row in ipairs(rows) do list[i] = { name = row.name, ident = row.ident } end
  reaper:setInstalledFx(list)
  return reaper
end

return {
  {
    name = 'installed yields key, format, name and raw ident for each format',
    run = function()
      seed(ROWS)
      local rows = fxCatalogue.installed()
      t.eq(#rows, #ROWS, 'one row per installed plugin, in enumeration order')
      for i, want in ipairs(ROWS) do
        t.eq(rows[i].name,   want.name,   want.name .. ': name')
        t.eq(rows[i].ident,  want.ident,  want.name .. ': ident raw from REAPER')
        t.eq(rows[i].format, want.format, want.name .. ': format')
        t.eq(rows[i].key,    want.key,    want.name .. ': key')
      end
    end,
  },
  {
    name = 'a VST3 shell file keys each of its plugins apart by its <id',
    run = function()
      seed({
        { name = 'VST3: Elastika (Sapphire)',
          ident = '/Library/Audio/Plug-Ins/VST3/Effects/Filter/Sapphire.vst3<739473316' },
        { name = 'VST3: Galaxy (Sapphire)',
          ident = '/Library/Audio/Plug-Ins/VST3/Effects/Filter/Sapphire.vst3<1323625663' },
      })
      local rows = fxCatalogue.installed()
      t.eq(rows[1].key, 'Sapphire.vst3<739473316')
      t.eq(rows[2].key, 'Sapphire.vst3<1323625663')
    end,
  },
  {
    name = 'a VST3 relocated to another directory keeps its key',
    run = function()
      seed({
        { name = 'VST3: 8K (Canvas Audio)',
          ident = '/Library/Audio/Plug-Ins/VST3/Effects/EQ/Canvas Audio - 8K.vst3' },
        { name = 'VST3: 8K (Canvas Audio)',
          ident = '/Library/Audio/Plug-Ins/VST3/Canvas Audio - 8K.vst3' },
      })
      local rows = fxCatalogue.installed()
      t.truthy(rows[1].ident ~= rows[2].ident, 'precondition: the idents differ')
      t.eq(rows[1].key, rows[2].key)
    end,
  },
  {
    name = 'key agrees with installed whether or not the format carries the instrument mark',
    run = function()
      local ident = '/Library/Audio/Plug-Ins/VST3/Generators/Keys/Aeolus.vst3'
      seed({ { name = 'VST3i: Aeolus (Arthur Benilov)', ident = ident } })
      local installedKey = fxCatalogue.installed()[1].key
      t.eq(installedKey, 'Aeolus.vst3')
      t.eq(fxCatalogue.key('VST3',  ident), installedKey, 'bare VST3')
      t.eq(fxCatalogue.key('VST3i', ident), installedKey, 'VST3i')
    end,
  },
}
