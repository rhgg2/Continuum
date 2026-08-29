-- See docs/trackerPage.md for the model.

--invariant: page is render + input only; tracker state lives in tv/ec/tm, never cached
--invariant: cm/tv read fresh each frame; only ephemeral UI state persists across frames
--invariant: page-persistent state: picker*, paletteFocus, stripFocus (modal state on modalHost)
--invariant: grid/lane render state lives in gridPane, not this page
--invariant: writes go through tv or cmgr commands; page never reaches into tm
local util    = require 'util'
local tuning  = require 'tuning'
local timing  = require 'timing'
local generators = require 'generators'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

--contract: trackerPage (the controller) owns the stack + take lifecycle and drives this renderer
--contract: the renderer holds only tv (injected); it never reaches mm/tm/gm
local cm, ds, cmgr, chrome, gui, modalHost, facade, tv, help, pe, keyQueue =
  (...).cm, (...).ds, (...).cmgr, (...).chrome, (...).gui, (...).modalHost, (...).facade, (...).tv, (...).help, (...).pe,
  (...).keyQueue

-- The renderer reads project data (tracks/slots) through the arrange facade;
-- the tracker's selection nav goes straight to tv. See docs/trackerPage.md.
local function arrange() return facade.get('arrange') end

---------- PRIVATE

local ctx, uiFont = gui.ctx, gui.uiFont

-- Group quick-verb state and lifetime moved to trackerView (this page is
-- pure render/UI). The 'region' overlay keymap and the
-- tv:wireGroupLifetime call stay here.

local pickTemper   = util.atomic('Set temper',       function(name)       tv:setTemperSlot(name)         end)
local pickSwing    = util.atomic('Set swing',        function(name)       tv:setSwingSlot(name)          end)
local pickColSwing = util.atomic('Set column swing', function(chan, name) tv:setColSwingSlot(chan, name) end)

-- 'identity' is the explicit no-swing sentinel (schema default); shown as
-- "Off" in the button, hidden from the picker rows.
local SWING_PRESET_EXCLUDE  = { identity = true }
-- 12EDO is the temper floor: shown by name as the active default, hidden from the +preset rows.
local TEMPER_PRESET_EXCLUDE = { ['12EDO'] = true }

-- Each render closure reads cm/tv fresh; segments declared once, reused per frame.
--shape: ToolbarSegment = { id, heading? (presence = collapsible), render = fn(), visible? = fn() -> bool, pickers? }

local function trackLabel(track) return track.name ~= '' and track.name or ('Track ' .. (track.idx + 1)) end
local function currentTrackLabel()
  local curIdx = tv:currentTrackIdx()
  for _, track in ipairs(arrange().tracks()) do
    if track.idx == curIdx then return trackLabel(track) end
  end
  return '\xe2\x80\x94'
end

local function slotLabel(slot) return slot.name ~= '' and slot.name or arrange().keyForSlot(slot.idx) end
local function currentSlotLabel()
  local curSlot = tv:currentSlotIdx()
  for _, slot in ipairs(arrange().midiSlots(tv:currentTrackIdx())) do
    if slot.idx == curSlot then return slotLabel(slot) end
  end
  return '\xe2\x80\x94'
end

-- Channel under the edit cursor, for the per-column swing picker.
local function cursorChan()
  local cursorCol = tv.grid.cols[tv:ec():col()]
  return cursorCol and cursorCol.midiChan
end

local toolbarSegments = {
  {
    id = 'track', heading = 'Track',
    render = function()
      local curIdx = tv:currentTrackIdx()
      local items = {}
      for _, track in ipairs(arrange().tracks()) do
        util.add(items, { label = trackLabel(track), key = track.idx, group = 1, current = track.idx == curIdx })
      end
      chrome.drawPicker {
        kind        = 'track',
        buttonLabel = currentTrackLabel(),
        width       = 120, items = items, onPick = function(idx) tv:pickTrack(idx) end,
      }
    end,
  },
  {
    id = 'take', heading = 'Take',
    render = function()
      local curSlot = tv:currentSlotIdx()
      local items = {}
      for _, slot in ipairs(arrange().midiSlots(tv:currentTrackIdx())) do
        util.add(items, { label = slotLabel(slot), key = slot.idx, group = 1, current = slot.idx == curSlot })
      end
      chrome.drawPicker {
        kind        = 'take',
        buttonLabel = currentSlotLabel(),
        width       = 120, items = items, onPick = function(idx) tv:pickTake(idx) end,
      }
    end,
  },
  {
    id = 'tuning', heading = 'Tuning', pickers = { 'temper' },
    render = function()
      local cur = cm:get('temper')
      chrome.drawPicker {
        kind        = 'temper',
        buttonLabel = cur or 'Off',
        width       = 120,
        items       = chrome.libPicker{ key = 'tempers', current = cur, excludeOthers = TEMPER_PRESET_EXCLUDE },
        onPick      = pickTemper,
      }
      ImGui.SameLine(ctx, 0, 6)
      if ImGui.Button(ctx, 'edit##editTemper') then cmgr:invoke('editTuning') end
    end,
  },
  {
    id = 'swing', heading = 'Swing', pickers = { 'swing', 'colSwing' },
    render = function()
      local cur = (ds:get('swing') or {}).global
      chrome.drawPicker {
        kind        = 'swing', heading = 'Take',
        buttonLabel = (not cur or cur == 'identity') and 'Off' or cur,
        width       = 120,
        items       = chrome.libPicker{ key = 'swings', current = cur, excludeOthers = SWING_PRESET_EXCLUDE },
        onPick      = pickSwing,
      }
      local chan = cursorChan()
      ImGui.SameLine(ctx, 0, 8)
      chrome.disabledIf(not chan, function()
        local chanCur = chan and (ds:get('swing') or {})[chan] or nil
        chrome.drawPicker {
          kind        = 'colSwing', heading = 'Ch',
          buttonLabel = chanCur or 'Off',
          width       = 120,
          items       = chrome.libPicker{ key = 'swings', current = chanCur, excludeOthers = SWING_PRESET_EXCLUDE },
          onPick      = function(name) pickColSwing(chan, name) end,
        }
      end)
      ImGui.SameLine(ctx, 0, 8)
      if ImGui.Button(ctx, 'edit##editSwing') then cmgr:invoke('editSwing') end
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

-- The caret identity a tab override anchors to, lapsing as soon as the caret moves off
-- it; tv owns the format, since the raise writes an anchor of its own (see tv:paletteTab).
local function caretKeyNow() return tv:caretKey() end

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
      util.add(bucket, prm)
    else
      util.add(ungrouped, prm)
    end
  end
  local order = {}
  for name in pairs(groups) do util.add(order, name) end
  if #order == 0 then
    for _, prm in ipairs(ungrouped) do util.add(plan, { kind = 'param', row = row, prm = prm }) end
    return
  end
  table.sort(order, function(a, b) return minIndex[a] < minIndex[b] end)
  local function emitGroup(label, bucket)
    util.add(plan, { kind = 'section', row = row, text = label })
    for _, prm in ipairs(bucket) do
      util.add(plan, { kind = 'param', row = row, prm = prm })
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
          util.add(shownParams, prm)
        end
      end
      shown, open = #shownParams > 0, true
    end
    if shown then
      if section ~= heading then
        heading = section
        util.add(plan, { kind = 'heading', text = section })
      end
      util.add(plan, { kind = 'fx', row = row, open = open })
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
      util.add(nav, { fxGuid = it.row.fxGuid, param = nil, item = it, row = it.row })
    elseif it.kind == 'param' then
      util.add(nav, { fxGuid = it.row.fxGuid, param = it.prm.index, item = it,
                        row = it.row, prm = it.prm })
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
    tv:overrideTab('fx', caretKeyNow()); fxFocusReq = true; return true   -- cross to fx: claim the tab, focus the chain next fx draw
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
                       { key = 'fx',         label = 'fx' },
                       { key = 'map',        label = 'map' } }

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

-- The arrange mini-map body: one filled box per instance over a window of tracks and QN, the current instance in the focused fill and nothing else.
-- The pane's pixels are this renderer's business — tv is asked for a window in columns and QN, as gridPane asks with setGridSize.
local MAP_COLS, MAP_PX_PER_QN = 5, 2
local MAP_CELL_QN, MAP_BAR_QN, MAP_PHRASE_QN = 4, 16, 64
-- Snap a press's QN down to the top edge of the cell it sits in.
local function floorToCell(qn) return math.floor(qn / MAP_CELL_QN) * MAP_CELL_QN end
--shape: mapPress = { qn, moved } — nil when no button is down over the map's margin; moved flips at the drag threshold.
--invariant: a margin press drives the transport: release seeks the cursor, drag sets the loop.
local mapPress = nil
local function drawMapBody()
  local p              = chrome.screenPainter()
  local availW, availH = ImGui.GetContentRegionAvail(ctx)
  -- Whole-pixel origin: the pane's screen position is fractional, and every rule
  -- and border here is 1px, so an unsnapped origin blurs the lot into invisibility.
  local curX, curY = ImGui.GetCursorScreenPos(ctx)
  local ox, oy     = math.floor(curX), math.floor(curY)
  -- Five track columns and a half-column margin: a lane for the loop bracket, then a
  -- gutter the grid runs out into, closed off by the first column's rule.
  local colW   = availW / (MAP_COLS + 1/2)
  local lane   = math.floor(colW / 4)
  local gutter = math.floor(colW / 4)
  local gridL  = ox + lane
  local win    = tv:mapWindow(MAP_COLS, availH / MAP_PX_PER_QN)
  local function colX(col) return gridL + gutter + math.floor((col - win.colLo) * colW) end
  local function qnY(qn)   return oy + math.floor((qn - win.qnLo) * MAP_PX_PER_QN) end
  local function qnAt(y)   return win.qnLo + (y - oy) / MAP_PX_PER_QN end

  -- The margin drives the transport, as the arrange page's gutter does (docs/trackerRender.md § The mini-map).
  -- A release commits and the candidate stands for the frame, so the bracket never flicks back.
  local loopCand
  local mx, my  = ImGui.GetMousePos(ctx)
  local inMargin = mx >= ox and mx < gridL + gutter and my >= oy and my < oy + availH
  if ImGui.IsMouseClicked(ctx, 0) and ImGui.IsWindowHovered(ctx) and inMargin then
    mapPress = { qn = qnAt(my), moved = false }
  end
  if mapPress then
    local snapped = ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift == 0
    if ImGui.IsMouseDragging(ctx, 0) then mapPress.moved = true end
    if mapPress.moved then
      loopCand = tv:mapLoopCand(mapPress, qnAt(my), snapped, MAP_CELL_QN)
    end
    if ImGui.IsMouseReleased(ctx, 0) then
      if loopCand then tv:setLoopRangeQN(loopCand.loQN, loopCand.hiQN)
      else tv:setEditCursorQN(snapped and floorToCell(mapPress.qn) or mapPress.qn) end
      mapPress = nil
    end
  end

  -- The arrange grid's cadence in its own inks: a cell every 4 QN ruled off, the bar and phrase cells tinted as the grid tints their rows.
  -- The grid reaches as far as the track list and no further, and sits under the boxes, as it does there.
  local gridR = colX(win.colHi + 1)
  for qn = math.floor(win.qnLo / MAP_CELL_QN) * MAP_CELL_QN, win.qnHi, MAP_CELL_QN do
    local tint = (qn % MAP_PHRASE_QN == 0) and 'arrange.phrase'
              or (qn % MAP_BAR_QN == 0)    and 'rowBeat'
              or nil
    if tint then
      p.fill({ x0 = gridL, y0 = qnY(qn), x1 = gridR, y1 = qnY(qn + MAP_CELL_QN) }, tint)
    end
    p.segment(gridL, qnY(qn), gridR, qnY(qn), 'separator')
  end
  for col = win.colLo, win.colHi + 1 do
    p.segment(colX(col), oy, colX(col), oy + availH, 'separator')
  end

  -- Rects share their edge pixel with the neighbouring box and with the gridline
  -- under it, as the arrange grid's do: the border rect runs a px past the fill.

  -- A click travels to the box under it (docs/trackerRender.md § The mini-map).
  local boxClick = ImGui.IsMouseClicked(ctx, 0) and ImGui.IsWindowHovered(ctx) and not inMargin
  local travelTk
  for _, tk in ipairs(win.takes) do
    local xLo, xHi = colX(tk.trackIdx), colX(tk.trackIdx + 1)
    local yLo = math.max(oy, qnY(tk.startQN))
    local yHi = math.min(oy + availH, qnY(tk.startQN + tk.lengthQN))
    if yHi - yLo < 2 then yHi = yLo + 2 end
    p.fill({ x0 = xLo + 1, y0 = yLo + 1, x1 = xHi, y1 = yHi },
           chrome.slotFill(tk.colourIdx, tk.take == win.current))
    p.border({ x0 = xLo, y0 = yLo, x1 = xHi + 1, y1 = yHi + 1 }, 'arrange.itemBorder')
    if boxClick and not travelTk
       and mx >= xLo and mx < xHi and my >= yLo and my < yHi then travelTk = tk end
  end
  if travelTk then tv:travelTo(travelTk) end

  -- The loop range: the `[` the arrange page strokes down its gutter, drawn in its own lane
  -- clear of the grid (docs/trackerRender.md § The mini-map). An in-flight drag preempts the committed range, as arrangeRender.lua:544 does.
  local loopLoQN, loopHiQN = win.loopLoQN, win.loopHiQN
  if loopCand then loopLoQN, loopHiQN = loopCand.loQN, loopCand.hiQN end
  if loopLoQN then
    local r      = math.max(2, (lane - 2) // 2)
    local x1     = ox + 1 + r
    local y1, y2 = qnY(loopLoQN), qnY(loopHiQN)
    p.pathClear()
    p.pathArcTo(x1, y1 + r, r, 3 * math.pi / 2, math.pi)
    p.pathLineTo(x1 - r, y1 + r + 1)
    p.pathLineTo(x1 - r, y2 - r - 1)
    p.pathArcTo(x1, y2 - r, r, math.pi, math.pi / 2)
    p.pathStroke('tail', 1.5)
    p.pathClear()
  end

  -- The play head last, in the tracker's own play-row ink, across the pane and over
  -- boxes and gaps alike (docs/trackerRender.md § The mini-map).
  if win.playQN then
    local y = qnY(win.playQN)
    p.segment(ox, y, math.floor(ox + availW), y, 'tracker.playRow')
  end
end

-- The right-hand pane: parameters | fx | map tabs. fx auto-raises on a showable chain; Super-R
-- parks parameters over it. See docs/trackerRender.md § Palette tabs.
local function drawParamPalette(x, y, h, caretKey, fxAvailable, fxPlan)
  local activeTab = tv:paletteTab(caretKey, fxAvailable)
  if activeTab ~= 'parameters' and paletteFocus then paletteFocus = nil end
  chrome.palettePane{
    x = x, y = y, h = h,
    tabs = PALETTE_TABS, activeTab = activeTab,
    onTab = function(key) tv:overrideTab(key, caretKey) end,   -- a tab click just switches the view; it never grabs focus
    draw = function(childFocused)
      if     activeTab == 'fx'  then drawFxChainBody(fxPlan)
      elseif activeTab == 'map' then drawMapBody()
      else                           drawParamsBody(childFocused) end
    end,
  }
end

----- Status bar

local function cursorColLabel()
  local col = tv.grid.cols[tv:ec():col()]
  return col and col.label or '?'
end

local function cursorPosition()
  local bar, beat, sub = tv:barBeatSub(tv:ec():row())
  return string.format('%d:%d.%d', bar, beat, sub)
end

local function sampleReadout()
  local slot  = cm:get('currentSample')
  local entry = (ds:get('slotEntries') or {})[slot]
  return string.format('%02X', slot) .. (entry and entry.name and (' ' .. entry.name) or '')
end

-- Hex stays visible when unassigned so `<`/`>` advertise their step.
-- No "Off" row — every slot is real.
local function sampleItems()
  local cur     = cm:get('currentSample')
  local entries = ds:get('slotEntries') or {}
  local indices = {}
  for idx, e in pairs(entries) do
    if e.path then util.add(indices, idx) end
  end
  table.sort(indices)
  local items = {}
  for _, idx in ipairs(indices) do
    util.add(items, {
      label   = string.format('%02X  %s', idx, entries[idx].name or ''),
      key     = idx,
      group   = 1,
      current = idx == cur,
    })
  end
  return items
end

-- The cells the keyboard also writes, so a mouse edit lands in the same undo block.
local setRpb     = function(n) tv:setRowPerBeat(n) end
local setOctave  = util.atomic('Set octave',  function(n) cm:set('take', 'currentOctave', n) end)
local setAdvance = util.atomic('Set advance', function(n) cm:set('take', 'advanceBy', n) end)
local setSample  = util.atomic('Set sample',  function(idx) cm:set('take', 'currentSample', idx) end)
-- Track tier: pbRange must match the pitch-bend range of the synth on the track, so
-- every take through it shares one window. cm's targeted fire re-derives all channels.
local setPbRange = util.atomic('Set bend range', function(n) cm:set('track', 'pbRange', n) end)

-- Each get reads cm/tv fresh; cells declared once, reused per frame.
local statusSegments = {
  { id = 'col',     label = 'Col',     width = 50,  get = cursorColLabel },
  { id = 'at',      label = 'At',      width = 40,  get = cursorPosition },
  { id = 'rpb',     label = 'RPB',     width = 20,  get = function() return cm:get('rowPerBeat')    end, format = '%d',
    set = setRpb,     edit = { kind = 'number', min =  1, max = 32 } },
  { id = 'octave',  label = 'Octave',  width = 20,  get = function() return cm:get('currentOctave') end, format = '%d',
    set = setOctave,  edit = { kind = 'number', min = -1, max =  9 } },
  { id = 'advance', label = 'Advance', width = 20,  get = function() return cm:get('advanceBy')     end, format = '%d',
    set = setAdvance, edit = { kind = 'number', min =  0, max =  9 } },
  { id = 'pbRange', label = 'Bend',    width = 20,  get = function() return cm:get('pbRange')       end, format = '%d',
    set = setPbRange, edit = { kind = 'number', min =  1, max = 48 } },
  { id = 'sample',  label = 'Sample',  width = 125, get = sampleReadout,
    visible = function() return cm:get('trackerMode') end,
    set = setSample,  edit = { kind = 'pick', items = sampleItems } },
  -- The page's modes, at the bar's right end. Each is checked far more often than it is
  -- flipped, and two carry keys, so none earns the toolbar frontage a headed segment costs.
  { id = 'modes', edit = { kind = 'flags', items = {
    { label = 'Loop',   get = function() return tv:loopsToItem() end, set = function(v) tv:setLoopToItem(v) end },
    { label = 'Follow', get = function() return tv:followsPlay()  end, set = function(v) tv:setFollowPlay(v)  end },
    { label = 'Curve',  get = function() return cm:get('laneStrip.visible') end,
                        set = function(v) cm:set('global', 'laneStrip.visible', v) end },
  } } },
}

----- Input

----- F1 help placements — toolbar callouts pin to their segments
-- The grid and global bindings flow in a panel packed over the grid body. See
-- docs/help.md § What's where.

help:registerPage('tracker', {
  { group = 'Track',           anchor = 'toolbar.track',  place = 'pin' },
  { group = 'Take',            anchor = 'toolbar.take',   place = 'pin' },
  { group = 'Rows / beat',     anchor = 'status.rpb',     place = 'pin' },
  { group = 'Tuning',          anchor = 'toolbar.tuning', place = 'pin' },
  { group = 'Swing',           anchor = 'toolbar.swing',  place = 'pin' },
  { group = 'Sample',          anchor = 'status.sample',  place = 'pin' },
  { group = 'Loop',            anchor = 'status.modes',   place = 'pin' },
  { group = 'Movement',        anchor = 'body',           place = 'flow' },
  { group = 'Editing',         anchor = 'body',           place = 'flow' },
  { group = 'Selection',       anchor = 'body',           place = 'flow' },
  { group = 'Columns & rows',  anchor = 'body',           place = 'flow' },
  { group = 'Groups & region', anchor = 'body',           place = 'flow' },
  { group = 'FX',              anchor = 'body',           place = 'flow' },
  { group = 'Input',           anchor = 'body',           place = 'flow' },
  { group = 'Transport',       anchor = 'body',           place = 'flow' },
  { group = 'Take management', anchor = 'body',           place = 'flow' },
  { group = 'Advance',         anchor = 'body',           place = 'flow' },
  { group = 'Pages',           anchor = 'body',           place = 'flow' },
  { group = 'Global',          anchor = 'body',           place = 'flow' },
})

----- Modal-driven commands

local function openPrompt(title, prompt, callback, resolve)
  modalHost:openPrompt{ title = title, prompt = prompt, callback = callback, resolve = resolve }
end

local function openConfirm(title, callback, prompt)
  modalHost:openConfirm{ title = title, prompt = prompt, callback = callback }
end

-- Custom modal: take properties. `docs/trackerRender.md` § Take properties modal
modalHost:registerKind('takeProps', function(s, close)
  local function scaleBy(factor)
    local n = tonumber(s.beatsBuf)
    if not n then return end
    local minBeats = 1 / cm:get('rowPerBeat')
    s.beatsBuf     = ('%g'):format(math.max(minBeats, n * factor))
    s.beatsGen     = s.beatsGen + 1
    s.refocusBeats = true
  end
  -- The rows-per-beat bindings are the modal's own while it owns the queue: each is
  -- claimed at the mods it carries. see docs/keyQueue.md § Ownership
  local function tookAny(specs)
    for _, spec in ipairs(specs or {}) do
      local key, mods = cmgr:keySpec(spec, ImGui)
      if keyQueue:take(key, mods, 'modal') then return true end
    end
    return false
  end

  if     tookAny(cmgr:keysFor('doubleRPB')) then scaleBy(2)
  elseif tookAny(cmgr:keysFor('halveRPB'))  then scaleBy(0.5) end

  local appearing = ImGui.IsWindowAppearing(ctx)   -- the frame the length field takes focus on

  ImGui.Text(ctx, 'Item name')
  local rvN, name = ImGui.InputText(ctx, '##takeprops_name', s.nameBuf)
  if rvN then s.nameBuf = name end

  ImGui.Text(ctx, 'Length (beats)')
  if appearing or s.refocusBeats then
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
  ImGui.SameLine(ctx)
  local cancelPressed = ImGui.Button(ctx, 'Cancel')
  local mods          = keyQueue:frameMods()
  if okPressed or keyQueue:take(ImGui.Key_Enter, mods, 'modal')
               or keyQueue:take(ImGui.Key_KeypadEnter, mods, 'modal') then
    close(true, s.nameBuf, tonumber(s.beatsBuf), s.mode)
  elseif cancelPressed or keyQueue:take(ImGui.Key_Escape, mods, 'modal') then
    close(false)
  end
end)

-- The library's targets as picker rows: a temper every one of whose pitches is a ratio.
-- Ineligible ones are filtered out rather than offered and refused. see design/adaptive-tuning.md § What a target is
local function retuneTargetItems(current)
  local library = cm:get('tempers', { mergeTiers = true })
  local items   = {}
  for _, item in ipairs(chrome.libPicker{ key = 'tempers', current = current }) do
    if item.key == nil or tuning.isTarget(library[item.key]) then util.add(items, item) end
  end
  return items
end

-- A notation step, spelled as the grid spells it.
local function stepLabel(notation, step)
  local name = notation.stepNames and notation.stepNames[step]
  return (name and name ~= '') and name or (step .. '-')
end

local function retuneKeyItems(notation, current)
  local items = {}
  for step = 1, #notation.cents do
    util.add(items, { label = stepLabel(notation, step), key = step, current = step == current })
  end
  return items
end

-- The modal's left labels, measured together so the controls share one column,
-- and the gap that column stands off the longest of them.
local RETUNE_LABELS    = { 'Target:', 'Sonority size:', 'Harmonic lock:', 'Purity:', 'Ambient:',
                           'Strength:' }
local RETUNE_LABEL_GAP = 6

-- The three dials' opening figures. see docs/sonority.md § The dials
local RETUNE_LOCK, RETUNE_PURITY, RETUNE_AMBIENT = 1, 32, 0.25

-- Custom modal: retune (docs/trackerView.md § Retune) — scope is a field
-- here, not scopedAction's confirm, and OK is the single commit point.
modalHost:registerKind('retune', function(s, close)
  local notation = tv:activeTemper()

  -- One column: every control's frame starts past the widest label, so the pickers,
  -- the stepper and the sliders line up however wide their own labels run.
  local originX = ImGui.GetCursorPosX(ctx)
  local columnX = 0
  for _, text in ipairs(RETUNE_LABELS) do
    local textW = ImGui.CalcTextSize(ctx, text)
    if textW > columnX then columnX = textW end
  end
  columnX = columnX + RETUNE_LABEL_GAP + ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
  local function labelled(text, draw)
    ImGui.AlignTextToFramePadding(ctx); ImGui.Text(ctx, text)
    ImGui.SameLine(ctx, columnX)
    draw()
  end

  for i, m in ipairs{ {'selection', 'Selection'}, {'all', 'Whole take'} } do
    if i > 1 then ImGui.SameLine(ctx) end
    if chrome.radio(m[2], s.scope == m[1]) then s.scope = m[1] end
  end

  -- No notation is no window to move inside, so the adaptive slots have nothing to
  -- say and the modal stands as the snap's two fields alone.
  if notation then
    -- Key rides the target's row: it is the target's own reading of the notation,
    -- and it is dead until one is chosen.
    labelled('Target:', function()
      chrome.drawPicker{
        kind        = 'retuneTarget', width = 90,
        buttonLabel = s.target or 'Off',
        items       = retuneTargetItems(s.target),
        onPick      = function(name) s.target = name end,
      }
      chrome.disabledIf(s.target == nil, function()
        -- The facility is a choice of its own beside the target.
        -- see docs/trackerView.md § Retune
        for _, f in ipairs{ {'points', 'Points'}, {'moves', 'Moves'} } do
          ImGui.SameLine(ctx)
          if chrome.radio(f[2], s.facility == f[1]) then s.facility = f[1] end
        end
        ImGui.SameLine(ctx); ImGui.AlignTextToFramePadding(ctx); ImGui.Text(ctx, 'Key:')
        ImGui.SameLine(ctx)
        -- A move set has no place on the pitch line, so there is no key to sit it on.
        chrome.disabledIf(s.facility == 'moves', function()
          chrome.drawPicker{
            kind        = 'retuneKey', width = 50,
            buttonLabel = stepLabel(notation, s.key),
            items       = retuneKeyItems(notation, s.key),
            onPick      = function(step) s.key = step end,
          }
        end)
      end)
    end)
    chrome.disabledIf(s.target == nil, function()
      labelled('Sonority size:', function()
        local rvN, size = chrome.numberStepper('retuneSonority', s.sonoritySize, { min = 2, max = 12 })
        if rvN then s.sonoritySize = size end
      end)
      -- Both dials are logarithmic, a doubling of one worth a halving of the other, and the
      -- lock's floor stops short of zero. see docs/sonority.md § The dials
      labelled('Harmonic lock:', function()
        ImGui.SetNextItemWidth(ctx, 150)
        local rvH, lock = ImGui.SliderDouble(ctx, '##harmonicLock', s.harmonicLock, 0.1, 10,
                                             '%.2f', ImGui.SliderFlags_Logarithmic)
        if rvH then s.harmonicLock = lock end
      end)
      -- Only the moves facility prices an interval against a spelling, a doubling of the dial
      -- halving the mistuning. see docs/sonority.md § The dials
      labelled('Purity:', function()
        chrome.disabledIf(s.facility ~= 'moves', function()
          ImGui.SetNextItemWidth(ctx, 150)
          local rvP, purity = ImGui.SliderDouble(ctx, '##purity', s.purity, 4, 256, '%.2f',
                                                 ImGui.SliderFlags_Logarithmic)
          if rvP then s.purity = purity end
        end)
      end)
      -- Only the moves facility has an ambient to share, a points solve resting a strand
      -- on its own step (docs/sonority.md § The dials).
      labelled('Ambient:', function()
        chrome.disabledIf(s.facility ~= 'moves', function()
          ImGui.SetNextItemWidth(ctx, 150)
          local rvA, ambient = ImGui.SliderDouble(ctx, '##ambient', s.ambient, 0, 1, '%.2f')
          if rvA then s.ambient = ambient end
        end)
      end)
    end)
  end

  labelled('Strength:', function()
    ImGui.SetNextItemWidth(ctx, 150)
    local rvS, strength = ImGui.SliderDouble(ctx, '##strength', s.strength, 0, 1, '%.2f')
    if rvS then s.strength = strength end
  end)

  local spacingX, padX = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing),
                         ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  local buttonsW      = ImGui.CalcTextSize(ctx, 'OK') + ImGui.CalcTextSize(ctx, 'Cancel')
                      + padX * 4 + spacingX
  ImGui.SetCursorPosX(ctx, originX + (ImGui.GetContentRegionAvail(ctx) - buttonsW) / 2)
  local okPressed     = ImGui.Button(ctx, 'OK')
  ImGui.SameLine(ctx)
  local cancelPressed = ImGui.Button(ctx, 'Cancel')
  -- A picker raised over the modal owns the frame, so these claims answer nil while one is
  -- up, and the Enter it consumes cannot commit the modal behind it.
  local mods          = keyQueue:frameMods()
  if okPressed or keyQueue:take(ImGui.Key_Enter, mods, 'modal')
               or keyQueue:take(ImGui.Key_KeypadEnter, mods, 'modal') then
    close(true, { scope        = s.scope,        strength     = s.strength,
                  target       = s.target,       key          = s.key,
                  facility     = s.facility,     purity       = s.purity,
                  sonoritySize = s.sonoritySize, harmonicLock = s.harmonicLock,
                  ambient      = s.ambient })
  elseif cancelPressed or keyQueue:take(ImGui.Key_Escape, mods, 'modal') then
    close(false)
  end
end)

-- A refused step's window widens to the nearest points on offer, not by default -- widening
-- relabels the cell. see docs/trackerView.md § Retune, design/adaptive-tuning.md § What the solver takes
local runRetune

local function offerWiden(slots, steps)
  local notation, names = tv:activeTemper(), {}
  for _, step in ipairs(steps) do util.add(names, stepLabel(notation, step)) end
  modalHost:openConfirm{
    title    = 'Retune',
    prompt   = ('%s has no point inside %s — widen the window and solve again? (y/n)')
               :format(slots.target, table.concat(names, ', ')),
    callback = function(widen) if widen then runRetune(slots, true) end end,
  }
end

-- The undo block wraps the callback, not the command: the opener does nothing undoable
-- and the edit lands frames later. see docs/trackerView.md § Retune
runRetune = util.atomic('Retune', function(slots, widen)
  local refused = tv:retune(slots, widen)
  if refused then offerWiden(slots, refused) end
end)

-- Target, facility and key open on what the take carries, the rest on its default.
-- see docs/trackerView.md § Retune
local function openRetuneModal()
  local notation = tv:activeTemper()
  local key      = cm:getAt('take', 'retune.key') or 1
  local facility = cm:getAt('take', 'retune.facility') or 'points'
  modalHost:open{
    kind         = 'retune',
    title        = 'Retune',
    scope        = tv:ec():hasSelection() and 'selection' or 'all',
    strength     = 1,
    target       = cm:getAt('take', 'retune.target'),
    facility     = facility,
    key          = notation and math.min(key, #notation.cents) or key,
    sonoritySize = 5,
    harmonicLock = RETUNE_LOCK,
    purity       = RETUNE_PURITY,
    ambient      = RETUNE_AMBIENT,
    callback     = runRetune,
  }
end

-- Naming convention <base>Selection / <base>All is the contract. The undo
-- label belongs on the tv verb, not here -- see docs/trackerView.md § Commands & wrappers.
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

-- The grid + lane render core. inputAllowed
-- folds focusState.acceptCmds so note entry self-suppresses under palette/strip focus.
local gridPane = util.instantiate('gridPane', {
  cm = cm, cmgr = cmgr, chrome = chrome, gui = gui, tv = tv, chordEntry = true,
  keyQueue = keyQueue,
  inputAllowed = function() return tr:focusState().acceptCmds end,
})

----- Note FX -- generator descriptors shared by the fx chain tab

-- A thin renderer over the generator registry: the fx list is an ordered series (C1), stages
-- reorderable/duplicable by position. see docs/generators.md § The chain
local FX_KINDS = generators.modalOrder

----- FX field descriptors (used by the fx strip)

local function choiceIndex(fd, value)
  for i, o in ipairs(fd.options) do if util.deepEq(o.v, value) then return i end end
  return 1
end
local function choiceLabels(fd)
  local out = {}; for i, o in ipairs(fd.options) do out[i] = o.l end; return out
end

-- stepInterval: stored value is signed cents, drawn as a step ladder over two
-- rows. see docs/trackerRender.md § An interval takes two rows
local function slideTemper() return tv:activeTemper() or tuning.presets['12EDO'] end

-- The strip's pattern-body fields (ostinato): a summary label + launch into the checkout editor,
-- which writes the edited body back through setFxField.
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
  -- A named wave opens the editor on its own seed body; the edit, not the opening, makes it the
  -- truth, so a stage flips to custom on first commit. see docs/trackerRender.md § FX chain — palette tab
  local stage = generators.customise(entry, tv:resolution())
  -- Stamp the field's label as a display-only header hint (readback strips it, so it never
  -- persists); deepClone keeps the stored body + its points array unmutated.
  local body = util.deepClone(stage[fd.field] or emptyBody(fd.kind))
  body.label = fd.label
  pe:launch(body, function(newBody)
    if stage == entry then return tv:setFxField(host, index, fd.field, newBody) end
    local edited = util.assign({}, stage)
    edited[fd.field] = newBody
    tv:replaceFxStage(host, index, edited)
  end, fd.poly)
end

-- The Dest row's picker: bare `CC 74` labels -- there is no controller-name table in the repo,
-- and pitch bend heads its own group so it reads as the one non-cc target.
local function destLabel(dest) return dest == 'pb' and 'Pitch Bend' or ('CC ' .. dest) end
local function destItems(entry)
  local current, items = generators.destOf(entry), {}
  for _, dest in ipairs(generators.destsFor(entry.kind)) do
    util.add(items, { label = destLabel(dest), key = dest,
                          group = dest == 'pb' and 1 or 2, current = dest == current })
  end
  return items
end

-- The option an arrow lands on, stepping over any marked `arrival` -- a state its stage reaches by
-- some other gesture (the LFO's Custom, which editing the curve sets). Nothing either side: stay put.
local function steppedOption(fd, value, right)
  local from, step = choiceIndex(fd, value), right and 1 or -1
  local i = from + step
  while fd.options[i] and fd.options[i].arrival do i = i + step end
  return fd.options[i] or fd.options[from]
end

-- Picking an option usually writes one field; one carrying `rewrite` restates the whole stage
-- instead, by the route the Dest picker takes. see docs/trackerRender.md § FX chain — palette tab
local function pickChoice(host, index, entry, fd, option)
  if not option.rewrite then return tv:setFxField(host, index, fd.field, option.v) end
  local stage = option.rewrite(entry, tv:resolution())   -- already in the picked state -> handed back as itself
  if stage ~= entry then tv:replaceFxStage(host, index, stage) end
end

-- Period rows: the ladder is a fast path, not a fence. see docs/trackerRender.md § A period is a fraction
local periodEdit       -- { id, buf } while a Period box holds the caret; nil otherwise
local periodFocusReq   -- id of the box the keyboard asked for, consumed by the next draw
local periodSwallow    -- one-shot: drop the strip's next key pass, so the Enter that closed a box isn't re-read as Enter on its row

local function rowId(row) return 'fx_' .. row.index .. '_' .. row.fd.field .. '_' .. row.part end

-- The tokenBox discipline (temperEditor): show the buffer while focused, commit on deactivate only
-- where the text parses. Unparsable input reverts next frame rather than clearing the field.
local function periodBox(host, row, width)
  local id    = rowId(row)
  local shown = (periodEdit and periodEdit.id == id) and periodEdit.buf
                or timing.formatPeriod(row.entry[row.fd.field])
  if periodFocusReq == id then ImGui.SetKeyboardFocusHere(ctx); periodFocusReq = nil end
  ImGui.SetNextItemWidth(ctx, width)
  local rv, buf = ImGui.InputText(ctx, '##' .. id, shown, ImGui.InputTextFlags_AutoSelectAll)
  -- Arm on activation, not on the first keystroke: a box reached and left untyped must still hold
  -- the strip's arrows, or Left/Right would step the ladder out from under the caret.
  if ImGui.IsItemActivated(ctx) then periodEdit = { id = id, buf = shown } end
  if rv and periodEdit then periodEdit.buf = buf end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) and periodEdit then
    local period = timing.parsePeriod(periodEdit.buf)
    if period then tv:setFxField(host, row.index, row.fd.field, period) end
  end
  if ImGui.IsItemDeactivated(ctx) then periodEdit, periodSwallow = nil, true end
end

-- Adjust rw's field one step: right increments, Ctrl coarse. The generic write both editors drive.
local function adjustRow(uuid, rw, right, mods)
  local fd, value = rw.fd, rw.entry[rw.fd.field]
  if fd.widget == 'dest' then          -- no scalar to nudge; arrowing opens the picker
    chrome.requestPickerOpen('fxDest_' .. rw.index)
  elseif fd.widget == 'choice' then
    pickChoice(uuid, rw.index, rw.entry, fd, steppedOption(fd, value, right))
  elseif fd.widget == 'period' then   -- by magnitude, so an off-ladder period steps from where it sits
    local coarse  = (mods & ImGui.Mod_Ctrl) ~= 0
    local stepped = timing.steppedPeriod(timing.periodLadder, value, right and 1 or -1, coarse)
    if stepped then tv:setFxField(uuid, rw.index, fd.field, stepped) end
  elseif fd.widget == 'stepInterval' then
    local temper = slideTemper()
    local note   = tv:noteByUuid(uuid)
    local dir    = right and 1 or -1
    local coarse = (mods & ImGui.Mod_Ctrl) ~= 0
    if rw.part == 'residual' then   -- the stored cents direct: past the half-gap the count follows
      tv:setFxField(uuid, rw.index, fd.field, (value or 0) + dir * (coarse and 10 or 1))
    else
      local steps, residual = tuning.stepLadder(temper, note, value or 0)
      tv:setFxField(uuid, rw.index, fd.field,
                    tuning.ladderCents(temper, note, steps + dir * (coarse and #temper.cents or 1), residual))
    end
  elseif fd.widget == 'pattern' then   -- no scalar to nudge; arrowing opens the editor
    launchPattern(uuid, rw.index, fd, rw.entry)
  else
    local step = (mods & ImGui.Mod_Ctrl) ~= 0 and fd.coarse or fd.base
    local min, max = generators.fieldRange(fd, generators.destOf(rw.entry))
    local n = util.clamp((value or 0) + (right and 1 or -1) * step, min, max)
    tv:setFxField(uuid, rw.index, fd.field, n)
  end
end

-- Value control for one strip row (dropdown / step ladder / number stepper); id keys ImGui per
-- row. width is the value column; stepper shrinks for -/+ buttons, choice dropdowns self-size.
local function fxFieldWidget(host, row, width)
  local fd, entry, index = row.fd, row.entry, row.index
  local value   = entry[fd.field]
  local id      = rowId(row)
  -- numberStepper's width sizes its input box only; its -/+ buttons add 2×(innerSpacing + frameH).
  local stepBoxW = width - 2 * (ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemInnerSpacing) + ImGui.GetFrameHeight(ctx))
  if fd.widget == 'dest' then
    -- A swap is a stage rewrite, not a field write: retarget carries the magnitudes across with it.
    chrome.drawPicker{
      kind = 'fxDest_' .. index, buttonLabel = destLabel(generators.destOf(entry)), width = width,
      items = destItems(entry),
      onPick = function(dest) tv:replaceFxStage(host, index, generators.retarget(entry, dest)) end,
    }
  elseif fd.widget == 'choice' then
    local pick = chrome.dropdown(id, fd.options[choiceIndex(fd, value)].l, choiceLabels(fd))
    if pick then pickChoice(host, index, entry, fd, fd.options[pick]) end
  elseif fd.widget == 'period' then
    periodBox(host, row, width)
  elseif fd.widget == 'stepInterval' then
    local temper = slideTemper()
    local note   = tv:noteByUuid(host)
    local steps, residual = tuning.stepLadder(temper, note, value or 0)
    if row.part == 'residual' then
      local rv, r = chrome.numberStepper(id, residual, { width = stepBoxW, format = '%+.0f' })
      if rv then tv:setFxField(host, index, fd.field, tuning.ladderCents(temper, note, steps, r)) end
    else
      local per   = #temper.cents
      local rv, n = chrome.numberStepper(id, steps, { width = stepBoxW, min = -2 * per, max = 2 * per })
      if rv then tv:setFxField(host, index, fd.field, tuning.ladderCents(temper, note, n, residual)) end
    end
  elseif fd.widget == 'pattern' then
    -- Summarise what the editor would open on -- for a named wave, the body it would be handed.
    local shown = patternSummary(generators.customise(entry, tv:resolution())[fd.field])
    if ImGui.Button(ctx, shown .. '##' .. id, width) then launchPattern(host, index, fd, entry) end
  else
    local min, max = generators.fieldRange(fd, generators.destOf(entry))
    local rv, n = chrome.numberStepper(id, value or 0, { width = stepBoxW, min = min, max = max })
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
      util.add(rows, { stage = si, param = 0 })
      for k = 1, #col.fields do util.add(rows, { stage = si, param = k }) end
    end
    return rows
  end
  local function rowIndexOf(rows, cur)
    for i, r in ipairs(rows) do if r.stage == cur.stage and r.param == cur.param then return i end end
    return 1
  end

  -- Columns: one per stage, holding its currently-visible fields (adding is the header picker).
  -- A step ladder is two rows over one field: the count, then the cents no count reaches.
  local function stripColumns(fx)
    local cols = {}
    for i, entry in ipairs(fx) do
      local fields = {}
      for _, fd in ipairs(generators.fieldsFor(entry)) do
        if not fd.when or fd.when(entry) then
          util.add(fields, { fd = fd, entry = entry, index = i, label = fd.label, part = 'steps' })
          if fd.widget == 'stepInterval' then
            util.add(fields, { fd = fd, entry = entry, index = i, label = 'Cents', part = 'residual' })
          end
        end
      end
      util.add(cols, { index = i, kind = entry.kind, bypass = entry.bypass,
                          label = generators.labelOf(entry.kind), fields = fields })
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
    util.add(cols, { isAdd = true, fields = {} })   -- terminal slot: arrow onto it, type/←→ opens the add picker
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
    if periodSwallow then periodSwallow = false; return end
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
      else                                                  -- field row: pattern opens its editor, a period takes the caret, plain values inert
        local rw = col.fields[cur.param]
        if     rw.fd.widget == 'pattern' then launchPattern(plan.host, rw.index, rw.fd, rw.entry)
        elseif rw.fd.widget == 'period'  then periodFocusReq = rowId(rw) end
      end
    elseif super and (up or down) and not col.isAdd then
      if tv:moveFxStage(plan.host, col.index, up and -1 or 1) then cur.stage = cur.stage + (up and -1 or 1) end
    elseif super and press(ImGui.Key_B) and not col.isAdd then   -- toggle bypass from any of the stage's rows (mirrors Super+↑/↓)
      tv:setFxBypass(plan.host, col.index, not col.bypass)
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

  -- clear and the conversions need no keyboard session, so they stay live regardless of focus; commit/cancel
  -- end the session, so they gate on strip focus (mouse parity for Super+X/Esc) — nothing to end unfocused.
  local function headerActions(plan)
    if ImGui.Button(ctx, 'clear') and plan.host then tv:setNoteFx(plan.host, util.REMOVE) end
    ImGui.SameLine(ctx, 0, 4)
    -- The pinned host is gone after either freeze, and stripPlan keeps a pinned session alive on a
    -- dead uuid (fx falls back to {}), so the vanished-host tidy at the sink never fires. Exit here.
    local mode = plan.host and tv:freezeMode(plan.host)
    chrome.disabledIf(not mode, function()
      if ImGui.Button(ctx, 'freeze') then
        tv:freezeRegion(plan.host)
        if stripHost == plan.host then stripExitReq = true end
      end
    end)
    ImGui.SameLine(ctx, 0, 4)
    chrome.disabledIf(mode ~= 'group', function()
      if ImGui.Button(ctx, 'to group') then
        tv:freezeToGroup(plan.host)
        if stripHost == plan.host then stripExitReq = true end
      end
    end)
    ImGui.SameLine(ctx, 0, 4)
    -- The third conversion, and the strip's own: live where the other two are dead, since freeze
    -- refuses a global region and explode refuses everything else.
    chrome.disabledIf(not (plan.host and tv:explodeEligible(plan.host)), function()
      if ImGui.Button(ctx, 'explode') then
        tv:explodeRegion(plan.host)
        if stripHost == plan.host then stripExitReq = true end
      end
    end)
    ImGui.SameLine(ctx, 0, 4)
    chrome.disabledIf(not stripFocus, function()
      if ImGui.Button(ctx, 'commit') then stripExitReq = true end
      ImGui.SameLine(ctx, 0, 4)
      if ImGui.Button(ctx, 'cancel') then cancelStrip() end
    end)
  end

  -- The catalogue's own row under the action row, both directions: `save` into whichever tier you
  -- pick, `load` back onto the host, minting one where `save` refuses to. See docs/trackerRender.md § FX chain.
  local function catalogueRow(plan)
    local fx      = plan.host and tv:noteFx(plan.host)
    local patches = chrome.tierPicker{ key = 'fxPatches' }
    -- Hostless, or a host standing empty: there is no chain to name. `add` is what mints one.
    chrome.disabledIf(not (fx and #fx > 0), function()
      chrome.drawPicker{
        kind = 'fxPatchSave', buttonLabel = 'save',
        items = patches, groups = chrome.tierGroups,
        onPick   = function(name, tier) tv:saveFxPatch(plan.host, tier, name) end,
        onCreate = function(name, tier) tv:saveFxPatch(plan.host, tier, name) end,
      }
    end)
    ImGui.SameLine(ctx, 0, 4)
    -- An empty catalogue offers nothing to load. No onCreate: you cannot create by loading; and no
    -- current: nothing names a patch once it has landed, so no row is the current one.
    chrome.disabledIf(#patches == 0, function()
      chrome.drawPicker{
        kind = 'fxPatchLoad', buttonLabel = 'load',
        items = patches, groups = chrome.tierGroups,
        -- Lazy mint, as the add row's own pick does: no host under the caret, materialise the
        -- selection's region now. The cursor then lands on the loaded chain's first stage.
        onPick = function(name, tier)
          local h = plan.host or tv:fxHostForEdit()
          if h then tv:loadFxPatch(h, tier, name); tv:setStripCursor{ stage = 1, param = 0 } end
        end,
        -- The catalogue's own housekeeping, on the rows: it touches neither host nor chain.
        onDelete = function(name, tier) tv:deleteFxPatch(tier, name) end,
      }
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
      util.add(items, { label = generators.labelOf(kind), key = kind, current = kind == currentKind })
    end
    return items
  end

  -- The add-stage picker, drawn as the chain's terminal row so the cursor can arrow onto it.
  local function drawAddChainStage(host, onCursor)
    rowHighlight(onCursor and stripFocus)
    chrome.drawPicker{
      kind = 'fxAdd', buttonLabel = 'add', flat = true, items = kindItems(),
      -- Lazy mint: the host under the caret wins; absent one (a bare selection), materialise its region now.
      onPick   = function(kind) local h = host or tv:fxHostForEdit(); if h then tv:addFxStage(h, generators.seed(kind)) end end,
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

  -- A bypassed stage dims its *labels* only. BeginDisabled would block the mouse while the keyboard
  -- path (adjustRow → tv:setFxField) sailed past it, and the A/B gesture wants the stage editable.
  local function withDim(dim, fn)
    if dim then ImGui.PushStyleColor(ctx, ImGui.Col_Text, chrome.colour('tracker.inactive')) end
    fn()
    if dim then ImGui.PopStyleColor(ctx, 1) end
  end

  -- Per-stage bypass, riding the header cluster beside `del`. Idle it inherits the row's text
  -- colour; lit it borrows the wiring page's bypass tint so the two bypasses read alike.
  local function drawBypassBadge(host, col)
    if col.bypass then ImGui.PushStyleColor(ctx, ImGui.Col_Text, chrome.colour('tracker.fx.bypassed')) end
    -- No clickToCursor: applies live without entering the session, like del/↑/↓ and value edits.
    if ImGui.Button(ctx, 'byp##fxbyp' .. col.index) then tv:setFxBypass(host, col.index, not col.bypass) end
    if col.bypass then ImGui.PopStyleColor(ctx, 1) end
  end

  -- One stage as tree rows: heading (swap-picker) with ↑/↓ reorder + del, then a field per row —
  -- label left, value column flush right. Cursor row highlights while the strip holds focus.
  local function drawChainStage(host, col, onStage, cur, isFirst, isLast)
    local btnSide = ImGui.GetFrameHeight(ctx)   -- square side for the ↑/↓ reorder buttons

    rowHighlight(onStage and cur.param == 0 and stripFocus)
    local headX, availW = ImGui.GetCursorPosX(ctx), select(1, ImGui.GetContentRegionAvail(ctx))
    withDim(col.bypass, function()
      chrome.drawPicker{
        kind = 'fxSwap_' .. col.index, buttonLabel = col.label, flat = true,
        -- Grow to fit the label, but stop short of the reorder cluster (which sits at availW - VALUE_W).
        minWidth = LABEL_W, maxWidth = availW - VALUE_W - LABEL_GAP,
        items = kindItems(col.kind),
        onPick = function(kind) tv:replaceFxStage(host, col.index, generators.seed(kind)) end,
      }
    end)
    -- No clickToCursor here: picking a kind applies live via onPick without grabbing strip focus (mirrors a value edit).
    ImGui.SameLine(ctx); ImGui.SetCursorPosX(ctx, headX + availW - VALUE_W)   -- ↑/↓/byp/del left-align with the value column
    chrome.disabledIf(isFirst, function()
      if ImGui.Button(ctx, '\xe2\x86\x91##fxup' .. col.index, btnSide, btnSide) then tv:moveFxStage(host, col.index, -1) end
    end)
    ImGui.SameLine(ctx, 0, BTN_GAP)
    chrome.disabledIf(isLast, function()
      if ImGui.Button(ctx, '\xe2\x86\x93##fxdn' .. col.index, btnSide, btnSide) then tv:moveFxStage(host, col.index, 1) end
    end)
    ImGui.SameLine(ctx, 0, DEL_GAP)
    drawBypassBadge(host, col)
    ImGui.SameLine(ctx, 0, BTN_GAP)
    if ImGui.Button(ctx, 'del##fxdel' .. col.index) then tv:removeFxStage(host, col.index) end

    for k, f in ipairs(col.fields) do
      ImGui.Indent(ctx, FIELD_INDENT)
      rowHighlight(onStage and cur.param == k and stripFocus)
      local labelX, rowW = ImGui.GetCursorPosX(ctx), select(1, ImGui.GetContentRegionAvail(ctx))
      ImGui.AlignTextToFramePadding(ctx)
      withDim(col.bypass, function() ImGui.Text(ctx, f.label) end)
      clickToCursor(host, col.index, k)
      ImGui.SameLine(ctx); ImGui.SetCursorPosX(ctx, labelX + rowW - VALUE_W)
      fxFieldWidget(host, f, VALUE_W)   -- edits apply live; a value edit never grabs strip focus
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
    catalogueRow(plan)
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

  -- Super+X enters the fx session (a selection mints its region, the caret pins); the session claims
  -- the fx tab so entry always lands keyboard focus there. Mouse entry is hostless (see stripPlan).
  function editFx()
    tv:overrideTab('fx', caretKeyNow())   -- claim the tab: the session outranks a parked parameters or a pinned map
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
      tv:newTakeBelow(nameBuf, b)
    end),
  }
end

modalHost:registerKind('newTake', function(s, close)
  ImGui.Text(ctx, 'Name')
  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  local rvN, nb = ImGui.InputText(ctx, '##newTakeName', s.nameBuf)
  if rvN then s.nameBuf = nb end
  ImGui.Text(ctx, 'Length (beats)')
  local rvB, bb = ImGui.InputText(ctx, '##newTakeBeats', s.beatsBuf)
  if rvB then s.beatsBuf = bb end
  local ok     = ImGui.Button(ctx, 'OK')
  ImGui.SameLine(ctx)
  local cancel = ImGui.Button(ctx, 'Cancel')
  local mods   = keyQueue:frameMods()
  if ok or keyQueue:take(ImGui.Key_Enter, mods, 'modal')
        or keyQueue:take(ImGui.Key_KeypadEnter, mods, 'modal') then
    close(true, s.nameBuf, s.beatsBuf)
  elseif cancel or keyQueue:take(ImGui.Key_Escape, mods, 'modal') then
    close(false)
  end
end)

-- Super-R toggles the parameters tab: park it over an auto-shown chain and land on the find box, or,
-- if already parked, drop the override back to the auto chain. Super-X (editFx) is the mirror, owning fx.
local function focusParams()
  if tv:tabOverride(caretKeyNow()) == 'parameters' then tv:clearTabOverride(); return end
  tv:overrideTab('parameters', caretKeyNow()); paletteFocus, focusFindReq = 'find', true
end

-- Ctrl+Delete forever-deletes the bound slot — every instance across the arrange and
-- the parked copy — so it stands behind a confirm, as the arrange page's does.
local function deleteBoundSlot()
  local trackIdx, slotIdx = tv:currentTrackIdx(), tv:currentSlotIdx()
  if not (trackIdx and slotIdx) then return end
  openConfirm('Delete take',
              util.atomic('Delete slot', function(yes)
                if yes then arrange().deleteSlot(trackIdx, slotIdx) end
              end),
              ('Delete take %s?\nRemoves every instance and discards the parked copy. (y/n)')
                :format(currentSlotLabel()))
end

local tracker = cmgr:scope('tracker')

tracker:registerAll{
  setRPB = function()
    openPrompt('Rows per beat', '1-32', function(buf)
      local n = tonumber(buf); if n then tv:setRowPerBeat(n) end
    end)
  end,

  takeProperties         = { function() tr:openTakeProperties() end, 'Take properties' },
  newTakeBelow           = { openNewTakeModal, 'New take' },
  duplicateBelow         = { function() tv:duplicateBelow() end, 'Duplicate take' },
  prevVariant            = { function() tv:stepVariant(-1) end, 'Previous variant' },
  nextVariant            = { function() tv:stepVariant(1)  end, 'Next variant' },
  deleteBoundSlot        = deleteBoundSlot,

  prevTrack    = { function() tv:gotoTrack(-1)    end, 'Previous track' },
  nextTrack    = { function() tv:gotoTrack(1)     end, 'Next track' },
  prevTake     = { function() tv:gotoTake(-1)     end, 'Previous take' },
  nextTake     = { function() tv:gotoTake(1)      end, 'Next take' },
  prevInstance = { function() tv:stepInstance(-1) end, 'Previous instance' },
  nextInstance = { function() tv:stepInstance(1)  end, 'Next instance' },
  deleteInstance = { function() tv:deleteInstance() end, 'Delete instance' },

  addNoteLane = { function() tv:addExtraCol('note') end, 'Add note lane' },
  addTypedCol = addColumn,
  hideExtraCol = removeOrHideCol,

  quantize             = scopedAction('quantize',               'quantize'),
  quantizeKeepRealised = scopedAction('quantize keep realised', 'quantizeKeepRealised'),

  retune = openRetuneModal,

  openTemperPicker = function() chrome.requestPickerOpen('temper') end,
  openSwingPicker  = function() chrome.requestPickerOpen('swing')  end,

  toggleLoopToItem = function() tv:setLoopToItem(not tv:loopsToItem()) end,
  loopToItemNow    = function() tv:bracketCurrentInstance() end,
  clearLoop        = function() tv:setLoopToItem(false) end,
  toggleFollowPlay = function() tv:setFollowPlay(not tv:followsPlay()) end,

  editNoteFx        = editFx,
  focusParamPalette = focusParams,
  pinMap            = function() tv:setMapPinned(not tv:mapPinned()) end,
}

cmgr:doAfter({ 'quantize', 'quantizeKeepRealised' },
             function() tv:ec():unstick() end)

-- Group quick-verb bodies + lifetime live on trackerView; install the
-- copy snapshot + clear-on-mutation sweep now that every tracker command
-- (incl. this page's) is registered.
tv:wireGroupLifetime()

---------- PUBLIC

----- Take properties modal helper

-- Shared by the tracker's takeProperties command and arrange's, which binds tm first.
-- see docs/trackerPage.md § Take properties
function tr:openTakeProperties()
  local rpb       = cm:get('rowPerBeat')
  local origBeats = (tv.grid.numRows or 0) / rpb
  local takeName  = tv:takeName() or ''
  modalHost:open{
    kind     = 'takeProps',
    title    = 'Take properties',
    nameBuf  = takeName,
    beatsBuf = ('%g'):format(origBeats),
    beatsGen = 0,
    mode     = 'resize',
    callback = function(name, beats, mode)
      if not beats or beats <= 0 then return end
      -- rescale is the monotone stretch — never deletes events.
      -- resize and tile both fall back to truncation when shrinking.
      if beats < origBeats and mode ~= 'rescale' then
        local txt = ('%g'):format(beats)
        openConfirm('Truncate take',
          function(yes)
            if yes then tv:applyTakeProperties{ name = name, beats = beats, mode = mode } end
          end,
          ('Truncate to %s beats? Events past beat %s will be deleted. (y/n)'):format(txt, txt))
      else
        tv:applyTakeProperties{ name = name, beats = beats, mode = mode }
      end
    end,
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
  help:anchor('body', g.originX, g.originY, ox + w - g.originX, g.height * g.cellH)

  drawParamPalette(ox + gridW, oy, h, caretKeyNow(), plan ~= nil, plan)
  tv:pollLearn(ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_AnyWindow))

  if not help:wasOpenAtFrameStart() then gridPane:handleMouse() end
  if stripFocus and ImGui.IsMouseClicked(ctx, 0) then   -- a click in the grid commits the strip and returns focus
    local mx, my = ImGui.GetMousePos(ctx)
    if mx >= ox and mx < ox + gridW and my >= oy and my < oy + h then stripExitReq = true end
  end
  if dispatch then dispatch(self:focusState()) end
  gridPane:handleKeys()
  if stripExitReq then   -- exit after this frame's dispatch saw us focused; prune a husk left empty
    if stripHost then tv:pruneEmptyRegion(stripHost) end
    stripFocus, stripExitReq, stripSnapshot, stripHost = false, false, nil, nil
  end

  tv:tick()
end

-- ctx and grid.cols are built together in tv:rebuild; an empty grid (no take
-- yet on script reopen) has no cursor to report, so the bar stays empty.
function tr:statusSegments()
  if #tv.grid.cols == 0 then return {} end
  return statusSegments
end

-- acceptCmds: no item active (toolbar focus is transient; see IsAnyItemActive), grid focus.
-- A modal, picker or status edit owns the queue instead -- docs/keyQueue.md § Ownership.
--shape: focusState = { pageSuppressed:bool, acceptCmds:bool }
function tr:focusState()
  if not ctx then return { pageSuppressed = false, acceptCmds = false } end
  return {
    pageSuppressed = false,   -- unused: swing/temper live on their own page
    acceptCmds     = not ImGui.IsAnyItemActive(ctx) and not paletteFocus and not stripFocus,
  }
end

return tr

