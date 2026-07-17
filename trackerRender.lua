-- See docs/trackerPage.md for the model.

--invariant: page is render + input only; tracker state lives in tv/ec/tm, never cached
--invariant: cm/tv read fresh each frame; only ephemeral UI state persists across frames
--invariant: page-persistent state: picker*, paletteFocus, stripFocus (modal state on modalHost)
--invariant: grid/lane render state lives in gridPane, not this page
--invariant: writes go through tv or cmgr commands; page never reaches into tm
local util    = require 'util'
local tuning  = require 'tuning'
local generators = require 'generators'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

--contract: trackerPage (the controller) owns the stack + take lifecycle and drives this renderer
--contract: the renderer holds only tv (injected); it never reaches mm/tm/gm
local cm, ds, cmgr, chrome, gui, modalHost, facade, tv, help, pe =
  (...).cm, (...).ds, (...).cmgr, (...).chrome, (...).gui, (...).modalHost, (...).facade, (...).tv, (...).help, (...).pe

-- The renderer reads project data (tracks/slots) through the arrange facade;
-- the tracker's selection nav goes straight to tv. See docs/trackerPage.md.
local function arrange() return facade.get('arrange') end

---------- PRIVATE

local ctx, uiFont = gui.ctx, gui.uiFont

-- Group quick-verb state and lifetime moved to trackerView (this page is
-- pure render/UI). The 'region' overlay keymap and the
-- tv:wireGroupLifetime call stay here.

-- Localize the picked temper into the project library if absent, so the project
-- carries every temper it references (mirrors swing's setSwingSlot).
local pickTemper = util.atomic('Set temper', function(name)
  if name and not (cm:getAt('project', 'tempers') or {})[name] then
    tv:setTemper(name, tuning.findTemper(name, cm:get('tempers')))
  end
  tv:setTemperSlot(name)
end)

local pickSwing    = util.atomic('Set swing',        function(name)       tv:setSwingSlot(name)          end)
local pickColSwing = util.atomic('Set column swing', function(chan, name) tv:setColSwingSlot(chan, name) end)

-- 'identity' is the explicit no-swing sentinel (schema default); shown as
-- "Off" in the button, hidden from the picker rows.
local SWING_PRESET_EXCLUDE  = { identity = true }
-- 12EDO is the temper floor: shown by name as the active default, hidden from the +preset rows.
local TEMPER_PRESET_EXCLUDE = { ['12EDO'] = true }

-- Hex stays visible when unassigned so `<`/`>` advertise their step.
-- No "Off" row — every slot is real.
local function drawSampleDropdown()
  local cur     = cm:get('currentSample')
  local entries = ds:get('slotEntries') or {}
  local curName = entries[cur] and entries[cur].name
  local indices = {}
  for idx, e in pairs(entries) do
    if e.path then indices[#indices + 1] = idx end
  end
  table.sort(indices)
  local items = {}
  for _, idx in ipairs(indices) do
    items[#items + 1] = {
      label   = string.format('%02X  %s', idx, entries[idx].name or ''),
      key     = idx,
      group   = 1,
      current = idx == cur,
    }
  end
  chrome.drawPicker {
    kind        = 'sample',
    heading     = 'Sample',
    buttonLabel = string.format('%02X', cur) .. (curName and (' ' .. curName) or ''),
    width       = 220,
    items       = items,
    onPick      = util.atomic('Set sample', function(idx) cm:set('take', 'currentSample', idx) end),
  }
end

-- Each render closure reads cm/tv fresh; segments declared once, reused per frame.
--shape: ToolbarSegment = { id, render = fn(), visible? = fn() -> bool }
local toolbarSegments = {
  {
    id = 'track',
    render = function()
      chrome.headingLabel('Track')
      ImGui.SameLine(ctx, 0, 8)
      local curIdx = tv:currentTrackIdx()
      local items, curName = {}, nil
      for _, tr in ipairs(arrange().tracks()) do
        local isCur = tr.idx == curIdx
        if isCur then curName = tr.name end
        items[#items + 1] = {
          label   = tr.name ~= '' and tr.name or ('Track ' .. (tr.idx + 1)),
          key     = tr.idx, group = 1, current = isCur,
        }
      end
      chrome.drawPicker {
        kind        = 'track',
        buttonLabel = (curName and curName ~= '' and curName)
          or (curIdx and ('Track ' .. (curIdx + 1)))
          or '\xe2\x80\x94',
        width       = 160, items = items, onPick = function(idx) tv:pickTrack(idx) end,
      }
    end,
  },
  {
    id = 'take',
    render = function()
      chrome.headingLabel('Take')
      ImGui.SameLine(ctx, 0, 8)
      local trackIdx = tv:currentTrackIdx()
      local curSlot  = tv:currentSlotIdx()
      local items, curName = {}, nil
      for _, slot in ipairs(arrange().midiSlots(trackIdx)) do
        local name = slot.name ~= '' and slot.name or arrange().keyForSlot(slot.idx)
        if slot.idx == curSlot then curName = name end
        items[#items + 1] = { label = name, key = slot.idx, group = 1, current = slot.idx == curSlot }
      end
      chrome.drawPicker {
        kind        = 'take',
        buttonLabel = curName or '\xe2\x80\x94',
        width       = 160, items = items, onPick = function(idx) tv:pickTake(idx) end,
      }
    end,
  },
  {
    id = 'rowsPerBeat',
    render = function()
      ImGui.AlignTextToFramePadding(ctx)
      chrome.headingLabel('RPB')
      ImGui.SameLine(ctx, 0, 8)
      local changed, n = chrome.numberStepper('rpb', cm:get('rowPerBeat'), { min = 1, max = 32, align = 'center' })
      if changed then tv:setRowPerBeat(n) end
    end,
  },
  {
    id = 'tuning',
    render = function()
      chrome.headingLabel('Tuning')
      ImGui.SameLine(ctx, 0, 8)
      local cur = cm:get('temper')
      chrome.drawPicker {
        kind        = 'temper',
        buttonLabel = cur or 'Off',
        width       = 120,
        items       = chrome.libPicker('tempers', cur, TEMPER_PRESET_EXCLUDE),
        onPick      = pickTemper,
      }
      ImGui.SameLine(ctx, 0, 6)
      if ImGui.Button(ctx, 'edit##editTemper') then cmgr:invoke('editTuning') end
    end,
  },
  {
    id = 'swing',
    render = function()
      chrome.headingLabel('Swing')
      ImGui.SameLine(ctx, 0, 8)
      do
        local cur = (ds:get('swing') or {}).global
        chrome.drawPicker {
          kind        = 'swing', heading = 'Take',
          buttonLabel = (not cur or cur == 'identity') and 'Off' or cur,
          width       = 120,
          items       = chrome.libPicker('swings', cur, SWING_PRESET_EXCLUDE),
          onPick      = pickSwing,
        }
      end
      -- Per-column swing in the same segment; channel from cursor's column.
      local cursorCol = tv.grid.cols[tv:ec():col()]
      local chan      = cursorCol and cursorCol.midiChan
      ImGui.SameLine(ctx, 0, 8)
      chrome.disabledIf(not chan, function()
        local cur = chan and (ds:get('swing') or {})[chan] or nil
        chrome.drawPicker {
          kind        = 'colSwing', heading = 'Ch',
          buttonLabel = cur or 'Off',
          width       = 120,
          items       = chrome.libPicker('swings', cur, SWING_PRESET_EXCLUDE),
          onPick      = function(name) pickColSwing(chan, name) end,
        }
      end)
      ImGui.SameLine(ctx, 0, 8)
      if ImGui.Button(ctx, 'edit##editSwing') then cmgr:invoke('editSwing') end
    end,
  },
  {
    id      = 'sample',
    visible = function() return cm:get('trackerMode') end,
    render  = function() drawSampleDropdown() end,
  },
  {
    id = 'graph',
    render = function()
      chrome.headingLabel('Graph')
      ImGui.SameLine(ctx, 0, 8)
      local cv, newVis = chrome.checkbox('##', cm:get('laneStrip.visible'))
      if cv then cm:set('global', 'laneStrip.visible', newVis) end
    end,
  },
}

----- Param palette

-- Remove the cursor's automation column; confirm first if it holds events.
local function removeAutomation(col)
  if #col.events > 0 then
    modalHost:openConfirm{
      title    = 'Remove automation',
      prompt   = ('Column has %d event%s — delete them with it? (y/n)')
                   :format(#col.events, #col.events == 1 and '' or 's'),
      callback = function(yes) if yes then tv:unautomateParam() end end,
    }
  else
    tv:unautomateParam()
  end
end

-- one-shot: a mouse automate (button / tree double-click) fired — hand palette focus back to the grid.
local automateReq = false

local function paletteActions()
  local col   = tv.grid.cols[tv:ec():col()]
  local bound = col and col.type == 'cc' and tv:paramBinding(col.midiChan, col.cc)
  chrome.disabledIf(not tv:paletteParam(), function()
    if ImGui.Button(ctx, 'automate##param') then tv:automateParam(); automateReq = true end
  end)
  ImGui.SameLine(ctx, 0, 4)
  chrome.disabledIf(not bound, function()
    if ImGui.Button(ctx, 'remove##param') then removeAutomation(col) end
  end)
end

-- Palette focus tri-state: 'find' | 'tree' | nil (grid). Gates focusState
-- and handleKeys. See docs/trackerRender.md § Param palette — keyboard focus.
local paletteFocus = nil
local focusFindReq = false   -- one-shot: focus the find box next draw
local defocusReq   = false   -- one-shot: park focus on the sink, leaving the find box
local releaseReq   = false   -- one-shot: drop paletteFocus to nil at the sink (Esc/Enter)
local scrollReq    = false   -- one-shot: scroll the cursor row into view next draw

-- FX-chain session focus: routes the keyboard into the fx palette tab (mirrors paletteFocus).
local stripFocus    = false
local stripHost     = nil    -- uuid the strip is pinned to while focused; lets a just-minted empty chain render
local stripSnapshot = nil    -- {host, fx}: chain state at keyboard-entry; Esc reverts to it, commit keeps the edits
local stripExitReq  = false  -- one-shot: drop stripFocus after dispatch, so the exit Esc isn't re-dispatched
local fxFocusReq    = false  -- one-shot: Super-X from the parameters pane enters the fx session next fx-body draw

-- Caret identity ('row,col') — the anchor for the Super-R parameters override, which
-- lapses as soon as the caret moves off it (see tv:paletteTab).
local function caretKeyNow()
  local e = tv:ec()
  return e and (e:row() .. ',' .. e:col()) or ''
end

local function paletteFindBox()
  ImGui.SetNextItemWidth(ctx, -1)
  if focusFindReq then ImGui.SetKeyboardFocusHere(ctx); focusFindReq, paletteFocus = false, 'find' end
  local changed, text = ImGui.InputTextWithHint(ctx, '##paramFilter', 'find', tv:paletteFilter())
  if changed then tv:setPaletteFilter(text) end
  return ImGui.IsItemActive(ctx)
end


-- Made on first draw + attached so it outlives the defer cycle. Per-frame
-- creation trips ReaImGui's short-lived guard; module-load faults the test fake.
local paramClipper = nil

local PARAM_INDENT = 6   -- px param labels nest past the fx-name / section-heading column
local PALETTE_PAGE = 12  -- PgUp / PgDn cursor step through the param list (arrow nav is too slow on big VSTs)

-- Group an fx's (frecency-ordered) params into section subgroups, each a section
-- heading + its params. See docs/trackerRender.md § Parameter sections.
local function emitParams(plan, row, params)
  local groups, minIndex, ungrouped = {}, {}, {}
  for _, prm in ipairs(params) do
    if prm.section then
      if not groups[prm.section] then groups[prm.section] = {}; minIndex[prm.section] = prm.index end
      if prm.index < minIndex[prm.section] then minIndex[prm.section] = prm.index end
      local bucket = groups[prm.section]
      bucket[#bucket + 1] = prm
    else
      ungrouped[#ungrouped + 1] = prm
    end
  end
  local order = {}
  for name in pairs(groups) do order[#order + 1] = name end
  if #order == 0 then
    for _, prm in ipairs(ungrouped) do plan[#plan + 1] = { kind = 'param', row = row, prm = prm } end
    return
  end
  table.sort(order, function(a, b) return minIndex[a] < minIndex[b] end)
  local function emitGroup(label, bucket)
    plan[#plan + 1] = { kind = 'section', row = row, text = label }
    for _, prm in ipairs(bucket) do
      plan[#plan + 1] = { kind = 'param', row = row, prm = prm }
    end
  end
  for _, label in ipairs(order) do emitGroup(label, groups[label]) end
  if #ungrouped > 0 then emitGroup('(ungrouped)', ungrouped) end
end

--shape: plan item = {kind='heading',text} | {kind='fx',row,open} | {kind='section',row,text} | {kind='param',row,prm}
--contract: non-empty needle prunes to matched subtrees (forced open); see docs § Filtering
local function buildPlan(rows, needle)
  local plan, heading = {}, nil
  for _, row in ipairs(rows) do
    local section = row.generator and 'generators' or 'fx'
    local shown, shownParams, open
    if needle == '' then
      open  = tv:paletteExpanded()[row.fxGuid] or false
      shown = true
      if open then shownParams = tv:listParams(row.trackGuid, row.fxGuid) end
    else
      shownParams = {}
      for _, prm in ipairs(tv:listParams(row.trackGuid, row.fxGuid)) do
        if (row.name .. ' ' .. (prm.section or '') .. ' ' .. prm.name):lower():find(needle, 1, true) then
          shownParams[#shownParams + 1] = prm
        end
      end
      shown, open = #shownParams > 0, true
    end
    if shown then
      if section ~= heading then
        heading = section
        plan[#plan + 1] = { kind = 'heading', text = section }
      end
      plan[#plan + 1] = { kind = 'fx', row = row, open = open }
      if open then emitParams(plan, row, shownParams) end
    end
  end
  return plan
end

-- Navigable rows in display order; headings are skipped, and so are fx rows
-- when filtering — the cursor then visits matched params only.
local function navRows(plan, paramsOnly)
  local nav = {}
  for _, it in ipairs(plan) do
    if it.kind == 'fx' and not paramsOnly then
      nav[#nav + 1] = { fxGuid = it.row.fxGuid, param = nil, item = it, row = it.row }
    elseif it.kind == 'param' then
      nav[#nav + 1] = { fxGuid = it.row.fxGuid, param = it.prm.index, item = it,
                        row = it.row, prm = it.prm }
    end
  end
  return nav
end

local function navIndex(nav, cur)
  if not cur then return nil end
  for i, e in ipairs(nav) do
    if e.fxGuid == cur.fxGuid and e.param == cur.param then return i end
  end
end

local function selectParam(e)
  tv:setPaletteParam{ trackGuid = e.row.trackGuid, fxGuid = e.fxGuid,
                      param = e.prm.index, label = e.prm.name }
end

-- Apply this frame's palette keys to cursor/expansion. Returns true when it
-- changed the focus mode (Tab/Esc/Enter-automate) so the caller skips reconcile.
local function handlePaletteKeys(nav)
  local press = function(k) return ImGui.IsKeyPressed(ctx, k) end
  if press(ImGui.Key_Tab) then
    if paletteFocus == 'find' then paletteFocus, defocusReq = 'tree', true
    else paletteFocus, focusFindReq = 'find', true end
    return true
  end
  if press(ImGui.Key_Escape) then
    -- Defer the focus drop to the sink next frame: keep paletteFocus set
    -- through this frame's focusState so the same Esc isn't dispatched.
    tv:setPaletteFilter(''); defocusReq, releaseReq = true, true
    return true
  end
  if ImGui.GetKeyMods(ctx) == ImGui.Mod_Super and press(ImGui.Key_X) then
    tv:clearTabOverride(); fxFocusReq = true; return true   -- cross to fx: drop the pin, focus the chain next fx draw
  end
  if ImGui.GetKeyMods(ctx) == ImGui.Mod_Super and press(ImGui.Key_R) then
    tv:clearTabOverride(); return true   -- toggle parameters off: the auto chain re-shows and focus falls to the grid
  end
  if #nav == 0 then return end

  local idx = navIndex(nav, tv:paletteCursor())
  if not idx then idx = 1; tv:setPaletteCursor{ fxGuid = nav[1].fxGuid, param = nav[1].param } end
  -- Up/Down move, clamped — no wrap past the ends. Left/Right drive the tree
  -- unless the find box is editing text. Any move scrolls the cursor in view.
  local treeArrows = paletteFocus == 'tree' or tv:paletteFilter() == ''
  local newIdx = idx
  if press(ImGui.Key_DownArrow) then newIdx = math.min(idx + 1, #nav)
  elseif press(ImGui.Key_UpArrow) then newIdx = math.max(idx - 1, 1)
  elseif press(ImGui.Key_PageDown) then newIdx = math.min(idx + PALETTE_PAGE, #nav)
  elseif press(ImGui.Key_PageUp) then newIdx = math.max(idx - PALETTE_PAGE, 1)
  elseif treeArrows and press(ImGui.Key_RightArrow) then
    local e = nav[idx]
    if e.param == nil and not e.item.open then tv:setFxExpanded(e.fxGuid, true)
    else newIdx = math.min(idx + 1, #nav) end
  elseif treeArrows and press(ImGui.Key_LeftArrow) then
    local e = nav[idx]
    if e.param == nil and e.item.open then tv:setFxExpanded(e.fxGuid, false)
    elseif e.param ~= nil then
      for j = idx - 1, 1, -1 do
        if nav[j].param == nil then newIdx = j; break end
      end
    end
  end

  local cur = nav[newIdx]
  if newIdx ~= idx then
    scrollReq = true
    tv:setPaletteCursor{ fxGuid = cur.fxGuid, param = cur.param }
    if cur.param then selectParam(cur) end
  end
  if ImGui.GetKeyMods(ctx) == ImGui.Mod_Super and press(ImGui.Key_L) then
    tv:armLearn(cur.row)   -- cur.row is the cursor's fx, whether on it or a child
    if tv:learnFxGuid() then tv:setFxExpanded(cur.row.fxGuid, true) end
  end
  if press(ImGui.Key_Enter) or press(ImGui.Key_KeypadEnter) then
    if cur.param then
      -- Deferred drop (see Esc) so the same Enter doesn't reach the grid.
      selectParam(cur); tv:automateParam()
      tv:setPaletteFilter(''); tv:setPaletteCursor(nil); defocusReq, releaseReq = true, true
      return true
    end
    tv:setFxExpanded(cur.fxGuid, not cur.item.open)
  end
end

-- On a keyboard move, scroll minimally so the just-submitted cursor row stays
-- inside the view; a no-op for mouse moves (scrollReq unset).
local function scrollFollow(onCur)
  if not (scrollReq and onCur) then return end
  scrollReq = false
  local _, rowTop = ImGui.GetItemRectMin(ctx)
  local _, rowBot = ImGui.GetItemRectMax(ctx)
  local _, winTop = ImGui.GetWindowPos(ctx)
  local winBot    = winTop + ImGui.GetWindowHeight(ctx)
  local sY        = ImGui.GetScrollY(ctx)
  if rowTop < winTop then ImGui.SetScrollY(ctx, sY - (winTop - rowTop))
  elseif rowBot > winBot then ImGui.SetScrollY(ctx, sY + (rowBot - winBot)) end
end

local function drawTreeItem(it, cur, showLearn, btns)
  if it.kind == 'heading' then
    chrome.treeHeading{ text = it.text }
  elseif it.kind == 'section' then
    chrome.treeHeading{ text = it.text, gutter = true }
  elseif it.kind == 'fx' then
    local row     = it.row
    local onCur   = cur and cur.fxGuid == row.fxGuid and cur.param == nil
    local availW  = select(1, ImGui.GetContentRegionAvail(ctx))
    local reserve = showLearn and btns.show + btns.learn + 36 or 8
    -- AllowOverlap so the show/learn buttons drawn on top still take their clicks.
    local r = chrome.treeRow{ id = 'fx' .. row.fxGuid, label = row.name,
                              hasChildren = true, open = it.open, selected = onCur,
                              reserve = reserve, flags = ImGui.SelectableFlags_AllowOverlap }
    scrollFollow(onCur)
    if r.selected then
      tv:setPaletteCursor{ fxGuid = row.fxGuid, param = nil }
      paletteFocus = 'tree'
    end
    if r.toggled then tv:setFxExpanded(row.fxGuid, not it.open) end
    if showLearn then
      local armed  = tv:learnFxGuid() == row.fxGuid
      -- Right-aligned, a few px in from the row edge so they sit inside the highlight.
      local learnX = availW - 4 - btns.learn
      ImGui.SameLine(ctx, learnX - 4 - btns.show)
      if ImGui.SmallButton(ctx, 'show###S' .. row.fxGuid) then tv:showFx(row) end
      ImGui.SameLine(ctx, learnX)
      if ImGui.SmallButton(ctx, (armed and 'stop' or 'learn') .. '###L' .. row.fxGuid) then
        tv:armLearn(row)
      end
    end
  else
    local row   = it.row
    local onCur = cur and cur.fxGuid == row.fxGuid and cur.param == it.prm.index
    -- id from guid+index alone: truncation/width must not remint it.
    local r = chrome.treeRow{ id = 'p' .. row.fxGuid .. it.prm.index, label = it.prm.name,
                              indent = PARAM_INDENT, hasChildren = false, selected = onCur,
                              allowDouble = true }
    scrollFollow(onCur)
    if r.selected or r.doubleClicked then
      tv:setPaletteCursor{ fxGuid = row.fxGuid, param = it.prm.index }
      tv:setPaletteParam{ trackGuid = row.trackGuid, fxGuid = row.fxGuid,
                          param = it.prm.index, label = it.prm.name }
      paletteFocus = 'tree'
    end
    if r.doubleClicked then tv:automateParam(); automateReq = true end
  end
end

-- Position of the cursor's row in the flat plan, so the clipper can force it
-- in-range for scroll-follow even when it sits just outside the window.
local function planIndexOfCursor(plan, cur)
  if not cur then return nil end
  for i, it in ipairs(plan) do
    local matchFx    = it.kind == 'fx'    and cur.param == nil and it.row.fxGuid == cur.fxGuid
    local matchParam = it.kind == 'param' and it.row.fxGuid == cur.fxGuid and it.prm.index == cur.param
    if matchFx or matchParam then return i end
  end
end

local function drawTree(plan)
  if #plan == 0 then
    ImGui.TextDisabled(ctx, tv:paletteFilter() == '' and '(no fx reachable)' or '(no match)')
    return
  end
  local cur  = tv:paletteCursor()
  local fpx  = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  local btns = { show  = ImGui.CalcTextSize(ctx, 'show')  + fpx * 2,
                 learn = ImGui.CalcTextSize(ctx, 'learn') + fpx * 2 }
  local showLearn = tv:paletteFilter() == ''   -- show/learn buttons hidden while filtering

  -- Clip to the visible rows: a fx with hundreds of params must not draw (and
  -- CalcTextSize) every row each frame.
  if not paramClipper then
    paramClipper = ImGui.CreateListClipper(ctx)
    ImGui.Attach(ctx, paramClipper)
  end
  ImGui.ListClipper_Begin(paramClipper, #plan)
  if scrollReq then
    local ci = planIndexOfCursor(plan, cur)
    if ci then ImGui.ListClipper_IncludeItemByIndex(paramClipper, ci - 1) end
  end
  while ImGui.ListClipper_Step(paramClipper) do
    local first, last = ImGui.ListClipper_GetDisplayRange(paramClipper)
    for i = first, last - 1 do
      drawTreeItem(plan[i + 1], cur, showLearn, btns)
    end
  end
  ImGui.ListClipper_End(paramClipper)
end

-- Assigned in the FX chain block below; drawn when the fx tab is active. editFx is hoisted here
-- too so the fx-tab click (drawParamPalette, above the block) can launch the session.
local drawFxChainBody
local editFx

local PALETTE_TABS = { { key = 'parameters', label = 'parameters' },
                       { key = 'fx',         label = 'fx' } }

-- The parameters tree body — the palette's former sole content, drawn on the params tab.
local function drawParamsBody(childFocused)
  paletteActions()
  local findActive = paletteFindBox()
  ImGui.Separator(ctx)

  -- Focus sink: SetKeyboardFocusHere parks here to deactivate the find box
  -- (Tab→tree, Esc/Enter→grid). Kept near the top so scroll never culls it.
  local parking = defocusReq
  if defocusReq then ImGui.SetKeyboardFocusHere(ctx); defocusReq = false end
  if releaseReq then paletteFocus, releaseReq = nil, false end
  ImGui.InvisibleButton(ctx, '##paletteSink', 1, 1)

  local plan = buildPlan(tv:paramTargets(), tv:paletteFilter():lower())
  local focusChanged = paletteFocus and handlePaletteKeys(navRows(plan, tv:paletteFilter() ~= ''))
  drawTree(plan)

  -- Reconcile paletteFocus with ImGui state: find box wins unless parking,
  -- a pane click grabs tree focus, clicking elsewhere releases to the grid.
  if automateReq then paletteFocus, automateReq = nil, false   -- mouse automate: hand focus back to the grid
  elseif not focusChanged then
    local clicked = ImGui.IsWindowHovered(ctx) and ImGui.IsMouseClicked(ctx, 0)
    if findActive and not parking then paletteFocus = 'find'
    elseif clicked then paletteFocus = paletteFocus or 'tree'
    elseif paletteFocus and not childFocused then paletteFocus = nil end
  end
end

-- The right-hand pane: parameters | fx tabs. fx auto-raises on a showable chain; Super-R parks
-- parameters over it. See docs/trackerRender.md § Palette tabs.
local function drawParamPalette(x, y, h, caretKey, fxAvailable, fxPlan)
  local activeTab = tv:paletteTab(caretKey, fxAvailable)
  if activeTab ~= 'parameters' and paletteFocus then paletteFocus = nil end
  chrome.palettePane{
    x = x, y = y, h = h,
    tabs = PALETTE_TABS, activeTab = activeTab,
    onTab = function(key) tv:overrideTab(key, caretKey) end,   -- a tab click just switches the view; it never grabs focus
    draw = function(childFocused)
      if activeTab == 'fx' then drawFxChainBody(fxPlan)
      else                      drawParamsBody(childFocused) end
    end,
  }
end

local function drawStatusBar()
  -- ctx and grid.cols are built together in tv:rebuild; an empty grid
  -- (no take yet on script reopen) means ctx is nil. Match renderBody's
  -- placeholder guard rather than indexing a nil ctx via barBeatSub.
  if #tv.grid.cols == 0 then return end
  local ec = tv:ec()
  local cursorRow, cursorCol = ec:row(), ec:col()
  local rowPerBeat    = cm:get('rowPerBeat')
  local currentOctave = cm:get('currentOctave')
  local advanceBy     = cm:get('advanceBy')
  local sampleSuffix = ''
  if cm:get('trackerMode') then
    local slot  = cm:get('currentSample')
    local entry = (ds:get('slotEntries') or {})[slot]
    local name  = entry and entry.name
    sampleSuffix = string.format(' | Sample: %02X', slot)
                .. (name and (' ' .. name) or '')
  end
  local col      = tv.grid.cols[cursorCol]
  local bar, beat, sub = tv:barBeatSub(cursorRow)
  local colLabel = col and col.label or '?'

  -- statusBar is rendered inside its own chrome BeginChild whose outer
  -- Col_Text push is `statusBar.text`; we just print, no inner push.
  ImGui.Text(ctx, string.format(
    '%s | %d:%d.%d/%d | Octave: %d | Advance: %d%s',
    colLabel, bar, beat, sub, rowPerBeat, currentOctave, advanceBy, sampleSuffix
  ))
end

----- Input

-- Tracker-scope bindings live in pageBindings (every page keymap in one place);
-- the fx-pattern mini cmgr binds a filtered subset. Globals bind on root in Main().
cmgr:scope('tracker'):bindAll(require('pageBindings').tracker)

----- F1 help manifest — toolbar callouts pinned to their segments, plus a
----- flowed panel of grid/global bindings packed over the grid body.

help:registerPage('tracker', {
  { anchor = 'toolbar.track', place = 'pin', title = 'Track', items = {
    { cmd = 'prevTrack', label = 'Previous track' },
    { cmd = 'nextTrack', label = 'Next track' },
  }},
  { anchor = 'toolbar.take', place = 'pin', title = 'Take', items = {
    { cmd = 'prevTake', label = 'Previous take' },
    { cmd = 'nextTake', label = 'Next take' },
  }},
  { anchor = 'toolbar.rowsPerBeat', place = 'pin', title = 'Rows / beat', items = {
    { cmd = 'doubleRPB', label = 'Double' },
    { cmd = 'halveRPB', label = 'Halve' },
    { cmd = 'setRPB', label = 'Set' },
    { cmd = 'matchGridToCursor', label = 'Match' },
  }},
  { anchor = 'toolbar.tuning', place = 'pin', title = 'Tuning', items = {
    { cmd = 'openTemperPicker', label = 'Pick tuning' },
    { cmd = 'editTuning', label = 'Edit tuning' },
  }},
  { anchor = 'toolbar.swing', place = 'pin', title = 'Swing', items = {
    { cmd = 'openSwingPicker', label = 'Pick swing' },
    { cmd = 'editSwing', label = 'Edit swing' },
  }},
  { anchor = 'toolbar.sample', place = 'pin', title = 'Sample', items = {
    { cmd = 'inputSampleUp', label = 'Sample +' },
    { cmd = 'inputSampleDown', label = 'Sample -' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Movement', items = {
    { cmd = 'cursorUp', label = 'Up' },
    { cmd = 'cursorDown', label = 'Down' },
    { cmd = 'cursorLeft', label = 'Left' },
    { cmd = 'cursorRight', label = 'Right' },
    { cmd = 'colLeft', label = 'Column left' },
    { cmd = 'colRight', label = 'Column right' },
    { cmd = 'channelLeft', label = 'Channel left' },
    { cmd = 'channelRight', label = 'Channel right' },
    { cmd = 'goTop', label = 'Top' },
    { cmd = 'goBottom', label = 'Bottom' },
    { cmd = 'pageUp', label = 'Page up' },
    { cmd = 'pageDown', label = 'Page down' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Editing', items = {
    { cmd = 'noteOff', label = 'Note off' },
    { cmd = 'delete', label = 'Clear cell' },
    { cmd = 'deleteSel', label = 'Delete selection' },
    { cmd = 'interpolate', label = 'Interpolate' },
    { cmd = 'nudgeBack', label = 'Push back' },
    { cmd = 'nudgeForward', label = 'Push forward' },
    { cmd = 'eventShiftLeft', label = 'Push left' },
    { cmd = 'eventShiftRight', label = 'Push right' },
    { cmd = 'shrinkNote', label = 'Shrink note' },
    { cmd = 'growNote', label = 'Grow note' },
    { cmd = 'nudgeFineUp', label = 'Nudge val +' },
    { cmd = 'nudgeFineDown', label = 'Nudge val -' },
    { cmd = 'nudgeCoarseUp', label = 'Nudge val ++' },
    { cmd = 'nudgeCoarseDown', label = 'Nudge val --' },
    { cmd = 'scaleHalf', label = 'Scale \xc3\x97\xc2\xbd' },
    { cmd = 'scaleDouble', label = 'Scale \xc3\x972' },
    { cmd = 'quantize', label = 'Quantize' },
    { cmd = 'quantizeKeepRealised', label = 'Quantize (keep realised)' },
    { cmd = 'editNoteFx', label = 'Edit note FX' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Selection', items = {
    { cmd = 'selectUp', label = 'Select up' },
    { cmd = 'selectDown', label = 'Select down' },
    { cmd = 'selectLeft', label = 'Select left' },
    { cmd = 'selectRight', label = 'Select right' },
    { cmd = 'selectClear', label = 'Clear selection' },
    { cmd = 'cycleBlock', label = 'Cycle selection H' },
    { cmd = 'cycleVBlock', label = 'Cycle selection V' },
    { cmd = 'swapBlockEnds', label = 'Swap block ends' },
    { cmd = 'cut', label = 'Cut' },
    { cmd = 'copy', label = 'Copy' },
    { cmd = 'paste', label = 'Paste' },
    { cmd = 'duplicateDown', label = 'Duplicate' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Columns & rows', items = {
    { cmd = 'addNoteLane', label = 'Add note lane' },
    { cmd = 'addTypedCol', label = 'Add cc/pb/at/pc column' },
    { cmd = 'hideExtraCol', label = 'Remove column' },
    { cmd = 'insertRowCol', label = 'Insert row' },
    { cmd = 'deleteRowCol', label = 'Delete row' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Groups & region', items = {
    { cmd = 'regionArm', label = 'Region mode' },
    { cmd = 'groupDuplicate', label = 'Duplicate group' },
    { cmd = 'groupPaste', label = 'Paste group' },
    { cmd = 'groupLocalToggle', label = 'Toggle local' },
    { cmd = 'groupInstPrev', label = 'Prev instance' },
    { cmd = 'groupInstNext', label = 'Next instance' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Input', items = {
    { cmd = 'inputOctaveUp', label = 'Octave +' },
    { cmd = 'inputOctaveDown', label = 'Octave -' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Transport', items = {
    { cmd = 'playPause', label = 'Play / pause' },
    { cmd = 'playFromTop', label = 'Play from top' },
    { cmd = 'playFromCursor', label = 'Play from cursor' },
    { cmd = 'stop', label = 'Stop' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Take management', items = {
    { cmd = 'newTakeBelow', label = 'New take' },
    { cmd = 'duplicateUnpooledBelow', label = 'Duplicate (unpooled)' },
    { cmd = 'takeProperties', label = 'Take properties' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Global', items = {
    { cmd = 'undo', label = 'Undo' },
    { cmd = 'redo', label = 'Redo' },
    { cmd = 'togglePage', label = 'Switch page' },
    { cmd = 'returnToArrange', label = 'Back to arrange' },
    { cmd = 'beginPrefix', label = 'Numeric prefix' },
    { cmd = 'toggleFxWindows', label = 'Toggle FX windows' },
    { cmd = 'toggleHelp', label = 'This help' },
    { cmd = 'quit', label = 'Quit' },
  }},
})

----- Modal-driven commands

local function openPrompt(title, prompt, callback, resolve, onChord)
  modalHost:openPrompt{ title = title, prompt = prompt, callback = callback, resolve = resolve, onChord = onChord }
end

local function openConfirm(title, callback, prompt)
  modalHost:openConfirm{ title = title, prompt = prompt, callback = callback }
end

-- Custom modal: take properties. Renderer reads/writes per-instance state
-- (s) supplied at open time. Mutating rowsBuf externally is invisible to an
-- active InputText, which caches its own buffer. Bumping rowsGen changes the
-- widget's PushID identity and forces it to re-initialise from rowsBuf;
-- refocusRows then puts the cursor back so the user can keep typing. Both
-- chord and button paths share this so the InputText stays in sync.
modalHost:registerKind('takeProps', function(s, close)
  local function scaleBy(factor)
    local n = tonumber(s.beatsBuf)
    if not n then return end
    local minBeats = 1 / cm:get('rowPerBeat')
    s.beatsBuf     = ('%g'):format(math.max(minBeats, n * factor))
    s.beatsGen     = s.beatsGen + 1
    s.refocusBeats = true
  end
  local function pressedAny(specs)
    if not specs then return false end
    for _, spec in ipairs(specs) do
      local key, mods = cmgr:keySpec(spec, ImGui)
      if ImGui.IsKeyPressed(ctx, key) and ImGui.GetKeyMods(ctx) == mods then return true end
    end
    return false
  end

  if     pressedAny(cmgr:keysFor('doubleRPB')) then scaleBy(2)
  elseif pressedAny(cmgr:keysFor('halveRPB'))  then scaleBy(0.5) end

  -- Appearing frame: Enter is still IsKeyPressed=true — gate OK/Cancel
  -- below so a binding like Super+Shift+Enter doesn't self-dismiss.
  local appearing = ImGui.IsWindowAppearing(ctx)

  ImGui.Text(ctx, 'Item name')
  -- Duplicate paths open with focusName so the clone is named first.
  if appearing and s.focusName then ImGui.SetKeyboardFocusHere(ctx) end
  local rvN, name = ImGui.InputText(ctx, '##takeprops_name', s.nameBuf)
  if rvN then s.nameBuf = name end

  ImGui.Text(ctx, 'Length (beats)')
  if (appearing and not s.focusName) or s.refocusBeats then
    ImGui.SetKeyboardFocusHere(ctx)
    s.refocusBeats = nil
  end
  ImGui.PushID(ctx, s.beatsGen)
  local rvR, beats = ImGui.InputText(ctx, '##takeprops_beats', s.beatsBuf)
  ImGui.PopID(ctx)
  if rvR then s.beatsBuf = beats end
  ImGui.SameLine(ctx); if ImGui.Button(ctx, '\xc3\x97' .. '2') then scaleBy(2)   end  -- ×2
  ImGui.SameLine(ctx); if ImGui.Button(ctx, '\xc3\xb7' .. '2') then scaleBy(0.5) end  -- ÷2

  for i, m in ipairs{ {'resize', 'Resize'}, {'rescale', 'Rescale'}, {'tile', 'Tile'} } do
    if i > 1 then ImGui.SameLine(ctx) end
    if ImGui.RadioButton(ctx, m[2], s.mode == m[1]) then s.mode = m[1] end
  end

  local okPressed     = ImGui.Button(ctx, 'OK')
                     or (not appearing and (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
                                         or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)))
  ImGui.SameLine(ctx)
  local cancelPressed = ImGui.Button(ctx, 'Cancel')
                     or (not appearing and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape))
  if     okPressed     then close(true, s.nameBuf, tonumber(s.beatsBuf), s.mode)
  elseif cancelPressed then close(false) end
end)

-- Naming convention <base>Selection / <base>All is the contract.
--contract: requires tv to expose both `<base>Selection` and `<base>All` methods
local function scopedAction(title, base)
  return function()
    if tv:ec():hasSelection() then tv[base..'Selection'](tv)
    else openConfirm(title, function(yes) if yes then tv[base..'All'](tv) end end)
    end
  end
end

-- Add-Column type vocabulary. See docs/trackerView.md § Extra columns.
local function resolveColType(s)
  local a, digits = s:lower():match('^(%a*)(%d*)$')
  if not a or a == '' then return digits ~= '' and ('cc' .. digits) or '' end
  local first = a:sub(1, 1)
  local canon = first == 'c' and 'pc'
             or first == 'a' and 'at'
             or first == 'd' and 'dly'
             or first == 'p' and 'pb'
             or a
  return canon .. digits
end

local function addColumn()
  openPrompt('Add Column', 'cc number, pb, at, pc, dly', function(typeStr)
    local type, idStr = typeStr:lower():match('^(%a+)(%d*)$')
    if not type then return end
    local id = idStr ~= '' and tonumber(idStr) or nil
    if type == 'dly' then tv:showDelay()
    elseif util.oneOf('cc pb at pc', type) then
      if type == 'cc' and (not id or id < 0 or id > 127) then return end
      tv:addExtraCol(type, id)
    end
  end, resolveColType)
end

-- Ctrl-Left drops the cursor column: a bound automation (cc) column goes
-- through the remove-automation flow; anything else just hides.
local function removeOrHideCol()
  local col   = tv.grid.cols[tv:ec():col()]
  local bound = col and col.type == 'cc' and tv:paramBinding(col.midiChan, col.cc)
  if bound then removeAutomation(col)
  else tv:hideExtraCol() end
end

-- Forward-declared so the takeProperties command body, registered
-- below, captures the same table the helper installs methods on.
local tr = {}

-- The grid + lane render core (design/fx-patterns.md § P1). inputAllowed
-- folds focusState.acceptCmds so note-entry self-suppresses under modal/picker/palette/strip focus.
local gridPane = util.instantiate('gridPane', {
  cm = cm, cmgr = cmgr, chrome = chrome, gui = gui, tv = tv, chordEntry = true,
  inputAllowed = function() return tr:focusState().acceptCmds end,
})

----- Note FX -- generator descriptors shared by the fx chain tab

-- A thin renderer over the generator registry: the fx list is an ordered series (C1), stages
-- reorderable/duplicable by position. see design/note-macros-v2.md § The fx chain, § Build progress C4
local FX_KINDS = generators.modalOrder

-- A kind's default fx entry: its registry params stamped with the kind tag downstream reads.
local function fxSeed(kind) return util.assign({ kind = kind }, generators.kinds[kind].defaults) end

----- FX field descriptors (used by the fx strip)

local function choiceIndex(fd, value)
  for i, o in ipairs(fd.options) do if util.deepEq(o.v, value) then return i end end
  return 1
end
local function choiceLabels(fd)
  local out = {}; for i, o in ipairs(fd.options) do out[i] = o.l end; return out
end

-- stepInterval: stored value is signed cents (a host-relative pitch demand);
-- shown/stepped as temper steps, anchored at the host. see design/archive/note-macros.md § UI
local function slideTemper() return tv:activeTemper() or tuning.findTemper('12EDO') end
local function hostPitch(uuid)
  local n = tv:noteByUuid(uuid)
  return (n and n.pitch) or 60, (n and n.detune) or 0
end
local function centsToSteps(temper, midi, detune, cents)
  local hStep, hOct = tuning.midiToStep(temper, midi, detune)
  local tStep, tOct = tuning.midiToStep(temper, 0, midi * 100 + detune + (cents or 0))
  return (tOct - hOct) * #temper.cents + (tStep - hStep)
end
local function stepsToCents(temper, midi, detune, n)
  local tMidi, tDetune = tuning.transposeStep(temper, midi, detune, n)
  return (tMidi - midi) * 100 + (tDetune - detune)
end

-- The strip's pattern-body fields (ostinato): a summary label + launch into the checkout editor,
-- which writes the edited body back through setFxField. see design/fx-patterns.md § P3.5
local function emptyBody(kind)
  if kind == 'curve' then return { kind = 'curve', points = {} } end
  return { kind = 'notes', specs = {} }
end

local function patternSummary(body)
  if not body then return 'empty' end
  if body.kind == 'curve' then return ('curve \xc2\xb7 %d'):format(#(body.points or {})) end
  return ('notes \xc2\xb7 %d'):format(#(body.specs or {}))
end

local function launchPattern(host, index, fd, entry)
  -- Stamp the field's label as a display-only header hint (readback strips it, so it never
  -- persists); deepClone keeps the stored body + its points array unmutated.
  local body = util.deepClone(entry[fd.field] or emptyBody(fd.kind))
  body.label = fd.label
  pe:launch(body, function(newBody) tv:setFxField(host, index, fd.field, newBody) end)
end

-- Adjust rw's field one step: right increments, Ctrl coarse. The generic write both editors drive.
local function adjustRow(uuid, rw, right, mods)
  local fd, value = rw.fd, rw.entry[rw.fd.field]
  if fd.widget == 'choice' then
    local i = util.clamp(choiceIndex(fd, value) + (right and 1 or -1), 1, #fd.options)
    tv:setFxField(uuid, rw.index, fd.field, fd.options[i].v)
  elseif fd.widget == 'stepInterval' then
    local temper = slideTemper()
    local midi, detune = hostPitch(uuid)
    local steps = centsToSteps(temper, midi, detune, value)
    local delta = (mods & ImGui.Mod_Ctrl) ~= 0 and #temper.cents or 1
    tv:setFxField(uuid, rw.index, fd.field,
                  stepsToCents(temper, midi, detune, steps + (right and 1 or -1) * delta))
  elseif fd.widget == 'pattern' then   -- no scalar to nudge; arrowing opens the editor
    launchPattern(uuid, rw.index, fd, rw.entry)
  else
    local step = (mods & ImGui.Mod_Ctrl) ~= 0 and fd.coarse or fd.base
    local n = util.clamp((value or 0) + (right and 1 or -1) * step, fd.min, fd.max)
    tv:setFxField(uuid, rw.index, fd.field, n)
  end
end

-- Value control for one fx field (dropdown / temper-step / number stepper); id keys ImGui per
-- field. width is the value column; stepper shrinks for -/+ buttons, choice dropdowns self-size.
local function fxFieldWidget(host, index, fd, entry, width)
  local value   = entry[fd.field]
  local id      = 'fx_' .. index .. '_' .. fd.field
  -- numberStepper's width sizes its input box only; its -/+ buttons add 2×(innerSpacing + frameH).
  local stepBoxW = width - 2 * (ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemInnerSpacing) + ImGui.GetFrameHeight(ctx))
  if fd.widget == 'choice' then
    local pick = chrome.dropdown(id, fd.options[choiceIndex(fd, value)].l, choiceLabels(fd))
    if pick then tv:setFxField(host, index, fd.field, fd.options[pick].v) end
  elseif fd.widget == 'stepInterval' then
    local temper = slideTemper()
    local midi, detune = hostPitch(host)
    local per = #temper.cents
    local rv, n = chrome.numberStepper(id, centsToSteps(temper, midi, detune, value),
                    { width = stepBoxW, min = -2 * per, max = 2 * per })
    if rv then tv:setFxField(host, index, fd.field, stepsToCents(temper, midi, detune, n)) end
  elseif fd.widget == 'pattern' then
    if ImGui.Button(ctx, patternSummary(value) .. '##' .. id, width) then launchPattern(host, index, fd, entry) end
  else
    local rv, n = chrome.numberStepper(id, value or 0, { width = stepBoxW, min = fd.min, max = fd.max })
    if rv then tv:setFxField(host, index, fd.field, n) end
  end
end

----- FX chain (palette tab; edits the chain under the caret in place)

-- see docs/trackerRender.md § FX chain for the vertical row grammar and 1D navigation.
local stripPlan do
  local LABEL_W, LABEL_GAP, VALUE_W = 64, 24, 96    -- swap-picker min width; value-column width (flush to the right margin)
  local FIELD_INDENT     = 12        -- fields nest one level under the fx-name heading
  local BTN_GAP, DEL_GAP = 4, 4      -- title→reorder, then reorder→del spacings
  local stripPaint                   -- identity screen painter, rebuilt each drawFxChainBody

  -- The chain flattened to one navigable column: each stage's header then its fields, crossing
  -- stage boundaries so Up/Down walk the whole chain as a single list.
  local function chainRows(cols)
    local rows = {}
    for si, col in ipairs(cols) do
      rows[#rows + 1] = { stage = si, param = 0 }
      for k = 1, #col.fields do rows[#rows + 1] = { stage = si, param = k } end
    end
    return rows
  end
  local function rowIndexOf(rows, cur)
    for i, r in ipairs(rows) do if r.stage == cur.stage and r.param == cur.param then return i end end
    return 1
  end

  -- Columns: one per stage, holding its currently-visible fields (adding is the header picker).
  local function stripColumns(fx)
    local cols = {}
    for i, entry in ipairs(fx) do
      local fields = {}
      for _, fd in ipairs(generators.kinds[entry.kind].fields) do
        if not fd.when or fd.when(entry) then
          fields[#fields + 1] = { fd = fd, entry = entry, index = i }
        end
      end
      cols[#cols + 1] = { index = i, kind = entry.kind,
                          label = generators.kinds[entry.kind].label, fields = fields }
    end
    return cols
  end

  -- A stage walks header(0)..fields.
  local function paramRange(col) return 0, #col.fields end

  -- The chain the fx tab draws. A non-empty chain (or a focused, pinned session) shows its stages;
  -- when fx is the chosen tab but nothing's there yet, show the bare add row alone (mint on first add).
  function stripPlan(fxChosen)
    local host   = stripFocus and stripHost or tv:fxHostAtCursor()
    local pinned = stripFocus and host == stripHost
    local fx     = host and tv:noteFx(host) or (pinned and {})   -- a note host reads nil until its first stage
    local haveChain = fx and (#fx > 0 or pinned)
    if not haveChain and not fxChosen then return nil end
    local cols = haveChain and stripColumns(fx) or {}
    cols[#cols + 1] = { isAdd = true, fields = {} }   -- terminal slot: arrow onto it, type/←→ opens the add picker
    return { host = host, cols = cols }
  end

  local function clampCursor(cols)
    local c = tv:stripCursor() or { stage = 1, param = 0 }
    c.stage = util.clamp(c.stage, 1, #cols)
    local lo, hi = paramRange(cols[c.stage])
    c.param = util.clamp(c.param, lo, hi)
    return c
  end

  -- First printable character typed this frame -- drives type-to-open on the add slot.
  local function typedChar()
    local ok, c = ImGui.GetInputQueueCharacter(ctx, 0)
    if ok and c >= 32 and c < 127 then return string.char(c) end
  end

  -- Revert the chain to its keyboard-entry baseline, then request exit. Shared by the strip's own
  -- Esc, the cancel button, and the add-slot picker's Esc (which aborts a still-empty gesture).
  local function cancelStrip()
    if stripSnapshot then tv:setNoteFx(stripSnapshot.host, stripSnapshot.fx or util.REMOVE) end
    stripExitReq = true   -- drop at frame end, not now, so the exit Esc isn't re-dispatched
  end

  -- 1D grammar: Up/Down walk rows, Left/Right edit or open a picker, Super+Up/Down reorder.
  -- Enter/Super+X/Super+R/Esc — see docs/trackerRender.md § FX chain — palette tab.
  local function handleFxChainKeys(plan)
    local press = function(k) return ImGui.IsKeyPressed(ctx, k) end
    local mods  = ImGui.GetKeyMods(ctx)
    local super = (mods & ImGui.Mod_Super) ~= 0
    if press(ImGui.Key_Escape) then cancelStrip(); return end
    if super and press(ImGui.Key_X) then stripExitReq = true; return end   -- commit and leave (Super+X toggles the session)
    if super and press(ImGui.Key_R) then                    -- commit, then raise the parameters tab
      stripExitReq = true; tv:overrideTab('parameters', caretKeyNow()); paletteFocus, focusFindReq = 'find', true; return
    end
    local cols = plan.cols
    local cur  = clampCursor(cols)
    local col  = cols[cur.stage]
    if press(ImGui.Key_Tab) then                            -- jump to the next/prev stage, onto its first field (add slot lands on its row)
      local back = (mods & ImGui.Mod_Shift) ~= 0
      cur.stage  = util.clamp(cur.stage + (back and -1 or 1), 1, #cols)
      cur.param  = #cols[cur.stage].fields > 0 and 1 or 0
      tv:setStripCursor(cur); return
    end
    local up, down    = press(ImGui.Key_UpArrow),   press(ImGui.Key_DownArrow)
    local left, right = press(ImGui.Key_LeftArrow), press(ImGui.Key_RightArrow)
    if press(ImGui.Key_Enter) or press(ImGui.Key_KeypadEnter) then
      if cur.param == 0 then                                -- header/add row: open the kind picker (mirrors ←→)
        chrome.requestPickerOpen(col.isAdd and 'fxAdd' or ('fxSwap_' .. col.index))
      else                                                  -- field row: pattern opens its editor, plain values inert
        local rw = col.fields[cur.param]
        if rw.fd.widget == 'pattern' then launchPattern(plan.host, rw.index, rw.fd, rw.entry) end
      end
    elseif super and (up or down) and not col.isAdd then
      if tv:moveFxStage(plan.host, col.index, up and -1 or 1) then cur.stage = cur.stage + (up and -1 or 1) end
    elseif up or down then                                  -- walk the whole chain as one column
      local rows = chainRows(cols)
      local i    = util.clamp(rowIndexOf(rows, cur) + (down and 1 or -1), 1, #rows)
      cur.stage, cur.param = rows[i].stage, rows[i].param
    elseif (left or right) and cur.param == 0 then          -- header/add row: open the picker (it cycles on ←→)
      chrome.requestPickerOpen(col.isAdd and 'fxAdd' or ('fxSwap_' .. col.index))
    elseif left or right then                               -- field row: nudge the value
      adjustRow(plan.host, col.fields[cur.param], right, mods)
    elseif press(ImGui.Key_Minus) or press(ImGui.Key_Equal) then
      if cur.param >= 1 then adjustRow(plan.host, col.fields[cur.param], press(ImGui.Key_Equal), mods) end
    elseif press(ImGui.Key_Backspace) or press(ImGui.Key_Delete) then
      if not col.isAdd then tv:removeFxStage(plan.host, col.index) end
    elseif col.isAdd or cur.param == 0 then
      local ch = typedChar()                                -- type-to-open: add slot appends, a header swaps
      if ch then chrome.requestPickerOpen(col.isAdd and 'fxAdd' or ('fxSwap_' .. col.index), ch) end
    end
    tv:setStripCursor(cur)
  end

  -- clear wipes the chain (always live). commit/cancel end the keyboard session, so they gate
  -- on strip focus (mouse parity for Super+X/Esc) — there's no session to end when unfocused.
  local function headerActions(plan)
    if ImGui.Button(ctx, 'clear') and plan.host then tv:setNoteFx(plan.host, util.REMOVE) end
    ImGui.SameLine(ctx, 0, 4)
    chrome.disabledIf(not stripFocus, function()
      if ImGui.Button(ctx, 'commit') then stripExitReq = true end
      ImGui.SameLine(ctx, 0, 4)
      if ImGui.Button(ctx, 'cancel') then cancelStrip() end
    end)
  end

  -- Fill behind the keyboard cursor's row (replacing the old ▸): drawn before the row content so it
  -- sits underneath; spans the current indent to the value column's left edge (not the margin).
  local function rowHighlight(active)
    if not active then return end
    local x, y   = ImGui.GetCursorScreenPos(ctx)
    local availW = select(1, ImGui.GetContentRegionAvail(ctx))
    stripPaint.fill({ x0 = x, y0 = y,
                      x1 = x + availW - VALUE_W - BTN_GAP, y1 = y + ImGui.GetFrameHeight(ctx) },
                    'toolbar.selectedRow')
  end

  -- Picker items for every fx kind; flags the caller's current kind (nil on the add slot).
  local function kindItems(currentKind)
    local items = {}
    for _, kind in ipairs(FX_KINDS) do
      items[#items + 1] = { label = generators.kinds[kind].label, key = kind, current = kind == currentKind }
    end
    return items
  end

  -- The add-stage picker, drawn as the chain's terminal row so the cursor can arrow onto it.
  local function drawAddChainStage(host, onCursor)
    rowHighlight(onCursor and stripFocus)
    chrome.drawPicker{
      kind = 'fxAdd', buttonLabel = 'add', flat = true, items = kindItems(),
      -- Lazy mint: the host under the caret wins; absent one (a bare selection), materialise its region now.
      onPick   = function(kind) local h = host or tv:fxHostForEdit(); if h then tv:addFxStage(h, fxSeed(kind)) end end,
      -- Esc aborts a still-empty keyboard gesture (prunes the eager-minted husk); the mouse path minted nothing.
      onCancel = function() if stripFocus and #(tv:noteFx(host) or {}) == 0 then cancelStrip() end end,
    }
  end

  -- Take strip focus and move the selection chip to (stage, param), snapshotting on entry.
  -- Label click enters; a value-widget edit doesn't — see docs/trackerRender.md § FX chain — palette tab.
  local function enterStrip(host, stage, param)
    if not stripFocus then stripSnapshot = { host = host, fx = util.deepClone(tv:noteFx(host)) } end
    stripHost = host
    tv:setStripCursor{ stage = stage, param = param }
    stripFocus = true
  end
  local function clickToCursor(host, stage, param)
    if ImGui.IsItemClicked(ctx) then enterStrip(host, stage, param) end
  end

  -- One stage as tree rows: heading (swap-picker) with ↑/↓ reorder + del, then a field per row —
  -- label left, value column flush right. Cursor row highlights while the strip holds focus.
  local function drawChainStage(host, col, onStage, cur, isFirst, isLast)
    local btnSide = ImGui.GetFrameHeight(ctx)   -- square side for the ↑/↓ reorder buttons

    rowHighlight(onStage and cur.param == 0 and stripFocus)
    local headX, availW = ImGui.GetCursorPosX(ctx), select(1, ImGui.GetContentRegionAvail(ctx))
    chrome.drawPicker{
      kind = 'fxSwap_' .. col.index, buttonLabel = col.label, flat = true,
      -- Grow to fit the label, but stop short of the reorder cluster (which sits at availW - VALUE_W).
      minWidth = LABEL_W, maxWidth = availW - VALUE_W - LABEL_GAP,
      items = kindItems(col.kind),
      onPick = function(kind) tv:replaceFxStage(host, col.index, fxSeed(kind)) end,
    }
    -- No clickToCursor here: picking a kind applies live via onPick without grabbing strip focus (mirrors a value edit).
    ImGui.SameLine(ctx); ImGui.SetCursorPosX(ctx, headX + availW - VALUE_W)   -- ↑/↓/del left-align with the value column
    chrome.disabledIf(isFirst, function()
      if ImGui.Button(ctx, '\xe2\x86\x91##fxup' .. col.index, btnSide, btnSide) then tv:moveFxStage(host, col.index, -1) end
    end)
    ImGui.SameLine(ctx, 0, BTN_GAP)
    chrome.disabledIf(isLast, function()
      if ImGui.Button(ctx, '\xe2\x86\x93##fxdn' .. col.index, btnSide, btnSide) then tv:moveFxStage(host, col.index, 1) end
    end)
    ImGui.SameLine(ctx, 0, DEL_GAP)
    if ImGui.Button(ctx, 'del##fxdel' .. col.index) then tv:removeFxStage(host, col.index) end

    for k, f in ipairs(col.fields) do
      ImGui.Indent(ctx, FIELD_INDENT)
      rowHighlight(onStage and cur.param == k and stripFocus)
      local labelX, rowW = ImGui.GetCursorPosX(ctx), select(1, ImGui.GetContentRegionAvail(ctx))
      ImGui.AlignTextToFramePadding(ctx); ImGui.Text(ctx, f.fd.label)
      clickToCursor(host, col.index, k)
      ImGui.SameLine(ctx); ImGui.SetCursorPosX(ctx, labelX + rowW - VALUE_W)
      fxFieldWidget(host, col.index, f.fd, f.entry, VALUE_W)   -- edits apply live; a value edit never grabs strip focus
      ImGui.Unindent(ctx, FIELD_INDENT)
    end
  end

  -- A crisp text-colour rule across the pane, split around a centred ↓ — signal flow down the
  -- chain (mirrors the old strip's divider). p.segment keeps the rule non-AA (a filled strip).
  local FLOW_GLYPH, FLOW_GAP = '\xe2\x8f\xb7', 4
  local function drawFlowMarker()
    local ox, oy = ImGui.GetCursorScreenPos(ctx)
    local availW = select(1, ImGui.GetContentRegionAvail(ctx))
    local gw, gh = ImGui.CalcTextSize(ctx, FLOW_GLYPH)
    local midX   = math.floor(ox + availW / 2)
    local ruleY  = math.floor(oy + gh / 2)
    local half   = math.ceil(gw / 2) + FLOW_GAP
    stripPaint.segment(ox, ruleY, midX - half, ruleY, 'text', 1)
    stripPaint.segment(midX + half, ruleY, ox + availW, ruleY, 'text', 1)
    stripPaint.text(midX - math.floor(gw / 2), oy, 'text', FLOW_GLYPH)
    ImGui.Dummy(ctx, availW, gh)
  end

  -- Drawn inside the palette child (the tab header + chrome styles are already pushed): the action
  -- row, then each stage top-to-bottom with a ↓ between, ending on the add row.
  function drawFxChainBody(plan)
    stripPaint = chrome.screenPainter()
    local cur = clampCursor(plan.cols); tv:setStripCursor(cur)
    if fxFocusReq then enterStrip(plan.host, cur.stage, cur.param); fxFocusReq = false end
    headerActions(plan)
    ImGui.Separator(ctx)
    local availW = select(1, ImGui.GetContentRegionAvail(ctx))
    ImGui.Dummy(ctx, availW, 2)
    for ci, col in ipairs(plan.cols) do
      if ci > 1 then drawFlowMarker() end
      if col.isAdd then drawAddChainStage(plan.host, cur.stage == ci)
      else              drawChainStage(plan.host, col, cur.stage == ci, cur, ci == 1, ci == #plan.cols - 1) end
    end
    if stripFocus and not modalHost:isOpen()
       and not chrome.pickerIsActive() and not ImGui.IsAnyItemActive(ctx) then
      handleFxChainKeys(plan)
    end
  end

  -- Super+X enters the fx session (a selection mints its region, the caret pins); any tab pin clears
  -- first so entry always lands keyboard focus in the fx palette. Mouse entry is hostless (see stripPlan).
  function editFx()
    tv:clearTabOverride()   -- drop any tab pin: the keyboard session owns the fx tab now
    local host, fresh = tv:fxHostForEdit()
    if not host then return end
    local existing = tv:noteFx(host)
    if host ~= stripHost then
      stripSnapshot = { host = host, fx = (not fresh) and existing and util.deepClone(existing) or nil }
    end
    stripHost = host
    -- Empty chain: park on the add slot and pop the add picker at once, so there's no dead Enter first.
    if not existing or #existing == 0 then
      tv:setStripCursor{ stage = 1, param = 0 }
      chrome.requestPickerOpen('fxAdd')
    elseif not tv:stripCursor() then
      tv:setStripCursor{ stage = 1, param = 0 }
    end
    stripFocus = true
  end
end

-- New take from the tracker: name + length modal, mint a parked slot, select it.
-- Length seeds from / persists to the project-tier newTakeBeats config.
local function openNewTakeModal()
  local trackIdx = tv:currentTrackIdx(); if not trackIdx then return end
  local slot = arrange().nextFreeSlot(trackIdx)
  modalHost:open{
    kind     = 'newTake',
    title    = 'New take',
    nameBuf  = slot and string.format('%02d', slot) or '',
    beatsBuf = tostring(cm:get('newTakeBeats')),
    callback = util.atomic('New take', function(nameBuf, beatsBuf)
      local b = math.max(1e-3, tonumber(beatsBuf) or cm:get('newTakeBeats'))
      cm:set('project', 'newTakeBeats', b)
      tv:newParkedTake(nameBuf, b)
    end),
  }
end

modalHost:registerKind('newTake', function(s, close)
  local appearing = ImGui.IsWindowAppearing(ctx)
  ImGui.Text(ctx, 'Name')
  if appearing then ImGui.SetKeyboardFocusHere(ctx) end
  local rvN, nb = ImGui.InputText(ctx, '##newTakeName', s.nameBuf)
  if rvN then s.nameBuf = nb end
  ImGui.Text(ctx, 'Length (beats)')
  local rvB, bb = ImGui.InputText(ctx, '##newTakeBeats', s.beatsBuf)
  if rvB then s.beatsBuf = bb end
  local ok = ImGui.Button(ctx, 'OK')
              or (not appearing and (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
                                  or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)))
  ImGui.SameLine(ctx)
  local cancel = ImGui.Button(ctx, 'Cancel')
              or (not appearing and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape))
  if ok then close(true, s.nameBuf, s.beatsBuf)
  elseif cancel then close(false) end
end)

-- Mint the clone, open take-properties focused on name. No rebind: slot selection re-binds
-- to the clone before any commit lands, so the seed and commit both target the clone.
local function duplicateUnpooledTake()
  if tv:duplicateBoundUnpooled() then tr:openTakeProperties{ focusName = true } end
end

-- Super-R toggles the parameters tab: park it over an auto-shown chain and land on the find box, or,
-- if already parked, drop the override back to the auto chain. Super-X (editFx) is the mirror, owning fx.
local function focusParams()
  if tv:tabOverride(caretKeyNow()) == 'parameters' then tv:clearTabOverride(); return end
  tv:overrideTab('parameters', caretKeyNow()); paletteFocus, focusFindReq = 'find', true
end

local tracker = cmgr:scope('tracker')

tracker:registerAll{
  setRPB = function()
    openPrompt('Rows per beat', '1-32', function(buf)
      local n = tonumber(buf); if n then tv:setRowPerBeat(n) end
    end)
  end,

  takeProperties         = { function() tr:openTakeProperties{} end, 'Take properties' },
  newTakeBelow           = { openNewTakeModal, 'New take' },
  duplicateUnpooledBelow = { duplicateUnpooledTake, 'Duplicate take (unpooled)' },

  prevTrack = { function() tv:gotoTrack(-1) end, 'Previous track' },
  nextTrack = { function() tv:gotoTrack(1)  end, 'Next track' },
  prevTake  = { function() tv:gotoTake(-1)  end, 'Previous take' },
  nextTake  = { function() tv:gotoTake(1)   end, 'Next take' },

  addNoteLane = { function() tv:addExtraCol('note') end, 'Add note lane' },
  addTypedCol = addColumn,
  hideExtraCol = { removeOrHideCol, 'Hide / remove column' },

  quantize             = { scopedAction('quantize',               'quantize'),             'Quantize' },
  quantizeKeepRealised = { scopedAction('quantize keep realised', 'quantizeKeepRealised'), 'Quantize (keep realised)' },

  openTemperPicker = function() chrome.requestPickerOpen('temper') end,
  openSwingPicker  = function() chrome.requestPickerOpen('swing')  end,

  editNoteFx        = editFx,
  focusParamPalette = focusParams,
}

cmgr:doAfter({ 'quantize', 'quantizeKeepRealised' },
             function() tv:ec():unstick() end)

----- Region overlay keymap

-- Overlay + verb bodies live on ec. Page wires only the \ entry and overlay-only keys
-- (exit/bail/paint); move/size/stamp/delete redirect off tracker commands, no keys needed.
cmgr:scope('region'):bindAll(require('pageBindings').region)

-- Group quick-verb bodies + lifetime live on trackerView; install the
-- copy snapshot + clear-on-mutation sweep now that every tracker command
-- (incl. this page's) is registered.
tv:wireGroupLifetime()

---------- PUBLIC

----- Take properties modal helper

-- Shared by the tracker-scope `takeProperties` command and the
-- arrange-scope `arrangeTakeProperties` (which binds tm to its focused
-- take first and supplies an onClose to restore the prior bind). The
-- helper reads name/beats from tp's currently-bound take and applies
-- through tv:applyTakeProperties; callers without a bound take get a
-- no-op-ish modal seeded with 0 beats.
--
-- onClose fires exactly once, after the whole modal chain — including
-- any truncate-confirm follow-up. Two sources of "chain done":
-- the apply path (callback ran, valid input, either direct apply or
-- truncate-confirm resolution) fires onClose at the leaf; the cancel
-- path (modal cancel, or invalid input) fires it via modalHost's own
-- onClose. The `transfer` flag handshake makes these mutually
-- exclusive: once a valid callback starts the apply chain it claims
-- ownership, so modalHost's onClose becomes a no-op.
function tr:openTakeProperties(args)
  args = args or {}
  local rpb        = cm:get('rowPerBeat')
  local origBeats  = (tv.grid.numRows or 0) / rpb
  local pendingOnClose = true
  local function fireOnClose()
    if not pendingOnClose then return end
    pendingOnClose = false
    if args.onClose then args.onClose() end
  end
  modalHost:open{
    kind     = 'takeProps',
    title    = 'Take properties',
    nameBuf  = tv:takeName() or '',
    beatsBuf = ('%g'):format(origBeats),
    beatsGen = 0,
    mode     = 'resize',
    focusName = args.focusName,
    callback = function(name, beats, mode)
      if not beats or beats <= 0 then return end
      pendingOnClose = false  -- transfer ownership to the apply chain
      -- rescale is the monotone stretch — never deletes events.
      -- resize and tile both fall back to truncation when shrinking.
      if beats < origBeats and mode ~= 'rescale' then
        local txt = ('%g'):format(beats)
        openConfirm('Truncate take',
          function(yes)
            if yes then tv:applyTakeProperties{ name = name, beats = beats, mode = mode } end
            if args.onClose then args.onClose() end
          end,
          ('Truncate to %s beats? Events past beat %s will be deleted. (y/n)'):format(txt, txt))
      else
        tv:applyTakeProperties{ name = name, beats = beats, mode = mode }
        if args.onClose then args.onClose() end
      end
    end,
    onClose = fireOnClose,
  }
end

----- Page interface (rendering only; trackerPage drives lifecycle and the dispatch)

function tr:toolbarSegments() return toolbarSegments end

function tr:renderBody(_, w, h, dispatch)
  -- No bound take ⇒ empty grid. Body pushes no Col_Text, so push uiFont +
  -- grid text colour explicitly; still dispatch so global keys fire.
  if #tv.grid.cols == 0 then
    if dispatch then dispatch(self:focusState()) end
    ImGui.PushFont(ctx, uiFont, gui.fontSize.ui)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, chrome.colour('text'))
    ImGui.Text(ctx, 'No MIDI takes on this track.')
    ImGui.PopStyleColor(ctx)
    ImGui.PopFont(ctx)
    return
  end
  local ox, oy = ImGui.GetCursorScreenPos(ctx)
  local gridW  = chrome.gridWidth(w)
  local fxChosen = stripFocus or tv:tabOverride(caretKeyNow()) == 'fx'
  local plan     = stripPlan(fxChosen)   -- fxChosen shows the bare add row when the fx tab is picked on an empty host
  if stripFocus and not plan then   -- the pinned host vanished (undo/removal); tidy and drop focus
    if stripHost then tv:pruneEmptyRegion(stripHost) end   -- cull an emptied husk
    stripFocus, stripSnapshot, stripHost = false, nil, nil
  end
  gridPane:draw(gridW, h)   -- half-row bottom breathing is built into gridPane; fx chain lives in the palette now
  if stripFocus or paletteFocus then   -- focus lives in the palette: wash the grid to disabled
    ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx),
      ox, oy, ox + gridW, oy + h, chrome.colour('tracker.focusScrim'))
  end
  -- Full body width (grid + palette) so the cheat-sheet can flow across both.
  local g = gridPane:geom()
  help:anchor('body.grid', g.originX, g.originY, ox + w - g.originX, g.height * g.cellH)

  drawParamPalette(ox + gridW, oy, h, caretKeyNow(), plan ~= nil, plan)
  tv:pollLearn(ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_AnyWindow))

  if not help:wasOpenAtFrameStart() then gridPane:handleMouse() end
  if stripFocus and ImGui.IsMouseClicked(ctx, 0) then   -- a click in the grid commits the strip and returns focus
    local mx, my = ImGui.GetMousePos(ctx)
    if mx >= ox and mx < ox + gridW and my >= oy and my < oy + h then stripExitReq = true end
  end
  local kr = dispatch and dispatch(self:focusState()) or { commandHeld = {} }
  if not help:wasOpenAtFrameStart() then gridPane:handleKeys(kr) end
  if stripExitReq then   -- exit after this frame's dispatch saw us focused; prune a husk left empty
    if stripHost then tv:pruneEmptyRegion(stripHost) end
    stripFocus, stripExitReq, stripSnapshot, stripHost = false, false, nil, nil
  end

  tv:tick()
end

function tr:renderStatusBar(_)
  drawStatusBar()
end

-- suppressKbd: modal/picker owns input. pageSuppressed: unused (swing/temper on own page).
-- acceptCmds: page visible and no item active (toolbar focus is transient; see IsAnyItemActive).
--shape: focusState = { suppressKbd:bool, pageSuppressed:bool, acceptCmds:bool }
function tr:focusState()
  if not ctx then return { suppressKbd = false, pageSuppressed = false, acceptCmds = false } end
  local suppressKbd = modalHost:isOpen() or chrome.pickerIsActive()
  return {
    suppressKbd    = suppressKbd,
    pageSuppressed = false,
    acceptCmds     = (not suppressKbd) and not ImGui.IsAnyItemActive(ctx) and not paletteFocus and not stripFocus,
  }
end

return tr

