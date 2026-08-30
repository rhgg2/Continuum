-- See docs/editorPage.md for the model.
-- @noindex
--
-- editorRender draws the library-workbench page: the toolbar pane-selector,
-- the body split (content pane + library tree palette) and the status bar.
-- editorPage owns the panes and delegates every render hook here; this module
-- is handed only the two panes and never reaches cm/ds.

--contract: render-only; owns pane-selection UI state; reaches the swing/temper panes, never cm/ds
--contract: body editor — focusState always page-suppresses (root globals stay live, page bindings off)
if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local swingEditor, temperEditor, cmgr, chrome, gui, keyQueue =
  (...).swingEditor, (...).temperEditor, (...).cmgr, (...).chrome, (...).gui, (...).keyQueue
local ctx, uiFont, uiSize = gui.ctx, gui.uiFont, gui.fontSize.ui

local pane = 'swing'   -- 'swing' | 'temper'
-- True only when entered via a tracker drop-in (editSwing/editTuning).
-- Gates Close button, page-level Esc, and status hint; cleared on unbind.
local droppedIn = false
local function activePane() return pane == 'temper' and temperEditor or swingEditor end

local function onClose() cmgr:invoke('closeEditor') end

----- Library tree palette (Active / Project / Library tiers; one per pane)

--shape: libraryTreeSpec = { x, y, h, label, active={{col,name}}, project={name}, library={name}, synthetic={[name]=true}, undeletable={[name]=true}, modified={[name]=true}, sel={tier,name}, dirty?:bool, onSelect(tier,name), onNew(), onImport?(), onPublish(name), onRevert(name), onImportFactory(name), onTidy?(), onReloadFactory?(), onReset?(), onDelete(tier,name) }

-- ↑/↓ name the far tier and point the way a copy moves through the vertical
-- Active/Project/Library/Factory stack: ↓ sends down, ↑ pulls up.
local ARROW_UP, ARROW_DOWN = '\xe2\x86\x91', '\xe2\x86\x93'

local function has(list, name)
  for _, n in ipairs(list or {}) do if n == name then return true end end
  return false
end

-- A project leaf shadows a source when the same name lives in the library
-- tier; only then can revert restore something.
local function shadowsSource(spec, name)
  return has(spec.library, name)
end

-- Action-bar button emitter: first flush, the rest spaced; `enabled` both gates
-- the click and greys the button, so each verb reads as a single call.
local function actionBar()
  local first = true
  return function(label, enabled, onClick)
    if not first then ImGui.SameLine(ctx, 0, 4) end
    first = false
    chrome.disabledIf(not enabled, function()
      if ImGui.Button(ctx, label) then onClick() end
    end)
  end
end

-- Project-tier action bar: new · del · reset · ↓library(publish) · ↑library(revert)
-- · tidy · import; no edit button since edits auto-fork, leaf verbs grey when they can't act.
local function projectActions(spec)
  local sel  = spec.sel or {}
  local name = sel.name
  local synthetic   = name and spec.synthetic and spec.synthetic[name]
  local undeletable = synthetic or (name and spec.undeletable and spec.undeletable[name])
  local btn = actionBar()
  btn('new', true, spec.onNew)
  btn('del', name ~= nil and not undeletable, function() spec.onDelete('project', name) end)
  if spec.onReset then btn('reset', spec.dirty, spec.onReset) end
  if name and not synthetic then
    btn(ARROW_DOWN .. ' library', true, function() spec.onPublish(name) end)
  end
  if name then
    btn(ARROW_UP .. ' library', shadowsSource(spec, name), function() spec.onRevert(name) end)
  end
  if spec.onTidy and sel.tier == 'project' and name == nil then
    btn('tidy', true, spec.onTidy)
  end
  if spec.onImport then btn('import', true, spec.onImport) end
end

-- Library-tier action bar: new · del · ↑project(revert) · ↑factory. Shown on the
-- folder header and every leaf; the leaf verbs grey on the header (name=nil).
local function libraryActions(spec)
  local sel  = spec.sel or {}
  local name = sel.name
  local undeletable = (name and spec.synthetic and spec.synthetic[name])
                        or (name and spec.undeletable and spec.undeletable[name])
  local btn = actionBar()
  btn('new', true, spec.onNew)
  btn('del', name ~= nil and not undeletable, function() spec.onDelete('global', name) end)
  -- ↑ project reuses revert: library source -> project is the same move as the
  -- project-tier ↑ library, offered from the library side.
  btn(ARROW_UP .. ' project', name ~= nil, function() spec.onRevert(name) end)
  -- ↑ factory: a leaf reimports that one entry (confirm on a divergent copy); the
  -- folder header runs the bulk reload (per-overwrite confirm).
  if name then
    btn(ARROW_UP .. ' factory', true, function() spec.onImportFactory(name) end)
  else
    btn(ARROW_UP .. ' factory', true, spec.onReloadFactory)
  end
end

-- PushID(tier) scopes the row's ImGui id: a promoted entry appears in both
-- Project and Global with the same label, which would otherwise collide.
local function libraryRow(spec, tier, name, label)
  ImGui.PushID(ctx, tier)
  local selected = spec.sel and spec.sel.tier == tier and spec.sel.name == name
  local r = chrome.treeRow{ id = name, label = label, depth = 1,
                            hasChildren = false, selected = selected }
  if r.selected then spec.onSelect(tier, name) end
  ImGui.PopID(ctx)
end

local treeOpen = { project = true, global = true }

-- Disclosure chip toggles the folder; the title row selects the tier (name=nil)
-- so add/import scope to it, and now also toggles. Mirrors the sampler tree.
local function libraryFolder(spec, tier, title, drawChildren)
  local selected = spec.sel and spec.sel.tier == tier and spec.sel.name == nil
  local r = chrome.treeRow{ id = tier, label = title, hasChildren = true,
                            open = treeOpen[tier], selected = selected }
  if r.toggled  then treeOpen[tier] = not treeOpen[tier] end
  if r.selected then spec.onSelect(tier, nil) end
  if treeOpen[tier] then drawChildren() end
end

local function libraryTree(spec)
  chrome.palettePane{
    x = spec.x, y = spec.y, h = spec.h, label = spec.label,
    draw = function()
      chrome.row(function()
        if (spec.sel or {}).tier == 'global' then libraryActions(spec)
        else projectActions(spec) end
      end)
      ImGui.Separator(ctx)
      for _, a in ipairs(spec.active or {}) do
        ImGui.PushID(ctx, a.col)
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.TextDisabled(ctx, ('Active %s: %s'):format(a.col, a.name))
        ImGui.SameLine(ctx)
        if ImGui.SmallButton(ctx, 'select') then spec.onSelect(nil, a.name) end   -- jump to its home tier
        ImGui.PopID(ctx)
      end
      libraryFolder(spec, 'project', 'Project', function()
        for _, name in ipairs(spec.project or {}) do
          local label = spec.modified and spec.modified[name]
                          and (name .. ' \xe2\x80\xa2') or name
          libraryRow(spec, 'project', name, label)
        end
      end)
      libraryFolder(spec, 'global', 'Library', function()
        for _, name in ipairs(spec.library or {}) do
          libraryRow(spec, 'global', name, name)
        end
      end)
    end,
  }
end

local er = {}

---------- PUBLIC

-- Fast path: set the pane + selection; the editTuning/editSwing commands
-- (which hold coord) switch the page. Mirrors samplePage's diveToSampler.
function er:edit(lib, name)
  droppedIn = true
  if lib == 'temper' then
    pane = 'temper'; temperEditor:open(name)
  else
    pane = 'swing';  swingEditor:open(name)
  end
end

-- Page unbind (leaving the editor) ends the drop-in: the next entry must
-- re-earn the Close affordance by coming through edit() again.
function er:unbind() droppedIn = false end

--shape: ToolbarSegment = { id, render = fn(), visible? = fn() -> bool }
local toolbarSegments = {
  {
    id = 'panes',
    render = function()
      local function paneButton(label, id)
        local isActive = pane == id
        if isActive then
          ImGui.PushStyleColor(ctx, ImGui.Col_Button,        chrome.colour('toolbar.buttonActive'))
          ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, chrome.colour('toolbar.buttonActive'))
        end
        if ImGui.Button(ctx, label) and not isActive then pane = id end
        if isActive then ImGui.PopStyleColor(ctx, 2) end
      end
      paneButton('Swing',  'swing')
      ImGui.SameLine(ctx, 0, 4)
      paneButton('Tuning', 'temper')
    end,
  },
  {
    id      = 'paneTools',
    visible = function() return activePane().renderToolbar ~= nil end,
    render  = function() activePane():renderToolbar() end,
  },
  {
    id      = 'close',
    visible = function() return droppedIn end,
    render  = function() if ImGui.Button(ctx, 'Close (Esc)') then onClose() end end,
  },
}

function er:toolbarSegments() return toolbarSegments end

function er:renderBody(_, w, h, dispatch)
  -- Dispatch BEFORE render so focusState reads modal-active while it's set
  -- (same ordering as the tracker path).
  if dispatch then dispatch(self:focusState()) end
  local p = activePane()
  -- Page-level Esc returns to the previous page; the take answers nil to a frame a
  -- sub-modal owns, and the guard keeps Esc for an active InputText or slider drag.
  if droppedIn and not ImGui.IsAnyItemActive(ctx)
     and keyQueue:take(ImGui.Key_Escape) then
    onClose(); return
  end
  if pane == 'swing'  and not swingEditor:isOpen()        then swingEditor:open()  end
  if pane == 'temper' and not temperEditor:hasSelection() then temperEditor:open() end

  -- Body splits into the content pane (variable width) and the fixed-width
  -- library tree palette, mirroring arrange/sampler.
  local ox, oy = ImGui.GetCursorScreenPos(ctx)
  local gridW  = chrome.gridWidth(w)
  ImGui.PushFont(ctx, uiFont, uiSize)
  p:render(gridW, h)
  ImGui.PopFont(ctx)

  local desc = p:libraryDescriptor()
  desc.x, desc.y, desc.h = ox + gridW, oy, h
  libraryTree(desc)
end

local statusSegments = {
  { id = 'pane',  label = 'Pane', width = 60,
    get = function() return pane == 'temper' and 'Temper' or 'Swing' end },
  { id = 'close', width = 95, get = function() return 'Esc returns' end,
    visible = function() return droppedIn end },
}

function er:statusSegments() return statusSegments end

--shape: focusState = { pageSuppressed:bool, acceptCmds:bool }
function er:focusState()
  if not ctx then return { pageSuppressed = false, acceptCmds = false } end
  return {
    pageSuppressed = true,
    acceptCmds     = not ImGui.IsAnyItemActive(ctx),
  }
end

return er
