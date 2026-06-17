-- See docs/tuning.md for the temper model.
-- @noindex
--
-- temperEditor is the editor page's tuning pane. Phase 1 is read-only: it
-- shows the active/selected temper's steps and seeds EDO presets into the
-- project library. Cents authoring + Scala import land in phase 2.
local util   = require 'util'
local tuning = require 'tuning'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local cm, chrome, ctx = (...).cm, (...).chrome, (...).ctx

local selected = nil   -- name being viewed; nil follows the active slot
local selTier  = nil   -- tier of the current selection ('project' | 'global')

local function viewedName() return selected or cm:get('temper') end

local SYNTHETIC = { ['12EDO'] = true }

local function projectTempers() return cm:getAt('project', 'tempers') or {} end
-- Reading the global library lazily seeds it from the EDO catalogue (minus the
-- synthetic 12EDO floor) the first time. Mirrors swingEditor's globalSwings.
local function globalTempers()
  cm:seedGlobalFromDefault('tempers', SYNTHETIC)
  return cm:getAt('global', 'tempers') or {}
end

-- A name's editable home: project copy if present, else global (covers the
-- synthetic '12EDO' floor too).
local function homeTier(name)
  if name and projectTempers()[name] ~= nil then return 'project' end
  return 'global'
end

local function sortedNames(tbl)
  local out = {}
  for k in pairs(tbl) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function temperFor(name) return tuning.findTemper(name, cm:get('tempers')) end

local function promote(name)
  if not name then return end
  local g = globalTempers()
  g[name] = util.deepClone(temperFor(name))
  cm:set('global', 'tempers', g)
end

local function demote(name)
  if not name then return end
  local p = projectTempers()
  p[name] = util.deepClone(globalTempers()[name])
  cm:set('project', 'tempers', p)
  selected, selTier = name, 'project'
end

local function deleteSel(tier, name)
  local lib = tier == 'global' and globalTempers() or projectTempers()
  if lib[name] ~= nil then
    lib[name] = nil
    cm:set(tier, 'tempers', lib)
  end
  if projectTempers()[name] or globalTempers()[name] then
    selected, selTier = name, homeTier(name)
  else
    selected, selTier = nil, nil
  end
end

local function buildDescriptor()
  local globalNames = sortedNames(globalTempers())
  if not globalTempers()['12EDO'] then table.insert(globalNames, 1, '12EDO') end
  local active = {}
  local cur    = cm:get('temper')
  if cur then active[1] = { col = 'take', name = cur } end
  return {
    label     = 'Temper',
    active    = active,
    project   = sortedNames(projectTempers()),
    global    = globalNames,
    synthetic = SYNTHETIC,
    sel       = { tier = selTier, name = selected },
    onSelect  = function(tier, name) selected, selTier = name, (tier ~= 'active' and tier or homeTier(name)) end,
    onNew     = function() end,   -- cents authoring lands in phase 2
    onPromote = promote,
    onDemote  = demote,
    onDelete  = deleteSel,
  }
end

local function draw(w, h)
  chrome.pushChromeStyles()
  ImGui.PushStyleColor(ctx, ImGui.Col_Separator, chrome.colour('toolbar.buttonBorder'))
  if ImGui.BeginChild(ctx, '##temperEditor', w, h) then
    local name   = viewedName()
    local temper = name and tuning.findTemper(name, cm:get('tempers'))
    if not temper then
      ImGui.Text(ctx, 'No temperament selected.')
    else
      ImGui.Text(ctx, ('%s   period %g\xc2\xa2   %d steps')
        :format(temper.name, temper.period, #temper.cents))
      ImGui.Separator(ctx)
      if ImGui.BeginChild(ctx, '##temperSteps', 0, 0) then
        for i, c in ipairs(temper.cents) do
          local nm = temper.stepNames and temper.stepNames[i]
          ImGui.Text(ctx, ('%3d   %-4s   %8.2f\xc2\xa2')
            :format(i, (nm and nm ~= '') and nm or '-', c))
        end
      end
      ImGui.EndChild(ctx)
    end
  end
  ImGui.EndChild(ctx)
  ImGui.PopStyleColor(ctx, 1)
  chrome.popChromeStyles()
end

----- Public
local self = {}
function self:select(name) selected, selTier = name, name and homeTier(name) or nil end
function self:render(w, h)  draw(w, h) end
function self:libraryDescriptor() return buildDescriptor() end
function self:modalActive() return false end
return self
