local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local wm = util.instantiate('wiringManager', { cm = h.cm })
  return h, wm
end

return {
  {
    name = 'listInstalledFX enumerates reaper.EnumInstalledFX until false',
    run = function(harness)
      local _, wm = mkWm(harness)
      local rows = {
        { 'VST3: ReaEQ (Cockos)',   'VST3:ReaEQ (Cockos)'   },
        { 'VST3: ReaComp (Cockos)', 'VST3:ReaComp (Cockos)' },
        { 'JS: 1175',               'JS:1175'               },
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
      t.eq(list[1].ident, 'VST3:ReaEQ (Cockos)')
      t.eq(list[2].name,  'VST3: ReaComp (Cockos)')
      t.eq(list[3].name,  'JS: 1175')
      t.eq(calls, 4, 'walked indices 0..3 — three hits + one terminating miss')
    end,
  },
  {
    name = 'listInstalledFX caches: second call does not re-enumerate',
    run = function(harness)
      local _, wm = mkWm(harness)
      local calls = 0
      reaper.EnumInstalledFX = function(i)
        calls = calls + 1
        if i == 0 then return true, 'JS: only', 'JS:only' end
        return false
      end
      wm:listInstalledFX()
      local before = calls
      wm:listInstalledFX()
      t.eq(calls, before, 'cache hit; no further enumeration calls')
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
