-- Authoring pane for a temperament. See docs/tuning.md, docs/editorPage.md.
-- @noindex
local util   = require 'util'
local tuning = require 'tuning'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local cm, chrome, ctx, gui = (...).cm, (...).chrome, (...).ctx, (...).gui

local CENT       = 'cents'
local TEMPER_ERR = 0xff6060ff
local SYNTHETIC  = { ['12EDO'] = true }

local selected = nil   -- explicitly-selected entry; nil follows the active slot
local selTier  = nil   -- tier of the selection ('project' | 'global')
local snapshot = nil   -- selection-time copy, for dirty-check + Reset
local create   = nil   -- { buf, err?, gen?, refocus? } — New-temper modal substate

local function viewedName() return selected or cm:get('temper') end

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

-- The selected entry's own tier copy. nil when nothing is selected or the
-- selection is a merge-floor with no tier copy — editing needs a dup first.
local function editedTemper()
  return selected and (cm:getAt(selTier, 'tempers') or {})[selected] or nil
end

-- Select without closing the pane; recapture the snapshot so dirty / Reset stay
-- coherent. tier defaults to the home tier.
local function selectTemper(name, tier)
  selected = name
  selTier  = name and (tier or homeTier(name)) or nil
  snapshot = name and util.deepClone(editedTemper() or temperFor(name)) or nil
end

----- Authoring writes

-- Sort the (cents, name) pairs ascending by cents so tuning.lua's ordered
-- assumptions hold; the unison stays at the front at 0.
local function sortSteps(temper)
  local rows = {}
  for i, c in ipairs(temper.cents) do
    rows[i] = { c = c, nm = temper.stepNames[i] or '' }
  end
  table.sort(rows, function(a, b) return a.c < b.c end)
  for i, row in ipairs(rows) do
    temper.cents[i]     = row.c
    temper.stepNames[i] = row.nm
  end
end

-- Sole write path. normalize sorts the steps (after a cents edit crosses a
-- neighbour); tuning.derive restamps octaveStep + cellWidth either way.
local function temperWrite(temper, normalize)
  if normalize then sortSteps(temper) end
  tuning.derive(temper)
  local lib = cm:getAt(selTier, 'tempers') or {}
  lib[selected] = temper
  cm:set(selTier, 'tempers', lib)
end

-- Editable clone with stepNames densified to #cents ('' for unnamed) so sort
-- and table.remove stay array operations.
local function cloneForEdit()
  local t = editedTemper()
  if not t then return nil end
  t = util.deepClone(t)
  t.stepNames = t.stepNames or {}
  for i = 1, #t.cents do t.stepNames[i] = t.stepNames[i] or '' end
  return t
end

local function setStepCents(i, c)
  local t = cloneForEdit(); if not t then return end
  t.cents[i] = c
  temperWrite(t, false)
end

-- On field-commit: re-sort so the edited step lands in pitch order.
local function commitSteps()
  local t = cloneForEdit(); if not t then return end
  temperWrite(t, true)
end

local function setStepName(i, nm)
  local t = cloneForEdit(); if not t then return end
  t.stepNames[i] = nm
  temperWrite(t, false)
end

local function setPeriod(p)
  local t = cloneForEdit(); if not t then return end
  t.period = p
  temperWrite(t, false)
end

local function addStep()
  local t = cloneForEdit(); if not t then return end
  local maxC = t.cents[#t.cents] or 0
  t.cents[#t.cents + 1]     = math.min(maxC + 100, t.period)
  t.stepNames[#t.cents]     = ''
  temperWrite(t, true)
end

local function removeStep(i)
  local t = cloneForEdit(); if not t or i == 1 or #t.cents <= 1 then return end
  table.remove(t.cents, i)
  table.remove(t.stepNames, i)
  temperWrite(t, false)
end

local function dirty()
  return selected ~= nil and editedTemper() ~= nil
     and not util.deepEq(editedTemper(), snapshot)
end

local function resetToSnapshot()
  if not (selected and snapshot) then return end
  temperWrite(util.deepClone(snapshot), false)
end

----- Tier-aware library writes

local function promote(name)
  if not name then return end
  local g = globalTempers()
  g[name] = util.deepClone(temperFor(name))
  cm:set('global', 'tempers', g)
end

local function demote(name)
  if not name then return end
  local p = projectTempers()
  p[name] = util.deepClone(globalTempers()[name] or temperFor(name))
  cm:set('project', 'tempers', p)
  selectTemper(name, 'project')
end

local function deleteSel(tier, name)
  local lib = tier == 'global' and globalTempers() or projectTempers()
  if lib[name] ~= nil then
    lib[name] = nil
    cm:set(tier, 'tempers', lib)
  end
  if projectTempers()[name] or globalTempers()[name] then
    selectTemper(name)
  else
    selectTemper(nil)
  end
end

local function buildDescriptor()
  local globalNames = sortedNames(globalTempers())
  if not globalTempers()['12EDO'] then table.insert(globalNames, 1, '12EDO') end
  local active = {}
  local cur    = cm:get('temper')
  if cur then active[1] = { col = 'take', name = cur } end
  return {
    label     = 'tuning',
    active    = active,
    project   = sortedNames(projectTempers()),
    global    = globalNames,
    synthetic = SYNTHETIC,
    sel       = { tier = selTier, name = selected },
    onSelect  = function(tier, name) selectTemper(name, tier ~= 'active' and tier or nil) end,
    onNew     = function() create = { buf = '' } end,
    onPromote = promote,
    onDemote  = demote,
    onDelete  = deleteSel,
    onReset   = resetToSnapshot,
    dirty     = dirty(),
  }
end

----- Draw

-- Fixed column widths so #, cents and name line up row-to-row.
local STEP_W, CENTS_W, NAME_W, DEL_W = 30, 72, 48, 44
local COL_LABELS = { 'step', 'cents', 'name', '' }

local function drawHeader(temper)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Period:')
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 72)
  local rv, p = ImGui.InputDouble(ctx, '##period', temper.period, 0, 0, '%.2f')
  if rv then setPeriod(p) end
  ImGui.SameLine(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, CENT)
end

-- The grid name box and ui-font cells round to different frame heights at one
-- nominal size; measure the grid box and pad ui widgets up so the row is flush.
local function pushUiPadToGrid()
  ImGui.PushFont(ctx, gui.font, gui.fontSize.ui)
  local gridH = ImGui.GetFrameHeight(ctx)
  ImGui.PopFont(ctx)
  local padX, padY = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, padX,
    padY + (gridH - ImGui.GetFrameHeight(ctx)) / 2)
end

local function drawStepRow(temper, i)
  ImGui.TableNextRow(ctx)
  ImGui.PushID(ctx, i)

  ImGui.TableNextColumn(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, tostring(i))

  ImGui.TableNextColumn(ctx)
  ImGui.SetNextItemWidth(ctx, -1)
  pushUiPadToGrid()
  if i == 1 then ImGui.BeginDisabled(ctx) end   -- the unison is pinned at 0
  local rvC, c = ImGui.InputDouble(ctx, '##c', temper.cents[i], 0, 0, '%.2f')
  if rvC then setStepCents(i, c) end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then commitSteps() end
  if i == 1 then ImGui.EndDisabled(ctx) end
  ImGui.PopStyleVar(ctx)

  -- Names are pitch labels: render in the grid font at the ui size so the field
  -- reads as the note on the tracker grid; ui-font cells pad up to match it.
  ImGui.TableNextColumn(ctx)
  ImGui.SetNextItemWidth(ctx, -1)
  ImGui.PushFont(ctx, gui.font, gui.fontSize.ui)
  local rvN, nm = ImGui.InputText(ctx, '##n', temper.stepNames[i] or '')
  ImGui.PopFont(ctx)
  if rvN then setStepName(i, nm) end

  ImGui.TableNextColumn(ctx)
  if i > 1 then
    pushUiPadToGrid()
    if ImGui.Button(ctx, 'del') then removeStep(i) end
    ImGui.PopStyleVar(ctx)
  end

  ImGui.PopID(ctx)
end

-- Plain dimmed labels rather than TableHeadersRow, whose filled background
-- clashes with the flat chrome.
local function drawColumnLabels()
  ImGui.TableNextRow(ctx)
  for _, label in ipairs(COL_LABELS) do
    ImGui.TableNextColumn(ctx)
    ImGui.TextDisabled(ctx, label)
  end
end

local function drawStepTable(temper)
  local _, availY = ImGui.GetContentRegionAvail(ctx)
  -- Zero vertical cell padding so rows abut with no gap, like the tracker grid.
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_CellPadding, 1, 2)
  if ImGui.BeginTable(ctx, '##temperSteps', 4, ImGui.TableFlags_ScrollY, 0, availY) then
    ImGui.TableSetupColumn(ctx, 'Step',  ImGui.TableColumnFlags_WidthFixed, STEP_W)
    ImGui.TableSetupColumn(ctx, 'Cents', ImGui.TableColumnFlags_WidthFixed, CENTS_W)
    ImGui.TableSetupColumn(ctx, 'Name',  ImGui.TableColumnFlags_WidthFixed, NAME_W)
    ImGui.TableSetupColumn(ctx, '',      ImGui.TableColumnFlags_WidthFixed, DEL_W)
    drawColumnLabels()

    for i = 1, #temper.cents do drawStepRow(temper, i) end

    -- Add lands in the next table row, aligned under the cents column.
    ImGui.TableNextRow(ctx)
    ImGui.TableNextColumn(ctx)
    ImGui.TableNextColumn(ctx)
    pushUiPadToGrid()
    if ImGui.Button(ctx, 'add row') then addStep() end
    ImGui.PopStyleVar(ctx)

    ImGui.EndTable(ctx)
  end
  ImGui.PopStyleVar(ctx)
end

-- '+ New' modal, copied from swingEditor's pattern: lives at draw top-level so
-- the popup isn't bound to the child window's lifetime.
local function drawCreateModal()
  if not create then return end
  create.gen = create.gen or 0
  if not ImGui.IsPopupOpen(ctx, 'New tuning') then
    ImGui.OpenPopup(ctx, 'New tuning')
  end
  local cx, cy = ImGui.Viewport_GetCenter(ImGui.GetWindowViewport(ctx))
  ImGui.SetNextWindowPos(ctx, cx, cy, ImGui.Cond_Appearing, 0.5, 0.5)
  chrome.pushChromeWindow()
  if ImGui.BeginPopupModal(ctx, 'New tuning', true, ImGui.WindowFlags_AlwaysAutoResize) then
    local function dismiss() create = nil; ImGui.CloseCurrentPopup(ctx) end
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Name:')
    ImGui.SameLine(ctx)
    if ImGui.IsWindowAppearing(ctx) or create.refocus then
      ImGui.SetKeyboardFocusHere(ctx)
      create.refocus = nil
    end
    ImGui.SetNextItemWidth(ctx, 240)
    ImGui.PushID(ctx, create.gen)
    local rv, buf = ImGui.InputText(ctx, '##newtemper', create.buf,
      ImGui.InputTextFlags_EnterReturnsTrue)
    ImGui.PopID(ctx)
    create.buf = buf
    ImGui.SameLine(ctx)
    local confirm = rv or ImGui.Button(ctx, 'Create')
    ImGui.SameLine(ctx)
    local cancel  = ImGui.Button(ctx, 'Cancel') or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape)
    if confirm then
      local name = buf and buf:match('^%s*(.-)%s*$')
      local lib  = cm:get('tempers', { mergeTiers = true })
      if not name or name == '' then
        create.err = 'Name required.'
      elseif lib[name] then
        create.err     = 'Name already in use.'
        create.buf     = ''
        create.gen     = create.gen + 1
        create.refocus = true
      else
        local p = projectTempers()
        p[name] = tuning.derive{ name = name, period = 1200, cents = { 0 }, stepNames = {} }
        cm:set('project', 'tempers', p)
        selectTemper(name, 'project')
        dismiss()
      end
    elseif cancel then dismiss() end
    if create and create.err then
      ImGui.TextColored(ctx, TEMPER_ERR, create.err)
    end
    ImGui.EndPopup(ctx)
  end
  chrome.popChromeWindow()
end

local function draw(w, h)
  chrome.pushChromeStyles()
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 9, 2)
  ImGui.PushStyleColor(ctx, ImGui.Col_Separator, chrome.colour('toolbar.buttonBorder'))
  if ImGui.BeginChild(ctx, '##temperEditor', w, h) then
    chrome.paletteHeader('steps')
    local temper   = editedTemper() or temperFor(viewedName())
    local editable = editedTemper() ~= nil
    if not temper then
      ImGui.Text(ctx, 'No temperament selected.')
    else
      -- Greyed when not editable (a merge-floor or the active slot with no tier
      -- copy); still drawn so the chrome doesn't shift. Dup to edit.
      if not editable then ImGui.BeginDisabled(ctx) end
      drawHeader(temper)
      ImGui.Separator(ctx)
      drawStepTable(temper)
      if not editable then ImGui.EndDisabled(ctx) end
    end
    drawCreateModal()
  end
  ImGui.EndChild(ctx)
  ImGui.PopStyleColor(ctx, 1)
  ImGui.PopStyleVar(ctx, 1)
  chrome.popChromeStyles()
end

----- Public
local self = {}
function self:select(name)        selectTemper(name) end
function self:render(w, h)        draw(w, h) end
function self:libraryDescriptor() return buildDescriptor() end
function self:modalActive()       return create ~= nil end
return self
