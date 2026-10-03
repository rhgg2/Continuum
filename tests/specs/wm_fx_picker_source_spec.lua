-- wm:fxPickerSource gathers what the add-fx picker lists over (docs/wiringPage.md
-- § The fx picker): the installed rows, the catalogue, and the catalogue keys of
-- the plugins in the project. "In the project" means an instance in the wiring
-- graph — an fx REAPER holds that the graph does not count.
local t    = require('support')
local util = require('util')

-- ident as EnumInstalledFX hands it; picked as the picker's row carries it (JS canonical).
local COMP  = { name = 'VST3: Comp (Acme)',  ident = '/Library/Audio/Plug-Ins/VST3/Comp.vst3',
                picked = '/Library/Audio/Plug-Ins/VST3/Comp.vst3',  key = 'Comp.vst3' }
local VOL   = { name = 'JS: Volume',         ident = 'utility/volume',
                picked = 'JS:utility/volume',                      key = 'utility/volume' }
local DELAY = { name = 'VST3: Delay (Acme)', ident = '/Library/Audio/Plug-Ins/VST3/Delay.vst3',
                picked = '/Library/Audio/Plug-Ins/VST3/Delay.vst3', key = 'Delay.vst3' }

local function mkWm(harness, opts)
  opts = opts or {}
  local h  = harness.mk()
  h.reaper:setInstalledFx(opts.installed or {})
  for _, fx in ipairs(opts.installed or {}) do h.reaper:setFxIO(fx.picked, { ins = 2, outs = 2 }) end
  h.ds:assign('fxCatalogue', opts.catalogue or { n = 0, entries = {} })
  if opts.masterFx then
    h.reaper:setTrackFX(h.reaper.GetMasterTrack(0), { { ident = opts.masterFx.picked, name = opts.masterFx.name } })
  end
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  wm:load()
  return h, wm
end

local function add(wm, fx)
  local id = wm:addFxNode(0, 0, { name = fx.name, ident = fx.picked })
  t.truthy(id, 'precondition: ' .. fx.name .. ' is added')
  return id
end

return {
  {
    name = 'rows: one walk of EnumInstalledFX to its first miss, names raw, JS idents canonical',
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
      local list = wm:fxPickerSource().rows
      t.eq(#list, 3)
      t.eq(list[1].name,  'VST3: ReaEQ (Cockos)',   'name returned raw')
      t.eq(list[1].ident, '/Library/Audio/Plug-Ins/VST3/ReaEQ.vst3')
      t.eq(list[2].name,  'VST3: ReaComp (Cockos)')
      t.eq(list[3].name,  'JS: 1175')
      t.eq(list[3].ident, 'JS:1175', 'bare JS path canonicalised before it reaches the picker')
      t.eq(calls, 4, 'walked indices 0..3 once — three hits + one terminating miss')
    end,
  },
  {
    name = 'rows: empty when EnumInstalledFX gives nothing',
    run = function(harness)
      local _, wm = mkWm(harness)
      reaper.EnumInstalledFX = function() return false end
      t.eq(#wm:fxPickerSource().rows, 0)
    end,
  },
  {
    name = 'inProject holds exactly the catalogue keys of the graph\'s fx nodes',
    run = function(harness)
      local _, wm = mkWm(harness, { installed = { COMP, VOL, DELAY } })
      t.deepEq(wm:fxPickerSource().inProject, {}, 'precondition: nothing in the project')
      add(wm, COMP)
      add(wm, VOL)
      t.deepEq(wm:fxPickerSource().inProject, { [COMP.key] = true, [VOL.key] = true })
    end,
  },
  {
    -- The master hosts graph fx like any track (docs/wiringManager.md § wiringSnapshot).
    name = 'an fx node the graph reads off the master counts as in the project',
    run = function(harness)
      local _, wm = mkWm(harness, { installed = { COMP }, masterFx = COMP })
      local onMaster = 0
      for _, node in pairs(wm:graph().nodes) do
        if node.kind == 'fx' then onMaster = onMaster + 1 end
      end
      t.eq(onMaster, 1, 'precondition: the read surfaces the master fx as a node')
      t.deepEq(wm:fxPickerSource().inProject, { [COMP.key] = true })
    end,
  },
  {
    name = 'a node dropped from the graph drops its key, whatever REAPER still holds',
    run = function(harness)
      local _, wm = mkWm(harness, { installed = { COMP, VOL } })
      local compId = add(wm, COMP)
      add(wm, VOL)
      t.truthy(wm:fxPickerSource().inProject[COMP.key], 'precondition: Comp counts while in the graph')
      t.truthy(wm:mutate(function(g) g.nodes[compId] = nil end), 'precondition: the drop validates')
      t.deepEq(wm:fxPickerSource().inProject, { [VOL.key] = true })
    end,
  },
  {
    name = 'catalogue is the fxCatalogue ds key as stored',
    run = function(harness)
      local catalogue = { n = 3, entries = { [COMP.key] = { paths = { ['Dynamics'] = true } } } }
      local _, wm = mkWm(harness, { installed = { COMP }, catalogue = catalogue })
      t.deepEq(wm:fxPickerSource().catalogue, catalogue)
    end,
  },
}
