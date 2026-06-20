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

local swingEditor, temperEditor, cmgr, chrome, gui, modalHost =
  (...).swingEditor, (...).temperEditor, (...).cmgr, (...).chrome, (...).gui, (...).modalHost
local ctx, uiFont, uiSize = gui.ctx, gui.uiFont, gui.fontSize.ui

local pane = 'swing'   -- 'swing' | 'temper'
-- True only when entered via a tracker drop-in (editSwing/editTuning).
-- Gates Close button, page-level Esc, and status hint; cleared on unbind.
local droppedIn = false
local function activePane() return pane == 'temper' and temperEditor or swingEditor end

local function onClose() cmgr:invoke('closeEditor') end

----- Library tree palette (Active / Project / Global tiers; one per pane)

--shape: libraryTreeSpec = { x, y, h, label, active={{col,name}}, project={name}, global={name}, synthetic={[name]=true}, undeletable={[name]=true}, sel={tier,name}, dirty?:bool, onSelect(tier,name), onNew(), onImport?(), onPromote(name), onDemote(name), onReset?(), onDelete(tier,name) }

-- sel.tier scopes the action bar: a folder selection (name=nil) scopes add/import,
-- a leaf arms dup/del. Active's 'select' button resolves an entry to its home tier.
local function libraryActions(spec)
  local sel         = spec.sel or {}
  local synthetic   = sel.name and spec.synthetic and spec.synthetic[sel.name]
  local undeletable = synthetic or (sel.name and spec.undeletable and spec.undeletable[sel.name])
  if ImGui.Button(ctx, 'add') then spec.onNew() end
  if spec.onImport then
    ImGui.SameLine(ctx, 0, 4)
    if ImGui.Button(ctx, 'import') then spec.onImport() end
  end
  ImGui.SameLine(ctx, 0, 4)
  if sel.tier == 'project' and sel.name then
--  chrome.disabledIf(sel.tier ~= 'project', function()
    if ImGui.Button(ctx, 'dup global') then spec.onPromote(sel.name) end   -- ↑G : promote
    --  end)
  end
  ImGui.SameLine(ctx, 0, 4)
  if sel.tier == 'global' and sel.name and not synthetic then
--  chrome.disabledIf(sel.tier ~= 'global' or synthetic, function()
    if ImGui.Button(ctx, 'dup project') then spec.onDemote(sel.name) end   -- ↓P : demote
    --  end)
  end
  ImGui.SameLine(ctx, 0, 4)
  -- reset reverts the selected entry's unsaved edits; only panes that supply
  -- onReset (swing) show it, greyed until the composite differs from snapshot.
  if spec.onReset then
    chrome.disabledIf(not spec.dirty, function()
      if ImGui.Button(ctx, 'reset') then spec.onReset() end
    end)
    ImGui.SameLine(ctx, 0, 4)
  end
  chrome.disabledIf(not sel.name or not (sel.tier == 'project' or sel.tier == 'global') or undeletable, function()
    if ImGui.Button(ctx, 'del') then spec.onDelete(sel.tier, sel.name) end   -- × : delete
  end)
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
      chrome.row(function() libraryActions(spec) end)
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
          libraryRow(spec, 'project', name, name)
        end
      end)
      libraryFolder(spec, 'global', 'Global', function()
        for _, name in ipairs(spec.global or {}) do
          libraryRow(spec, 'global', name, name)
        end
      end)
    end,
  }
end

local er = {}

----------- PUBLIC

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
  -- Page-level Esc returns to the previous page; guarded so an active
  -- InputText/slider keeps Esc to cancel itself, and a sub-modal owns it.
  if droppedIn and not modalHost:isOpen() and not ImGui.IsAnyItemActive(ctx)
     and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
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

function er:renderStatusBar(_)
  local tail = droppedIn and ' · Esc returns' or ''
  ImGui.Text(ctx, ('Editor — %s%s'):format(pane == 'temper' and 'Temper' or 'Swing', tail))
end

--shape: focusState = { suppressKbd:bool, pageSuppressed:bool, acceptCmds:bool }
function er:focusState()
  if not ctx then return { suppressKbd = false, pageSuppressed = false, acceptCmds = false } end
  local suppressKbd = modalHost:isOpen() or chrome.pickerIsActive()
  return {
    suppressKbd    = suppressKbd,
    pageSuppressed = true,
    acceptCmds     = (not suppressKbd) and not ImGui.IsAnyItemActive(ctx),
  }
end

return er
