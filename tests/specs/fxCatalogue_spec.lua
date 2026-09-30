-- fxCatalogue: the catalogue key and the installed-plugin walk. A VST-family
-- key is the ident's last path part with every byte outside [%w.<] spelt '_'
-- (REAPER's own reaper-vstplugins key), so it survives an update that moves
-- the plugin's files; any other format keys on the ident as reported. Rows
-- carry REAPER's raw ident, and the set is walked afresh on every call.
--
-- keyAt keys an fx instance. A VST instance's ident always carries '<id'
-- (VST3 adds '{' and 32 hex, unclosed), but the installed list keeps '<id'
-- only for a shell file's members; so the instance resolves against the
-- installed set, and falls back to the bare file key when not installed.
local t           = require('support')
local harness     = require('harness')
local fxCatalogue = require('fxCatalogue')
local util        = require('util')

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

local VST3DIR = '/Library/Audio/Plug-Ins/VST3/'
local COCKOS  = '/Applications/REAPER.app/Contents/Plugins/FX/'

-- Real (installed ident, instance fx_type, instance fx_ident) triples, probed
-- 2026-09-30, with REAPER's key for the installed row.
local INSTANCES = {
  { name = 'VST: ReaComp (Cockos)', installed = COCKOS .. 'reacomp.vst.dylib',
    fxType = 'VST', ident = COCKOS .. 'reacomp.vst.dylib<1919247213',
    key = 'reacomp.vst.dylib' },
  { name = 'VSTi: ReaSynth (Cockos)', installed = COCKOS .. 'reasynth.vst.dylib',
    fxType = 'VSTi', ident = COCKOS .. 'reasynth.vst.dylib<1919251321',
    key = 'reasynth.vst.dylib' },
  { name = 'VST3: 8K (Canvas Audio)', installed = VST3DIR .. 'Effects/EQ/Canvas Audio - 8K.vst3',
    fxType = 'VST3',
    ident = VST3DIR .. 'Effects/EQ/Canvas Audio - 8K.vst3<1886275761{ABCDEF019182FAEB436E764F4B636444',
    key = 'Canvas_Audio___8K.vst3' },
  { name = 'VST3i: Aeolus (Arthur Benilov)', installed = VST3DIR .. 'Generators/Keys/Aeolus.vst3',
    fxType = 'VST3i',
    ident = VST3DIR .. 'Generators/Keys/Aeolus.vst3<1667713279{ABCDEF019182FAEB4172626545366865',
    key = 'Aeolus.vst3' },
  { name = 'VST3: Elastika (Sapphire)', installed = VST3DIR .. 'Effects/Filter/Sapphire.vst3<739473316',
    fxType = 'VST3',
    ident = VST3DIR .. 'Effects/Filter/Sapphire.vst3<739473316{8135F27069395E078A8B52BA702088D7',
    key = 'Sapphire.vst3<739473316' },
  { name = 'VST3i: Six Sines (Baconpaul)', installed = VST3DIR .. 'Generators/Six Sines.vst3<508894598',
    fxType = 'VST3i',
    ident = VST3DIR .. 'Generators/Six Sines.vst3<508894598{37A66D34E2835683B952CD15E50BAA6C',
    key = 'Six_Sines.vst3<508894598' },
  { name = 'JS: SuperPitch', installed = 'pitch/superpitch',
    fxType = 'JS', ident = 'pitch/superpitch', key = 'pitch/superpitch' },
  { name = 'AU: AUDelay (Apple)', installed = 'Apple: AUDelay',
    fxType = 'AU', ident = 'Apple: AUDelay', key = 'Apple: AUDelay' },
  { name = 'CLAPi: Aeolus (Arthur Benilov)', installed = 'com.ArthurBenilov.Aeolus',
    fxType = 'CLAPi', ident = 'com.ArthurBenilov.Aeolus', key = 'com.ArthurBenilov.Aeolus' },
}

-- A second member of Sapphire's shell file, listed ahead of Elastika so a
-- match on the file alone picks the wrong plugin.
local GALAXY = { name = 'VST3: Galaxy (Sapphire)',
                 ident = VST3DIR .. 'Effects/Filter/Sapphire.vst3<1323625663' }

return {
  {
    name = 'keyAt resolves each format\'s instance to its installed row\'s key',
    run = function()
      local list = { GALAXY }
      local fx   = {}
      for _, row in ipairs(INSTANCES) do
        util.add(list, { name = row.name, ident = row.installed })
        util.add(fx, { ident = row.ident, fxType = row.fxType })
      end
      local reaper = harness.mk().reaper
      reaper:setInstalledFx(list)
      reaper:setTrackFX('fx/track', fx)

      local installedKey = {}
      for _, row in ipairs(fxCatalogue.installed()) do installedKey[row.name] = row.key end
      for i, row in ipairs(INSTANCES) do
        t.eq(installedKey[row.name], row.key, row.name .. ': precondition, installed key')
        t.eq(fxCatalogue.keyAt('fx/track', i - 1), row.key, row.name)
      end
    end,
  },
  {
    name = 'keyAt gives a VST3 missing from the installed set its bare file key',
    run = function()
      local reaper = seed({ GALAXY })
      reaper:setTrackFX('fx/track', { { fxType = 'VST3',
        ident = VST3DIR .. 'Canvas Audio - 8K.vst3<1886275761{ABCDEF019182FAEB436E764F4B636444' } })
      t.eq(fxCatalogue.keyAt('fx/track', 0), 'Canvas_Audio___8K.vst3')
    end,
  },
  {
    name = 'keyAt is nil for an instance reporting an empty ident',
    run = function()
      local reaper = seed({ { name = 'AU: BitShiftGain (x64) (Airwindows)', ident = 'Airwindows: BitShiftGain' } })
      reaper:setTrackFX('fx/track', { { ident = '', fxType = 'AU' } })
      t.eq(fxCatalogue.keyAt('fx/track', 0), nil)
    end,
  },
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
