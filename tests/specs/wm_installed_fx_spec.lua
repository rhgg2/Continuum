local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  return h, wm
end

return {
  {
    name = 'listInstalledFX enumerates reaper.EnumInstalledFX until false',
    run = function(harness)
      local _, wm = mkWm(harness)
      local rows = {
        { 'VST3: ReaEQ (Cockos)',   '/Library/Audio/Plug-Ins/VST3/ReaEQ.vst3'   },
        { 'VST3: ReaComp (Cockos)', '/Library/Audio/Plug-Ins/VST3/ReaComp.vst3' },
        { 'JS: 1175',               '1175'                                      },
      }
      local calls = 0
      reaper.EnumInstalledFX = function(i)
        calls = calls + 1
        local row = rows[i + 1]
        if not row then return false end
        return true, row[1], row[2]
      end
      local list = wm:listInstalledFX()
      t.eq(#list, 3)
      t.eq(list[1].name,  'VST3: ReaEQ (Cockos)',   'name returned raw')
      t.eq(list[1].ident, '/Library/Audio/Plug-Ins/VST3/ReaEQ.vst3')
      t.eq(list[2].name,  'VST3: ReaComp (Cockos)')
      t.eq(list[3].name,  'JS: 1175')
      t.eq(list[3].ident, 'JS:1175', "bare JS path canonicalised before it reaches the picker")
      t.eq(calls, 4, 'walked indices 0..3 — three hits + one terminating miss')
    end,
  },
  {
    name = 'listInstalledFX returns empty list when EnumInstalledFX gives nothing',
    run = function(harness)
      local _, wm = mkWm(harness)
      reaper.EnumInstalledFX = function() return false end
      local list = wm:listInstalledFX()
      t.eq(#list, 0)
    end,
  },
}
