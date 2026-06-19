-- Authoring pane for a temperament. See docs/tuning.md, docs/editorPage.md.
-- @noindex
local util   = require 'util'
local tuning = require 'tuning'
local fs     = require 'fs'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local cm, chrome, ctx, gui, modalHost = (...).cm, (...).chrome, (...).ctx, (...).gui, (...).modalHost

local TEMPER_ERR = 0xff6060ff
local SYNTHETIC  = { ['12EDO'] = true }

local selected = nil   -- explicitly-selected entry; nil follows the active slot
local selTier  = nil   -- tier of the selection ('project' | 'global')
local snapshot = nil   -- selection-time copy, for dirty-check + Reset
local openNewModal, openImportModal   -- New/Import modals, hosted by modalHost (defined below)
local editing  = nil   -- { key, buf } in-flight pitch token; commits on deactivate

local DIVIDER_GRAB = 7     -- px hit-height of the steps / generators splitter
local MIN_GEN_AREA = 175   -- px kept below the splitter for the generators pane
local MIN_TOP_AREA = 88    -- px kept above it for the step table

-- Generators pane state. equal keeps relative + absolute degree specs mirrored:
-- editing either updates the other and the divisions readout, live.
local genState = {
  topH = nil, splitDrag = nil, kind = 'equal',
  equal   = { divisions = '12', interval = '2/1',
              relative = '1 1 1 1 1 1 1 1 1 1 1 1',
              absolute = '1 2 3 4 5 6 7 8 9 10 11 12' },
  harm    = { lo = '4', hi = '8' },
  subharm = { lo = '4', hi = '8' },
  chord   = { members = '4:5:6:7', invert = false },
}

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
  selTier  = tier or (name and homeTier(name)) or nil
  snapshot = name and util.deepClone(editedTemper() or temperFor(name)) or nil
end

----- Authoring writes

-- Sort the (pitch, name) pairs ascending by compiled cents so tuning.lua's
-- ordered assumptions hold; the unison (1/1 = 0) stays at the front.
local function sortSteps(temper)
  local rows = {}
  for i, tok in ipairs(temper.pitches) do
    rows[i] = { tok = tok, nm = temper.stepNames[i] or '', c = tuning.scalaPitch(tok) or 0 }
  end
  table.sort(rows, function(a, b) return a.c < b.c end)
  for i, row in ipairs(rows) do
    temper.pitches[i]   = row.tok
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

-- Editable clone with pitches/stepNames densified to a common length ('' for
-- unnamed) so sort and table.remove stay array operations.
local function cloneForEdit()
  local t = editedTemper()
  if not t then return nil end
  t = util.deepClone(t)
  t.pitches   = t.pitches or {}
  t.stepNames = t.stepNames or {}
  for i = 1, #t.pitches do t.stepNames[i] = t.stepNames[i] or '' end
  return t
end

-- Re-sort on commit so the edited step lands in pitch order; derive recompiles
-- cents from the token.
local function setStepPitch(i, tok)
  local t = cloneForEdit(); if not t then return end
  t.pitches[i] = tok
  temperWrite(t, true)
end

local function setStepName(i, nm)
  local t = cloneForEdit(); if not t then return end
  t.stepNames[i] = nm
  temperWrite(t, false)
end

local function setPeriodPitch(tok)
  local t = cloneForEdit(); if not t then return end
  t.periodPitch = tok
  temperWrite(t, false)
end

local function setPeriodAsStep(on)
  local t = cloneForEdit(); if not t then return end
  t.periodAsStep = on
  temperWrite(t, false)
end

local function addStep()
  local t = cloneForEdit(); if not t then return end
  local maxC = t.cents[#t.cents] or 0
  t.pitches[#t.pitches + 1] = string.format('%.2f', math.min(maxC + 100, t.period))
  t.stepNames[#t.pitches]   = ''
  temperWrite(t, true)
end

local function removeStep(i)
  local t = cloneForEdit(); if not t or i == 1 or #t.pitches <= 1 then return end
  table.remove(t.pitches, i)
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

-- Replace the selected temper's scale wholesale from a generator result
-- ({pitches, periodPitch, periodAsStep}); names clear, tokens arrive ascending.
local function generateInto(gen)
  local t = cloneForEdit(); if not t then return end
  t.pitches      = { table.unpack(gen.pitches) }
  t.periodPitch  = gen.periodPitch
  t.periodAsStep = gen.periodAsStep
  t.stepNames    = {}
  temperWrite(t, true)
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
    onSelect  = function(tier, name) selectTemper(name, tier) end,
    onNew     = openNewModal,
    onImport  = openImportModal,
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
local COL_LABELS = { 'step', 'pitch', 'name', '' }

-- Pitch-token text box: shows `current` until focused; commits via commit(tok) on
-- deactivate only when the token parses — invalid input reverts next frame.
local function tokenBox(idStr, key, current, commit)
  local shown = (editing and editing.key == key) and editing.buf or current
  local rv, buf = ImGui.InputText(ctx, idStr, shown)
  if rv then editing = { key = key, buf = buf } end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) and editing and editing.key == key then
    if tuning.scalaPitch(editing.buf) then commit(editing.buf) end
    editing = nil
  end
end

-- Period sits in its own box, unless periodAsStep moves it to the table's last
-- row; the checkbox toggles that per-temper display preference.
local function drawHeader(temper)
  ImGui.AlignTextToFramePadding(ctx)
  if not temper.periodAsStep then
    ImGui.Text(ctx, 'Period:')
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 72)
    tokenBox('##period', 'period', temper.periodPitch or '2/1', setPeriodPitch)
    ImGui.SameLine(ctx)
  end
  local rv, on = chrome.checkbox('period as last step', temper.periodAsStep or false)
  if rv then setPeriodAsStep(on) end
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
  if i == 1 then ImGui.BeginDisabled(ctx) end   -- the unison is pinned at 1/1
  tokenBox('##c', i, temper.pitches[i], function(tok) setStepPitch(i, tok) end)
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
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_CellPadding, 0, 1)
  if ImGui.BeginTable(ctx, '##temperSteps', 4, ImGui.TableFlags_ScrollY, 0, availY) then
    ImGui.TableSetupColumn(ctx, 'Step',  ImGui.TableColumnFlags_WidthFixed, STEP_W)
    ImGui.TableSetupColumn(ctx, 'Cents', ImGui.TableColumnFlags_WidthFixed, CENTS_W)
    ImGui.TableSetupColumn(ctx, 'Name',  ImGui.TableColumnFlags_WidthFixed, NAME_W)
    ImGui.TableSetupColumn(ctx, '',      ImGui.TableColumnFlags_WidthFixed, DEL_W)
    drawColumnLabels()

    for i = 1, #temper.pitches do drawStepRow(temper, i) end

    -- periodAsStep: the period shows as a trailing row (still backed by
    -- periodPitch, not a step) so the scale reads top-to-bottom like a Scala file.
    if temper.periodAsStep then
      ImGui.TableNextRow(ctx)
      ImGui.PushID(ctx, 'period')
      ImGui.TableNextColumn(ctx)
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.TextDisabled(ctx, 'P')
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      pushUiPadToGrid()
      tokenBox('##period', 'period', temper.periodPitch or '2/1', setPeriodPitch)
      ImGui.PopStyleVar(ctx)
      ImGui.PopID(ctx)
    end

    -- Add lands in the next table row, aligned under the pitch column.
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

-- New + Import modals, hosted by modalHost (kinds registered below). The opener
-- captures the target tier; the render keeps the popup open on a name clash.
openNewModal = function()
  local tier = selTier or 'project'
  modalHost:open{
    kind = 'temperNew', title = 'New tuning', buf = '',
    callback = function(name)
      local p = tier == 'global' and globalTempers() or projectTempers()
      p[name] = tuning.derive{ name = name, periodPitch = '2/1', pitches = { '1/1' }, stepNames = {} }
      cm:set(tier, 'tempers', p)
      selectTemper(name, tier)
    end,
  }
end

openImportModal = function()
  local tier = selTier or 'project'
  modalHost:open{
    kind = 'temperImport', title = 'Import tuning', buf = '', name = '',
    callback = function(name, temper)
      local p = tier == 'global' and globalTempers() or projectTempers()
      p[name] = temper
      cm:set(tier, 'tempers', p)
      selectTemper(name, tier)
    end,
  }
end

modalHost:registerKind('temperNew', function(s, close)
  if ImGui.IsWindowAppearing(ctx) or s.refocus then
    ImGui.SetKeyboardFocusHere(ctx); s.refocus = nil
  end
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Name:')
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 240)
  s.gen = s.gen or 0
  ImGui.PushID(ctx, s.gen)
  local rv, buf = ImGui.InputText(ctx, '##newtemper', s.buf, ImGui.InputTextFlags_EnterReturnsTrue)
  ImGui.PopID(ctx)
  s.buf = buf
  ImGui.SameLine(ctx)
  local confirm = rv or ImGui.Button(ctx, 'Create')
  ImGui.SameLine(ctx)
  local cancel  = ImGui.Button(ctx, 'Cancel') or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape)
  if confirm then
    local name = (buf or ''):match('^%s*(.-)%s*$')
    if name == '' then
      s.err = 'Name required.'
    elseif cm:get('tempers', { mergeTiers = true })[name] then
      s.err = 'Name already in use.'; s.buf = ''; s.gen = s.gen + 1; s.refocus = true
    else
      close(true, name)
    end
  elseif cancel then close(false) end
  if s.err then ImGui.TextColored(ctx, TEMPER_ERR, s.err) end
end)

modalHost:registerKind('temperImport', function(s, close)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Name:')
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 200)
  local rvN, nm = ImGui.InputText(ctx, '##importname', s.name or '')
  if rvN then s.name = nm end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Load .scl…') then
    local ok, path = reaper.GetUserFileNameForRead('', 'Import Scala scale', '.scl')
    if ok then
      local text = fs.readText(path)
      if text then
        local pitches, desc = tuning.parseScalaFile(text)
        s.buf = table.concat(pitches, '\n')
        if (s.name or '') == '' then s.name = (desc ~= '' and desc) or fs.basename(path) end
      end
    end
  end
  ImGui.TextDisabled(ctx, 'Scala pitches, one per line (e.g. 9/8 or 204.0):')
  local rvB, buf = ImGui.InputTextMultiline(ctx, '##importbuf', s.buf or '', 320, 200)
  if rvB then s.buf = buf end
  local confirm = ImGui.Button(ctx, 'Create')
  ImGui.SameLine(ctx)
  local cancel  = ImGui.Button(ctx, 'Cancel') or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape)
  if confirm then
    local name = (s.name or ''):match('^%s*(.-)%s*$')
    if name == '' then
      s.err = 'Name required.'
    elseif cm:get('tempers', { mergeTiers = true })[name] then
      s.err = 'Name already in use.'
    else
      local temper, perr = tuning.scalaToTemper(tuning.parseScalaPitches(s.buf or ''), name)
      if not temper then s.err = perr
      else close(true, name, temper) end
    end
  elseif cancel then close(false) end
  if s.err then ImGui.TextColored(ctx, TEMPER_ERR, s.err) end
end)

----- Generators pane

local GEN_KINDS = {
  { id = 'equal',   label = 'Equal' },
  { id = 'harm',    label = 'Harmonics' },
  { id = 'subharm', label = 'Subharmonics' },
  { id = 'chord',   label = 'Chord' },
}

-- Pane-selector pill. Pushes the editor-zone button colours (one zone below the
-- toolbar's, since editor.bg is darker); active stays recessed/lit.
local function pillButton(label, active)
  local fill = chrome.colour(active and 'editor.buttonActive' or 'editor.button')
  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        fill)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, fill)
  local hit = ImGui.Button(ctx, label)
  ImGui.PopStyleColor(ctx, 2)
  return hit
end

local function genKindSelector()
  for i, k in ipairs(GEN_KINDS) do
    if i > 1 then ImGui.SameLine(ctx, 0, 4) end
    if pillButton(k.label, genState.kind == k.id) then genState.kind = k.id end
  end
end

local function labeledInput(label, w, value)
  ImGui.AlignTextToFramePadding(ctx); ImGui.Text(ctx, label); ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, w)
  return ImGui.InputText(ctx, '##' .. label, value)
end

local function reseedEqual(e, n)
  local degs = {}; for i = 1, n do degs[i] = i end
  e.relative  = tuning.degreesToSpec(degs, 'relative')
  e.absolute  = tuning.degreesToSpec(degs, 'absolute')
  e.divisions = tostring(n)
end

local function drawEqualFields()
  local e = genState.equal
  local rvD, dbuf = labeledInput('Divisions', 56, e.divisions)
  if rvD then e.divisions = dbuf end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then
    local n = tonumber(e.divisions)
    if n and n >= 1 then reseedEqual(e, math.floor(n)) end
  end
  ImGui.SameLine(ctx)
  local rvI, ibuf = labeledInput('of', 56, e.interval)
  if rvI then e.interval = ibuf end

  -- Relative and absolute mirror each other: a valid edit to one rewrites the
  -- other (and divisions = largest degree); the typed field is left untouched.
  local rvR, rbuf = labeledInput('Relative', 180, e.relative)
  if rvR then
    e.relative = rbuf
    local degs = tuning.edoDegrees(e.relative, 'relative')
    if degs then e.absolute = tuning.degreesToSpec(degs, 'absolute'); e.divisions = tostring(degs[#degs]) end
  end
  local rvA, abuf = labeledInput('Absolute', 180, e.absolute)
  if rvA then
    e.absolute = abuf
    local degs = tuning.edoDegrees(e.absolute, 'absolute')
    if degs then e.relative = tuning.degreesToSpec(degs, 'relative'); e.divisions = tostring(degs[#degs]) end
  end
end

local function drawSeriesFields(p, lowLabel, highLabel)
  local rvL, lo = labeledInput(lowLabel, 56, p.lo)
  if rvL then p.lo = lo end
  ImGui.SameLine(ctx)
  local rvH, hi = labeledInput(highLabel, 56, p.hi)
  if rvH then p.hi = hi end
end

local function drawChordFields()
  local c = genState.chord
  local rvM, m = labeledInput('Chord', 160, c.members)
  if rvM then c.members = m end
  local rvI, on = chrome.checkbox('invert', c.invert)
  if rvI then c.invert = on end
end

-- Build (and validate) a generator result for the active kind. Re-run each
-- frame to drive the Generate button's enabled state + the error hint.
local function buildGen()
  local g = genState
  if g.kind == 'equal' then
    local degs = tuning.edoDegrees(g.equal.absolute, 'absolute')
    if not degs then return nil, 'enter degrees' end
    if g.equal.interval ~= '' and not tuning.scalaPitch(g.equal.interval) then return nil, 'bad interval' end
    return tuning.genEqual(degs, g.equal.interval)
  elseif g.kind == 'harm' or g.kind == 'subharm' then
    local p = g[g.kind]
    local lo, hi = tonumber(p.lo), tonumber(p.hi)
    if not (lo and hi and lo == math.floor(lo) and hi == math.floor(hi) and lo >= 1 and hi > lo) then
      return nil, 'need 1 <= low < high'
    end
    return g.kind == 'harm' and tuning.genHarmonics(lo, hi) or tuning.genSubharmonics(lo, hi)
  end
  local members, cerr = tuning.parseChord(g.chord.members)
  if not members then return nil, cerr end
  return tuning.genChord(members, g.chord.invert)
end

local function drawGenerators()
  local editable = editedTemper() ~= nil
  if not editable then ImGui.BeginDisabled(ctx) end
  genKindSelector()
  ImGui.Spacing(ctx)
  if genState.kind == 'equal' then drawEqualFields()
  elseif genState.kind == 'harm' then drawSeriesFields(genState.harm, 'Lowest harmonic', 'Highest harmonic')
  elseif genState.kind == 'subharm' then drawSeriesFields(genState.subharm, 'Lowest subharmonic', 'Highest subharmonic')
  else drawChordFields() end

  local gen, err = buildGen()
  ImGui.Spacing(ctx)
  chrome.disabledIf(not gen, function()
    if ImGui.Button(ctx, 'Generate') then generateInto(gen) end
  end)
  if not editable then ImGui.EndDisabled(ctx) end
  if editable and err then ImGui.SameLine(ctx); ImGui.TextColored(ctx, TEMPER_ERR, err) end
end

----- Draw body

-- Top region: the active temper's header + step table, greyed when the
-- selection has no editable tier copy (merge-floor or active slot).
local function drawStepsTop()
  local temper   = editedTemper() or temperFor(viewedName())
  local editable = editedTemper() ~= nil
  if not temper then
    ImGui.Text(ctx, 'No temperament selected.')
    return
  end
  if not editable then ImGui.BeginDisabled(ctx) end
  chrome.row(function() drawHeader(temper) end)
  if not editable then ImGui.EndDisabled(ctx) end
  ImGui.Separator(ctx)
  if not editable then ImGui.BeginDisabled(ctx) end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 9, 2)
  drawStepTable(temper)
  ImGui.PopStyleVar(ctx, 1)
  if not editable then ImGui.EndDisabled(ctx) end
end

-- Step table (topH) over the generators pane; draggable divider doubles as
-- the 'generators' header, mirrors swingEditor's preview/factor splitter.
local function drawEditBody(availW, bodyAvailH)
  local minTop = MIN_TOP_AREA
  local maxTop = math.max(minTop, bodyAvailH - MIN_GEN_AREA)
  genState.topH = math.max(minTop, math.min(maxTop, genState.topH or math.floor(bodyAvailH * 0.6)))

  if ImGui.BeginChild(ctx, '##temperTop', availW, genState.topH) then
    drawStepsTop()
  end
  ImGui.EndChild(ctx)

  local ruleY = chrome.paletteHeader('generators')
  local afterX, afterY = ImGui.GetCursorScreenPos(ctx)
  ImGui.SetCursorScreenPos(ctx, afterX, ruleY - math.floor(DIVIDER_GRAB / 2))
  ImGui.InvisibleButton(ctx, '##genSplit', availW, DIVIDER_GRAB)
  local hovered, active = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)
  if active then
    local _, my = ImGui.GetMousePos(ctx)
    genState.splitDrag = genState.splitDrag or { y0 = my, h0 = genState.topH }
    genState.topH = math.max(minTop, math.min(maxTop, genState.splitDrag.h0 + (my - genState.splitDrag.y0)))
  else
    genState.splitDrag = nil
  end
  if hovered or active then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeNS) end
  ImGui.SetCursorScreenPos(ctx, afterX, afterY)

  drawGenerators()
end

local function draw(w, h)
  chrome.pushChromeStyles()
  if ImGui.BeginChild(ctx, '##temperEditor', w, h) then
    chrome.paletteHeader('steps')
    local availW, bodyAvailH = ImGui.GetContentRegionAvail(ctx)
    drawEditBody(availW, bodyAvailH)
  end
  ImGui.EndChild(ctx)
  chrome.popChromeStyles()
end

----- Public
local self = {}
function self:select(name)        selectTemper(name) end
function self:render(w, h)        draw(w, h) end
function self:libraryDescriptor() return buildDescriptor() end
return self
