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

local PRESET_ORDER = { '12EDO', '19EDO', '31EDO', '53EDO' }

local cm, chrome, ctx, facade = (...).cm, (...).chrome, (...).ctx, (...).facade
local function tracker() return facade.get('tracker') end

local selected = nil   -- name being viewed; nil follows the active slot

local function viewedName() return selected or cm:get('temper') end

-- Seed a preset into the project library if absent, then make it the project
-- temper. Both writes are project-tier: the editor page is context-free, with
-- no bound take/track to carry take/track-tier slots.
local function seedAndUse(name)
  if not cm:get('tempers')[name] then
    tracker().setTemper(name, tuning.presets[name])
  end
  tracker().setProjectTemper(name)
  selected = name
end

local function draw(w, h)
  chrome.pushChromeStyles()
  ImGui.PushStyleColor(ctx, ImGui.Col_Separator, chrome.colour('toolbar.buttonBorder'))
  if ImGui.BeginChild(ctx, '##temperEditor', w, h) then
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 10, 3)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Seed preset:')
    for _, name in ipairs(PRESET_ORDER) do
      ImGui.SameLine(ctx, 0, 6)
      if ImGui.Button(ctx, name) then seedAndUse(name) end
    end
    ImGui.PopStyleVar(ctx, 1)
    ImGui.Separator(ctx)

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
function self:select(name)         selected = name end
function self:render(w, h, _onClose) draw(w, h) end
function self:modalActive()        return false end
return self
