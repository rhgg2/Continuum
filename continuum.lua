-- See docs/continuum.md for the model.

--@map:invariant entry point — owns lifecycle (Main runs once per ReaScript invocation), wires the layered manager stack, drives the render loop via reaper.defer
--@map:invariant module load order is bottom-up: util first (everyone calls util.installHooks), commandManager before view layers (which self-register commands), pages last
--@map:invariant one MIDI item per session — Main binds to the take at startup; selection changes mid-session require re-invoking the action
--@map:invariant no teardown path — coord:quit() sets a flag that stops scheduling further defers; REAPER reclaims state on script unload
--@map:invariant errors inside the defer loop surface through the same xpcall frame because each iteration reschedules itself

function loadModule(module)
  local info = debug.getinfo(1,'S')
  local script_path = info.source:match[[^@?(.*[\/])[^\/]-$]]
  require(script_path .. module)
end

loadModule('util')
loadModule('configManager')
loadModule('midiManager')
loadModule('trackerManager')
loadModule('commandManager')
loadModule('editCursor')
loadModule('trackerView')
loadModule('sampleManager')
loadModule('sampleView')
loadModule('swingEditor')
loadModule('curveEditor')
loadModule('trackerPage')
loadModule('samplePage')

local ImGui = require 'imgui' '0.10'

math.randomseed(os.time())

local function print(...)
  return util.print(...)
end

local function err_handler(err)
  reaper.ShowConsoleMsg('\nERROR:\n' .. tostring(err) .. '\n\n')
  reaper.ShowConsoleMsg(debug.traceback() .. '\n')
  reaper.defer(function() end)
end

local function run(fn)
  reaper.ClearConsole()
  xpcall(fn, err_handler)
end

--@map:shape fileOps = { copy(src,dst)->bool, move(src,dst)->bool, mkdir(dir), exists(path)->bool, hash(path)->string }

-- 64KB chunks so big samples don't allocate a Lua string the size of the file.
local function copyFileBytes(src, dst)
  local fin = io.open(src, 'rb');  if not fin  then return false end
  local fout = io.open(dst, 'wb'); if not fout then fin:close(); return false end
  while true do
    local chunk = fin:read(64 * 1024)
    if not chunk then break end
    fout:write(chunk)
  end
  fin:close(); fout:close()
  return true
end

local fileOps = {
  copy  = copyFileBytes,
  -- os.rename fails across filesystems; fall back to copy+delete.
  move  = function(src, dst)
    if os.rename(src, dst) then return true end
    if copyFileBytes(src, dst) then os.remove(src); return true end
    return false
  end,
  mkdir  = function(dir) reaper.RecursiveCreateDirectory(dir, 0) end,
  exists = function(path) return fs.exists(path) end,
  hash   = function(path) return fs.hashFile(path) end,
}

local function createImGui()
  local ctx   = ImGui.CreateContext('Continuum Tracker')
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_ViewportsNoDecoration, 0)
  -- Body drags must not move the window — only title-bar drags do.
  -- Lane-strip and grid drags otherwise propagate as a window move.
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_WindowsMoveFromTitleBarOnly, 1)
  -- macOS' system font is private (dot-prefixed) and not reachable by
  -- family name, so load SFNS.ttf directly. Other platforms resolve by name.
  local osName = reaper.GetOS()
  local font   = ImGui.CreateFont('Source Code Pro')
  local uiFont = (osName:find('OSX') or osName:find('mac'))
               and ImGui.CreateFontFromFile('/System/Library/Fonts/SFNS.ttf')
               or  ImGui.CreateFont(osName:find('Win') and 'Segoe UI' or 'sans-serif')
  ImGui.Attach(ctx, font)
  ImGui.Attach(ctx, uiFont)
  return ctx, font, uiFont
end

----- Chrome

--@map:shape chrome = { colour(name)->u32, pushChromeStyles(), popChromeStyles(), pushChromeWindow(), popChromeWindow(), verticalSeparator(), disabledIf(cond,fn), checkbox(label,v), radio(label,active), makeToolbar()->fn(segments), drawPicker(d), pickerIsActive()->bool, resetPickerActive(), requestPickerOpen(kind) }
--@map:shape pickerSpec = { kind: string, heading: string, buttonLabel: string, items: [{label, key, group?=int, current?=bool}], onPick: fn(key), width?, minWidth?, maxWidth? }
--@map:contract one chrome instance per coordinator; threaded into every page
--@map:invariant colour cache lives on the chrome instance and is invalidated on cm:configChanged
local function newChrome(cm, ctx)
  local cache = {}
  cm:subscribe('configChanged', function() cache = {} end)

  --@map:contract walks colour aliases (see docs/configManager.md) to a terminal atom; outermost alpha override wins; cycles raise with the resolved chain
  local function resolve(key)
    local seen, override = {}, nil
    while true do
      if seen[key] then
        seen[#seen+1] = key
        error('colour cycle: ' .. table.concat(seen, ' → '))
      end
      seen[#seen+1] = key; seen[key] = true
      local v = cm:get(key)
      if v == nil then error('unknown colour: ' .. key) end
      if type(v) == 'string' then
        key = v
      elseif type(v[1]) == 'string' then
        key      = v[1]
        override = override or v[2]
      else
        return v[1], v[2], v[3], override or v[4]
      end
    end
  end

  local function colour(name)
    name = name or 'text'
    if not cache[name] then
      local r, g, b, a = resolve('colour.' .. name)
      cache[name] = ImGui.ColorConvertDouble4ToU32(r, g, b, a)
    end
    return cache[name]
  end

  local function pushChromeStyles()
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text,           colour('toolbar.text'))
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,         colour('toolbar.button'))
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered,  colour('toolbar.buttonHover'))
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,   colour('toolbar.buttonActive'))
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg,        colour('toolbar.button'))
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, colour('toolbar.buttonHover'))
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive,  colour('toolbar.buttonActive'))
    ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark,      colour('toolbar.checkMark'))
    ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,        colour('toolbar.popupBg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_Border,         colour('toolbar.buttonBorder'))
  end

  local function popChromeStyles()
    ImGui.PopStyleColor(ctx, 10)
    ImGui.PopStyleVar(ctx, 1)
  end

  -- Floating surfaces fill with editor.bg (opaque); toolbar.bg is 0.5 alpha and would bleed the grid through.
  local function pushChromeWindow()
    pushChromeStyles()
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowBorderSize, 1)
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg,         colour('editor.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,          colour('editor.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg,          colour('editor.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive,    colour('editor.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgCollapsed, colour('editor.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_Separator,        colour('toolbar.buttonBorder'))
  end

  local function popChromeWindow()
    ImGui.PopStyleColor(ctx, 6)
    ImGui.PopStyleVar(ctx, 1)
    popChromeStyles()
  end

  -- reaper-imgui has no Separator(Vertical); draw a 1px vertical line
  -- via the window draw list and reserve a Dummy slot so SameLine works.
  local function verticalSeparator()
    local x, y = ImGui.GetCursorScreenPos(ctx)
    local h    = ImGui.GetFrameHeight(ctx)
    ImGui.DrawList_AddLine(ImGui.GetWindowDrawList(ctx),
      x, y, x, y + h, colour('separator'), 1)
    ImGui.Dummy(ctx, 1, h)
  end

  -- RAII wrapper for ImGui.BeginDisabled / EndDisabled: dropping the
  -- bracket-match removes a class of mismatched-pop bugs on early return.
  local function disabledIf(cond, fn)
    if cond then ImGui.BeginDisabled(ctx) end
    fn()
    if cond then ImGui.EndDisabled(ctx) end
  end

  -- Compact checkbox / radio for toolbar contexts: zero FramePadding
  -- shrinks the box to its glyph; the +3 cursorY nudge re-aligns the
  -- small box with framed siblings on the same row.
  local function checkbox(label, value)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 0, 0)
    ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + 3)
    local changed, v = ImGui.Checkbox(ctx, label, value)
    ImGui.PopStyleVar(ctx, 1)
    return changed, v
  end

  local function radio(label, active)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 0, 0)
    ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + 3)
    local pressed = ImGui.RadioButton(ctx, label, active)
    ImGui.PopStyleVar(ctx, 1)
    return pressed
  end

  --@map:shape toolbarSegment = { id: string, render: fn, visible?: fn() -> bool }
  -- Wraps each segment in BeginGroup/EndGroup so GetItemRectMin/Max measures the whole
  -- segment. Caches last-frame width per id; if (lastEnd + sep + cached) overflows the
  -- row, the leading SameLine is skipped and ImGui wraps. One-frame slop on size change.
  local function makeToolbar()
    local widths = {}
    return function(segments)
      local startX = ImGui.GetCursorScreenPos(ctx)
      local availW = ImGui.GetContentRegionAvail(ctx)
      local rightX = startX + availW
      local lastEndX, first = startX, true
      for _, seg in ipairs(segments) do
        if not seg.visible or seg.visible() then
          local cachedW = widths[seg.id] or 0
          if not first then
            local sepW = 12 + 1 + 12
            if lastEndX + sepW + cachedW <= rightX then
              ImGui.SameLine(ctx, 0, 12)
              verticalSeparator()
              ImGui.SameLine(ctx, 0, 12)
            end
          end
          ImGui.BeginGroup(ctx)
          seg.render()
          ImGui.EndGroup(ctx)
          local minX = ImGui.GetItemRectMin(ctx)
          local maxX = ImGui.GetItemRectMax(ctx)
          widths[seg.id] = maxX - minX
          lastEndX, first = maxX, false
        end
      end
    end
  end

  ----- Picker (typeahead popup, shared across pages)

  -- Per-kind state; popups close on focus loss so a missing entry just
  -- means "default empty filter / cursor at top".
  local pickerFilter, pickerCursor = {}, {}
  local pickerOpenReq = nil   -- kind name; consumed by next drawPicker(kind)
  local pickerActive  = false -- frame-scoped: any picker popup live this frame

  local function requestPickerOpen(kind) pickerOpenReq = kind end
  local function pickerIsActive()        return pickerActive end
  local function resetPickerActive()     pickerActive = false end

  -- Generic typeahead picker. Enter picks the highlighted match; group
  -- separators show only when filter is empty.
  local function drawPicker(d)
    local popupId = '##picker_' .. d.kind

    -- Heading inherits the toolbar's outer Col_Text push; no inner push.
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, d.heading .. ':  ')
    ImGui.SameLine(ctx)

    -- ##d.kind disambiguates the ImGui ID — different pickers may all
    -- show the same buttonLabel once the heading is no longer in the ID.
    local btnTxt = d.buttonLabel .. ' \xe2\x96\xbe##' .. d.kind
    local minW, maxW = d.minWidth, d.maxWidth
    if d.width then minW, maxW = d.width, d.width end
    local btnW
    if minW or maxW then
      local tw  = ImGui.CalcTextSize(ctx, btnTxt)
      local fpx = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
      btnW = tw + fpx * 2
      if minW and btnW < minW then btnW = minW end
      if maxW and btnW > maxW then btnW = maxW end
    end
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_ButtonTextAlign, 0, 0.5)
    local opening
    if btnW then opening = ImGui.Button(ctx, btnTxt, btnW, 0)
    else         opening = ImGui.Button(ctx, btnTxt) end
    ImGui.PopStyleVar(ctx, 1)
    -- Anchor popup to the button rect; OpenPopup otherwise uses mouse
    -- position, putting a keyboard-triggered popup at the text cursor.
    local btnX = ImGui.GetItemRectMin(ctx)
    local _, btnY = ImGui.GetItemRectMax(ctx)
    if pickerOpenReq == d.kind then
      pickerOpenReq = nil
      opening = true
    end
    if opening then
      pickerFilter[d.kind] = ''
      ImGui.OpenPopup(ctx, popupId)
    end

    ImGui.SetNextWindowPos(ctx, btnX, btnY, ImGui.Cond_Appearing)
    -- NoNav: kill ImGui's built-in keyboard nav highlight on the popup —
    -- otherwise it draws a second cursor that fights ours and steals
    -- arrow keys / character input from the filter InputText.
    if not ImGui.BeginPopup(ctx, popupId, ImGui.WindowFlags_NoNav) then return end
    pickerActive = true   -- block page key dispatch this frame so Enter doesn't leak

    if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
    ImGui.SetNextItemWidth(ctx, 180)
    local prevFilter = pickerFilter[d.kind] or ''
    -- Plain InputText (no EnterReturnsTrue): with that flag, ReaImGui
    -- only commits the buffer on Enter, so the live filter would never
    -- update during typing. We watch Enter ourselves below.
    local _, filter = ImGui.InputText(ctx, '##filter_' .. d.kind, prevFilter)
    pickerFilter[d.kind] = filter
    local entered = ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
                 or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)
    ImGui.Separator(ctx)

    local lf = filter:lower()
    local matches, currentMatch = {}, nil
    for _, it in ipairs(d.items) do
      if filter == '' or it.label:lower():find(lf, 1, true) then
        matches[#matches + 1] = it
        if it.current then currentMatch = #matches end
      end
    end

    -- On open or filter-change, highlight the current pick if it survived; else top.
    if ImGui.IsWindowAppearing(ctx) or filter ~= prevFilter then
      pickerCursor[d.kind] = currentMatch or 1
    end
    local cursor = pickerCursor[d.kind] or 1
    local n = #matches
    if n > 0 then
      if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) then
        cursor = cursor % n + 1
      elseif ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow) then
        cursor = (cursor - 2) % n + 1
      end
    end
    cursor = math.min(math.max(cursor, 1), math.max(n, 1))
    pickerCursor[d.kind] = cursor

    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      ImGui.CloseCurrentPopup(ctx)
    elseif entered then
      if matches[cursor] then d.onPick(matches[cursor].key) end
      ImGui.CloseCurrentPopup(ctx)
    else
      local lastGroup
      for i, it in ipairs(matches) do
        if filter == '' and lastGroup and lastGroup ~= (it.group or 1) then
          ImGui.Separator(ctx)
        end
        if ImGui.Selectable(ctx, it.label, i == cursor) then d.onPick(it.key) end
        lastGroup = it.group or 1
      end
    end

    ImGui.EndPopup(ctx)
  end

  return {
    colour             = colour,
    pushChromeStyles   = pushChromeStyles,
    popChromeStyles    = popChromeStyles,
    pushChromeWindow   = pushChromeWindow,
    popChromeWindow    = popChromeWindow,
    verticalSeparator  = verticalSeparator,
    disabledIf         = disabledIf,
    checkbox           = checkbox,
    radio              = radio,
    makeToolbar        = makeToolbar,
    drawPicker         = drawPicker,
    pickerIsActive     = pickerIsActive,
    resetPickerActive  = resetPickerActive,
    requestPickerOpen  = requestPickerOpen,
  }
end

----- Keyboard router

--@map:shape dispatchResult = { consumed: bool, commandHeld: bool }
--@map:contract returns early (no dispatch) when state.suppressKbd or not state.acceptCmds
--@map:contract first-hit wins across the keychain; a command returning false declines and releases the key (clearing commandHeld) so the page char queue sees it
local function dispatchKeys(state, cmgr, ctx)
  if state.suppressKbd or not state.acceptCmds then
    return { consumed = false, commandHeld = false }
  end
  local commandHeld = false
  for _, keymap in ipairs(cmgr:keychain()) do
    for command, keys in pairs(keymap) do
      for _, spec in ipairs(keys) do
        local key, mods = cmgr:keySpec(spec, ImGui)
        if ImGui.IsKeyDown(ctx, key) and mods == ImGui.Mod_None then
          commandHeld = true
        end
        if ImGui.IsKeyPressed(ctx, key) and ImGui.GetKeyMods(ctx) == mods then
          if cmgr:invoke(command) == false then
            commandHeld = false
          else
            return { consumed = true, commandHeld = commandHeld }
          end
        end
      end
    end
  end
  return { consumed = false, commandHeld = commandHeld }
end

----- Coordinator

local CHROME_PAD_X, CHROME_PAD_Y = 8, 4

--@map:shape page = { renderToolbarBits(ctx), renderBody(ctx,w,h,dispatch), renderStatusBar(ctx), bind(...), unbind(), [renderFloating(ctx)] }
--@map:contract pages must be registered via coord:register(name,page); first registered becomes active
--@map:contract setActive(name) is a no-op when name == active; otherwise unbinds the outgoing page, swaps cmgr scope, and binds the incoming page (tracker→take, sample→track)
--@map:contract tick() runs once per frame before the page draws; setPrefix is republished only when the project path changes (one mailbox cell shared across instances)
local function newCoordinator(cm, cmgr, sm, take, ctx, font, uiFont)
  local pages, active = {}, nil
  local quitting = false
  local lastProjectPath = nil
  local chrome = newChrome(cm, ctx)

  local function tick()
    sm:probeMode(take, cm)
    local pp = reaper.GetProjectPath(0)
    if lastProjectPath ~= pp then
      sm:setPrefix(pp)
      if lastProjectPath then sm:migrate(pp, lastProjectPath, cm) end
    end
    sm:tick(cm)
    lastProjectPath = pp
  end

  local function drawSwitcher()
    local function pageButton(label, name)
      local isActive = active == name
      if isActive then
        ImGui.PushStyleColor(ctx, ImGui.Col_Button, chrome.colour('toolbar.buttonActive'))
      end
      if ImGui.Button(ctx, label) and not isActive then
        cmgr:invoke('switchPage', name)
      end
      if isActive then ImGui.PopStyleColor(ctx, 1) end
    end
    pageButton('Tracker', 'tracker')
    ImGui.SameLine(ctx, 0, 4)
    pageButton('Sample',  'sample')
  end

  local function dispatch(state) return dispatchKeys(state, cmgr, ctx) end

  local function frame()
    tick()
    local page = pages[active]

    ImGui.PushFont(ctx, uiFont, 13)
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg,     chrome.colour('bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg,      chrome.colour('toolbar.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive,chrome.colour('toolbar.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarBg,  chrome.colour('scrollBg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrab,chrome.colour('scrollHandle'))

    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 0, 0)
    local visible, open = ImGui.Begin(ctx, 'Continuum', true,
      ImGui.WindowFlags_NoScrollbar
      | ImGui.WindowFlags_NoScrollWithMouse
      | ImGui.WindowFlags_NoDocking
      | ImGui.WindowFlags_NoNav
      | ImGui.WindowFlags_NoMove)
    ImGui.PopStyleVar(ctx)
    -- Active-item drags (e.g. the lane strip's curve editor) can otherwise
    -- accumulate auto-scroll on the parent window, pushing the grid below
    -- the visible region for the duration of the drag.
    if visible then ImGui.SetScrollY(ctx, 0); ImGui.SetScrollX(ctx, 0) end

    if visible and page then
      -- Toolbar band
      ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, chrome.colour('toolbar.bg'))
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, CHROME_PAD_X, CHROME_PAD_Y)
      if ImGui.BeginChild(ctx, '##toolbar', 0, 0,
                          ImGui.ChildFlags_AutoResizeY | ImGui.ChildFlags_AlwaysUseWindowPadding,
                          ImGui.WindowFlags_NoScrollbar) then
        chrome.pushChromeStyles()
        ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 10, 3)
        drawSwitcher()
        ImGui.SameLine(ctx, 0, 12)
        chrome.verticalSeparator()
        ImGui.SameLine(ctx, 0, 12)
        page:renderToolbarBits(ctx)
        ImGui.PopStyleVar(ctx, 1)
        chrome.popChromeStyles()
      end
      ImGui.EndChild(ctx)
      ImGui.PopStyleVar(ctx)
      ImGui.PopStyleColor(ctx)

      -- Body region: reserve a fixed footer for the status bar; the
      -- page paints into the remaining viewport at (CHROME_PAD_X,
      -- toolbarBottom + CHROME_PAD_Y).
      local cursorY     = ImGui.GetCursorPosY(ctx)
      local availW0, availH = ImGui.GetContentRegionAvail(ctx)
      local footerH     = ImGui.GetFrameHeightWithSpacing(ctx) + 4
      local bodyH       = availH - footerH

      ImGui.Indent(ctx, CHROME_PAD_X)
      ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + CHROME_PAD_Y)
      page:renderBody(ctx,
        availW0 - CHROME_PAD_X * 2,
        bodyH   - CHROME_PAD_Y,
        dispatch)
      ImGui.Unindent(ctx, CHROME_PAD_X)

      -- Status band pinned to (toolbarBottom + bodyH); the parchment
      -- gap above is the leftover.
      ImGui.SetCursorPosY(ctx, cursorY + bodyH)
      ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, chrome.colour('statusBar.bg'))
      ImGui.PushStyleColor(ctx, ImGui.Col_Text,    chrome.colour('statusBar.text'))
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, CHROME_PAD_X + 4, CHROME_PAD_Y)
      if ImGui.BeginChild(ctx, '##statusBar', 0, footerH,
                          ImGui.ChildFlags_AlwaysUseWindowPadding,
                          ImGui.WindowFlags_NoScrollbar) then
        page:renderStatusBar(ctx)
      end
      ImGui.EndChild(ctx)
      ImGui.PopStyleVar(ctx)
      ImGui.PopStyleColor(ctx, 2)
    elseif visible then
      ImGui.Text(ctx, 'Select a MIDI item to begin.')
    end

    ImGui.End(ctx)

    if page and page.renderFloating then page:renderFloating(ctx) end

    ImGui.PopStyleColor(ctx, 5)
    ImGui.PopFont(ctx)

    if open and not quitting then reaper.defer(frame) end
  end

  ----- Public

  local self = {}

  function self:register(name, page)
    pages[name] = page
    if not active then self:setActive(name) end
  end

  function self:setActive(name)
    if active == name then return end
    if active and pages[active] then pages[active]:unbind() end
    active = name
    cmgr:setActive(name)
    if name == 'tracker' then
      pages.tracker:bind(take)
    elseif name == 'sample' then
      pages.sample:bind(reaper.GetMediaItemTake_Track(take))
    end
  end

  function self:togglePage()
    self:setActive(active == 'tracker' and 'sample' or 'tracker')
  end

  function self:quit() quitting = true end

  function self:chrome() return chrome end

  function self:run() frame() end

  return self
end

--@map:contract Main bails with a console message if no MIDI item is selected; otherwise builds the manager stack bottom-up, then enters the defer loop via coord:run()
local function Main()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    reaper.ShowConsoleMsg('Please select a MIDI item.\n')
    return
  end

  local take = reaper.GetActiveTake(item)
  local mm   = newMidiManager(take)
  local cm   = newConfigManager()
  cm:setContext(take)
  local tm   = newTrackerManager(mm, cm)
  local cmgr = newCommandManager(cm)
  local vm   = newTrackerView(tm, cm, cmgr)
  local sm   = newSampleManager(fileOps)

  local sv
  sv = newSampleView(cm,
    function(slot, srcPath)
      return sm:assign(sv:getTrack(), slot, srcPath, reaper.GetProjectPath(0), cm)
    end,
    function(slot, bounds) return sm:previewSlot(sv:getTrack(), slot, bounds) end,
    function(path)         return sm:previewPath(sv:getTrack(), path)         end,
    function()             return sm:listTracks()                             end,
    function(slot)         return sm:clearSlot(sv:getTrack(), slot, cm)       end,
    function()             return sm:stopPreview(sv:getTrack())               end)

  local ctx, font, uiFont = createImGui()
  local coord = newCoordinator(cm, cmgr, sm, take, ctx, font, uiFont)

  cmgr:scope('tracker'):register('loadSampleAtCurrentSlot', function()
    if not cm:get('trackerMode') then return end
    local rv, path = reaper.GetUserFileNameForRead('', 'Load sample into current slot', '')
    if rv and path ~= '' then
      sm:assign(reaper.GetMediaItemTake_Track(take),
                cm:get('currentSample'), path, reaper.GetProjectPath(0), cm)
    end
  end)

  -- Globals: transport wrappers, page switching, quit. Bound on root
  -- so any page picks them up unchanged.
  cmgr:registerAll{
    play       = function() reaper.Main_OnCommand(1007,  0) end,
    playPause  = function() reaper.Main_OnCommand(40073, 0) end,
    stop       = function() reaper.Main_OnCommand(1016,  0) end,
    switchPage = function(name) coord:setActive(name)      end,
    togglePage = function()     coord:togglePage()         end,
    quit       = function()     coord:quit()               end,
  }
  cmgr:bindAll{
    playPause  = { ImGui.Key_Space },
    stop       = { ImGui.Key_F8    },
    togglePage = { {ImGui.Key_Tab, ImGui.Mod_Super} },
    quit       = { ImGui.Key_Enter },
  }

  coord:register('tracker', newTrackerPage(vm, cm, cmgr, coord:chrome(), ctx, font, uiFont))
  coord:register('sample',  newSamplePage (sv, sm, cm, cmgr, coord:chrome(), ctx, uiFont))
  coord:run()
end

run(Main)
